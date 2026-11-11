import Foundation

/// Which menu bar icons the owner keeps on the bar and the order of the rest in the pill (Menu Bar Hider).
/// Task 3 completes this; the stored shape is final.
public struct BarArrangement: Codable, Equatable {
    /// Keys of the icons that always stay on the bar.
    public var pinned: [String]
    /// Keys of the icons behind the chevron, in the order the pill shows them.
    public var pillOrder: [String]

    public init(pinned: [String], pillOrder: [String]) {
        self.pinned = pinned
        self.pillOrder = pillOrder
    }
}
