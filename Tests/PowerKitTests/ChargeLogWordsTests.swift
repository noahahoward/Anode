import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The charge log is read by a person. A reason for a limit used to be written as the enum's own raw value, so a line
/// read "limit 80 -> 100 (fullCharge)"; it is written in words now, and the stored values did not change.
final class ChargeLogWordsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: Settings!
    private var client: FakeChargeLimitClient!
    private var helper: FakeHelperLink!
    private var battery: Battery.State?
    private var lines: [String] = []
    private var controller: ChargeController?
    private var clockNow = ISO8601DateFormatter().date(from: "2026-11-12T23:00:00Z")!

    override func setUpWithError() throws {
        (defaults, suite) = try TestDefaults.make(owner: "ChargeLogWords", test: name)
        settings = Settings(defaults: defaults)
        client = FakeChargeLimitClient()
        helper = FakeHelperLink()
        helper.landsOn = client
        battery = ReadyByControllerTests.plugged(70)
        lines = []
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        settings = nil
        TestDefaults.destroy(defaults, suite)
    }

    @discardableResult
    private func make() -> ChargeController {
        settings.chargeControlEnabled = true
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = ChargeController(settings: settings, makeClient: { [weak self] in self?.client }, helper: helper,
                                 battery: { [weak self] in self?.battery }, chargerSwitch: { nil },
                                 log: { [weak self] in self?.lines.append($0) },
                                 noClientBecause: { ChargeController.NoClientReason(unsupportedMac: true, step: nil) },
                                 onConsole: { true }, rateStore: MemoryRateStore(),
                                 now: { [weak self] in self?.clockNow ?? Date() }, calendar: { utc })
        controller = c
        return c
    }

    // ── The words ───────────────────────────────────────────────────────────

    func testEveryReasonHasPlainWords() {
        let all: [ChargeReason] = [.limit, .fullCharge, .heat, .sleeping, .drift, .draining, .drained, .readyBy]
        XCTAssertEqual(ChargeController.logWords(.limit), "limit")
        XCTAssertEqual(ChargeController.logWords(.fullCharge), "charge to full")
        XCTAssertEqual(ChargeController.logWords(.heat), "pause when hot")
        XCTAssertEqual(ChargeController.logWords(.sleeping), "hold during sleep")
        XCTAssertEqual(ChargeController.logWords(.drift), "drift")
        XCTAssertEqual(ChargeController.logWords(.draining), "draining")
        XCTAssertEqual(ChargeController.logWords(.drained), "drained")
        XCTAssertEqual(ChargeController.logWords(.readyBy), "ready by")
        for r in all {
            let words = ChargeController.logWords(r)
            XCTAssertEqual(words, words.lowercased(), "\(r) is not plain lower-case words: \(words)")
            XCTAssertFalse(words.isEmpty)
            XCTAssertNil(words.range(of: #"[a-z][A-Z]"#, options: .regularExpression), words)
        }
    }

    /// Nothing stored changed: the raw values are what they were.
    func testTheRawValuesAreWhatTheyWere() {
        XCTAssertEqual(ChargeReason.fullCharge.rawValue, "fullCharge")
        XCTAssertEqual(ChargeReason.heat.rawValue, "heat")
        XCTAssertEqual(ChargeReason.sleeping.rawValue, "sleeping")
        XCTAssertEqual(ChargeReason.readyBy.rawValue, "readyBy")
    }

    // ── The log ─────────────────────────────────────────────────────────────

    func testChargeToFullIsLoggedInWords() {
        let c = make()
        c.pressFullCharge()
        XCTAssertTrue(lines.contains("limit 80 -> 100 (charge to full)"), lines.joined(separator: "\n"))
    }

    func testPauseWhenHotIsLoggedInWords() {
        settings.chargePauseWhenHotEnabled = true
        battery = ReadyByControllerTests.plugged(60)
        battery?.temperature_C = 40
        make()
        XCTAssertTrue(lines.contains("limit set to 60 (pause when hot)"), lines.joined(separator: "\n"))
    }

    func testHoldLevelDuringSleepIsLoggedInWords() {
        settings.chargeHoldDuringSleep = true
        battery = ReadyByControllerTests.plugged(66)
        let c = make()
        c.willSleep()
        XCTAssertTrue(lines.contains("limit 80 -> 66 (hold during sleep)"), lines.joined(separator: "\n"))
    }

    func testDriftIsLoggedInWords() {
        settings.chargeLimit = 88
        settings.chargeDriftEnabled = true
        battery = ReadyByControllerTests.plugged(88)
        let c = make()
        battery = ReadyByControllerTests.plugged(86)
        c.tick()
        XCTAssertTrue(lines.contains("limit 88 -> 86 (drift)"), lines.joined(separator: "\n"))
    }

    func testReadyByIsLoggedInWords() {
        settings.chargeReadyByEnabled = true
        battery = ReadyByControllerTests.plugged(54)
        make()
        XCTAssertTrue(lines.contains("limit set to 54 (ready by)"), lines.joined(separator: "\n"))
    }

    func testTheLimitAndAClientValueNeedingTheHelperAreLoggedInWords() {
        settings.chargeLimit = 63
        make()
        XCTAssertTrue(lines.contains("limit set to 63 (limit)"), lines.joined(separator: "\n"))
        settings.chargeLimit = 85
        XCTAssertTrue(lines.contains("limit 63 -> 85 (limit)"), lines.joined(separator: "\n"))
    }

    /// A drain's lines name why in words as well.
    func testADrainIsStoppedInWords() {
        battery = ReadyByControllerTests.plugged(90)
        let c = make()
        c.pressDrain()
        c.pressDrain()
        XCTAssertFalse(lines.contains { $0.range(of: #"\([a-z]+[A-Z]\w*\)"#, options: .regularExpression) != nil },
                       lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("drain to ") && $0.contains(" stopped (") }, lines.joined(separator: "\n"))
    }

    /// Whatever it does, the log has no camelCase word in brackets.
    func testNoLineKeepsACamelCaseReason() {
        settings.chargeReadyByEnabled = true
        settings.chargePauseWhenHotEnabled = true
        settings.chargeHoldDuringSleep = true
        battery = ReadyByControllerTests.plugged(54)
        let c = make()
        c.pressFullCharge()
        c.pressFullCharge()
        c.willSleep()
        c.didWake()
        battery?.temperature_C = 42
        c.tick()
        for line in lines {
            XCTAssertNil(line.range(of: #"\([a-z]+[A-Z]\w*\)"#, options: .regularExpression), line)
        }
        XCTAssertFalse(lines.isEmpty)
    }
}
