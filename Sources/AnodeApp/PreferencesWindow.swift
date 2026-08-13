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

    private init() {
        let tabs = NSTabViewController()
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
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
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
        tokens.append(settings.observe(Settings.Key.any) { [weak self] in self?.refresh() })
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
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
        preferredContentSize = NSSize(width: 560, height: max(root.fittingSize.height, 120))
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
        let updateButtons = NSStackView(views: [checkButton, updateButton])
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
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["BSSourceCommit"] as? String ?? "unknown"
        return "\(version) (build \(build)) · \(commit)"
    }

    private func checkout() -> SourceCheckout? {
        SourceCheckout.recordedPath(in: .main).map(SourceCheckout.atPath)
    }

    /// Reads the checkout WITHOUT fetching, so opening this window never blocks
    /// on the network. The answer is still true, only older — pressing Check is
    /// what goes and looks.
    private func refreshCheckoutState() {
        guard let c = checkout() else { return checkoutState = .missing }
        checkoutState = c.state()
    }

    @objc private func checkForUpdates() {
        guard !checking, let c = checkout() else {
            checkoutState = .missing
            return refresh()
        }
        checking = true
        refresh()
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
                self.refresh()
            }
        }
    }

    /// Runs `update.sh` in a VISIBLE Terminal window.
    ///
    /// The same rule the fan helper's install follows, for a stronger reason: this
    /// one quits the running app, rebuilds it and launches the replacement. An app
    /// that silently replaces itself while you are looking at it is not something
    /// to ship to be tidy. Opened through LaunchServices rather than Apple events,
    /// so it needs no Automation permission and cannot be denied by TCC.
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
        if checkoutState == nil { refreshCheckoutState() }
        let state = checkoutState ?? .missing
        updateNote.stringValue = checking ? "Checking…" : SourceCheckout.summary(state)
        checkButton.isEnabled = !checking && state != .missing && state != .notARepository
        updateButton.isEnabled = !checking && state.isUpdatable
        // Hidden rather than permanently greyed: on a machine whose checkout is
        // gone there is no update path at all, and a dead button is a worse
        // answer than none. The sentence above already explains why.
        updateButton.isHidden = state == .missing || state == .notARepository
    }

    @objc private func intervalChanged() {
        settings.sampleInterval = intervalSlider.doubleValue
        // Continuous drag: label tracks even when the write was a no-op.
        intervalValue.stringValue = String(format: "%.0f s", settings.sampleInterval)
    }

    @objc private func loginToggled() {
        let wanted = loginCheckbox.state == .on
        settings.launchAtLogin = wanted
        refresh()  // register may fail or land in requiresApproval — show truth now
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

    override func loadView() {
        choices = PreferencesWindowController.metricProvider?()
            ?? PreferencesWindowController.fallbackMetrics
        boxes = choices.map {
            NSButton(checkboxWithTitle: $0.label, target: self, action: #selector(toggled))
        }

        let list = NSStackView(views: boxes)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6

        masterCheckbox = NSButton(checkboxWithTitle: "Show widgets in the menu bar",
                                  target: self, action: #selector(masterToggled))

        install(rows: [
            [rowLabel("Menu bar:"), masterCheckbox],
            [spacer, caption("When off, Anode keeps its Dock icon so the window is still one "
                             + "click away, and the sampler stops reading anything only a widget "
                             + "was showing. Which widgets are checked below is remembered.")],
            [rowLabel("Show in menu bar:"), list],
            [spacer, caption("Each checked metric becomes a menu bar widget. Widgets bind to any "
                             + "metric; clicking one opens the main window.")],
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

        // Never fight the user mid-click: while applying, the boxes already show
        // the intended state and the controller is only just catching up.
        guard !isApplying else { return }
        let current = Set(PreferencesWindowController.currentWidgetIDs?()
                          ?? settings.menuBarWidgets)
        for (choice, box) in zip(choices, boxes) {
            box.state = current.contains(choice.id) ? .on : .off
        }
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
