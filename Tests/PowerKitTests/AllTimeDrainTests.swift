import XCTest
@testable import PowerKit

// Time left divides by the mean drain over every display-on minute on battery
// the app has ever recorded. These pin what that mean includes and that it
// never forgets.
final class AllTimeDrainTests: XCTestCase {

    private var awake: TimeInterval = 10_000
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fresh() -> LifetimeDrainModel {
        LifetimeDrainModel(machineModel: "Mac17,9", designCapacity_mAh: 6251, osBuild: "26A428")
    }

    private func feed(_ m: inout LifetimeDrainModel, watts: Double, seconds: Int,
                      displayOn: Bool = true) {
        for _ in 0..<(seconds / 2) {
            awake += 2; now += 2
            m.observe(batteryWatts: watts, onBattery: true, displayOn: displayOn,
                      interval: 2, awake: awake, now: now, topApp: nil)
        }
    }

    func testSilentUntilTwoHoursRecorded() {
        var m = fresh()
        feed(&m, watts: 8, seconds: 120 + 3600)
        XCTAssertNil(m.allTimeMean_W)
        feed(&m, watts: 8, seconds: 3602)
        XCTAssertEqual(m.allTimeMean_W!, 8, accuracy: 1e-9)
    }

    func testIsThePlainMeanOfEverythingWithNoDecay() {
        var m = fresh()
        feed(&m, watts: 4, seconds: 120 + 3600)
        // Sixty days later, an hour at 12 W. The baseline halves its old weight
        // twice over; the all-time mean must not.
        now += 60 * 86_400
        feed(&m, watts: 12, seconds: 3600)
        XCTAssertEqual(m.allTimeMean_W!, 8, accuracy: 0.01)
    }

    func testDisplayOffTimeIsExcluded() {
        var m = fresh()
        feed(&m, watts: 8, seconds: 120 + 7200)
        feed(&m, watts: 1, seconds: 7200, displayOn: false)
        XCTAssertEqual(m.allTimeMean_W!, 8, accuracy: 1e-9)
    }

    func testAMacOSUpdateDoesNotRestartIt() {
        var m = fresh()
        feed(&m, watts: 8, seconds: 120 + 7200)
        m.adopt(osBuild: "26B100")
        XCTAssertEqual(m.allTimeMean_W!, 8, accuracy: 1e-9)
    }

    func testSurvivesSaveAndLoad() throws {
        var m = fresh()
        feed(&m, watts: 8, seconds: 120 + 7200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alltime-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(m.save(to: url))
        let back = try XCTUnwrap(LifetimeDrainModel.load(from: url, machineModel: "Mac17,9",
                                                         designCapacity_mAh: 6251))
        XCTAssertEqual(back.allTimeMean_W!, 8, accuracy: 1e-9)
    }

    /// A file saved before the all-time fields existed still loads, and its
    /// baseline seeds the total rather than being thrown away.
    func testAnOlderFileSeedsFromItsBaseline() throws {
        let old = #"{"machineModel":"Mac17,9","apps":{},"bands":{},"weightSeconds":3600,"version":1,"totalSeconds":3600,"osBuild":"26A428","designCapacity_mAh":6251,"weightedJoules":36000}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alltime-old-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(old.utf8).write(to: url)
        var m = try XCTUnwrap(LifetimeDrainModel.load(from: url, machineModel: "Mac17,9",
                                                      designCapacity_mAh: 6251))
        feed(&m, watts: 6, seconds: 120 + 3600)
        // 1 h at 10 W carried over + 1 h at 6 W = 8 W.
        XCTAssertEqual(m.allTimeMean_W!, 8, accuracy: 0.01)
    }
}
