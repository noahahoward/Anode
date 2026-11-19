import AppKit

// ── A blur of what is behind a window ───────────────────────────────────────
//
// The system's ⌘Space panel is frosted: its card blurs what is behind it (a hard edge of the backdrop fades over about 20 points, which
// is a gaussian blur of about 8) and its bar only a little (about 3, a sigma of 1.5). The clear glass does not blur at all, so
// Clipboard History had the page behind it showing through, words and all, where the system's shows soft smudges.
//
// The only public blur of what is behind a window is NSVisualEffectView, and its materials come with their own veil of colour and one
// fixed radius (tried: far too bright and 33 points wide). The layer that view is made of, `CABackdropLayer` with a `CAFilter` gaussian
// blur, is what gives a radius of one's own. Both are the system's private classes, found by name; if they are ever not there, or do not
// answer as expected, nothing is blurred and the glass is as it was (never a crash: no private key is set on a class that does not
// answer to it).

final class BackdropBlurView: NSView {

    /// The blur's radius (a gaussian's sigma, in points); 0 is none.
    let sigma: CGFloat
    /// The system's layer, a sublayer of this view's own plain one (as the view's own backing layer it was reset by AppKit and blurred
    /// nothing).
    private(set) var blurLayer: CALayer?

    init(sigma: CGFloat) {
        self.sigma = sigma
        super.init(frame: .zero)
        wantsLayer = true
        if let blur = Self.makeLayer(sigma: sigma) {
            layer?.addSublayer(blur)
            blurLayer = blur
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurLayer?.frame = bounds
        CATransaction.commit()
    }

    /// It is only a look: it takes no clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the system's blur layer is there on this macOS.
    static var isAvailable: Bool { makeLayer(sigma: 1) != nil }

    static func makeLayer(sigma: CGFloat) -> CALayer? {
        guard sigma > 0,
              let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let made = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        let layer = layerClass.init()
        // The backdrop layer's own settings are set only where it answers to them.
        guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")), layer.responds(to: NSSelectorFromString("setScale:")) else { return nil }
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(1.0, forKey: "scale")
        made.setValue(Double(sigma), forKey: "inputRadius")
        made.setValue(true, forKey: "inputNormalizeEdges")     // no dark ring where the blur reaches past the edge
        layer.filters = [made]
        return layer
    }
}
