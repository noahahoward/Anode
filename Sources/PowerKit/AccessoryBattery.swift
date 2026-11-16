import Foundation

/// One battery of an accessory that IOKit lists beside the Mac's own: an AirPods bud, their case, or a single earbud.
public struct AccessoryBattery: Equatable {
    public enum Part: Equatable { case left, right, case_, single }

    public var group: String
    public var part: Part
    public var percent: Int
    public var charging: Bool
    public var productID: Int?

    public init(group: String, part: Part, percent: Int, charging: Bool, productID: Int? = nil) {
        self.group = group; self.part = part; self.percent = percent; self.charging = charging; self.productID = productID
    }

    /// The accessory entries among IOKit's power sources. The Mac's own battery, and any entry without a percentage, are
    /// left out.
    public static func parse(_ sources: [[String: Any]]) -> [AccessoryBattery] {
        sources.compactMap { d in
            guard d["Type"] as? String == "Accessory Source", let percent = (d["Current Capacity"] as? NSNumber)?.intValue else { return nil }
            let part: Part
            switch d["Part Identifier"] as? String {
            case "Left": part = .left
            case "Right": part = .right
            case "Case": part = .case_
            default: part = .single
            }
            return AccessoryBattery(group: d["Group Identifier"] as? String ?? "", part: part, percent: percent,
                                    charging: (d["Is Charging"] as? NSNumber)?.boolValue ?? false,
                                    productID: (d["Product ID"] as? NSNumber)?.intValue)
        }
    }

    /// Whether both buds of the group are listed. A bud in the case is listed too, so this says the pair is there, not that
    /// both are in the ears; macOS refuses Adaptive Audio unless both are, and Anode shows its reason.
    public static func bothBudsPresent(in batteries: [AccessoryBattery], group: String) -> Bool {
        let parts = Set(batteries.filter { $0.group == group }.map(\.part))
        return parts.contains(.left) && parts.contains(.right)
    }
}
