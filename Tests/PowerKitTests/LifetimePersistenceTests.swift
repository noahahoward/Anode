import XCTest
@testable import PowerKit

// The lifetime model is only worth anything if it outlives the process: crashes,
// force-quits, reboots, a pack run flat. And it must refuse to be someone else's —
// Migration Assistant copies Application Support to a different Mac wholesale.
final class LifetimePersistenceTests: XCTestCase {

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("lifetime-drain.json") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func learned() -> LifetimeDrainModel {
        var m = LifetimeDrainModel(machineModel: "Mac17,9", designCapacity_mAh: 6251, osBuild: "26A428")
        var awake: TimeInterval = 1000
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let app = LifetimeDrainModel.TopApp(key: "com.apple.FinalCut", name: "Final Cut Pro", share: 0.9)
        func feed(_ w: Double, _ s: Int, _ top: LifetimeDrainModel.TopApp? = nil) {
            for _ in 0..<(s / 2) {
                awake += 2; now += 2
                m.observe(batteryWatts: w, onBattery: true, interval: 2, awake: awake, now: now, topApp: top)
            }
        }
        feed(10, 120 + 2 * 3600 + 2)
        feed(30, 1200, app)
        feed(10, 600)
        return m
    }

    private func load(machine: String = "Mac17,9", design: Double = 6251) -> LifetimeDrainModel? {
        LifetimeDrainModel.load(from: file, machineModel: machine, designCapacity_mAh: design)
    }

    func testWhatIsLearnedComesBack() throws {
        let m = learned()
        XCTAssertTrue(m.save(to: file))
        let back = try XCTUnwrap(load())
        XCTAssertEqual(back.baseline_W, m.baseline_W)
        XCTAssertEqual(back.osBuild, m.osBuild)
        XCTAssertEqual(back.excursionStat(high: true), m.excursionStat(high: true))
        XCTAssertEqual(back.appStat("com.apple.FinalCut"), m.appStat("com.apple.FinalCut"))
        XCTAssertNotNil(back.prior(awake: 0), "still warm after a relaunch")
    }

    func testNothingSavedIsAColdStart() {
        XCTAssertNil(load())
    }

    func testACorruptFileIsAColdStartNotACrash() throws {
        try Data("{ not json".utf8).write(to: file)
        XCTAssertNil(load())
    }

    func testAFormatThisBuildDoesNotKnowIsIgnored() throws {
        XCTAssertTrue(learned().save(to: file))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertNil(load())
    }

    func testAnotherMacsHistoryIsNotAdopted() {
        XCTAssertTrue(learned().save(to: file))
        XCTAssertNil(load(machine: "Mac16,1"), "different model")
        XCTAssertNil(load(design: 4382), "different battery")
        XCTAssertNotNil(load(design: 6251.4), "the same pack, reported a hair differently")
    }

    /// Only the learned figures are written; the rolling window and the open
    /// stretch describe one session and are re-observed after a relaunch.
    func testOnlyTheLearnedFiguresAreWritten() throws {
        XCTAssertTrue(learned().save(to: file))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "machineModel", "designCapacity_mAh", "osBuild",
                                        "weightedJoules", "weightSeconds", "totalSeconds",
                                        "lastDecay", "bands", "apps",
                                        "allTimeJoules", "allTimeSeconds", "wattsBasis"])
    }
}
