import Foundation

/// A session command another app sends by opening an `insomnia://` URL
/// (`open "insomnia://start?hours=2"`, a Raycast or Shortcuts action). Each
/// one does what the matching menu bar gesture does and nothing more:
///
///     insomnia://start                       the default preset, like bare Enter
///     insomnia://start?days=1&hours=2&minutes=30
///     insomnia://extend?minutes=30           add time to the running session
///     insomnia://end                         end the session, like hold-to-end
///
/// `days`, `hours` and `minutes` are whole numbers from 0 to `maxField`, each
/// at most once, summed; any of them may be left out, and `minutes=90` is
/// fine. `extend` needs a total above zero, and so does `start` when it names
/// any field. The manager clamps the result to `config.maxDuration` as it does
/// for the pills. Anything else (another host, an unknown or repeated
/// parameter, a sign, a fraction, a path, a parameter on `end`) is refused
/// whole rather than half-read, so a mistyped URL never runs a guess.
enum URLCommand: Equatable, Sendable {
    /// Start a session. nil means the default preset.
    case start(TimeInterval?)
    case extend(TimeInterval)
    case end

    static let scheme = "insomnia"
    /// Per-field ceiling: far above any session `maxDuration` allows, low
    /// enough that the sum cannot overflow or lose whole seconds.
    static let maxField = 100_000

    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.fragment == nil,
              let host = parts.host?.lowercased()
        else { return nil }
        let items = parts.queryItems ?? []
        switch host {
        case "end":
            return items.isEmpty ? .end : nil
        case "start":
            if items.isEmpty { return .start(nil) }
            return duration(items).map { .start($0) }
        case "extend":
            return duration(items).map { .extend($0) }
        default:
            return nil
        }
    }

    private static let unitSeconds: [String: TimeInterval] = [
        "days": 86_400,
        "hours": 3_600,
        "minutes": 60,
    ]

    /// Total seconds the items name, or nil if any item is unusable or the
    /// total is zero.
    private static func duration(_ items: [URLQueryItem]) -> TimeInterval? {
        var seen = Set<String>()
        var total: TimeInterval = 0
        for item in items {
            guard let unit = unitSeconds[item.name], seen.insert(item.name).inserted,
                  let text = item.value, !text.isEmpty, text.count <= 6,
                  text.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(text), value <= maxField
            else { return nil }
            total += TimeInterval(value) * unit
        }
        return total > 0 ? total : nil
    }
}
