import AppKit
import PowerKit

// ── Charge Control (Beta Features) ──────────────────────────────────────────

/// The Charge Control section: the switch, the limit, Drain to Limit and Charge to Full, the four modes, Ready By with
/// its time of day, and a line saying what is happening now (see `ChargeController`).
///
/// Every control writes straight to `Settings`, which the controller observes; the two buttons press the controller
/// itself. What the section shows is read back from `Settings` and the controller in `redraw`, which runs when any
/// charge setting changes and whenever the controller says something it shows changed (its status, a button's
/// state, the discharge in force, the charge or the cable), so "Draining to 40%" appears when the helper starts
/// it rather than at the next 30 s tick.
final class ChargeControlFeature: BetaFeature {

    let title = "Charge Control"
    let summary = "Holds the battery at a charge limit you choose, and can drain it down to the limit while the Mac stays "
                + "plugged in. The limit applies while Anode is running, and is lifted when Anode quits, unless "
                + "another account's Anode is holding one. While Charge Control is on, Anode turns off Optimized "
                + "Battery Charging, and puts it back as it was when you turn Charge Control off or quit. Draining "
                + "needs the Anode helper, and so does holding the charge anywhere but 80, 85, 90, 95 or 100%, whether "
                + "for your limit, Pause When Hot, Drift Below the Limit or Hold Level During Sleep. Ready By holds the "
                + "battery where it is and charges it to the limit by a time you choose, waking the Mac if it has to; "
                + "it needs the Anode helper. Quit Anode before "
                + "removing it by hand (if it ever stopped without quitting, open it and quit it once more first): "
                + "dragging it to the Trash puts nothing back."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let controller: () -> ChargeController?
    private let installHelper: (@escaping (String) -> Void) -> Void
    private var tokens: [AnyObject] = []
    /// The controller this section listens to, and the token that keeps it listening; one per controller.
    private weak var hooked: ChargeController?
    private var hookToken: AnyObject?
    /// The redraw that ends "Reconnecting the charger…" when its time is up.
    private var reconnectRedraw: DispatchWorkItem?
    /// Everything under the switch that goes away while Charge Control is off. The status line, the install button
    /// and its note have rules of their own.
    private var rows: [NSView] = []
    /// See `installNoteLabel`. Kept until the next press, or until Charge Control is switched off.
    private var installNote: String?

    // Internal, so the tests can drive them as a click would.
    let enableCheckbox = NSButton(checkboxWithTitle: "Charge Control", target: nil, action: nil)
    let limitLabel = NSTextField(labelWithString: "Limit")
    let limitSlider = ChargeControlFeature.makeLimitSlider()
    let limitValueLabel = NSTextField(labelWithString: "")
    let drainButton = NSButton(title: "Drain to Limit", target: nil, action: nil)
    let fullChargeButton = NSButton(title: "Charge to Full", target: nil, action: nil)
    let driftCheckbox = NSButton(checkboxWithTitle: "Drift Below the Limit", target: nil, action: nil)
    let driftLabel = NSTextField(labelWithString: "")
    let driftStepper = ChargeControlFeature.makeStepper(Double(Settings.chargeDriftGapRange.lowerBound),
                                                          Double(Settings.chargeDriftGapRange.upperBound))
    let heatCheckbox = NSButton(checkboxWithTitle: "Pause When Hot", target: nil, action: nil)
    let heatLabel = NSTextField(labelWithString: "")
    let heatStepper = ChargeControlFeature.makeStepper(Settings.chargeMaxTemperatureRange.lowerBound,
                                                       Settings.chargeMaxTemperatureRange.upperBound)
    let sleepCheckbox = NSButton(checkboxWithTitle: "Hold Level During Sleep", target: nil, action: nil)
    let drainAutomaticallyCheckbox = NSButton(checkboxWithTitle: "Drain Automatically Above the Limit", target: nil, action: nil)
    let readyByCheckbox = NSButton(checkboxWithTitle: "Ready By", target: nil, action: nil)
    /// The time of day, hours and minutes, in the person's own format (12 or 24 hour, as their Mac shows it).
    let readyByTimePicker = ChargeControlFeature.makeTimePicker()
    let statusLabel = BetaFeaturesWindowController.wrapping("")
    /// One more line under the Ready By row, for a helper that controls charging but is too old for Ready By: the status
    /// above stays what the features that work make it.
    let readyByNoteLabel = BetaFeaturesWindowController.wrapping("", color: .systemOrange)
    let installButton = NSButton(title: "Install Helper\u{2026}", target: nil, action: nil)
    /// What the install started here last said: it runs in the Fans tab's flow, whose own strip is not on screen.
    let installNoteLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)

    init(settings: Settings = .shared,
         controller: @escaping () -> ChargeController? = { ChargeController.current },
         installHelper: @escaping (@escaping (String) -> Void) -> Void = { report in
             (NSApplication.shared.delegate as? AppDelegate)?.fansPane.control.installHelper(report: report)
         },
         timeZone: @escaping () -> TimeZone = { Calendar.autoupdatingCurrent.timeZone }) {
        self.settings = settings
        self.controller = controller
        self.installHelper = installHelper
        self.zone = timeZone
    }

    /// The zone the times in the status line are written in: the one the controller's calendar follows
    /// (`Calendar.autoupdatingCurrent`), asked each time, so the line says the time the controller acts on.
    private let zone: () -> TimeZone

    // ── Words ───────────────────────────────────────────────────────────────

    static let fullChargeTip = "Charge to 100% this once. It ends when you unplug."
    static let installTip = "The Anode helper is needed for Drain to Limit, Ready By, and holding the charge anywhere but "
        + "80, 85, 90, 95 or 100%."
    static let fullChargeBlockedTip = "Charge to Full needs the charger."
    static let drainTip = "Run the Mac from the battery while it stays plugged in, until the charge is down to the "
        + "limit. Needs the Anode helper."
    static let drainBlockedTip = "Drain to Limit needs the charger and a battery above the limit."
    /// The three holds pause where the charge is, which macOS can do by itself only at its own steps.
    static let holdNeedsHelperTip = "Without the Anode helper it can pause only at 80, 85, 90, 95 or 100%, and the "
        + "Mac charges on to the next of those."

    static let readyByTip = "While the Mac is on the charger and below the limit, hold the charge where it is until it "
        + "has to charge to be at the limit by this time every day. It only waits when that time is within the next "
        + "12 hours, and never below 30%: it charges to 30% first. Needs the Anode helper."

    /// What the status line needs besides the status: the battery and the drain as the controller last saw them.
    struct Facts: Equatable {
        /// The charge; nil when not known.
        var percent: Int?
        var cablePresent = true
        /// The drain the helper is running, if any (not the one asked for).
        var dischargeInForce: Int?
        /// A drain ended moments ago with the cable in, and macOS may still show "not charging".
        var reconnecting = false
    }

    /// The status line. macOS's limit is a ceiling, so the words say where the charge is against it: "charging to"
    /// below it, "holding" only at it. A drain is described by what the helper runs, not what was asked for.
    static func statusText(_ s: ChargeStatus, _ facts: Facts = Facts(),
                           time: (Date) -> String = { ChargeControlFeature.shortTime($0) }) -> String {
        switch s {
        case .off:
            return "Off"
        case .unavailable(let why), .needsHelper(let why), .refused(let why), .warning(let why), .waiting(let why):
            return why
        case .active(let d):
            let limit = d.osLimit, why = reasonText(d.reason)
            if let running = facts.dischargeInForce {
                return d.dischargeTo != nil ? "Draining to \(running)% on the adapter" : "Stopping the drain\u{2026}"
            }
            if d.dischargeTo != nil { return "Starting to drain\u{2026}" }
            if !facts.cablePresent { return "On battery; charging stops at \(limit)%" }
            if let r = d.readyBy { return readyByText(d, r, facts, time: time) }
            guard let p = facts.percent else { return "Charging stops at \(limit)% (\(why))" }
            if p < limit {
                // Measured: after a drain macOS shows "not charging" for about a minute. Nothing is wrong.
                return facts.reconnecting ? "Reconnecting the charger\u{2026}" : "Charging to \(limit)% (\(why))"
            }
            if p == limit { return "Holding \(limit)% (\(why))" }
            return "Not charging: \(p)% is above \(limit)% (\(why))"
        }
    }

    /// What Ready By is doing, in words, with its times on the person's own clock: holding until the moment to start,
    /// or charging to be at the limit by the time they chose. A battery still below the level it is to hold at (it is
    /// charging up to the lowest it holds) says so first.
    private static func readyByText(_ d: ChargeDecision, _ r: ReadyByState, _ facts: Facts,
                                    time: (Date) -> String) -> String {
        let by = "reach \(r.raiseTo)% by \(time(r.by))"
        guard let raiseAt = r.raiseAt else { return "Charging to \(by)" }
        if let p = facts.percent, p + 1 < d.osLimit {
            return "Charging to \(d.osLimit)%, then holding until \(time(raiseAt)), then charging to \(by)"
        }
        return "Holding at \(d.osLimit)% until \(time(raiseAt)), then charging to \(by)"
    }

    /// A time of day in the person's own short format: "7:00 AM" on a Mac set to 12 hours in the US, "07:00" on one set
    /// to 24. `locale` and `timeZone` are parameters for the tests.
    static func shortTime(_ date: Date, locale: Locale = .autoupdatingCurrent,
                          timeZone: TimeZone = Calendar.autoupdatingCurrent.timeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Why the limit is what it is, in the words the section uses for the setting behind it.
    static func reasonText(_ r: ChargeReason) -> String {
        switch r {
        case .limit: return "your limit"
        case .fullCharge: return "Charge to Full"
        case .heat: return "Pause When Hot"
        case .sleeping: return "sleeping"
        case .drift: return "drifting"
        case .draining: return "draining"
        case .drained: return "drained"
        case .readyBy: return "Ready By"
        }
    }

    /// "at": the policy charges again once the charge is down to the limit minus the gap, not only below it.
    static func driftText(gap: Int) -> String { "recharge at limit \u{2212} \(gap)%" }

    /// "at": the policy pauses once the pack reaches the temperature, not only above it.
    static func heatText(maxC: Double) -> String {
        // Whole degrees as whole numbers; a stored half degree (from `defaults write`) as stored, not rounded away.
        let n = maxC == maxC.rounded() ? String(Int(maxC)) : String(format: "%.1f", maxC)
        return "pause at \(n) \u{00B0}C"
    }

    // ── Building ────────────────────────────────────────────────────────────

    private static func makeLimitSlider() -> NSSlider {
        let s = NSSlider()
        // The cell first: it holds the range, the value, the target and the action.
        s.cell = TrackingSliderCell()
        s.isVertical = false
        s.minValue = Double(Settings.chargeLimitRange.lowerBound)
        s.maxValue = Double(Settings.chargeLimitRange.upperBound)
        s.doubleValue = s.maxValue
        // Written on release: every write reaches macOS's charge limit (or the helper), so one per drag, not one per
        // pixel. The percentage beside it follows the knob through the cell instead.
        s.isContinuous = false
        return s
    }

    /// Hours and minutes, and nothing else. The date it holds is a day that has no daylight saving, in a calendar and a
    /// zone of its own (UTC), so that what it shows is exactly the number of minutes after midnight and a change of the
    /// Mac's time zone never moves it; the locale is the person's, so its format is theirs.
    private static func makeTimePicker() -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerStyle = .textFieldAndStepper
        p.datePickerElements = .hourMinute
        p.datePickerMode = .single
        p.calendar = utcCalendar
        p.timeZone = utcCalendar.timeZone
        // The person's own way of writing a time: 19:30 with 24-hour time switched on in System Settings, 7:30 PM with
        // it off (both rendered on a Mac17,9, macOS 27.0). Auto-updating, so a change of that setting while Anode runs
        // is followed.
        p.locale = .autoupdatingCurrent
        p.dateValue = pickerDate(minutes: ChargePolicy.defaultReadyByMinutes)
        return p
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    /// The picker's date for a time of day: 1 January 2001, UTC, at that time.
    static func pickerDate(minutes: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
    }

    /// The time of day a picker date shows, in minutes after midnight. Whatever day the picker has stepped onto.
    static func minutes(ofPickerDate d: Date) -> Int {
        let c = utcCalendar.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func makeStepper(_ min: Double, _ max: Double) -> NSStepper {
        let s = NSStepper()
        s.minValue = min
        s.maxValue = max
        s.increment = 1
        s.valueWraps = false
        s.autorepeat = true
        return s
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggled)
        limitSlider.target = self
        limitSlider.action = #selector(limitReleased)
        (limitSlider.cell as? TrackingSliderCell)?.onTrack = { [weak self] in self?.limitDragged() }
        (limitSlider.cell as? TrackingSliderCell)?.onStop = { [weak self] in self?.limitDragEnded() }
        limitSlider.translatesAutoresizingMaskIntoConstraints = false
        limitSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        limitValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        limitValueLabel.translatesAutoresizingMaskIntoConstraints = false
        limitValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        // The slider and the steppers have no title of their own for VoiceOver to read.
        limitSlider.setAccessibilityLabel("Charge limit")
        driftStepper.setAccessibilityLabel("Drift Below the Limit: how far below the limit to recharge")
        heatStepper.setAccessibilityLabel("Pause When Hot: temperature to pause at")
        readyByTimePicker.setAccessibilityLabel("Ready By: the time of day the battery is to be at the limit")

        drainButton.target = self
        drainButton.action = #selector(drainPressed)
        drainButton.toolTip = Self.drainTip
        fullChargeButton.target = self
        fullChargeButton.action = #selector(fullChargePressed)
        fullChargeButton.toolTip = Self.fullChargeTip
        for b in [drainButton, fullChargeButton, installButton] { b.bezelStyle = .rounded }
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installPressed)
        installButton.toolTip = Self.installTip

        driftCheckbox.target = self
        driftCheckbox.action = #selector(driftToggled)
        driftCheckbox.toolTip = "Once the battery reaches the limit, let it drift down, and charge again only when it "
            + "has fallen this far below the limit. " + Self.holdNeedsHelperTip
        driftStepper.target = self
        driftStepper.action = #selector(driftGapStepped)
        heatCheckbox.target = self
        heatCheckbox.action = #selector(heatToggled)
        heatCheckbox.toolTip = "Pause charging while the battery is this warm, and for five minutes after it cools. "
            + Self.holdNeedsHelperTip
        heatStepper.target = self
        heatStepper.action = #selector(heatStepped)
        sleepCheckbox.target = self
        sleepCheckbox.action = #selector(sleepToggled)
        sleepCheckbox.toolTip = "While the Mac sleeps on the adapter, the charge stays where it was. "
            + Self.holdNeedsHelperTip
        readyByCheckbox.target = self
        readyByCheckbox.action = #selector(readyByToggled)
        readyByCheckbox.toolTip = Self.readyByTip
        readyByTimePicker.target = self
        readyByTimePicker.action = #selector(readyByTimeChanged)
        readyByTimePicker.toolTip = Self.readyByTip
        drainAutomaticallyCheckbox.target = self
        drainAutomaticallyCheckbox.action = #selector(drainAutomaticallyToggled)
        drainAutomaticallyCheckbox.toolTip = "Whenever the battery is above the limit on the adapter, run from the battery "
            + "until it is down to the limit. Needs the Anode helper."

        func row(_ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: views)
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        let limitRow = row([limitLabel, limitSlider, limitValueLabel])
        let buttonRow = row([drainButton, fullChargeButton])
        let driftRow = row([driftCheckbox, driftLabel, driftStepper])
        let heatRow = row([heatCheckbox, heatLabel, heatStepper])
        let readyByRow = row([readyByCheckbox, readyByTimePicker])
        rows = [limitRow, buttonRow, driftRow, heatRow, sleepCheckbox, drainAutomaticallyCheckbox, readyByRow,
                readyByNoteLabel]

        let column = NSStackView(views: [enableCheckbox] + rows + [statusLabel, installButton, installNoteLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        let keys = [Settings.Key.chargeControlEnabled, Settings.Key.chargeLimit, Settings.Key.chargeDriftEnabled,
                    Settings.Key.chargeDriftGap, Settings.Key.chargePauseWhenHotEnabled,
                    Settings.Key.chargeMaxTemperatureC, Settings.Key.chargeHoldDuringSleep,
                    Settings.Key.chargeDrainAutomatically, Settings.Key.chargeReadyByEnabled,
                    Settings.Key.chargeReadyByMinutes]
        tokens = keys.map { settings.observe($0) { [weak self] in self?.redraw() } }
        redraw()
        return column
    }

    /// Listen to the controller, once per controller. Its other listeners are not affected, nor can they displace
    /// this one.
    private func hookController() {
        guard let c = controller(), c !== hooked else { return }
        hooked = c
        hookToken = c.observeChanges { [weak self] in self?.redraw() }
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func toggled() { settings.chargeControlEnabled = enableCheckbox.state == .on }

    /// The knob moved under the pointer: the label follows it, nothing is written yet.
    private func limitDragged() {
        limitValueLabel.stringValue = "\(Int(limitSlider.doubleValue.rounded()))%"
    }

    /// The drag ended. A slider disabled or hidden under the pointer sends no action, which would leave the knob on a
    /// value nobody stored; so the section is redrawn from the stored limit once the drag is over. Not now: the
    /// action, when there is one, comes after this, and must find the knob where the person let it go. The default
    /// mode only: the run loop leaves the tracking mode before it gets there.
    private func limitDragEnded() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in self?.redraw() }
    }

    /// The knob was let go (or moved by the keyboard): write the limit in whole percent, and settle the knob on it.
    @objc private func limitReleased() {
        settings.chargeLimit = Int(limitSlider.doubleValue.rounded())
        // Not left to `refresh`, which keeps its hands off the knob while a drag may still be under way.
        limitSlider.doubleValue = Double(settings.chargeLimit)
        limitValueLabel.stringValue = "\(settings.chargeLimit)%"
    }

    @objc private func drainPressed() { controller()?.pressDrain(); redraw() }
    @objc private func fullChargePressed() { controller()?.pressFullCharge(); redraw() }
    /// The install says how it is going here, as it goes: waiting, a dialog already up, how it ended.
    @objc private func installPressed() {
        installNote = nil
        redraw()
        installHelper { [weak self] text in
            self?.installNote = text
            // With Charge Control off nothing else would ask the helper that has just been installed, so a charger it
            // is owed for is looked at now (it asks only when there is a debt, and only an installed helper).
            self?.controller()?.recheckHelper()
            self?.redraw()
            // And again shortly: launchd has only just been given the helper, and a look made in the same instant can
            // find nothing there. Without this the line saying the helper is needed, and this button, stayed on screen
            // beside the note saying it was installed.
            self?.lookAgainAfterAnInstall()
        }
    }

    /// When the looks after an install's report are made, in seconds. Internal for the tests.
    static let looksAfterAnInstall: [TimeInterval] = [1.5, 4]
    private var installLooks = 0

    private func lookAgainAfterAnInstall() {
        installLooks += 1
        let mine = installLooks
        for delay in Self.looksAfterAnInstall {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // Only for the latest report: an install says several things as it goes.
                guard let self, self.installLooks == mine else { return }
                self.controller()?.recheckHelper()
                self.redraw()
            }
        }
    }

    @objc private func driftToggled() { settings.chargeDriftEnabled = driftCheckbox.state == .on }
    @objc private func driftGapStepped() { settings.chargeDriftGap = driftStepper.integerValue }
    @objc private func heatToggled() { settings.chargePauseWhenHotEnabled = heatCheckbox.state == .on }
    @objc private func heatStepped() { settings.chargeMaxTemperatureC = heatStepper.doubleValue.rounded() }
    @objc private func sleepToggled() { settings.chargeHoldDuringSleep = sleepCheckbox.state == .on }
    @objc private func drainAutomaticallyToggled() { settings.chargeDrainAutomatically = drainAutomaticallyCheckbox.state == .on }
    @objc private func readyByToggled() { settings.chargeReadyByEnabled = readyByCheckbox.state == .on }
    @objc private func readyByTimeChanged() {
        settings.chargeReadyByMinutes = Self.minutes(ofPickerDate: readyByTimePicker.dateValue)
    }

    // ── Showing ─────────────────────────────────────────────────────────────

    /// The window is showing the section, or the app came forward with it open: the controller looks again for a
    /// helper that has not answered (installed from a terminal since, say), and the section is redrawn. This is the
    /// one place that looks; the controller does not do it on a timer.
    func refresh() {
        controller()?.recheckHelper()
        redraw()
    }

    /// Reads only: it never writes a setting, presses the controller or asks it to look for the helper, so the
    /// observers and the controller's callback cannot loop through it. (It forgets the install's note when switched
    /// off, which is the section's own.)
    private func redraw() {
        hookController()
        let on = settings.chargeControlEnabled
        let c = controller()
        let status = c?.status ?? .off
        var unavailable = false, needsHelper = false, refused = false
        switch status {
        case .unavailable: unavailable = true
        case .needsHelper: needsHelper = true
        case .refused, .warning: refused = true
        case .off, .active, .waiting: break
        }
        // Off, or on but impossible on this Mac: nothing below the switch can do anything.
        let usable = on && !unavailable

        enableCheckbox.state = on ? .on : .off

        // The controller's timer runs while a drag is tracked; it must not pull the knob from under the pointer.
        if (limitSlider.cell as? TrackingSliderCell)?.isTracking != true {
            limitSlider.doubleValue = Double(settings.chargeLimit)
            limitValueLabel.stringValue = "\(settings.chargeLimit)%"
        }
        limitSlider.isEnabled = usable
        for label in [limitLabel, limitValueLabel] {
            label.textColor = usable ? .labelColor : .disabledControlTextColor
        }

        // A button that would undo itself at once waits, and says why: Charge to Full and a drain both end when the
        // cable is out, and a drain ends at the limit. One already pressed can always be pressed again to stop.
        let cable = c?.isCablePresent ?? false
        let percent = c?.batteryPercent
        let fullChargeRequested = c?.isFullChargeRequested == true, drainRequested = c?.isDrainRequested == true
        let aboveTarget = percent.map { $0 > ChargePolicy.dischargeTarget(limit: settings.chargeLimit) } ?? true
        let fullChargeCan = fullChargeRequested || cable
        let drainCan = drainRequested || (cable && aboveTarget)
        // Not while it waits out the delay after an unclean exit: it holds nothing yet, and a press would do nothing.
        let waiting = c?.isWaitingToStart == true
        let pressable = usable && c != nil && !waiting
        drainButton.title = drainRequested ? "Stop Draining" : "Drain to Limit"
        fullChargeButton.title = fullChargeRequested ? "Cancel Charge to Full" : "Charge to Full"
        drainButton.isEnabled = pressable && drainCan
        fullChargeButton.isEnabled = pressable && fullChargeCan
        drainButton.toolTip = pressable && !drainCan ? Self.drainBlockedTip : Self.drainTip
        fullChargeButton.toolTip = pressable && !fullChargeCan ? Self.fullChargeBlockedTip : Self.fullChargeTip

        let drift = settings.chargeDriftEnabled, heat = settings.chargePauseWhenHotEnabled
        driftCheckbox.state = drift ? .on : .off
        driftCheckbox.isEnabled = usable
        driftStepper.integerValue = settings.chargeDriftGap
        driftStepper.isEnabled = usable && drift
        driftLabel.stringValue = Self.driftText(gap: settings.chargeDriftGap)
        driftLabel.textColor = usable && drift ? .labelColor : .disabledControlTextColor

        heatCheckbox.state = heat ? .on : .off
        heatCheckbox.isEnabled = usable
        heatStepper.doubleValue = settings.chargeMaxTemperatureC
        heatStepper.isEnabled = usable && heat
        heatLabel.stringValue = Self.heatText(maxC: settings.chargeMaxTemperatureC)
        heatLabel.textColor = usable && heat ? .labelColor : .disabledControlTextColor

        sleepCheckbox.state = settings.chargeHoldDuringSleep ? .on : .off
        sleepCheckbox.isEnabled = usable
        drainAutomaticallyCheckbox.state = settings.chargeDrainAutomatically ? .on : .off
        drainAutomaticallyCheckbox.isEnabled = usable
        readyByCheckbox.state = settings.chargeReadyByEnabled ? .on : .off
        readyByCheckbox.isEnabled = usable
        // Not while it is being edited with the keyboard to the value it already holds: only a time that differs.
        if Self.minutes(ofPickerDate: readyByTimePicker.dateValue) != settings.chargeReadyByMinutes {
            readyByTimePicker.dateValue = Self.pickerDate(minutes: settings.chargeReadyByMinutes)
        }
        readyByTimePicker.isEnabled = usable && settings.chargeReadyByEnabled

        for r in rows { r.isHidden = !on }
        let readyByNote = usable && c?.readyByNeedsNewerHelper == true
        readyByNoteLabel.stringValue = readyByNote ? ChargeController.readyByNeedsNewerHelperText : ""
        readyByNoteLabel.isHidden = !readyByNote
        var facts = Facts(percent: percent, cablePresent: cable, dischargeInForce: c?.dischargeInForce)
        if let left = c?.chargerReconnectTimeLeft() {
            facts.reconnecting = true
            redraw(after: left)
        }
        // Not running (off, or waiting out the delay after an unclean exit), the one line that can show besides the
        // delay's own: a drain's end never confirmed, so the charger may still be cut. It is shown first.
        let offWarning = !on || waiting ? c?.offWarning : nil
        statusLabel.stringValue = offWarning ?? Self.statusText(status, facts, time: { [zone] in
            Self.shortTime($0, timeZone: zone())
        })
        statusLabel.textColor = unavailable || needsHelper || refused || offWarning != nil
            ? .systemOrange : .secondaryLabelColor
        // A switched-on section with nothing to report yet (the controller has not answered) shows no line.
        statusLabel.isHidden = offWarning == nil && (!on || status == .off)
        // Beside a line that points at it (`ChargeController.cutWarningsThatOfferInstall`), on or off: a charger that
        // may still be cut and no helper installed to switch it back on, which the Fans tab offers no button for
        // unless fan control is on (or blocked).
        let offersInstallForCut = ChargeController.cutWarningsThatOfferInstall.contains(statusLabel.stringValue)
            && !statusLabel.isHidden
        // And whenever something switched on needs more of the helper than there is: none installed, or one too old
        // (Ready By needs a newer one than a drain does). Not before the helper has answered, and not for a helper
        // that is there and knows enough.
        // Also with nothing switched on that needs it, when no helper answers at all: a person who wants to drain, or a
        // limit other than the five macOS takes itself, has to be able to install it first, and found no button here.
        var helperFallsShort = false
        if usable, let reach = c?.helperReach {
            if reach == .none {
                helperFallsShort = true
            } else if let needed = ChargeController.helperNeeded(by: settings) {
                helperFallsShort = reach < needed
            }
        }
        installButton.isHidden = !((on && needsHelper) || offersInstallForCut || helperFallsShort)
        // Kept once the helper is there and the button has gone (it says the install worked), not once switched off.
        if !on, !offersInstallForCut { installNote = nil }
        installNoteLabel.stringValue = installNote ?? ""
        installNoteLabel.isHidden = installNote == nil
        layoutChanged?()
    }

    /// Redraw once more when "Reconnecting the charger…" runs out; nothing else would say so until the next change.
    private func redraw(after delay: TimeInterval) {
        reconnectRedraw?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.redraw() }
        reconnectRedraw = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5, execute: w)
    }
}

/// A slider cell that reports every step of a drag, and whether one is under way.
///
/// The slider sends its action only when the knob is let go (`isContinuous = false`); this is how the label beside it
/// still follows the knob. AppKit tracks a slider through its cell (`startTracking`, `continueTracking`,
/// `stopTracking`), checked on this macOS: an `NSSlider` has no gesture recognizers and its cell is called on each drag.
final class TrackingSliderCell: NSSliderCell {

    var onTrack: (() -> Void)?
    /// The drag ended, whether or not an action follows.
    var onStop: (() -> Void)?
    private(set) var isTracking = false

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        let go = super.startTracking(at: startPoint, in: controlView)
        // A drag AppKit refuses to start (a disabled slider) gets no `stopTracking`, so it must not count as one.
        isTracking = go
        if go { onTrack?() }
        return go
    }

    override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        let go = super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
        onTrack?()
        return go
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        isTracking = false
        onStop?()
    }
}
