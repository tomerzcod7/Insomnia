import AppKit
import SwiftUI

/// Menu bar app. The status item is an `NSStatusItem` hosting SwiftUI, and
/// the settings window is an `NSWindow` this app opens itself (see
/// `SettingsWindow`), so there is no SwiftUI scene with any content in it.
/// `App` still requires one, hence the empty `Settings`. main.swift starts
/// this app unless the command line asks for a one-shot mode first.
struct InsomniaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: SessionManager
    let status: any StatusSource
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    let loginItem = LoginItem()
    let releases = ReleaseChecker()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var terminating = false
    /// `insomnia://` commands that arrived before the launch reconcile
    /// finished, in arrival order (see `URLCommand`).
    private var queuedURLCommands: [URLCommand] = []
    private var urlCommandsReady = false
    private var runningURLCommands = false

    override init() {
        let manager = SessionManager.live()
        self.manager = manager
        secrets = KeychainHotspotSecretStore(keychain: KeychainStore()) {
            manager.config.hotspotSSID
        }
        if let services = manager.services {
            status = LiveStatusSource(services: services)
            locationPermission = services.locationPermission
        } else {
            Log.error("live SessionManager has no AppServices; using placeholder status")
            status = PlaceholderStatus()
            locationPermission = LocationPermission()
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the first notification already shows
        // while Insomnia is frontmost.
        ForegroundNotifications.install()
        // Before launch finishes too: a URL that launched the app is
        // delivered as the first event after it. A handler of our own, not
        // `application(_:open:)`, so SwiftUI's scene routing cannot claim it.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched, version \(AppBuild.current.label)")
        if LidSimulationBuild.isCompiledIn {
            Log.info(LidSimulationBuild.marker)
        }
        // The login item is tied to the bundle's signature, which install.sh
        // renews on every run: register again if the flag is on, macOS no
        // longer reports the item and the install changed; follow the user
        // if they removed the item for the install macOS had on file.
        var config = manager.config
        if loginItem.healAtLaunch(config: &config) {
            manager.config = config
            do {
                try manager.store.saveConfig(config)
            } catch {
                Log.error("could not save config after the launch at login check: \(error.localizedDescription)")
            }
        }
        let settings = SettingsWindow { [manager, secrets, locationPermission, loginItem, releases] in
            AnyView(
                SettingsView(
                    manager: manager,
                    secrets: secrets,
                    locationPermission: locationPermission,
                    loginItem: loginItem,
                    releases: releases
                )
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status) { [weak settings] in
            settings?.show()
        }
        Task {
            await manager.reconcile()
            // A command that starts or extends before the launch reconcile
            // has undone a stale journal would act on the wrong state.
            urlCommandsReady = true
            runURLCommands()
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text)
        else {
            Log.error("url command ignored: no URL in the event")
            return
        }
        guard let command = URLCommand.parse(url) else {
            Log.error("url command ignored: not one Insomnia understands")
            return
        }
        Log.info("url command received: \(command)")
        queuedURLCommands.append(command)
        runURLCommands()
    }

    /// Runs queued URL commands one at a time, in order, once the launch
    /// reconcile is done. Each goes through the same manager call as its
    /// menu bar gesture, so the status item follows along by itself.
    private func runURLCommands() {
        guard urlCommandsReady, !runningURLCommands, !terminating else { return }
        runningURLCommands = true
        Task {
            while !queuedURLCommands.isEmpty, !terminating {
                let command = queuedURLCommands.removeFirst()
                switch command {
                case let .start(duration):
                    let preset = manager.config.defaultPreset
                    guard let seconds = duration ?? (preset > 0 ? preset : nil) else {
                        Log.error("url start ignored: no duration and no default preset")
                        continue
                    }
                    await manager.start(duration: seconds)
                case let .extend(seconds):
                    if manager.isActive {
                        await manager.extend(by: seconds)
                    } else {
                        Log.info("url extend ignored: no session running")
                    }
                case .end:
                    if manager.isActive {
                        await manager.end(reason: .user)
                    } else {
                        Log.info("url end ignored: no session running")
                    }
                }
            }
            runningURLCommands = false
        }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// the end has run. A second quit while that is pending is refused rather
    /// than allowed through: `.terminateNow` there would exit mid-cleanup.
    /// If the end could not run (recovery lock busy, journal unreadable),
    /// left the journal dirty with no agent to retry, or could not remove
    /// session.json, the app stays so its own retry can finish the job;
    /// quitting then would abandon a live session. It also stays while a
    /// `sudo pmset` that ignored SIGTERM is alive. The recovery lock would
    /// outlive a quit (the command holds it through its own descriptor),
    /// but the end the command holds up would not: the app is what retries
    /// it, and confirms an undo the command finishes, the moment it exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let outcome = await manager.end(reason: .quit)
            if outcome.letsQuitGo {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                Log.error("quit deferred: recovery still pending (\(outcome)); staying to retry")
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
