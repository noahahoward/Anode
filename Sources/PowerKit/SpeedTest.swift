import Foundation

/// A user-initiated internet throughput measurement.
///
/// THIS IS THE FIRST NETWORK EGRESS THIS PROJECT HAS EVER HAD, and that is worth
/// stating rather than burying. Everything else here reads local counters and
/// writes one SQLite file; `TESTING.md` says so as a privacy property, and it is
/// part of why "build it from source and run it unsandboxed" is a reasonable ask.
/// A speed test necessarily contacts a third party and uploads bytes to them.
///
/// So it is constrained deliberately:
///
///  * **User-initiated only.** Nothing here runs on a timer, at launch, or as a
///    side effect of opening a pane. There is no scheduled mode and no
///    "background check" — a monitor that generates hundreds of megabytes of
///    traffic on its own is a different product, and one nobody asked for.
///  * **The endpoint is named, not hidden.** `Endpoint.host` is surfaced so the
///    UI can say who is being contacted before anything is sent.
///  * **Failure is nil, never zero.** An unreachable network yields no result.
///    Zero megabits is a measurement, and we would not have made one.
///
/// WHAT THIS MEASURES, and what it does not: single-stream HTTP throughput to one
/// server, which is what a browser download or an app update will actually get.
/// It is NOT a line-rate benchmark — multi-stream tools routinely report higher
/// numbers on the same link because they defeat per-connection bottlenecks like
/// TCP window limits and single-path routing. Reporting one figure and calling it
/// "your speed" would be the same category of overclaim this project rejects in
/// the ledger, so the result carries its own method.
public enum SpeedTest {

    /// Cloudflare's public speed endpoints: unauthenticated, no API key, no
    /// account, and widely used for exactly this. Ookla's require a license.
    ///
    /// One host for all three phases so latency, download and upload describe
    /// the same path. Mixing hosts would produce three numbers that cannot be
    /// reasoned about together.
    public struct Endpoint {
        public let host: String
        public let downURL: (Int) -> URL
        public let upURL: URL

        public static let cloudflare = Endpoint(
            host: "speed.cloudflare.com",
            downURL: { URL(string: "https://speed.cloudflare.com/__down?bytes=\($0)")! },
            upURL: URL(string: "https://speed.cloudflare.com/__up")!)
    }

    public struct Result: Equatable {
        /// Megabits per second, base 10 — the unit ISPs sell in, so it is the one
        /// a user can compare against what they pay for. Bytes elsewhere in this
        /// app are base 2; that inconsistency is deliberate and this is the
        /// comment recording why.
        public let downloadMbps: Double
        public let uploadMbps: Double
        /// Round trip to the same host, milliseconds. The MINIMUM of several
        /// probes, not the mean: latency has a hard floor set by distance and
        /// everything above it is queueing, so the minimum is the closest thing
        /// to a property of the path.
        public let latencyMs: Double
        /// Bytes actually transferred, so a user can see the test was real and
        /// how much of their data plan it spent.
        public let downloadBytes: Int
        public let uploadBytes: Int
        public let host: String
    }

    public enum Failure: Error, Equatable {
        case unreachable(String)
        case tooSlowToMeasure
        case cancelled
    }

    /// Sizes are ramped rather than fixed. A fast link finishes 1 MB before TCP
    /// has left slow start, so a single small transfer measures the ramp instead
    /// of the plateau; a slow link would sit through a 100 MB download for
    /// minutes. Each phase stops as soon as it has both enough bytes and enough
    /// time to be meaningful.
    static let downSizes = [1_000_000, 10_000_000, 25_000_000]
    static let upSizes = [1_000_000, 10_000_000]
    /// A transfer shorter than this is dominated by connection setup and the TCP
    /// ramp, so it is not evidence about steady-state throughput.
    static let minPhaseSeconds: Double = 2.0
    /// Ceiling per phase, so a slow link fails fast instead of hanging.
    static let maxPhaseSeconds: Double = 15.0

    /// Megabits per second from bytes and seconds. Base 10: 1 Mbit = 1e6 bits.
    static func mbps(bytes: Int, seconds: Double) -> Double? {
        guard seconds > 0, bytes > 0 else { return nil }
        return Double(bytes) * 8 / seconds / 1e6
    }

    /// Is this phase long enough to have measured the plateau rather than the
    /// ramp? Separated out so the rule is testable without a network.
    static func isMeaningful(seconds: Double) -> Bool { seconds >= minPhaseSeconds }

    /// The next size to try, or nil when the ramp is done. A phase that finished
    /// too quickly to be meaningful gets the next size up; one that took long
    /// enough stops there, because more bytes would cost the user data for no
    /// extra confidence.
    static func nextSize(after size: Int, seconds: Double, in ladder: [Int]) -> Int? {
        guard !isMeaningful(seconds: seconds) else { return nil }
        guard let i = ladder.firstIndex(of: size), i + 1 < ladder.count else { return nil }
        return ladder[i + 1]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The measurement itself

extension SpeedTest {

    /// Run a full test. `progress` is called on an arbitrary queue with a 0…1
    /// fraction and a phase name, so a UI can show something is happening —
    /// a 20-second freeze reads as a hang.
    ///
    /// Every phase is bounded in time, so a dead link fails in seconds rather
    /// than hanging on a socket that will never answer.
    public static func run(endpoint: Endpoint = .cloudflare,
                           progress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> Result {
        let cfg = URLSessionConfiguration.ephemeral
        // Ephemeral, and caching explicitly off: a cached body would measure the
        // disk rather than the link, and would report a spectacular figure while
        // sending no packets at all.
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = maxPhaseSeconds
        cfg.timeoutIntervalForResource = maxPhaseSeconds * 3
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        progress(0.05, "latency")
        let latency = try await measureLatency(session: session, endpoint: endpoint)

        progress(0.15, "download")
        let down = try await measureDownload(session: session, endpoint: endpoint) {
            progress(0.15 + 0.5 * $0, "download")
        }

        progress(0.7, "upload")
        let up = try await measureUpload(session: session, endpoint: endpoint) {
            progress(0.7 + 0.3 * $0, "upload")
        }

        progress(1, "done")
        return Result(downloadMbps: down.mbps, uploadMbps: up.mbps, latencyMs: latency,
                      downloadBytes: down.bytes, uploadBytes: up.bytes, host: endpoint.host)
    }

    /// Minimum of five small round trips. The first is discarded: it pays for DNS,
    /// the TCP handshake and the TLS handshake, none of which recur on a warm
    /// connection and none of which are the latency anyone means.
    private static func measureLatency(session: URLSession, endpoint: Endpoint) async throws -> Double {
        var best = Double.infinity
        for i in 0..<5 {
            let t0 = Date()
            do {
                _ = try await session.data(from: endpoint.downURL(0))
            } catch {
                throw Failure.unreachable(String(describing: error))
            }
            guard i > 0 else { continue }
            best = min(best, Date().timeIntervalSince(t0) * 1000)
        }
        guard best.isFinite else { throw Failure.unreachable("no successful probe") }
        return best
    }

    private static func measureDownload(session: URLSession, endpoint: Endpoint,
                                        progress: @escaping (Double) -> Void
    ) async throws -> (mbps: Double, bytes: Int) {
        var size = downSizes[0]
        var last: (mbps: Double, bytes: Int)?
        while true {
            let t0 = Date()
            let bytes: Int
            do {
                let (data, _) = try await session.data(from: endpoint.downURL(size))
                bytes = data.count
            } catch {
                if let l = last { return l }          // a smaller size already worked
                throw Failure.unreachable(String(describing: error))
            }
            let secs = Date().timeIntervalSince(t0)
            guard let rate = mbps(bytes: bytes, seconds: secs) else {
                throw Failure.tooSlowToMeasure
            }
            last = (rate, bytes)
            progress(min(1, Double(downSizes.firstIndex(of: size).map { $0 + 1 } ?? 1)
                            / Double(downSizes.count)))
            guard let next = nextSize(after: size, seconds: secs, in: downSizes) else {
                return (rate, bytes)
            }
            size = next
        }
    }

    private static func measureUpload(session: URLSession, endpoint: Endpoint,
                                      progress: @escaping (Double) -> Void
    ) async throws -> (mbps: Double, bytes: Int) {
        var size = upSizes[0]
        var last: (mbps: Double, bytes: Int)?
        while true {
            // Incompressible, so a transparent proxy or the server's own gzip
            // cannot shrink it in flight and hand us a rate for bytes that were
            // never actually sent.
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                arc4random_buf(base, raw.count)
            }
            var req = URLRequest(url: endpoint.upURL)
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            let t0 = Date()
            do {
                _ = try await session.upload(for: req, from: payload)
            } catch {
                if let l = last { return l }
                throw Failure.unreachable(String(describing: error))
            }
            let secs = Date().timeIntervalSince(t0)
            guard let rate = mbps(bytes: size, seconds: secs) else {
                throw Failure.tooSlowToMeasure
            }
            last = (rate, size)
            progress(min(1, Double(upSizes.firstIndex(of: size).map { $0 + 1 } ?? 1)
                            / Double(upSizes.count)))
            guard let next = nextSize(after: size, seconds: secs, in: upSizes) else {
                return (rate, size)
            }
            size = next
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Whether to just run the test, or ask first.
///
/// Split from the view because "does this cost the user money" is a rule, not a
/// layout, and it is the one part of this feature that can be got wrong
/// expensively. A monitor that quietly moves 47 MB over someone's phone plan has
/// done real harm with a button press.
public enum SpeedTestGate {

    /// The worst case, if every rung of both ladders is climbed. A fast link
    /// stops earlier — each phase ends as soon as it has enough bytes AND enough
    /// seconds — so this is the number to disclose, not the number to expect.
    /// Every rung of both ladders, because a link fast enough to climb them all
    /// transfers all of them — the earlier sizes are not replaced by the later
    /// ones, they are spent on the way up.
    public static var worstCaseBytes: Int {
        SpeedTest.downSizes.reduce(0, +) + SpeedTest.upSizes.reduce(0, +)
    }

    public enum Decision: Equatable {
        /// Run it. Nothing to say that has not been said.
        case run
        /// Put this question to the user first, and run only if they agree.
        case ask(String)
    }

    /// `hasAgreedBefore` is a stored preference: the disclosure is worth making
    /// once, and worth NOT making every time, or it becomes the dialog people
    /// dismiss without reading.
    ///
    /// A metered path re-asks every time regardless, because the cost is real and
    /// recurring rather than a one-off explanation. `isConstrained` is Low Data
    /// Mode — the user has already said, at the OS level, that they want less
    /// traffic on this network, and a speed test is the least respectful possible
    /// answer to that.
    public static func decide(hasAgreedBefore: Bool,
                              isExpensive: Bool,
                              isConstrained: Bool,
                              host: String) -> Decision {
        let mb = String(format: "%.0f MB", Double(worstCaseBytes) / 1e6)
        if isExpensive || isConstrained {
            let why = isConstrained
                ? "This network is in Low Data Mode"
                : "This looks like a cellular or personal hotspot connection"
            return .ask("""
            \(why), and a speed test is the opposite of low data: it will send \
            and receive up to \(mb) to \(host).

            On a metered plan that is a real cost. Run it anyway?
            """)
        }
        guard !hasAgreedBefore else { return .run }
        return .ask("""
        This is the only thing BetterStats ever sends anywhere.

        It transfers up to \(mb) to and from \(host) — usually less, because each \
        stage stops as soon as it has measured enough. Cloudflare will see your \
        IP address, as any speed test's server must.

        Nothing here runs on a timer or at launch. It happens when you press the \
        button and at no other time.
        """)
    }
}
