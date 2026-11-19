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

    /// How the blur fades toward the edge of the shape it frosts: the system's frost lightens round the edge, so that what the glass's rim
    /// bends is seen sharper there. The mask is a rounded rectangle, `inset` points in from the shape's edge and blurred by `sigma`.
    struct Feather: Equatable {
        var cornerRadius: CGFloat
        var inset: CGFloat
        var sigma: CGFloat
    }

    /// The blur's radius (a gaussian's sigma, in points); 0 is none.
    let sigma: CGFloat
    let feather: Feather?
    /// How far this view reaches past the shape above and below (the glass is made taller than its shape, and the shape's clip cuts the rest).
    var overhangTop: CGFloat = 0 { didSet { needsLayout = true } }
    var overhangBottom: CGFloat = 0 { didSet { needsLayout = true } }
    /// The system's layer, a sublayer of this view's own plain one (as the view's own backing layer it was reset by AppKit and blurred
    /// nothing).
    private(set) var blurLayer: CALayer?
    private var maskedFor: (size: CGSize, top: CGFloat, bottom: CGFloat, scale: CGFloat)?

    init(sigma: CGFloat, feather: Feather? = nil) {
        self.sigma = sigma
        self.feather = feather
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
        updateMask()
        CATransaction.commit()
    }

    /// It is only a look: it takes no clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateMask() {
        guard let blurLayer, let feather, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = (size: bounds.size, top: overhangTop, bottom: overhangBottom, scale: scale)
        if let done = maskedFor, done == key { return }
        maskedFor = key
        let shape = CGRect(x: 0, y: overhangBottom, width: bounds.width, height: bounds.height - overhangTop - overhangBottom)
        guard let image = Self.featherMask(size: bounds.size, shape: shape, feather: feather, scale: scale) else { return }
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = image
        mask.contentsScale = scale
        blurLayer.mask = mask
    }

    /// The mask (its alpha): whole (the blur shows) inside a rounded rectangle `feather.inset` in from `shape`'s edge, blurred so it fades to nothing
    /// at the edge. `shape` is in the view's coordinates (y up).
    static func featherMask(size: CGSize, shape: CGRect, feather: Feather, scale: CGFloat) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 1, h > 1,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A layer's mask is read from its alpha: clear where the blur is not wanted, white where it is.
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let inner = shape.insetBy(dx: feather.inset, dy: feather.inset)
        let r = max(0, feather.cornerRadius - feather.inset)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.addPath(CGPath(roundedRect: CGRect(x: inner.minX * scale, y: inner.minY * scale, width: inner.width * scale, height: inner.height * scale),
                               cornerWidth: r * scale, cornerHeight: r * scale, transform: nil))
        context.fillPath()
        guard let sharp = context.makeImage() else { return nil }
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(CIImage(cgImage: sharp).clampedToExtent(), forKey: kCIInputImageKey)
        blur?.setValue(Double(feather.sigma * scale), forKey: kCIInputRadiusKey)
        guard let out = blur?.outputImage else { return sharp }
        return CIContext().createCGImage(out, from: CGRect(x: 0, y: 0, width: w, height: h)) ?? sharp
    }

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
