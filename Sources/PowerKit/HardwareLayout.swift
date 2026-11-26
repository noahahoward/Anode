import Foundation

/// A point in a layout's drawing units.
public struct HWPoint: Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in a layout's drawing units (origin top left, y down).
public struct HWRect: Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// How sure the layout is about where a part sits. A wrong picture is worse
/// than none, so a part that is a plausible guess says `inferred`.
public enum Confidence: Equatable {
    case verified
    case inferred
}

public enum HardwareComponentKind: Equatable {
    case display
    case fan(index: Int)
    case heatPipe
    case memory
    case storage
    case wifi
    case antenna
    case powerIn
    case battery
    case speaker
    case trackpad
    case board
    case soc
    case psu
    case note
}

/// A named piece of a component: a memory die, a NAND chip, a battery cell, a
/// USB-C port. `roles` is only used by battery cells (which readings the cell
/// shows, for example `["charge"]`).
public struct HardwarePart: Equatable {
    public let name: String
    public let rect: HWRect
    public let roles: [String]

    public init(name: String, rect: HWRect, roles: [String] = []) {
        self.name = name
        self.rect = rect
        self.roles = roles
    }
}

/// One part of a Mac's inside, in the layout's drawing units.
///
/// `rect` is the part's own box (nil for a part drawn only as a path). `points`
/// is the heat-pipe path, or a fan's centre. `jump` is the rectangle a narrow
/// window eases to when this part's chip is picked, and `jumpLabel` the chip's
/// text. The remaining fields carry what the drawers need that does not fit a
/// single rectangle; they all default to empty.
public struct HardwareComponent: Equatable {
    public let id: String
    public let kind: HardwareComponentKind
    public let rect: HWRect?
    public let points: [HWPoint]
    public let confidence: Confidence
    public let jump: HWRect?
    public let jumpLabel: String?
    /// Sub-pieces: memory dies and bar, NAND chips, battery cells, ports, an
    /// SoC die.
    public let parts: [HardwarePart]
    /// Named single positions: the CPU and GPU pill centres on a pipe, the
    /// adapter's port dot.
    public let anchors: [String: HWPoint]
    /// Small drawing switches, for example "plated", "short", "spreader",
    /// "compact", "stack", "small", "usbcPower", "cpuSideLeft",
    /// "dieSideInferred".
    public let flags: [String]
    /// Fixed text lines (a note's words, a label override).
    public let text: [String]
    /// Named numbers, for example a pipe's "split" and an adapter's "adapterW".
    public let values: [String: Double]

    public init(id: String,
                kind: HardwareComponentKind,
                rect: HWRect? = nil,
                points: [HWPoint] = [],
                confidence: Confidence,
                jump: HWRect? = nil,
                jumpLabel: String? = nil,
                parts: [HardwarePart] = [],
                anchors: [String: HWPoint] = [:],
                flags: [String] = [],
                text: [String] = [],
                values: [String: Double] = [:]) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.points = points
        self.confidence = confidence
        self.jump = jump
        self.jumpLabel = jumpLabel
        self.parts = parts
        self.anchors = anchors
        self.flags = flags
        self.text = text
        self.values = values
    }
}

/// The inside of one family of Mac, as data. Adding a model is adding a layout
/// here, not drawing code.
public struct HardwareLayout: Equatable {
    public let family: MacFamily
    public let title: String
    /// The drawing's size (and origin, for the mini) in drawing units.
    public let size: HWRect
    /// The bundled photo's resource name (a .jpg), or nil for a drawn layout.
    public let photoResource: String?
    /// Where the photo sits in drawing units; nil for a drawn layout.
    public let photoFrame: HWRect?
    public let components: [HardwareComponent]

    public init(family: MacFamily,
                title: String,
                size: HWRect,
                photoResource: String?,
                photoFrame: HWRect?,
                components: [HardwareComponent]) {
        self.family = family
        self.title = title
        self.size = size
        self.photoResource = photoResource
        self.photoFrame = photoFrame
        self.components = components
    }

    /// The layout for a family. An unknown Mac gets the plainly labelled
    /// generic schematic.
    public static func layout(for family: MacFamily) -> HardwareLayout {
        switch family {
        case .macBookPro14ProMax: return HardwareLayouts.macBookPro14ProMax
        case .macBookPro16ProMax: return HardwareLayouts.macBookPro16ProMax
        case .macBookPro14Base: return HardwareLayouts.macBookPro14Base
        case .macBookNeo: return HardwareLayouts.macBookNeo
        case .macMiniM4: return HardwareLayouts.macMiniM4
        case .generic: return HardwareLayouts.generic
        }
    }
}
