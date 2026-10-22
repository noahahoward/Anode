import AppKit
import PowerKit

// Programmatic preferences window — no xib, no storyboard, semantic colours
// only, so light/dark both come for free from AppKit.
//
// Every control writes straight into Settings.shared and then re-reads the
// stored truth: Settings clamps out-of-range input, so the UI snaps to what was
// actually accepted rather than displaying a value that was silently rejected.
// Live propagation to the rest of the app is Settings.observe() — nothing here
// requires a relaunch.

/// One bindable menu bar metric. Kept as a plain (id, label) pair so the prefs
/// pane doesn't care whether the list came from a live MetricRegistry or the
/// static fallback below.
public struct MetricChoice {
    public let id: String
    public let label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public final class PreferencesWindowController: NSWindowController {

    public static let shared = PreferencesWindowController()

    /// If a MetricRegistry exists, the integrator points this at
    /// `MetricRegistry.descriptors()` before first show; otherwise the static
    /// list below drives the Menu Bar pane. Widgets bind to metric IDs, so the
    /// pane works identically either way.
    public static var metricProvider: (() -> [MetricChoice])?

    /// The Menu Bar pane used to read and write `Settings.menuBarWidgets`, which
    /// NOTHING consumed — MenuBarWidgetController keeps its own persisted config.
    /// Checking a box therefore appeared to work and changed nothing. These two
    /// hooks make the controller the single source of truth.
    public static var currentWidgetIDs: (() -> [String])?
    public static var onWidgetsChanged: (([String]) -> Void)?

    /// Displayed units only — %/hr, trailing-window %, runtime. Never watts.
    public static let fallbackMetrics: [MetricChoice] = [
        MetricChoice(id: "drain.pctHr", label: "Battery drain (%/hr)"),
        MetricChoice(id: "battery.percent", label: "Battery charge (%)"),
        MetricChoice(id: "runtime.projected", label: "Projected runtime (h:mm)"),
        MetricChoice(id: "power.window", label: "Trailing-window power (\u{201C}10 hr power\u{201D})"),
        MetricChoice(id: "drain.topApp", label: "Top-draining app"),
    ]

    private var keyObserver: NSObjectProtocol?
    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar

        func item(_ vc: NSViewController, _ label: String, _ symbol: String) -> NSTabViewItem {
            // The view controller's `title`, not just the tab's `label`.
            //
            // An NSTabViewController in `.toolbar` style drives the window title
            // from the SELECTED PANE, overwriting whatever the window was given.
            // With no title on the pane it substitutes a placeholder, and the
            // Settings window read "Untitled" on screen despite line 71 setting
            // "Anode Settings" — the assignment happens first and is then
            // replaced. Titling the panes is what actually reaches the titlebar,
            // and it gives the macOS-standard behaviour of the title naming the
            // pane you are looking at.
            vc.title = label
            let i = NSTabViewItem(viewController: vc)
            i.label = label
            // Symbol lookup can fail on older SDK/asset mismatches; a label-only
            // tab beats a crash.
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                ?? NSImage(named: NSImage.preferencesGeneralName)
            return i
        }
        tabs.addTabViewItem(item(GeneralPane(), "General", "gearshape"))
        tabs.addTabViewItem(item(BatteryPane(), "Battery", "battery.100"))
        tabs.addTabViewItem(item(MenuBarPane(), "Menu Bar", "menubar.rectangle"))
        tabs.addTabViewItem(item(GraphPane(), "Graph", "chart.xyaxis.line"))

        let window = NSWindow(contentViewController: tabs)
        window.title = "Anode Settings"
        window.toolbarStyle = .preference
        // Resizable stays on (grids stretch sanely); a floor stops the toolbar
        // tabs from clipping.
        window.contentMinSize = NSSize(width: 480, height: 200)
        super.init(window: window)

        // SMAppService has no change notification: the user can revoke the
        // login item in System Settings behind our back. Re-poll every time the
        // window comes forward so the checkbox reflects reality.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in Settings.shared.refreshLaunchAtLogin() }
    }

    /// Programmatic-only; nothing to decode. Fail soft, don't crash.
    public required init?(coder: NSCoder) { return nil }

    deinit {
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
    }

    public func show() {
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        w.bringForward()
    }

    /// Open on the Graph pane, for the button over the main window's graph.
    public func showGraph() {
        // Select first: the tab's view loads lazily and `show()` brings it forward.
        if let i = tabs.tabViewItems.firstIndex(where: { $0.viewController is GraphPane }) {
            tabs.selectedTabViewItemIndex = i
        }
        show()
    }
}

// ── Shared pane machinery ───────────────────────────────────────────────────

/// Base pane: builds a two-column grid ("label: control"), observes Settings
/// with a wildcard token so ANY write — this window, another window, another
/// Settings instance — refreshes the controls. Programmatic value changes do
/// not re-fire NSControl actions, so refresh() cannot loop back into a write.
private class Pane: NSViewController {
    let settings = Settings.shared
    private var tokens: [AnyObject] = []

    /// Push current Settings values into the controls. Called on every change.
    func refresh() {}

    override func viewDidLoad() {
        super.viewDidLoad()
        tokens.append(settings.observe(Settings.Key.any) { [weak self] in self?.refreshLayout() })
        refreshLayout()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLayout()
    }

    /// `refresh()`, then collapse whatever it hid.
    func refreshLayout() {
        refresh()
        syncGridRows()
    }

    /// The pane's grid, kept so rows can collapse.
    private var grid: NSGridView?

    /// Hiding a VIEW inside an NSGridView does not hide its ROW: the row keeps
    /// its height and spacing, so every note that is usually empty left a
    /// blank band — under "Launch Anode at login" in the ordinary unregistered
    /// state, and under the menu bar switch whenever every widget was showing.
    /// A row whose every real view is hidden is collapsed here instead, which
    /// keeps the panes' own code free to go on toggling `isHidden` as it did.
    func syncGridRows() {
        guard let grid else { return }
        var changed = false
        for r in 0..<grid.numberOfRows {
            let row = grid.row(at: r)
            let views = (0..<row.numberOfCells).compactMap { row.cell(at: $0).contentView }
                .filter { $0 !== NSGridCell.emptyContentView }
            let hide = !views.isEmpty && views.allSatisfy(\.isHidden)
            if row.isHidden != hide { row.isHidden = hide; changed = true }
        }
        guard changed else { return }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: max(view.fittingSize.width, 560),
                                      height: max(view.fittingSize.height, 120))
    }

    // Layout helpers -------------------------------------------------------

    func rowLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor   // semantic: adapts to dark mode
        l.preferredMaxLayoutWidth = 380      // forces wrap so fittingSize has a height
        l.isSelectable = false
        return l
    }

    func install(rows: [[NSView]]) {
        let grid = NSGridView(views: rows)
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        view = root
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: max(root.fittingSize.width, 560),
                                      height: max(root.fittingSize.height, 120))
    }

    var spacer: NSView { NSGridCell.emptyContentView }

    /// Editable number field + stepper pair that share one write closure.
    /// The formatter deliberately has NO min/max: Settings owns validation, and
    /// the refresh() round-trip shows the user the clamped truth.
    func fieldAndStepper(range: ClosedRange<Double>, step: Double, fractionDigits: Int,
                         unit: String, action: Selector) -> (NSTextField, NSStepper, NSStackView) {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = fractionDigits

        let field = NSTextField()
        field.formatter = f
        field.alignment = .right
        field.target = self
        field.action = action
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stepper = NSStepper()
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action

        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [field, stepper, unitLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        return (field, stepper, stack)
    }
}

// ── General ─────────────────────────────────────────────────────────────────

private final class GeneralPane: Pane {
    private var intervalSlider: NSSlider!
    private var intervalValue: NSTextField!
    private var loginCheckbox: NSButton!
    private var loginNote: NSTextField!
    private var loginButton: NSButton!
    private var menuBarOnlyCheckbox: NSButton!
    private var menuBarOnlyNote: NSTextField!
    private var updateStatus: NSTextField!
    private var updateNote: NSTextField!
    private var updateButton: NSButton!
    private var checkButton: NSButton!
    private var autoUpdateCheckbox: NSButton!
    private var uninstallButton: NSButton!

    /// Last answer from the checkout, so `refresh()` — which fires on ANY
    /// settings write — redraws the row without re-running git each time.
    private var checkoutState: SourceCheckout.State?
    private var checking = false

    override func loadView() {
        let r = Settings.sampleIntervalRange
        intervalSlider = NSSlider(value: settings.sampleInterval,
                                  minValue: r.lowerBound, maxValue: r.upperBound,
                                  target: self, action: #selector(intervalChanged))
        // One tick per second and tick-only values: discrete, no float noise.
        intervalSlider.numberOfTickMarks = Int(r.upperBound - r.lowerBound) + 1
        intervalSlider.allowsTickMarkValuesOnly = true
        intervalSlider.isContinuous = true
        intervalSlider.translatesAutoresizingMaskIntoConstraints = false
        intervalSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true

        intervalValue = NSTextField(labelWithString: "")
        intervalValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let intervalRow = NSStackView(views: [intervalSlider, intervalValue])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 10

        loginCheckbox = NSButton(checkboxWithTitle: "Launch Anode at login",
                                 target: self, action: #selector(loginToggled))
        loginNote = caption("")
        loginButton = NSButton(title: "Open Login Items Settings…",
                               target: self, action: #selector(openLoginItems))
        loginButton.controlSize = .small
        loginButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        menuBarOnlyCheckbox = NSButton(checkboxWithTitle: "Start in the menu bar only (no window)",
                                       target: self, action: #selector(menuBarOnlyToggled))
        menuBarOnlyNote = caption("")

        updateStatus = NSTextField(labelWithString: "")
        updateNote = caption("")
        checkButton = NSButton(title: "Check for Updates",
                               target: self, action: #selector(checkForUpdates))
        checkButton.controlSize = .small
        checkButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateButton = NSButton(title: "Update and Rebuild…",
                                target: self, action: #selector(runUpdate))
        updateButton.controlSize = .small
        updateButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoUpdateCheckbox = NSButton(
            checkboxWithTitle: "Check when Anode starts, and update automatically",
            target: self, action: #selector(autoUpdateToggled))
        autoUpdateCheckbox.controlSize = .small
        autoUpdateCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        uninstallButton = NSButton(title: "Uninstall Anode…",
                                   target: self, action: #selector(uninstall))
        uninstallButton.controlSize = .small
        uninstallButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let updateButtons = NSStackView(views: [checkButton, updateButton,
                                                NSView(), uninstallButton])
        updateButtons.orientation = .horizontal
        updateButtons.spacing = 8

        install(rows: [
            [rowLabel("Sample every:"), intervalRow],
            [spacer, caption("How often per-process energy is read. Shorter is more responsive "
                             + "but costs more of the battery being measured.")],
            [rowLabel("Startup:"), loginCheckbox],
            [spacer, loginNote],
            [spacer, loginButton],
            [spacer, menuBarOnlyCheckbox],
            [spacer, menuBarOnlyNote],
            [rowLabel("Version:"), updateStatus],
            [spacer, updateNote],
            [spacer, autoUpdateCheckbox],
            [spacer, updateButtons],
        ])
    }

    // ── Updates ─────────────────────────────────────────────────────────────
    //
    // Anode is built from source rather than downloaded — it is ad-hoc signed,
    // so a bundle that arrives through a browser is quarantined and refused, and
    // the honest fix is to build it rather than to teach people to switch
    // Gatekeeper off. So "update" here means pull and rebuild the checkout this
    // bundle was built from, and the checkout's state is the thing this row
    // reports. `SourceCheckout` owns every state it can be in.

    /// What this build is, independent of any checkout — true even when the
    /// source has since been moved or deleted.
    private var buildDescription: String {
        BuildInfo(info: Bundle.main.infoDictionary).summary
    }

    private func checkout() -> SourceCheckout? {
        SourceCheckout.recordedPath(in: .main).map(SourceCheckout.atPath)
    }

    /// Goes and looks: fetches, then reads the checkout's state.
    ///
    /// The ONLY thing that touches the source folder. Opening this window
    /// deliberately does not — see `refreshLayout`, which explains what reading
    /// it unasked cost. Both halves run off the main thread, because a fetch
    /// talks to a server and a settings window that freezes while someone's
    /// Wi-Fi times out is a worse bug than a stale count.
    @objc private func checkForUpdates() {
        guard !checking, let c = checkout() else {
            checkoutState = .missing
            return refreshLayout()
        }
        checking = true
        refreshLayout()
        // Off the main thread: a fetch talks to a server, and a settings window
        // that freezes while someone's Wi-Fi times out is a worse bug than a
        // stale count.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            c.fetch()
            let state = c.state()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.checkoutState = state
                // The user asked and this window is up, so a consent prompt
                // has had somewhere to appear. See `AutoUpdate.mayCheckUnasked`.
                AutoUpdater.shared.noteAsked(state)
                self.refreshLayout()
            }
        }
    }

    /// Remove Anode from the machine.
    ///
    /// Every path is listed before anything happens, and the checkbox decides
    /// the one question that actually matters — whether a month of measurements
    /// goes with it. An uninstaller that says "and associated files" is asking
    /// for trust it has not earned, and this one is deleting things it cannot
    /// put back.
    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Remove Anode from this Mac?"
        alert.alertStyle = .warning

        let wipe = NSButton(checkboxWithTitle: "Also remove settings and measurement history",
                            target: nil, action: nil)
        wipe.state = .off
        wipe.sizeToFit()
        alert.accessoryView = wipe

        alert.informativeText = Uninstall.summary(Uninstall.plan(removingData: false),
                                                  removingData: false)
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        // Cancel is the default: the destructive button should never be the one
        // a stray Return press hits.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch UpdateLauncher.launchUninstall(removingData: wipe.state == .on) {
        case .openedTerminal:
            updateNote.stringValue = "Uninstalling in Terminal…"
        case .failed(let why):
            updateNote.stringValue = why
        }
    }

    /// Turning it on checks straight away: the row then says where the checkout
    /// stands, and the check is what lets later ones run with no window up.
    @objc private func autoUpdateToggled() {
        settings.autoUpdateEnabled = autoUpdateCheckbox.state == .on
        if settings.autoUpdateEnabled { checkForUpdates() }
    }

    /// Runs `update.sh` in a VISIBLE Terminal window.
    ///
    /// The same rule the fan helper's install follows, for a stronger reason: this
    /// one quits the running app, rebuilds it and launches the replacement. An app
    /// that silently replaces itself while you are looking at it is not something
    /// to ship to be tidy. Opened through LaunchServices rather than Apple events,
    /// so it needs no Automation permission and cannot be denied by TCC.
    ///
    /// The checkbox above is the one exception, and it is opt-in: `AutoUpdater`
    /// runs the same script behind a progress window instead.
    @objc private func runUpdate() {
        guard let path = SourceCheckout.recordedPath(in: .main) else { return }
        switch UpdateLauncher.launch(checkout: path) {
        case .openedTerminal:
            updateNote.stringValue = "Updating in Terminal…"
        case .failed(let why):
            updateNote.stringValue = why
        }
    }

    override func refresh() {
        intervalSlider.doubleValue = settings.sampleInterval
        intervalValue.stringValue = String(format: "%.0f s", settings.sampleInterval)

        // The checkbox shows OS truth, not our last request. requiresApproval
        // is explicitly NOT "on": nothing will launch until the user approves.
        let status = settings.launchAtLoginStatus
        loginCheckbox.state = (status == .enabled || status == .enabledViaAgent) ? .on : .off
        switch status {
        case .enabled:
            // Say so, rather than showing nothing. An empty row after ticking a
            // box reads as "did that work?", and the answer is only visible after
            // a reboot — which is far too late to find out it did not.
            loginNote.stringValue = settings.startInMenuBarOnly
                ? "Opens at login, in the menu bar only."
                : "Opens at login, with its window."
            loginNote.isHidden = false
            loginButton.isHidden = false
        case .requiresApproval:
            loginNote.stringValue = "Waiting for approval in System Settings → General → Login Items."
            loginNote.isHidden = false
            loginButton.isHidden = false
        case .enabledViaAgent:
            // It WILL launch at login — via a launchd agent rather than the
            // modern registration, because this build is ad-hoc signed. Say
            // which mechanism is in force rather than claiming the other one:
            // the user will find it under "Allow in the Background", not under
            // Login Items, and being sent to the wrong pane is worse than being
            // told the truth about an unglamorous implementation.
            loginNote.stringValue = (settings.startInMenuBarOnly
                ? "Opens at login, in the menu bar only."
                : "Opens at login, with its window.")
                + " Using a launch agent, because this build is not signed with a "
                + "Developer ID. It appears in System Settings under Login Items → "
                + "Allow in the Background."
            loginNote.isHidden = false
            loginButton.isHidden = false
        case .notFound:
            // Unbundled dev builds report notFound, yet register() on the bare
            // executable still succeeds (measured on this machine) — keep the
            // checkbox usable and let the OS answer.
            loginNote.stringValue = Settings.notFoundNote(isBundled: Settings.isBundled())
            loginNote.isHidden = false
            loginButton.isHidden = true
        case .notRegistered, .unknown:
            if let err = settings.lastLaunchAtLoginError {
                loginNote.stringValue = "Could not change login item: \(err.localizedDescription)"
                loginNote.isHidden = false
            } else {
                loginNote.isHidden = true
            }
            loginButton.isHidden = true
        }

        menuBarOnlyCheckbox.state = settings.startInMenuBarOnly ? .on : .off
        // The checkbox keeps showing the STORED preference even when it cannot be
        // honoured — flipping it to "off" behind the user's back would lose a
        // setting they will get back the moment widgets return. The note carries
        // the override, because an override nobody can see is a control that
        // silently does nothing.
        let widgetsOn = settings.menuBarWidgetsEnabled
        menuBarOnlyCheckbox.isEnabled = widgetsOn
        menuBarOnlyNote.stringValue = widgetsOn
            ? "Applies to every launch, including opening Anode by hand — macOS gives an "
              + "app no way to tell a login launch from a double-click, so this is one switch and "
              + "not two. Click any menu bar widget, or open the app again, to get the window."
            : "Ignored while menu bar widgets are off (Menu Bar tab): starting with no window and "
              + "no widgets would leave nothing to click."

        // The version is always true; the checkout's state may not have been
        // looked at yet, and "unknown" is said rather than implied.
        updateStatus.stringValue = buildDescription
        // The checkout is NOT read when this window opens.
        //
        // Reading it runs git in the source folder, and a checkout under
        // Downloads, Desktop or Documents is behind a TCC consent dialog. Raising
        // one unasked is how this app stranded itself: the prompt goes
        // unanswered, and until it is answered the app cannot show ANY window —
        // frontmost, menu bar drawn, nothing on screen, cleared only by
        // relaunching. It also blocks the Dock from unhiding, so the machine
        // looks broken rather than the app.
        //
        // Pressing Check is the user asking, with this window already up to host
        // the dialog. `nil` means "not looked at", which is NOT `.missing` — one
        // is a question nobody asked, the other is an answer.
        let state = checkoutState
        updateNote.stringValue = checking
            ? "Checking…"
            : state.map(SourceCheckout.summary) ?? "Not checked yet."
        checkButton.isEnabled = !checking
            && state != .missing && state != .notARepository
        updateButton.isEnabled = !checking && (state?.isUpdatable ?? false)
        // Hidden rather than permanently greyed: on a machine whose checkout is
        // gone there is no update path at all, and a dead button is a worse
        // answer than none. The sentence above already explains why.
        updateButton.isHidden = state == nil || state == .missing || state == .notARepository
        autoUpdateCheckbox.state = settings.autoUpdateEnabled ? .on : .off
        autoUpdateCheckbox.isEnabled = AutoUpdater.shared.isAvailable
    }

    @objc private func intervalChanged() {
        settings.sampleInterval = intervalSlider.doubleValue
        // Continuous drag: label tracks even when the write was a no-op.
        intervalValue.stringValue = String(format: "%.0f s", settings.sampleInterval)
    }

    @objc private func loginToggled() {
        let wanted = loginCheckbox.state == .on
        settings.launchAtLogin = wanted
        refreshLayout()  // register may fail or land in requiresApproval — show truth now
        guard wanted else { return }   // turning it OFF needs no explanation
        explainLoginResult(settings.launchAtLoginStatus)
    }

    /// Say something. Anything.
    ///
    /// Reported by the user: "I just never saw one" — they ticked the box and
    /// nothing happened, so they had no idea whether it had worked or what to do
    /// next. That was accurate. On the success path `refresh()` hides both the
    /// note and the button, leaving a checkmark as the entire feedback, and
    /// macOS's own "added to Login Items" banner is a transient notification that
    /// Focus or Do Not Disturb swallows without trace.
    ///
    /// A registration that needs the user to go somewhere else and flip a second
    /// switch cannot be communicated by a checkbox changing state. So this is a
    /// deliberate modal: it is the one moment in the app where the next step is
    /// outside the app, and the user cannot be expected to guess it.
    ///
    /// It fires only on ENABLE, and only from the click — never from `refresh()`,
    /// which runs on every settings change from anywhere and would otherwise pop
    /// an alert while the user was doing something unrelated.
    private func explainLoginResult(_ status: Settings.LoginItemStatus) {
        let a = NSAlert()
        switch status {
        case .enabled, .enabledViaAgent:
            a.messageText = "Anode will open at login"
            a.informativeText = settings.startInMenuBarOnly
                ? "It will start in the menu bar with no window, as configured below.\n\n"
                  + "If macOS asks you to approve it, that switch lives in "
                  + "System Settings → General → Login Items."
                : "It will start with its window open.\n\n"
                  + "If macOS asks you to approve it, that switch lives in "
                  + "System Settings → General → Login Items."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Open Login Items…")
        case .requiresApproval:
            // The important case, and the one with no in-app remedy.
            a.alertStyle = .informational
            a.messageText = "One more step in System Settings"
            a.informativeText = "macOS needs you to approve Anode before it "
                + "can open at login.\n\nOpen System Settings → General → Login Items "
                + "and switch Anode on. Until you do, nothing will start "
                + "automatically — the checkbox here stays off on purpose, because "
                + "it reports what the system will actually do."
            a.addButton(withTitle: "Open Login Items…")
            a.addButton(withTitle: "Later")
        default:
            a.alertStyle = .warning
            a.messageText = "Could not set Anode to open at login"
            a.informativeText = settings.lastLaunchAtLoginError?.localizedDescription
                ?? "The system did not accept the request, and gave no reason."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Open Login Items…")
        }
        guard let w = view.window else { return }
        a.beginSheetModal(for: w) { [weak self] response in
            // "Open Login Items…" is the SECOND button except in the approval
            // case, where it is the first — keyed off the title rather than the
            // index so reordering a button cannot silently open the wrong thing.
            let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if idx >= 0, idx < a.buttons.count,
               a.buttons[idx].title.hasPrefix("Open Login Items") {
                self?.settings.openLoginItemsSettings()
            }
        }
    }

    @objc private func openLoginItems() {
        settings.openLoginItemsSettings()
    }

    @objc private func menuBarOnlyToggled() {
        settings.startInMenuBarOnly = menuBarOnlyCheckbox.state == .on
    }
}

// ── Battery ─────────────────────────────────────────────────────────────────

private final class BatteryPane: Pane {
    private var windowField: NSTextField!
    private var windowStepper: NSStepper!
    private var retentionField: NSTextField!
    private var retentionStepper: NSStepper!
    private var thresholdField: NSTextField!
    private var thresholdStepper: NSStepper!
    private var daemonsCheckbox: NSButton!
    private var loggingCheckbox: NSButton!

    override func loadView() {
        let (wf, ws, wRow) = fieldAndStepper(range: Settings.powerWindowHoursRange, step: 1,
                                             fractionDigits: 1, unit: "hours",
                                             action: #selector(windowChanged))
        (windowField, windowStepper) = (wf, ws)

        let (rf, rs, rRow) = fieldAndStepper(range: Settings.historyRetentionDaysRange, step: 1,
                                             fractionDigits: 1, unit: "days",
                                             action: #selector(retentionChanged))
        (retentionField, retentionStepper) = (rf, rs)

        let (tf, ts, tRow) = fieldAndStepper(range: Settings.minimumDisplayRange, step: 0.01,
                                             fractionDigits: 3, unit: "%/hr",
                                             action: #selector(thresholdChanged))
        (thresholdField, thresholdStepper) = (tf, ts)

        daemonsCheckbox = NSButton(checkboxWithTitle: "Show daemons and helpers",
                                   target: self, action: #selector(daemonsToggled))

        loggingCheckbox = NSButton(checkboxWithTitle: "Record battery history",
                                   target: self, action: #selector(loggingToggled))

        install(rows: [
            [rowLabel("History:"), loggingCheckbox],
            [spacer, caption("When off, no new samples are written. The \u{201C}10 hr power\u{201D} "
                             + "column stops advancing and reads \u{201C}\u{2014}\u{201D} for what "
                             + "was never recorded, and graph ranges longer than the live hour "
                             + "stop filling in. History already on disk is kept. While the window "
                             + "is closed the sampler also stops the periodic full sweep, which "
                             + "exists only to feed this.")],
            [rowLabel("Power window:"), wRow],
            [spacer, caption("Trailing on-battery window behind the \u{201C}10 hr power\u{201D} figure. "
                             + "Activity Monitor uses 12 hours; this stays configurable.")],
            [rowLabel("Keep history:"), rRow],
            [spacer, caption("Sampled history older than this is pruned.")],
            [rowLabel("Hide drains below:"), tRow],
            [spacer, caption("Rows under this floor display as \u{201C}<0.01\u{201D}.")],
            [rowLabel("Processes:"), daemonsCheckbox],
            [spacer, caption("When off, only apps are listed. Daemon drain still counts toward the "
                             + "measured total — hiding rows never moves energy onto other rows.")],
        ])
    }

    override func refresh() {
        windowField.doubleValue = settings.powerWindowHours
        windowStepper.doubleValue = settings.powerWindowHours
        retentionField.doubleValue = settings.historyRetentionDays
        retentionStepper.doubleValue = settings.historyRetentionDays
        thresholdField.doubleValue = settings.minimumDisplayPercentPerHour
        thresholdStepper.doubleValue = settings.minimumDisplayPercentPerHour
        daemonsCheckbox.state = settings.showDaemons ? .on : .off
        loggingCheckbox.state = settings.batteryLogging ? .on : .off
    }

    @objc private func windowChanged(_ sender: NSControl) {
        settings.powerWindowHours = sender.doubleValue
        refresh()  // snap field AND stepper to the clamped truth
    }

    @objc private func retentionChanged(_ sender: NSControl) {
        settings.historyRetentionDays = sender.doubleValue
        refresh()
    }

    @objc private func thresholdChanged(_ sender: NSControl) {
        settings.minimumDisplayPercentPerHour = sender.doubleValue
        refresh()
    }

    @objc private func daemonsToggled() {
        settings.showDaemons = daemonsCheckbox.state == .on
    }

    @objc private func loggingToggled() {
        settings.batteryLogging = loggingCheckbox.state == .on
    }
}

// ── Graph ───────────────────────────────────────────────────────────────────

/// Which lines the ledger screen's bottom graph draws while it is about the
/// battery. Same checkbox-list shape as the Menu Bar pane.
private final class GraphPane: Pane {
    private let lines = LedgerGraphLine.allCases
    private var boxes: [NSButton] = []
    /// See `MenuBarPane.isApplying`: the Pane base calls refresh() on every
    /// Settings write, which would otherwise reset the box the user just clicked
    /// before the write had landed.
    private var isApplying = false

    override func loadView() {
        boxes = lines.map {
            NSButton(checkboxWithTitle: $0.title + ($0.sessionOnly ? "  (current session only)" : ""),
                     target: self, action: #selector(toggled))
        }
        func column(_ views: [NSView]) -> NSStackView {
            let c = NSStackView(views: views)
            c.orientation = .vertical
            c.alignment = .leading
            c.spacing = 6
            return c
        }
        let half = (boxes.count + 1) / 2
        let list = NSStackView(views: [column(Array(boxes[..<half])),
                                       column(Array(boxes[half...]))])
        list.orientation = .horizontal
        list.alignment = .top
        list.spacing = 18

        let reset = NSButton(title: "Restore defaults", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        reset.controlSize = .small

        install(rows: [
            [rowLabel("Graph lines:"), list],
            [spacer, caption("The graph at the bottom of the main window, while it is about the "
                             + "battery. Every line is a percentage, so they all share one 0\u{2013}100 "
                             + "scale. Battery level is drawn against the right-hand axis.")],
            [spacer, caption("\u{201C}Current session only\u{201D} lines are not kept in history: they draw "
                             + "on the live hour and are blank on 6H, 24H and 7D. Fan speed also "
                             + "keeps the temperature sensors being read while the window is open.")],
            [spacer, reset],
        ])
    }

    override func refresh() {
        guard !isApplying else { return }
        let current = Set(settings.ledgerGraphLines)
        for (line, box) in zip(lines, boxes) {
            box.state = current.contains(line.rawValue) ? .on : .off
        }
    }

    @objc private func toggled() {
        isApplying = true
        defer { isApplying = false }
        let known = Set(lines.map(\.rawValue))
        // Lines this build does not know are kept, so unticking never destroys them.
        let unknown = settings.ledgerGraphLines.filter { !known.contains($0) }
        settings.ledgerGraphLines = zip(lines, boxes).filter { $1.state == .on }
            .map { $0.0.rawValue } + unknown
    }

    @objc private func restoreDefaults() {
        settings.ledgerGraphLines = Settings.defaultLedgerGraphLines
        refresh()
    }
}

// ── Menu Bar ────────────────────────────────────────────────────────────────

private final class MenuBarPane: Pane {
    private var choices: [MetricChoice] = []
    private var boxes: [NSButton] = []
    /// Set while the pane is applying the user's click.
    ///
    /// The Pane base observes every Settings write and calls refresh(). Writing
    /// the new selection therefore re-entered refresh() BEFORE the widget
    /// controller had been updated, so refresh() read the old membership and
    /// reset the checkbox the user had just toggled. It looked like clicks were
    /// being ignored, and like unchecking one box re-checked others.
    private var isApplying = false
    private var masterCheckbox: NSButton!
    /// What macOS actually did with the widgets. A checked box is a request; this
    /// line is the answer, which on a full menu bar is not the same thing.
    private var placementNote: NSTextField!
    private var placementButton: NSButton!
    private var placementToken: NSObjectProtocol?

    deinit {
        if let token = placementToken { NotificationCenter.default.removeObserver(token) }
    }

    override func loadView() {
        choices = PreferencesWindowController.metricProvider?()
            ?? PreferencesWindowController.fallbackMetrics
        boxes = choices.map {
            NSButton(checkboxWithTitle: $0.label, target: self, action: #selector(toggled))
        }

        // The group widget's checkbox gets an Edit… beside it: what that widget
        // CONTAINS is a property of that widget, so its editor belongs on its
        // own row rather than in a section of its own further down the pane.
        let rowsForList: [NSView] = zip(choices, boxes).map { choice, box in
            guard choice.id == MetricID.groupPlaceholder.rawValue else { return box }
            let edit = NSButton(title: "Edit\u{2026}", target: self,
                                action: #selector(editPanel))
            edit.bezelStyle = .rounded
            edit.controlSize = .small
            let row = NSStackView(views: [box, edit])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }

        // TWO columns. One checkbox per metric in a single column made this pane
        // ~740 pt tall with its toolbar — taller than a 13" screen's visible
        // height (a MacBook Neo has ~660 pt below the menu bar and above the
        // Dock), so the last boxes and the captions under them sat off screen
        // with nothing to scroll.
        func column(_ views: [NSView]) -> NSStackView {
            let c = NSStackView(views: views)
            c.orientation = .vertical
            c.alignment = .leading
            c.spacing = 6
            return c
        }
        let half = (rowsForList.count + 1) / 2
        let list = NSStackView(views: [column(Array(rowsForList[..<half])),
                                       column(Array(rowsForList[half...]))])
        list.orientation = .horizontal
        list.alignment = .top
        list.spacing = 18

        masterCheckbox = NSButton(checkboxWithTitle: "Show widgets in the menu bar",
                                  target: self, action: #selector(masterToggled))

        placementNote = caption("")
        placementNote.textColor = .systemOrange
        placementButton = NSButton(title: "Open Menu Bar Settings\u{2026}", target: self,
                                   action: #selector(openMenuBarSettings))
        placementButton.bezelStyle = .rounded
        placementButton.controlSize = .small
        placementToken = NotificationCenter.default.addObserver(
            forName: MenuBarWidgetController.placementDidChange, object: nil,
            queue: .main) { [weak self] _ in self?.refreshPlacement() }

        install(rows: [
            [rowLabel("Menu bar:"), masterCheckbox],
            [spacer, placementNote],
            [spacer, placementButton],
            [spacer, caption("When off, Anode keeps its Dock icon so the window is still one "
                             + "click away, and the sampler stops reading anything only a widget "
                             + "was showing. Which widgets are checked below is remembered.")],
            [rowLabel("Show in menu bar:"), list],
            [spacer, caption("Each checked item is its own widget in the menu bar; clicking one "
                             + "opens the main window.")],
            [spacer, caption("\u{201C}All metrics\u{201D} is one widget that opens into a list of "
                             + "readings. Edit\u{2026} chooses which readings that list shows and in "
                             + "what order, separately from the checkboxes here.")],
        ])
    }

    override func refresh() {
        // Outside the isApplying guard: that guard exists for the per-widget
        // boxes, which a click writes and this method would then overwrite. The
        // master switch is never the control mid-click, and it also arrives from
        // outside this pane (another Settings instance, `defaults write`), so it
        // must be re-read on every notification without exception.
        let on = settings.menuBarWidgetsEnabled
        masterCheckbox.state = on ? .on : .off
        for box in boxes { box.isEnabled = on }
        refreshPlacement()

        // Never fight the user mid-click: while applying, the boxes already show
        // the intended state and the controller is only just catching up.
        guard !isApplying else { return }
        let current = Set(PreferencesWindowController.currentWidgetIDs?()
                          ?? settings.menuBarWidgets)
        for (choice, box) in zip(choices, boxes) {
            box.state = current.contains(choice.id) ? .on : .off
        }
    }

    /// Held for the sheet's lifetime — an NSWindowController with no owner is
    /// deallocated the moment this method returns, taking its table's data
    /// source with it.
    private var panelEditor: PanelEditorController?

    @objc private func editPanel() {
        guard let host = view.window else { return }
        let editor = PanelEditorController()
        panelEditor = editor
        guard let sheet = editor.window else { return }
        host.beginSheet(sheet) { [weak self] _ in self?.panelEditor = nil }
    }

    private func refreshPlacement() {
        let text = settings.menuBarWidgetsEnabled
            ? MenuBarWidgetController.lastPlacement.settingsNote : nil
        placementNote.stringValue = text ?? ""
        placementNote.isHidden = text == nil
        placementButton.isHidden = text == nil
        syncGridRows()
    }

    @objc private func openMenuBarSettings() {
        AppDelegate.openMenuBarSettings()
    }

    @objc private func masterToggled() {
        settings.menuBarWidgetsEnabled = masterCheckbox.state == .on
    }

    @objc private func toggled() {
        isApplying = true
        defer { isApplying = false }

        let selected = zip(choices, boxes).filter { $1.state == .on }.map { $0.0.id }

        // Preserve bound IDs this pane cannot display (a metric from a module that
        // is not loaded right now) so unchecking never silently destroys a binding.
        // Sourced ONLY from the widget controller: reading Settings here let stale
        // IDs from an older build accumulate on every toggle, because they are
        // never in `choices` and so were re-appended as "unknown" each time.
        let known = Set(choices.map { $0.id })
        let unknown = (PreferencesWindowController.currentWidgetIDs?() ?? [])
            .filter { !known.contains($0) }

        let final = selected + unknown
        // Controller FIRST — it is the source of truth, and the Settings write
        // below triggers refresh() which reads back from it.
        PreferencesWindowController.onWidgetsChanged?(final)
        settings.menuBarWidgets = final
    }
}

extension MenuBarWidgetController.Placement {
    /// The sentence for a placement, or nil when there is nothing worth saying.
    var settingsNote: String? {
        switch self {
        case .unknown, .allShown:
            return nil
        case let .partlyHidden(shown, total):
            return "\u{26A0}\u{FE0E} macOS is showing \(shown) of \(total) widgets \u{2014} the menu bar "
                + "is full, so the rest were dropped. Anode has already shortened them; uncheck a "
                + "few, or quit another menu bar app, to see them all."
        case .noneShown:
            return "\u{26A0}\u{FE0E} macOS is not showing any Anode widget \u{2014} the menu bar is "
                + "full, even with Anode shrunk to one item. Quit another menu bar app to make room. "
                + "Anode keeps its Dock icon until one is visible."
        case .notAllowed:
            return "\u{26A0}\u{FE0E} macOS is hiding Anode\u{2019}s widgets: Anode is switched off under "
                + "System Settings \u{203A} Menu Bar \u{203A} Allow in the Menu Bar. Turn it on and "
                + "they appear straight away."
        }
    }
}
