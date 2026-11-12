import Foundation
import notify

// What the root helper does to the charger: set macOS's own charge limit, and
// cut or reconnect the adapter. Policy — when, to what, for how long — lives in
// `FanHelperServer` and above it; nothing in this file decides anything.

/// The charger, behind a protocol, for the same reason `FanHardware` is: the
/// server's refusals and its reconnect-on-every-exit can be tested against a
/// fake. A cut made by a test on a real machine OUTLIVES the test process
/// (measured: `kill -9` left `CHIE` = 08 and the charger disconnected).
public protocol ChargeHardware: AnyObject {
    /// Is the charger cut right now? nil when the key cannot be read.
    func adapterCut() -> Bool?
    /// Cut (true) or reconnect (false). The only two writes the helper makes to
    /// the charger.
    func setAdapterCut(_ on: Bool) -> Bool
    func batteryPercent() -> Int?
    /// Is a charger attached? nil when that cannot be told — including while the
    /// charger is cut, see `ChargeAC.presence`.
    func onAC() -> Bool?
    /// Set macOS's own charge limit (`mclLimitValue`), 0…100.
    func writeChargeLimit(_ percent: Int) -> Bool
}

/// The adapter-cut key and the only two values ever written to it.
///
/// MEASURED on macOS 27: `CHIE` is `hex_`, one byte; 0x08 cuts the charger
/// with the cable still in, 0x00 reconnects it. Root alone suffices. Any other
/// value has never been observed and is never written.
public enum AdapterCutKey {
    public static let key = "CHIE"
    public static let cut: UInt8 = 0x08
    public static let connected: UInt8 = 0x00
}

/// When a discharge has to end. Pure, so it can be pinned by tests.
public struct DischargeWatch {
    /// Never discharge below this, whatever the target says.
    public static let floor = 10

    /// True when the charger must be reconnected now: the battery cannot be
    /// read, it has reached `max(target, floor)`, or the cable is known to be
    /// out. An UNKNOWN cable (`onAC == nil`) is not "out": that is what the
    /// hardware reports for the whole of a cut.
    public static func shouldRestore(target: Int, percent: Int?, onAC: Bool?) -> Bool {
        guard let percent else { return true }
        if percent <= max(target, floor) { return true }
        return onAC == false
    }
}

/// What "is a charger attached" means while the helper may be cutting it.
public enum ChargeAC {
    /// MEASURED: `ExternalConnected` reads No about 10 s after `CHIE` = 08,
    /// with the cable still in (plan-0 results). So while the cut byte is
    /// non-zero that flag says nothing about the cable, and the answer is
    /// unknown. With the cut byte unreadable the flag is believed: if it then
    /// says unplugged, the charger gets reconnected, which cannot hurt.
    public static func presence(externalConnected: Bool?, cutByte: UInt8?) -> Bool? {
        if let cutByte, cutByte != AdapterCutKey.connected { return nil }
        return externalConnected
    }
}

/// `ChargeHardware` over the real SMC, battery and preferences. Needs root for
/// every write. No policy: range checks and the discharge floor are the
/// server's.
public final class SystemChargeHardware: ChargeHardware {
    private let smc: SMC?

    /// The preference macOS's Charge Limit setting is stored in, and the
    /// notification that makes PowerUIAgent re-read it (measured: applied within
    /// about 6 s). Written as root this lands in
    /// /var/root/Library/Preferences/com.apple.smartcharging.topoffprotection.plist.
    public static let limitDomain = "com.apple.smartcharging.topoffprotection"
    public static let limitKey = "mclLimitValue"
    public static let limitChanged = "com.apple.smartcharging.defaultschanged"

    public init(smc: SMC? = SMC()) {
        self.smc = smc
    }

    public func adapterCut() -> Bool? {
        smc?.readByte(AdapterCutKey.key).map { $0 != AdapterCutKey.connected }
    }

    public func setAdapterCut(_ on: Bool) -> Bool {
        smc?.writeByte(AdapterCutKey.key, on ? AdapterCutKey.cut : AdapterCutKey.connected) ?? false
    }

    public func batteryPercent() -> Int? {
        Battery.state()?.percent
    }

    public func onAC() -> Bool? {
        ChargeAC.presence(externalConnected: Battery.state()?.onAC,
                          cutByte: smc?.readByte(AdapterCutKey.key))
    }

    public func writeChargeLimit(_ percent: Int) -> Bool {
        guard (0...100).contains(percent) else { return false }
        let domain = Self.limitDomain as CFString
        CFPreferencesSetValue(Self.limitKey as CFString,
                              NSNumber(value: percent),
                              domain,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return false
        }
        return notify_post(Self.limitChanged) == UInt32(NOTIFY_STATUS_OK)
    }
}
