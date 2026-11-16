import Foundation
import CoreGraphics

/// One node of an Accessibility tree, copied out so what reads it can be tested with a tree made by hand. The live
/// reader (in the app) fills these in from `AXUIElement`s; nothing here touches the system.
public struct AXNode: Equatable {
    public var role, subrole, identifier, description, value: String
    public var enabled: Bool
    public var frame: CGRect
    public var children: [AXNode]

    public init(role: String = "", subrole: String = "", identifier: String = "", description: String = "",
                value: String = "", enabled: Bool = true, frame: CGRect = .zero, children: [AXNode] = []) {
        self.role = role; self.subrole = subrole; self.identifier = identifier; self.description = description
        self.value = value; self.enabled = enabled; self.frame = frame; self.children = children
    }

    /// This node and everything under it, parents before children, in the order Accessibility lists them (the order the
    /// rows are drawn in).
    public var flattened: [AXNode] { [self] + children.flatMap(\.flattened) }
}
