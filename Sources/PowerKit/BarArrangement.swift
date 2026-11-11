import Foundation

public enum BarGroup: Equatable {
    case onBar
    case behindChevron
}

/// Which menu bar icons the owner keeps on the bar and the order of the rest in the pill (Menu Bar Hider).
public struct BarArrangement: Codable, Equatable {
    /// Keys of the icons that always stay on the bar.
    public var pinned: [String]
    /// Keys of the icons behind the chevron, in the order the pill shows them.
    public var pillOrder: [String]

    public init(pinned: [String], pillOrder: [String]) {
        self.pinned = pinned
        self.pillOrder = pillOrder
    }

    /// One damaged field degrades that field, not the whole arrangement.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = (try? c.decode([String].self, forKey: .pinned)) ?? []
        pillOrder = (try? c.decode([String].self, forKey: .pillOrder)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case pinned, pillOrder }

    /// The first arrangement: battery, sound and Wi-Fi stay on the bar, everything else goes behind the chevron.
    public static func defaultArrangement(for items: [BarItem]) -> BarArrangement {
        func staysOnBar(_ item: BarItem) -> Bool {
            // Anode's own widgets fold into the pill by default.
            if item.bundleID == "dev.anode.app" { return false }
            // The name part of the key (identifier, else title), and the title: not the bundle id, which may say "sound" or
            // "battery" for an app that is neither.
            let name = item.key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? item.key
            let hay = (name + " " + item.title).lowercased()
            return ["battery", "sound", "wi-fi", "wifi"].contains { hay.contains($0) }
        }
        let movable = items.filter { !$0.isLocked }
        return BarArrangement(pinned: movable.filter(staysOnBar).map(\.key),
                              pillOrder: movable.filter { !staysOnBar($0) }.map(\.key))
    }

    /// Locked items (the clock, Control Center) are always on the bar; so is anything pinned; the rest is behind the chevron,
    /// including an item never seen before.
    public func group(of key: String, items: [BarItem]) -> BarGroup {
        if items.contains(where: { $0.key == key && $0.isLocked }) { return .onBar }
        return pinned.contains(key) ? .onBar : .behindChevron
    }

    /// What the pill shows: the items behind the chevron, in `pillOrder` order, items it does not name after them in the
    /// order given. Keys naming no item that exists now (an app that quit) are ignored.
    public func pillItems(from items: [BarItem]) -> [BarItem] {
        let behind = items.filter { group(of: $0.key, items: items) == .behindChevron }
        var out: [BarItem] = []
        var seen = Set<String>()
        for key in pillOrder {
            if let match = behind.first(where: { $0.key == key }), seen.insert(key).inserted { out.append(match) }
        }
        for item in behind where seen.insert(item.key).inserted { out.append(item) }
        return out
    }

    /// The result of dropping `key` into `group` at `index` (clamped). Locked and unknown items do not move. The order of
    /// keys naming absent apps is kept, so quitting an app does not lose where its icon was put.
    public func moving(_ key: String, to group: BarGroup, at index: Int, items: [BarItem]) -> BarArrangement {
        guard let item = items.first(where: { $0.key == key }), !item.isLocked else { return self }
        func inserting(_ key: String, into list: [String], at index: Int) -> [String] {
            var l = list.filter { $0 != key }
            l.insert(key, at: min(max(index, 0), l.count))
            return l
        }
        var result = self
        switch group {
        case .onBar:
            let shown = pinned.filter { k in k != key && items.contains { $0.key == k } }
            let absent = pinned.filter { k in k != key && !items.contains { $0.key == k } }
            result.pinned = inserting(key, into: shown, at: index) + absent
            result.pillOrder = pillOrder.filter { $0 != key }
        case .behindChevron:
            result.pinned = pinned.filter { $0 != key }
            let shown = pillItems(from: items).map(\.key).filter { $0 != key }
            let absent = pillOrder.filter { k in k != key && !items.contains { $0.key == k } }
            result.pillOrder = inserting(key, into: shown, at: index) + absent
        }
        return result
    }
}
