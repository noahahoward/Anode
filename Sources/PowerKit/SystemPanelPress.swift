import Foundation

// ── Using macOS's own panel without it being seen ───────────────────────────
//
// Some rows of macOS's Sound menu (the AirPods listening mode, Spatial Audio, Conversation Awareness, the AirPlay speakers)
// can only be read and pressed through macOS's own panel; the calls behind them answer only apps Apple has signed for it.
// So Anode opens that panel with Accessibility, moves it off the screen the moment it exists, reads or presses a row, and
// closes it. Apple's own icon shows its pressed look while the panel is open, so Anode covers it with a still picture of the
// idle icon for that long and a little after (measured: the look fades for about a second after the close).
//
// This file is the order of those steps and what each one reports, as a value that can be tested. The app carries the
// actions out and feeds back what happened.

public enum SystemPanelKind: Equatable { case sound, battery }

/// A row of macOS's panel, named the way Accessibility names it: both must match, since several rows of one device share an id.
public struct SystemPanelRow: Equatable {
    public var identifier: String
    public var description: String
    public init(identifier: String, description: String) { self.identifier = identifier; self.description = description }
}

public enum SystemPanelError: Error, Equatable {
    case noAccessibility, noMenuExtra, panelDidNotOpen, rowNotFound
    /// The person has macOS's panel open on screen: Anode neither moves nor presses anything in it.
    case personHasItOpen
}

public enum SystemPanelOutcome: Equatable {
    /// A read: the panel's whole tree.
    case tree(AXNode)
    /// A press that macOS took without complaint. The new state is read the next time the menu opens.
    case pressed
    /// macOS refused and showed an alert. These are its words, title and message joined by " / ".
    case refused(String)
    case failed(SystemPanelError)
}

public enum SystemPanelTiming {
    /// How long to wait for the panel to appear after pressing its icon.
    public static let openTimeout: TimeInterval = 1.0
    /// How long after a press to wait for a refusal alert (measured: it shows within about half a second).
    public static let alertWindow: TimeInterval = 0.5
    /// How long Anode's still picture stays over macOS's icon after the panel closes.
    public static let coverHold: TimeInterval = 1.2
}

/// How the panel is reached: by pressing its own icon in the menu bar, or, when the person has removed that icon, through
/// Control Center's button for the section.
public enum SystemPanelRoute: Equatable {
    case menuExtra
    case controlCenter(section: String)
}

public struct SystemPanelPress {

    public enum Job: Equatable { case read, press(SystemPanelRow) }

    public enum Event: Equatable {
        case opened, sectionOpened, openTimedOut
        case treeRead(AXNode), rowPressed, rowMissing
        case alert(String), alertWindowElapsed
        case closed
    }

    public enum Action: Equatable {
        case coverIcon
        case openPanel(SystemPanelRoute)
        case openSection(String)
        case movePanelOffScreen
        case readTree
        case pressRow(SystemPanelRow)
        case dismissAlert
        case closePanel
        case waitForAlert(TimeInterval)
        case uncoverIcon(after: TimeInterval)
        case finish(SystemPanelOutcome)
    }

    private enum Phase { case idle, opening, openingSection, working, closing, awaitingAlert, done }

    private let job: Job
    private let route: SystemPanelRoute
    private let personHasPanelOpen: Bool
    private let accessibility: Bool
    private var phase = Phase.idle
    private var pending: SystemPanelOutcome = .pressed

    public init(job: Job, route: SystemPanelRoute, personHasPanelOpen: Bool, accessibility: Bool = true) {
        self.job = job; self.route = route; self.personHasPanelOpen = personHasPanelOpen; self.accessibility = accessibility
    }

    public mutating func start() -> [Action] {
        guard accessibility else { phase = .done; return [.finish(.failed(.noAccessibility))] }
        guard !personHasPanelOpen else { phase = .done; return [.finish(.failed(.personHasItOpen))] }
        phase = .opening
        return [.coverIcon, .openPanel(route)]
    }

    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .opened:
            if case .controlCenter(let section) = route, phase == .opening {
                phase = .openingSection
                return [.movePanelOffScreen, .openSection(section)]
            }
            phase = .working
            return [.movePanelOffScreen, work]
        case .sectionOpened:
            phase = .working
            return [.movePanelOffScreen, work]
        case .openTimedOut:
            guard phase == .opening || phase == .openingSection else { return [] }
            return finishNow(.failed(.panelDidNotOpen), close: true)
        case .treeRead(let tree):
            pending = .tree(tree); phase = .closing
            return [.closePanel]
        case .rowPressed:
            pending = .pressed; phase = .awaitingAlert
            return [.closePanel, .waitForAlert(SystemPanelTiming.alertWindow)]
        case .rowMissing:
            pending = .failed(.rowNotFound); phase = .closing
            return [.closePanel]
        case .alert(let text):
            // Always dismissed, so no alert is left on the screen; only one inside the window decides the outcome.
            if phase == .awaitingAlert, pending == .pressed { pending = .refused(text) }
            return [.dismissAlert]
        case .alertWindowElapsed:
            guard phase == .awaitingAlert else { return [] }
            return finishNow(pending, close: false)
        case .closed:
            guard phase == .closing else { return [] }
            return finishNow(pending, close: false)
        }
    }

    private var work: Action {
        switch job { case .read: return .readTree; case .press(let row): return .pressRow(row) }
    }

    private mutating func finishNow(_ outcome: SystemPanelOutcome, close: Bool) -> [Action] {
        phase = .done
        return (close ? [.closePanel] : []) + [.uncoverIcon(after: SystemPanelTiming.coverHold), .finish(outcome)]
    }
}
