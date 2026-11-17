import AppKit
import PowerKit

/// Charge Control as the Battery menu sees it: the controller's drains, and the limit in Settings.
final class LiveChargeLimit: ChargeLimiting {

    private let controller: ChargeController
    private let settings: Settings

    init(_ controller: ChargeController, settings: Settings = .shared) { self.controller = controller; self.settings = settings }

    var limit: Int { settings.chargeLimit }
    var range: ClosedRange<Int> { Settings.chargeLimitRange }
    func setLimit(_ value: Int) { settings.chargeLimit = value }
    var softDrainRunning: Bool { controller.isDrainRequested }
    var hardDrainRunning: Bool { controller.isHardDrainRequested }
    var canHardDrain: Bool { controller.hardDrainLevel != nil }
    var topUpRunning: Bool { controller.isFullChargeRequested }
    var canTopUp: Bool { controller.isCablePresent }
    func pressSoftDrain() { controller.pressDrain() }
    func pressTopUp() { controller.pressFullCharge() }
    func pressHardDrain() { controller.pressHardDrain() }

    func observe(_ changed: @escaping () -> Void) -> AnyObject {
        [controller.observeChanges(changed), settings.observe(Settings.Key.chargeLimit, changed)] as AnyObject
    }
}

/// "Would you like to Hard Drain?" as a box on the screen. No is the default button: Hard Drain makes the Mac hot and loud.
final class HardDrainAlert: HardDrainPrompting {

    func ask(_ done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Would you like to Hard Drain?"
        alert.informativeText = "Anode gives the processor and the GPU extra work so the battery comes down fast. The Mac gets warm and "
            + "its fans may be heard, and it stays awake while this runs. Press minus again to stop it."
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")
        alert.window.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        done(alert.runModal() == .alertSecondButtonReturn)
    }

    func explainBlocked() {
        let alert = NSAlert()
        alert.messageText = "Hard Drain can't run now"
        alert.informativeText = ChargeControlFeature.hardDrainBlockedTip
        alert.addButton(withTitle: "OK")
        alert.window.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
