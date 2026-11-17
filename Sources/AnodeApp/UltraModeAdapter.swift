import Foundation

/// Ultra Low Power Mode as the Battery menu sees it: the mode's own controller, asked and told through the few calls the menu needs.
/// The controller keeps its own state `.on` until everything is put back, so "off" here means off and done.
final class LiveUltraMode: UltraModeControlling {

    private let controller: UltraLowPowerController

    init(_ controller: UltraLowPowerController) { self.controller = controller }

    var isOn: Bool { controller.state == .on }
    var isOff: Bool { controller.state == .off }
    func request() { controller.request() }
    func turnOff() { controller.turnOff() }

    /// Told on every change of the mode, with any number listening (the mode's own `onChange` has room for one, and the app uses it).
    func observe(_ changed: @escaping () -> Void) -> AnyObject {
        Token(NotificationCenter.default.addObserver(forName: UltraLowPowerController.didChange, object: nil, queue: .main) { _ in changed() })
    }

    private final class Token {
        private let observer: NSObjectProtocol
        init(_ observer: NSObjectProtocol) { self.observer = observer }
        deinit { NotificationCenter.default.removeObserver(observer) }
    }
}
