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
/// WHAT THIS MEASURES: HTTP throughput to one server over several connections at
/// once, for a fixed number of seconds, discarding the opening warmup.
///
/// That is a deliberate change of position and it is worth recording. This used
/// to run ONE stream, on the argument that it is what a browser download
/// actually gets. The argument is sound and the number was still wrong: a single
/// connection to a distant CDN node is bounded by round-trip time and the TCP
/// window rather than by the link, so on a 364 Mbps ethernet connection it read
/// about a third of what every other tool reported. A figure that is defensible
/// in principle and wrong in practice is not the honest one — it just moves the
/// error somewhere the user cannot see it.
///
/// It is still not a line-rate benchmark, and the result carries its own method
/// so nobody has to guess which question was asked.
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

    /// LocalizedError, not merely Error, and that conformance is load-bearing.
    ///
    /// A Swift error bridged to NSError without it produces
    /// "PowerKit.SpeedTest.Failure error 0" — the case's INDEX. Every explanation
    /// this type is careful to build ("the server answered HTTP 429 — too many
    /// tests too quickly") was thrown away at the last step, and the one message
    /// the user actually saw was the one nobody wrote.
    public enum Failure: LocalizedError, Equatable {
        case unreachable(String)
        case tooSlowToMeasure
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .unreachable(let why):  return why
            case .tooSlowToMeasure:      return "the connection was too slow to measure"
            case .cancelled:             return "the test was cancelled"
            }
        }
    }

    /// MEASURE FOR A DURATION, NOT FOR A SIZE.
    ///
    /// The first version of this climbed a fixed ladder — 1, 10, 25 MB — and
    /// stopped when a transfer took at least two seconds. On a fast link it never
    /// got there: 25 MB at 364 Mbps is 0.55 s, so the ladder ran out of rungs
    /// while still inside TCP slow start and the reported figure was the RAMP.
    /// Measured against other tools on the same ethernet link, it under-reported
    /// by roughly a factor of three.
    ///
    /// So a phase now runs for a fixed number of seconds and the bytes are
    /// whatever fits. The cost of that is honest but not fixed: a fast link moves
    /// far more data than a slow one, which is the opposite of the old ladder and
    /// the reason `SpeedTestGate` can no longer quote one number.
    public static let downSeconds: Double = 6
    public static let upSeconds: Double = 4
    /// The opening transfer of each phase is thrown away. It is the connection
    /// warming up — DNS, TLS, and slow start — and averaging it in is exactly the
    /// mistake the ladder made.
    public static let warmupSeconds: Double = 1.0
    /// Streams per phase.
    ///
    /// One connection to a distant CDN node is limited by round-trip time and
    /// the TCP window rather than by the link, which is why single-stream tools
    /// read low on fast connections. Every speed test a user will compare this
    /// against — fast.com, Ookla, Cloudflare's own page — runs several. Matching
    /// them is the point of the number.
    public static let streams = 4
    /// A hard ceiling per phase, so a very fast link cannot turn a six-second
    /// test into a gigabyte.
    static let maxBytesPerPhase = 600_000_000
    /// How long to make a user wait between tests.
    ///
    /// NOT arbitrary politeness. `speed.cloudflare.com` rate-limits by download
    /// VOLUME, and it is a courtesy endpoint this project does not pay for:
    /// measured, after several GB in twenty minutes, 1 MB requests still answered
    /// 200 while 10 MB and 64 MB answered 429. One run moves a few hundred
    /// megabytes on a fast line, so a button with no cooldown is a button that
    /// gets a user rate-limited by their third press — and an open-source app
    /// shipping that to everyone is how a free endpoint stops being free.
    public static let cooldownSeconds: Double = 60

    /// Below this, a phase has not measured anything — it has caught the tail of
    /// a refusal or a connection that died. Reported as a failure rather than as
    /// a very small number, because "0.0 Mbps" is a claim about the link.
    static let minimumBytesToBelieve = 1_000_000
    /// A transfer shorter than this is dominated by connection setup and the TCP
    /// ramp, so it is not evidence about steady-state throughput.
    static let minPhaseSeconds: Double = 2.0
    /// Ceiling per phase, so a slow link fails fast instead of hanging.
    static let maxPhaseSeconds: Double = 25.0
    /// What one request asks for.
    ///
    /// MEASURED CEILING: `__down` answers 200 up to 90 MB and 403s at 100 MB, so
    /// "ask for more than the window can deliver" is not available — an earlier
    /// draft asked for 2 GB and every download returned nothing at all. 64 MB
    /// sits clear of the limit, and a stream that finishes before the clock is
    /// simply replaced (`didCompleteWithError`), so the flow is continuous
    /// whatever the line speed.
    static let requestBytes = 64_000_000

    /// Megabits per second from bytes and seconds. Base 10: 1 Mbit = 1e6 bits.
    static func mbps(bytes: Int, seconds: Double) -> Double? {
        guard seconds > 0, bytes > 0 else { return nil }
        return Double(bytes) * 8 / seconds / 1e6
    }

    /// Is this phase long enough to have measured the plateau rather than the
    /// ramp? Separated out so the rule is testable without a network.
    static func isMeaningful(seconds: Double) -> Bool { seconds >= minPhaseSeconds }

    /// Roughly what a phase will transfer at a given rate, for the disclosure.
    /// An estimate and labelled as one: the real figure depends on a line speed
    /// nobody knows until the test has run.
    public static func estimatedBytes(atMbps rate: Double, seconds: Double) -> Int {
        min(maxBytesPerPhase, Int(rate * 1e6 / 8 * seconds))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The measurement itself

extension SpeedTest {

    /// What a test reports while it is running.
    ///
    /// `mbps` is the rate SO FAR in the current phase, not a final answer, and it
    /// is what a live gauge needs: a progress bar that only says "43%" tells a
    /// user nothing they wanted to know about their connection.
    public struct Update: Equatable {
        public let phase: String
        /// 0…1 through the whole test, for anything that wants one bar.
        public let fraction: Double
        /// Live rate in the current phase, or nil during latency and at the end.
        public let mbps: Double?
    }

    /// Run a full test. `progress` is called on an arbitrary queue, so a UI can
    /// show something is happening — a 20-second freeze reads as a hang.
    ///
    /// Every phase is bounded in time, so a dead link fails in seconds rather
    /// than hanging on a socket that will never answer.
    public static func run(endpoint: Endpoint = .cloudflare,
                           progress: @escaping (Update) -> Void = { _ in }
    ) async throws -> Result {
        let cfg = URLSessionConfiguration.ephemeral
        // Ephemeral, and caching explicitly off: a cached body would measure the
        // disk rather than the link, and would report a spectacular figure while
        // sending no packets at all.
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = maxPhaseSeconds
        cfg.timeoutIntervalForResource = maxPhaseSeconds * 3
        // The counter IS the session's delegate: bytes are counted where they
        // arrive rather than when a whole body has landed.
        let counter = PhaseCounter()
        let session = URLSession(configuration: cfg, delegate: counter, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        progress(Update(phase: "latency", fraction: 0.05, mbps: nil))
        let latency = try await measureLatency(session: session, endpoint: endpoint)

        progress(Update(phase: "download", fraction: 0.1, mbps: nil))
        counter.onProgress = { f, rate in
            progress(Update(phase: "download", fraction: 0.1 + 0.55 * f, mbps: rate))
        }
        let down = try await measureDownload(session: session, endpoint: endpoint,
                                             counter: counter)

        progress(Update(phase: "upload", fraction: 0.65, mbps: nil))
        counter.onProgress = { f, rate in
            progress(Update(phase: "upload", fraction: 0.65 + 0.35 * f, mbps: rate))
        }
        let up = try await measureUpload(session: session, endpoint: endpoint,
                                         counter: counter)

        progress(Update(phase: "done", fraction: 1, mbps: nil))
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

    /// A phase: `streams` transfers at once, counted AS THE BYTES ARRIVE, each
    /// replaced when it finishes, all stopped when the clock runs out.
    ///
    /// Two things had to be true together and the first draft had neither. Bytes
    /// must be counted continuously — counting only completed transfers quantises
    /// the measurement to the request size and lets one slow transfer outlive the
    /// window it is supposed to describe. And the flow must not stop early —
    /// `__down` caps at 90 MB, so on a fast link a single request is over in
    /// under two seconds.
    ///
    /// Both failure modes were seen on one ethernet link: 445 Mbps then 65.8 from
    /// the first, and 0.0 Mbps from an attempt to fix it by asking for 2 GB.
    private static func runPhase(seconds: Double,
                                 session: URLSession,
                                 counter: PhaseCounter
    ) async throws -> (mbps: Double, bytes: Int) {
        counter.begin(seconds: seconds, warmup: warmupSeconds, session: session)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        counter.stop()
        // A moment for the last in-flight callbacks to land before reading.
        try? await Task.sleep(nanoseconds: 150_000_000)

        if let status = counter.rejection {
            throw Failure.unreachable("the server answered HTTP \(status)"
                                    + (status == 429 || status == 403
                                       ? " — too many tests too quickly; wait a minute" : ""))
        }
        let (measured, total, window) = counter.read()
        // A trickle is not a measurement. Without a floor, a refusal whose error
        // body is a few hundred bytes gets divided by six seconds and printed as
        // a confident 0.0 Mbps.
        guard total >= minimumBytesToBelieve else {
            throw Failure.unreachable("only \(total) bytes arrived — the connection "
                                    + "dropped or the server refused")
        }
        // Below the warmup there is nothing but the ramp; a link that slow has
        // spent the whole window ramping, so the ramp is the answer there.
        if measured == 0 || window < 0.5 {
            guard let rate = mbps(bytes: total, seconds: seconds) else {
                throw Failure.tooSlowToMeasure
            }
            return (rate, total)
        }
        guard let rate = mbps(bytes: measured, seconds: window) else {
            throw Failure.tooSlowToMeasure
        }
        return (rate, total)
    }

    /// Counts bytes in flight, keeps `streams` transfers running, and stops them
    /// when the clock runs out.
    ///
    /// A delegate rather than `await session.data(...)`, because that call only
    /// yields once the whole body has arrived — which is exactly the granularity
    /// that made the first version swing between 445 and 66 Mbps on one link.
    final class PhaseCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        private var afterWarmup = 0
        private var warmupEnds = Date.distantFuture
        private var deadline = Date.distantPast
        private var startedAt = Date()
        private var live: [URLSessionTask] = []
        private var running = false
        /// Consecutive replacements that carried nothing, so a request the server
        /// refuses outright cannot become a restart loop.
        private var emptyCompletions = 0
        /// The last non-200 the server answered with, if any. A refusal is a
        /// failure to report, not a slow connection to average in — Cloudflare
        /// 403s a request over 90 MB, and rate-limits a client that has asked too
        /// often, which is a thing this will meet in the field.
        private(set) var rejection: Int?

        /// Builds one request. Set before `begin`.
        var makeTask: ((URLSession) -> URLSessionTask)?
        /// Live progress, for the dial.
        var onProgress: ((Double, Double) -> Void)?

        func begin(seconds: Double, warmup: Double, session: URLSession) {
            lock.lock()
            total = 0; afterWarmup = 0; emptyCompletions = 0
            startedAt = Date()
            warmupEnds = startedAt.addingTimeInterval(warmup)
            deadline = startedAt.addingTimeInterval(seconds)
            running = true
            live.removeAll()
            lock.unlock()
            for _ in 0..<SpeedTest.streams { launch(on: session) }
        }

        func stop() {
            lock.lock()
            running = false
            let tasks = live
            live.removeAll()
            lock.unlock()
            for t in tasks { t.cancel() }
        }

        /// (bytes after the warmup, bytes in total, seconds the first covers).
        func read() -> (measured: Int, total: Int, window: Double) {
            lock.lock(); defer { lock.unlock() }
            return (afterWarmup, total, max(0, min(Date(), deadline).timeIntervalSince(warmupEnds)))
        }

        private func launch(on session: URLSession) {
            guard let makeTask else { return }
            let task = makeTask(session)
            lock.lock()
            guard running else { lock.unlock(); return }
            live.append(task)
            lock.unlock()
            task.resume()
        }

        private func count(_ bytes: Int, task: URLSessionTask) {
            let now = Date()
            lock.lock()
            total += bytes
            if now > warmupEnds { afterWarmup += bytes }
            if bytes > 0 { emptyCompletions = 0 }
            let measured = afterWarmup
            let window = now.timeIntervalSince(warmupEnds)
            let elapsed = now.timeIntervalSince(startedAt)
            let span = max(deadline.timeIntervalSince(startedAt), 0.001)
            let past = now > deadline
            lock.unlock()

            if past { task.cancel() }
            let rate = window > 0.3 ? (SpeedTest.mbps(bytes: measured, seconds: window) ?? 0) : 0
            onProgress?(min(1, elapsed / span), rate)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            count(data.count, task: dataTask)
        }

        /// Refuse to measure a refusal. Without this the error body is counted as
        /// payload and a rate-limited test reports a confident 0.0 Mbps, which is
        /// the one thing this type promises never to do.
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                lock.lock(); rejection = http.statusCode; running = false; lock.unlock()
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            count(Int(bytesSent), task: task)
        }

        /// One transfer ended. Replace it, so the line stays busy for the whole
        /// window rather than going quiet the moment a 64 MB request completes.
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            lock.lock()
            live.removeAll { $0 === task }
            let moved = task.countOfBytesReceived + task.countOfBytesSent
            if moved == 0 { emptyCompletions += 1 }
            let giveUp = emptyCompletions >= SpeedTest.streams * 2
            let keepGoing = running && Date() < deadline && !giveUp
            lock.unlock()
            guard keepGoing else { return }
            launch(on: session)
        }
    }

    private static func measureDownload(session: URLSession, endpoint: Endpoint,
                                        counter: PhaseCounter
    ) async throws -> (mbps: Double, bytes: Int) {
        let url = endpoint.downURL(requestBytes)
        counter.makeTask = { $0.dataTask(with: url) }
        return try await runPhase(seconds: downSeconds, session: session, counter: counter)
    }

    private static func measureUpload(session: URLSession, endpoint: Endpoint,
                                      counter: PhaseCounter
    ) async throws -> (mbps: Double, bytes: Int) {
        // Incompressible, so a transparent proxy or the server's own gzip cannot
        // shrink it in flight and hand us a rate for bytes that were never sent.
        var payload = Data(count: requestBytes)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }
        var req = URLRequest(url: endpoint.upURL)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        counter.makeTask = { $0.uploadTask(with: req, from: payload) }
        return try await runPhase(seconds: upSeconds, session: session, counter: counter)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Whether to just run the test, or ask first.
///
/// Split from the view because "does this cost the user money" is a rule, not a
/// layout, and it is the one part of this feature that can be got wrong
/// expensively. A monitor that quietly moves several hundred megabytes over
/// someone's phone plan has done real harm with a button press.
public enum SpeedTestGate {

    /// THE COST IS NO LONGER A FIXED NUMBER, and pretending otherwise would be
    /// the more comfortable lie.
    ///
    /// The old ladder transferred at most 47 MB whatever your line did, and could
    /// therefore promise it. Measuring for a fixed DURATION means a fast link
    /// moves more — that is the whole point of the change — so the disclosure
    /// gives the shape and the ceiling instead of a single figure.
    public static var ceilingBytes: Int { SpeedTest.maxBytesPerPhase * 2 }

    /// Roughly what a link of a given speed will spend. Used to put a real number
    /// in front of someone on a metered connection, where "it depends" is not an
    /// acceptable answer.
    public static func estimatedBytes(atMbps rate: Double) -> Int {
        SpeedTest.estimatedBytes(atMbps: rate, seconds: SpeedTest.downSeconds)
            + SpeedTest.estimatedBytes(atMbps: rate, seconds: SpeedTest.upSeconds)
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
        let seconds = Int(SpeedTest.downSeconds + SpeedTest.upSeconds)
        if isExpensive || isConstrained {
            let why = isConstrained
                ? "This network is in Low Data Mode"
                : "This looks like a cellular or personal hotspot connection"
            return .ask("""
            \(why), and a speed test is the opposite of low data.

            It transfers for about \(seconds) seconds as fast as the connection \
            will go, so the faster the link the more it spends — roughly \
            \(mb(estimatedBytes(atMbps: 50))) on a 50 Mbps connection and \
            \(mb(estimatedBytes(atMbps: 300))) on a 300 Mbps one.

            On a metered plan that is a real cost. Run it anyway?
            """)
        }
        guard !hasAgreedBefore else { return .run }
        return .ask("""
        This is the only thing BetterStats ever sends anywhere.

        It transfers for about \(seconds) seconds to and from \(host), as fast as \
        your connection will go — so the amount of data depends on your speed: \
        roughly \(mb(estimatedBytes(atMbps: 50))) at 50 Mbps, \
        \(mb(estimatedBytes(atMbps: 300))) at 300 Mbps, never more than \
        \(mb(ceilingBytes)). Cloudflare will see your IP address, as any speed \
        test's server must.

        Nothing here runs on a timer or at launch. It happens when you press the \
        button and at no other time.
        """)
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}
