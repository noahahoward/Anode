import Foundation

/// The rules for updating without being asked each time.
///
/// With the setting on, the first time the window opens after Anode starts it
/// asks the checkout whether it is behind, and if it is the window stays shut while `update.sh` pulls and
/// rebuilds. That is the app replacing itself, which the Update button will
/// only do in a Terminal window the user can watch — so everything here is
/// about when the unattended version is allowed to go ahead, and it is written
/// as pure functions so those rules are tested rather than read off the UI.
public enum AutoUpdate {

    public enum Decision: Equatable {
        case openWindow
        case update
    }

    /// How long the window may wait on the network before giving up and
    /// opening anyway. The update is then found the next time Anode starts.
    public static let checkTimeout: TimeInterval = 3

    /// Only `.behind` updates. Every other state is one `update.sh` would refuse
    /// or have nothing to do in, and the window opening normally is the right
    /// answer to all of them.
    ///
    /// `failedCommit` is the upstream commit whose rebuild last failed. Without
    /// it a push that does not build would be pulled at, and fail at, every
    /// launch; the next commit upstream has a different hash and is tried.
    public static func decision(enabled: Bool, state: SourceCheckout.State,
                                upstreamCommit: String?, failedCommit: String?) -> Decision {
        guard enabled, state.isUpdatable else { return .openWindow }
        if let failedCommit, !failedCommit.isEmpty, failedCommit == upstreamCommit {
            return .openWindow
        }
        return .update
    }

    /// May git be run in the checkout with no window on screen?
    ///
    /// A checkout under Downloads, Desktop or Documents is behind a consent
    /// prompt, and this check runs BEFORE the window opens — the one moment a
    /// prompt has nothing to attach to. That is how the app once stranded
    /// itself (see `ProtectedPath`). So a gated checkout is only read unasked
    /// once git has been seen to read it with a window up, which is what
    /// turning the setting on does.
    public static func mayCheckUnasked(path: String, confirmedPath: String?) -> Bool {
        !ProtectedPath.isGated(path + "/") || path == confirmedPath
    }

    /// Did reading the checkout work? A denied consent prompt makes git fail,
    /// which `SourceCheckout` reports as not a repository.
    public static func confirmsAccess(_ state: SourceCheckout.State) -> Bool {
        state != .missing && state != .notARepository
    }

    /// Where `update.sh` has got to, read from what it prints.
    ///
    /// The script's `› ` lines mark the stages and `swift build` prints
    /// `[done/total]` steps between them. Neither is a contract, so an
    /// unrecognised line changes nothing and the bar only ever moves forward.
    public struct Progress: Equatable {

        public enum Stage: Int, Comparable {
            case starting, fetching, building, assembling, installing, relaunching

            public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

            public var label: String {
                switch self {
                case .starting: return "Starting…"
                case .fetching: return "Downloading changes…"
                case .building: return "Building…"
                case .assembling: return "Assembling…"
                case .installing: return "Installing…"
                case .relaunching: return "Relaunching…"
                }
            }
        }

        public private(set) var stage: Stage = .starting
        /// 0…1, or nil while there is nothing to measure — the build has begun
        /// and `swift build` has not reported a step yet.
        public private(set) var fraction: Double? = 0

        /// The share of the bar the build gets. It is nearly all of the time.
        static let buildRange: ClosedRange<Double> = 0.08...0.85

        public init() {}

        public mutating func consume(line raw: String) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("›") {
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("fetching") { advance(to: .fetching, 0.03) }
                else if text.hasPrefix("building") { advance(to: .building, nil) }
                else if text.hasPrefix("assembling") { advance(to: .assembling, 0.88) }
                else if text.hasPrefix("installed") { advance(to: .installing, 0.96) }
                else if text.hasPrefix("launching") { advance(to: .relaunching, 1) }
            } else if stage == .building, let step = Self.step(in: line) {
                let r = Self.buildRange
                let f = r.lowerBound + (r.upperBound - r.lowerBound) * step
                fraction = max(fraction ?? 0, f)
            }
        }

        private mutating func advance(to next: Stage, _ value: Double?) {
            guard next > stage else { return }
            stage = next
            fraction = value
        }

        /// `[4 / 7] PowerKit` → 4/7, which is how `swift build` writes a step
        /// when its output is not a terminal; `[12/85] Compiling …` is read
        /// too. Nil for anything else, including the `[0/1] Planning build`
        /// shape where the total says nothing yet.
        static func step(in line: String) -> Double? {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let parts = line[line.index(after: line.startIndex)..<close].split(separator: "/")
            guard parts.count == 2,
                  let done = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let total = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  total > 1, done >= 0, done <= total else { return nil }
            return done / total
        }
    }
}
