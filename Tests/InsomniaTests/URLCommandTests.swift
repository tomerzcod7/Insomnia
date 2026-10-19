import XCTest
@testable import Insomnia

final class URLCommandTests: XCTestCase {
    private func parse(_ text: String) -> URLCommand? {
        URLCommand.parse(URL(string: text)!)
    }

    func testStartWithoutFieldsUsesTheDefaultPreset() {
        XCTAssertEqual(parse("insomnia://start"), .start(nil))
        XCTAssertEqual(parse("insomnia://start/"), .start(nil))
    }

    func testStartSumsFields() {
        XCTAssertEqual(parse("insomnia://start?days=1&hours=2&minutes=30"), .start(86_400 + 7_200 + 1_800))
        XCTAssertEqual(parse("insomnia://start?minutes=90"), .start(5_400))
        XCTAssertEqual(parse("insomnia://start?hours=0&minutes=1"), .start(60))
    }

    func testExtendNeedsADuration() {
        XCTAssertEqual(parse("insomnia://extend?minutes=30"), .extend(1_800))
        XCTAssertNil(parse("insomnia://extend"))
        XCTAssertNil(parse("insomnia://extend?minutes=0"))
    }

    func testEnd() {
        XCTAssertEqual(parse("insomnia://end"), .end)
        XCTAssertNil(parse("insomnia://end?minutes=5"))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(parse("INSOMNIA://END"), .end)
        XCTAssertEqual(parse("Insomnia://Start?hours=1"), .start(3_600))
    }

    func testRefusesAnythingElseWhole() {
        for text in [
            "https://start?hours=1",
            "insomnia://stop",
            "insomnia:start",
            "insomnia://start?hours=1&hours=2",
            "insomnia://start?weeks=1",
            "insomnia://start?seconds=30",
            "insomnia://start?hours=0",
            "insomnia://start?hours=",
            "insomnia://start?hours",
            "insomnia://start?hours=-1",
            "insomnia://start?hours=%2B1",
            "insomnia://start?hours=1.5",
            "insomnia://start?hours=1e3",
            "insomnia://start?hours=%D9%A1",
            "insomnia://start?hours=100001",
            "insomnia://start?hours=99999999999999999999",
            "insomnia://start/now?hours=1",
            "insomnia://start?hours=1#x",
            "insomnia://user@start?hours=1",
            "insomnia://start:80?hours=1",
        ] {
            XCTAssertNil(parse(text), text)
        }
    }

    func testFieldCeilingIsAccepted() {
        XCTAssertEqual(parse("insomnia://start?days=100000"), .start(100_000 * 86_400))
    }

    func testBundleRegistersTheScheme() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [URLCommand.scheme])
    }
}
