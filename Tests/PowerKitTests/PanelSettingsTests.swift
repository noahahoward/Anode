import XCTest
@testable import PowerKit

/// Persistence for the stats panel's arrangement: `panelOrder` and
/// `panelHidden`.
///
/// Both follow `menuBarWidgets`' contract, for the same reasons it documents —
/// sanitize on read AND write, keep unknown IDs (a metric from a module that
/// isn't loaded must not be silently dropped from someone's arrangement), and
/// notify only on real change so the panes don't churn.
final class PanelSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        let made = try TestDefaults.make(owner: "PanelSettings")
        defaults = made.defaults
        suiteName = made.name
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    /// Untouched settings claim no arrangement at all — that is how
    /// `PanelOrder` knows to speak for itself. An eagerly materialized default
    /// would freeze today's ordering into a user's plist and make every future
    /// default change invisible to them.
    func testAnUntouchedInstallHasNoSavedArrangement() {
        XCTAssertTrue(settings.panelOrder.isEmpty)
        XCTAssertTrue(settings.panelHidden.isEmpty)
    }

    func testOrderRoundTrips() {
        let ids = [MetricID.cpuUsage.rawValue, MetricID.batteryDrain.rawValue]
        settings.panelOrder = ids
        XCTAssertEqual(settings.panelOrder, ids)
        XCTAssertEqual(Settings(defaults: defaults).panelOrder, ids,
                       "a second handle on the same suite must see it")
    }

    func testHiddenRoundTrips() {
        settings.panelHidden = [MetricID.samplerDrops.rawValue]
        XCTAssertEqual(settings.panelHidden, [MetricID.samplerDrops.rawValue])
    }

    func testBothAreDedupedAndTrimmed() {
        settings.panelOrder = ["  a  ", "a", "", "b"]
        XCTAssertEqual(settings.panelOrder, ["a", "b"])
        settings.panelHidden = ["b", "b", "   "]
        XCTAssertEqual(settings.panelHidden, ["b"])
    }

    /// Unlike `menuBarWidgets`, the panel list is NOT capped at 12: the widget
    /// cap exists so a corrupt plist cannot flood the menu bar with status
    /// items, and the panel is a single scrollable menu with no such cost. It
    /// must hold every metric the app has, or hiding one would evict another.
    func testTheOrderIsNotCappedAtTheWidgetLimit() {
        let many = (0..<40).map { "metric.\($0)" }
        settings.panelOrder = many
        XCTAssertEqual(settings.panelOrder, many)
    }

    func testWritingObservesAndNotifiesOnceOnRealChange() {
        var fires = 0
        let token = settings.observe(Settings.Key.panelOrder) { fires += 1 }
        settings.panelOrder = [MetricID.cpuUsage.rawValue]
        XCTAssertEqual(fires, 1)
        settings.panelOrder = [MetricID.cpuUsage.rawValue]   // same value
        XCTAssertEqual(fires, 1, "an unchanged write must not notify")
        settings.panelOrder = []
        XCTAssertEqual(fires, 2, "clearing back to 'no arrangement' is a change")
        _ = token
    }

    /// The end-to-end contract the UI depends on: what the editor saves is what
    /// the panel renders.
    func testSettingsFeedTheResolver() {
        let available: [MetricID] = [.batteryDrain, .cpuUsage, .memoryUsage]
        settings.panelOrder = [MetricID.memoryUsage.rawValue,
                               MetricID.batteryDrain.rawValue,
                               MetricID.cpuUsage.rawValue]
        settings.panelHidden = [MetricID.batteryDrain.rawValue]
        XCTAssertEqual(
            PanelOrder.visible(saved: settings.panelOrder,
                               hidden: settings.panelHidden,
                               available: available),
            [MetricID.memoryUsage.rawValue, MetricID.cpuUsage.rawValue])
    }
}
