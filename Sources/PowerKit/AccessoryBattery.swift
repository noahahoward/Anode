import Foundation

/// One battery of an accessory that IOKit lists beside the Mac's own: an AirPods bud, their case, or a single earbud.
public struct AccessoryBattery: Equatable {
    public enum Part: Equatable { case left, right, case_, single }

    public var group: String
    public var part: Part
    public var percent: Int
    public var charging: Bool
    public var productID: Int?
    /// What IOKit calls the accessory (an AirPods entry is named after the AirPods, the case with " Case" added).
    public var name: String?

    public init(group: String, part: Part, percent: Int, charging: Bool, productID: Int? = nil, name: String? = nil) {
        self.group = group; self.part = part; self.percent = percent; self.charging = charging; self.productID = productID; self.name = name
    }

    /// The accessory entries among IOKit's power sources. The Mac's own battery, and any entry without a percentage, are
    /// left out.
    public static func parse(_ sources: [[String: Any]]) -> [AccessoryBattery] {
        sources.compactMap { d in
            guard d["Type"] as? String == "Accessory Source", let percent = (d["Current Capacity"] as? NSNumber)?.intValue else { return nil }
            // A keyboard or mouse is listed the same way, and is not the AirPods.
            let category = (d["Accessory Category"] as? String ?? "").lowercased()
            if ["keyboard", "mouse", "trackpad", "controller", "pencil", "gamepad"].contains(where: category.contains) { return nil }
            let part: Part
            switch d["Part Identifier"] as? String {
            case "Left": part = .left
            case "Right": part = .right
            case "Case": part = .case_
            default: part = .single
            }
            return AccessoryBattery(group: d["Group Identifier"] as? String ?? "", part: part, percent: percent,
                                    charging: (d["Is Charging"] as? NSNumber)?.boolValue ?? false,
                                    productID: (d["Product ID"] as? NSNumber)?.intValue, name: d["Name"] as? String)
        }
    }

    private static func normalised(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{FFFD}", with: "'").lowercased()
    }

    /// The entries that belong to the output called `deviceName`: the group whose accessory carries that name (the case's entry
    /// has " Case" after it). When no entry is named, or none matches, the first group that has AirPods-style parts.
    public static func selected(forDeviceNamed deviceName: String, in batteries: [AccessoryBattery]) -> [AccessoryBattery] {
        let want = normalised(deviceName)
        if let hit = batteries.first(where: { b in
            guard let n = b.name.map(normalised) else { return false }
            return n == want || n == want + " case"
        }) { return batteries.filter { $0.group == hit.group } }
        guard let first = batteries.first(where: { $0.part != .single }) ?? batteries.first else { return [] }
        return batteries.filter { $0.group == first.group }
    }
}
