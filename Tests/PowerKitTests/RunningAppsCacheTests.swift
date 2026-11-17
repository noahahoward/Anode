import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Asking macOS which apps are open is a round trip to LaunchServices for each app: the menu does not ask again on every rebuild.
final class RunningAppsCacheTests: XCTestCase {

    private func app(_ id: String) -> RunningAppsCache.App { .init(id: id, name: id, executablePath: nil) }

    func testRepeatedLooksWithinTheAgeLimitFetchOnce() {
        var fetches = 0, now = Date(timeIntervalSince1970: 1000)
        let cache = RunningAppsCache(maxAge: 2, now: { now }, fetch: { fetches += 1; return [self.app("a")] })
        for _ in 0..<50 { _ = cache.apps }
        now += 1.5
        _ = cache.apps
        XCTAssertEqual(fetches, 1)
    }

    func testAnOldSnapshotIsReplaced() {
        var fetches = 0, now = Date(timeIntervalSince1970: 1000)
        let cache = RunningAppsCache(maxAge: 2, now: { now }, fetch: { fetches += 1; return [] })
        _ = cache.apps
        now += 2.5
        _ = cache.apps
        XCTAssertEqual(fetches, 2)
    }

    func testInvalidatingMakesTheNextLookFetchAtOnce() {
        var list = [app("a")], now = Date(timeIntervalSince1970: 1000)
        let cache = RunningAppsCache(maxAge: 60, now: { now }, fetch: { list })
        XCTAssertEqual(cache.apps.map(\.id), ["a"])
        list = [app("a"), app("b")]
        XCTAssertEqual(cache.apps.map(\.id), ["a"], "still the snapshot")
        cache.invalidate()
        XCTAssertEqual(cache.apps.map(\.id), ["a", "b"])
        now += 0
    }
}
