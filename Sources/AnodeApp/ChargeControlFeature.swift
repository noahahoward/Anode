import AppKit
import PowerKit

// ── Charge Control (Beta Features) ──────────────────────────────────────────

/// The Charge Control section: the switch, the limit, Discharge and Top Up, the four modes, and a line saying what
/// is happening now (see `ChargeController`).
///
/// Every control writes straight to `Settings`, which the controller observes; the two buttons press the controller
/// itself. What the section shows is read back from `Settings` and the controller in `redraw`, which runs when any
/// charge setting changes and whenever the controller says something it shows changed (its status, a button's
/// state, the discharge in force, the charge or the cable), so "Discharging to 40%" appears when the helper starts
/// it rather than at the next 30 s tick.
final class ChargeControlFeature: BetaFeature {

    let title = "Charge Control"
    let summary = "Holds the battery at a charge limit you choose, and can drain it down to the limit while the Mac stays "
                + "plugged in. The limit keeps working while Anode is closed. While Charge Control is on, Anode turns off "
                + "Optimized Battery Charging, and puts it back as it was when you turn Charge Control off. Discharging "
                + "needs the Anode helper, and so does holding the charge anywhere but 80, 85, 90, 95 or 100%, whether "
                + "for your limit, Heat Protection, Sailing Mode or Stop charging when sleeping. Turn Charge Control off "
                + "before removing Anode by hand: dragging it to the Trash puts nothing back."
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
    let dischargeButton = NSButton(title: "Discharge", target: nil, action: nil)
    let topUpButton = NSButton(title: "Top Up", target: nil, action: nil)
    let sailingCheckbox = NSButton(checkboxWithTitle: "Sailing Mode", target: nil, action: nil)
    let sailingLabel = NSTextField(labelWithString: "")
    let sailingStepper = ChargeControlFeature.makeStepper(Double(Settings.chargeSailingGapRange.lowerBound),
                                                          Double(Settings.chargeSailingGapRange.upperBound))
    let heatCheckbox = NSButton(checkboxWithTitle: "Heat Protection", target: nil, action: nil)
    let heatLabel = NSTextField(labelWithString: "")
    let heatStepper = ChargeControlFeature.makeStepper(Settings.chargeMaxTemperatureRange.lowerBound,
                                                       Settings.chargeMaxTemperatureRange.upperBound)
    let sleepCheckbox = NSButton(checkboxWithTitle: "Stop charging when sleeping", target: nil, action: nil)
    let autoDischargeCheckbox = NSButton(checkboxWithTitle: "Discharge automatically to the limit", target: nil, action: nil)
    let statusLabel = BetaFeaturesWindowController.wrapping("")
    let installButton = NSButton(title: "Install Helper\u{2026}", target: nil, action: nil)
    /// What the install started here last said: it runs in the Fans tab's flow, whose own strip is not on screen.
    let installNoteLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)

    init(settings: Settings = .shared,
         controller: @escaping () -> ChargeController? = { ChargeController.current },
         installHelper: @escaping (@escaping (String) -> Void) -> Void = { report in
             (NSApplication.shared.delegate as? AppDelegate)?.fansPane.control.installHelper(report: report)
         }) {
        self.settings = settings
        self.controller = controller
        self.installHelper = installHelper
    }

    // ── Words ───────────────────────────────────────────────────────────────

    static let topUpTip = "Charge to 100% this once. It ends when you unplug."
    static let topUpBlockedTip = "Top Up needs the charger."
    static let dischargeTip = "Run the Mac from the battery while it stays plugged in, until the charge is down to the "
        + "limit. Needs the Anode helper."
    static let dischargeBlockedTip = "Discharge needs the charger and a battery above the limit."
    /// The three holds pause where the charge is, which macOS can do by itself only at its own steps.
    static let holdNeedsHelperTip = "Without the Anode helper it can pause only at 80, 85, 90, 95 or 100%, and the "
        + "Mac charges on to the next of those."

    /// What the status line needs besides the status: the battery and the discharge as the controller last saw them.
    struct Facts: Equatable {
        /// The charge; nil when not known.
        var percent: Int?
        var cablePresent = true
        /// The discharge the helper is running, if any (not the one asked for).
        var dischargeInForce: Int?
        /// A discharge ended moments ago with the cable in, and macOS may still show "not charging".
        var reconnecting = false
    }

    /// The status line. macOS's limit is a ceiling, so the words say where the charge is against it: "charging to"
    /// below it, "holding" only at it. A discharge is described by what the helper runs, not what was asked for.
    static func statusText(_ s: ChargeStatus, _ facts: Facts = Facts()) -> String {
        switch s {
        case .off:
            return "Off"
        case .unavailable(let why), .needsHelper(let why), .refused(let why), .warning(let why):
            return why
        case .active(let d):
            let limit = d.osLimit, why = reasonText(d.reason)
            if let running = facts.dischargeInForce {
                return d.dischargeTo != nil ? "Discharging to \(running)% on the adapter" : "Stopping the discharge\u{2026}"
            }
            if d.dischargeTo != nil { return "Starting to discharge\u{2026}" }
            if !facts.cablePresent { return "On battery; charging stops at \(limit)%" }
            guard let p = facts.percent else { return "Charging stops at \(limit)% (\(why))" }
            if p < limit {
                // Measured: after a discharge macOS shows "not charging" for about a minute. Nothing is wrong.
                return facts.reconnecting ? "Reconnecting the charger\u{2026}" : "Charging to \(limit)% (\(why))"
            }
            if p == limit { return "Holding \(limit)% (\(why))" }
            return "Not charging: \(p)% is above \(limit)% (\(why))"
        }
    }

    /// Why the limit is what it is, in the words the section uses for the setting behind it.
    static func reasonText(_ r: ChargeReason) -> String {
        switch r {
        case .limit: return "your limit"
        case .topUp: return "Top Up"
        case .heat: return "Heat Protection"
        case .sleeping: return "sleeping"
        case .sailing: return "sailing"
        case .discharging: return "discharging"
        case .discharged: return "discharged"
        }
    }

    /// "at": the policy charges again once the charge is down to the limit minus the gap, not only below it.
    static func sailingText(gap: Int) -> String { "recharge at limit \u{2212} \(gap)%" }

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
        sailingStepper.setAccessibilityLabel("Sailing Mode: how far below the limit to recharge")
        heatStepper.setAccessibilityLabel("Heat Protection: temperature to pause at")

        dischargeButton.target = self
        dischargeButton.action = #selector(dischargePressed)
        dischargeButton.toolTip = Self.dischargeTip
        topUpButton.target = self
        topUpButton.action = #selector(topUpPressed)
        topUpButton.toolTip = Self.topUpTip
        for b in [dischargeButton, topUpButton, installButton] { b.bezelStyle = .rounded }
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installPressed)

        sailingCheckbox.target = self
        sailingCheckbox.action = #selector(sailingToggled)
        sailingCheckbox.toolTip = "Once the battery reaches the limit, let it drift down, and charge again only when it "
            + "has fallen this far below the limit. " + Self.holdNeedsHelperTip
        sailingStepper.target = self
        sailingStepper.action = #selector(sailingGapStepped)
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
        autoDischargeCheckbox.target = self
        autoDischargeCheckbox.action = #selector(autoDischargeToggled)
        autoDischargeCheckbox.toolTip = "Whenever the battery is above the limit on the adapter, run from the battery "
            + "until it is down to the limit. Needs the Anode helper."

        func row(_ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: views)
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        let limitRow = row([limitLabel, limitSlider, limitValueLabel])
        let buttonRow = row([dischargeButton, topUpButton])
        let sailingRow = row([sailingCheckbox, sailingLabel, sailingStepper])
        let heatRow = row([heatCheckbox, heatLabel, heatStepper])
        rows = [limitRow, buttonRow, sailingRow, heatRow, sleepCheckbox, autoDischargeCheckbox]

        let column = NSStackView(views: [enableCheckbox] + rows + [statusLabel, installButton, installNoteLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        let keys = [Settings.Key.chargeControlEnabled, Settings.Key.chargeLimit, Settings.Key.chargeSailingEnabled,
                    Settings.Key.chargeSailingGap, Settings.Key.chargeHeatProtectionEnabled,
                    Settings.Key.chargeMaxTemperatureC, Settings.Key.chargeStopWhenSleeping,
                    Settings.Key.chargeAutomaticDischarge]
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

    @objc private func dischargePressed() { controller()?.pressDischarge(); redraw() }
    @objc private func topUpPressed() { controller()?.pressTopUp(); redraw() }
    /// The install says how it is going here, as it goes: waiting, a dialog already up, how it ended.
    @objc private func installPressed() {
        installNote = nil
        redraw()
        installHelper { [weak self] text in
            self?.installNote = text
            self?.redraw()
        }
    }

    @objc private func sailingToggled() { settings.chargeSailingEnabled = sailingCheckbox.state == .on }
    @objc private func sailingGapStepped() { settings.chargeSailingGap = sailingStepper.integerValue }
    @objc private func heatToggled() { settings.chargeHeatProtectionEnabled = heatCheckbox.state == .on }
    @objc private func heatStepped() { settings.chargeMaxTemperatureC = heatStepper.doubleValue.rounded() }
    @objc private func sleepToggled() { settings.chargeStopWhenSleeping = sleepCheckbox.state == .on }
    @objc private func autoDischargeToggled() { settings.chargeAutomaticDischarge = autoDischargeCheckbox.state == .on }

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
        case .off, .active: break
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

        // A button that would undo itself at once waits, and says why: Top Up and a discharge both end when the
        // cable is out, and a discharge ends at the limit. One already pressed can always be pressed again to stop.
        let cable = c?.isCablePresent ?? false
        let percent = c?.batteryPercent
        let topUpRequested = c?.isTopUpRequested == true, dischargeRequested = c?.isDischargeRequested == true
        let aboveTarget = percent.map { $0 > ChargePolicy.dischargeTarget(limit: settings.chargeLimit) } ?? true
        let topUpCan = topUpRequested || cable
        let dischargeCan = dischargeRequested || (cable && aboveTarget)
        let pressable = usable && c != nil
        dischargeButton.title = dischargeRequested ? "Stop Discharge" : "Discharge"
        topUpButton.title = topUpRequested ? "Cancel Top Up" : "Top Up"
        dischargeButton.isEnabled = pressable && dischargeCan
        topUpButton.isEnabled = pressable && topUpCan
        dischargeButton.toolTip = pressable && !dischargeCan ? Self.dischargeBlockedTip : Self.dischargeTip
        topUpButton.toolTip = pressable && !topUpCan ? Self.topUpBlockedTip : Self.topUpTip

        let sailing = settings.chargeSailingEnabled, heat = settings.chargeHeatProtectionEnabled
        sailingCheckbox.state = sailing ? .on : .off
        sailingCheckbox.isEnabled = usable
        sailingStepper.integerValue = settings.chargeSailingGap
        sailingStepper.isEnabled = usable && sailing
        sailingLabel.stringValue = Self.sailingText(gap: settings.chargeSailingGap)
        sailingLabel.textColor = usable && sailing ? .labelColor : .disabledControlTextColor

        heatCheckbox.state = heat ? .on : .off
        heatCheckbox.isEnabled = usable
        heatStepper.doubleValue = settings.chargeMaxTemperatureC
        heatStepper.isEnabled = usable && heat
        heatLabel.stringValue = Self.heatText(maxC: settings.chargeMaxTemperatureC)
        heatLabel.textColor = usable && heat ? .labelColor : .disabledControlTextColor

        sleepCheckbox.state = settings.chargeStopWhenSleeping ? .on : .off
        sleepCheckbox.isEnabled = usable
        autoDischargeCheckbox.state = settings.chargeAutomaticDischarge ? .on : .off
        autoDischargeCheckbox.isEnabled = usable

        for r in rows { r.isHidden = !on }
        var facts = Facts(percent: percent, cablePresent: cable, dischargeInForce: c?.dischargeInForce)
        if let left = c?.chargerReconnectTimeLeft() {
            facts.reconnecting = true
            redraw(after: left)
        }
        // Off, the one line that can show: a discharge's end never confirmed, so the charger may still be cut.
        let offWarning = on ? nil : c?.offWarning
        statusLabel.stringValue = offWarning ?? Self.statusText(status, facts)
        statusLabel.textColor = unavailable || needsHelper || refused || offWarning != nil
            ? .systemOrange : .secondaryLabelColor
        // A switched-on section with nothing to report yet (the controller has not answered) shows no line.
        statusLabel.isHidden = offWarning == nil && (!on || status == .off)
        installButton.isHidden = !on || !needsHelper
        // Kept once the helper is there and the button has gone (it says the install worked), not once switched off.
        if !on { installNote = nil }
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
