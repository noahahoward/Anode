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

    /// A blur whose radius grows with the depth from the shape's edge (the system's card: a hard edge of the backdrop is sharp at the glass's
    /// rim and softens the further in it is, to a sigma of about 6.5 points 70 points in). `profile` is the sigma wanted at each depth in
    /// points (linear between, and the last for deeper); the system's `variableBlur` filter takes the radius from a mask picture's alpha.
    struct Variable: Equatable {
        var cornerRadius: CGFloat
        var profile: [Point]
        struct Point: Equatable { var depth: CGFloat; var sigma: CGFloat }
    }

    /// The blur's radius (a gaussian's sigma, in points); 0 is none.
    let sigma: CGFloat
    let variable: Variable?
    /// How far this view reaches past the shape above and below (the glass is made taller than its shape, and the shape's clip cuts the rest).
    var overhangTop: CGFloat = 0 { didSet { needsLayout = true } }
    var overhangBottom: CGFloat = 0 { didSet { needsLayout = true } }
    /// The system's layer, a sublayer of this view's own plain one (as the view's own backing layer it was reset by AppKit and blurred
    /// nothing).
    private(set) var blurLayer: CALayer?

    init(sigma: CGFloat, variable: Variable? = nil) {
        self.sigma = sigma
        self.variable = variable
        super.init(frame: .zero)
        wantsLayer = true
        if let blur = variable != nil ? Self.makeVariableLayer() : Self.makeLayer(sigma: sigma) {
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
        updateVariableMask()
        CATransaction.commit()
    }

    /// It is only a look: it takes no clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refreshMask() { variableFor = nil; needsLayout = true }
    private var variableFor: (size: CGSize, top: CGFloat, bottom: CGFloat, profile: [Variable.Point])?

    private func updateVariableMask() {
        guard let layer = blurLayer, let variable, bounds.width > 1, bounds.height > 1 else { return }
        let current = variable
        let key = (size: bounds.size, top: overhangTop, bottom: overhangBottom, profile: current.profile)
        if let done = variableFor, done.size == key.size, done.top == key.top, done.bottom == key.bottom, done.profile == key.profile { return }
        variableFor = key
        let shape = CGRect(x: 0, y: overhangBottom, width: bounds.width, height: bounds.height - overhangTop - overhangBottom)
        guard let image = Self.variableMask(size: bounds.size, shape: shape, variable: current),
              let filter = Self.makeVariableFilter() else { return }
        filter.setValue(image, forKey: "inputMaskImage")
        layer.filters = [filter]       // a new filter each time: the layer takes a changed picture in an old one for no change
    }

    /// The radius the variable blur's filter is given: the mask's alpha is a fraction of it.
    static let variableRadius: CGFloat = 10

    /// What fraction of `variableRadius` (the mask's alpha) gives a gaussian of this sigma (points): measured with fine stripes behind the
    /// filter (contrast against sigma, for two stripe periods). Not linear: the filter gets less than proportionally stronger.
    static let alphaForSigma: [(sigma: CGFloat, alpha: CGFloat)] = [(0, 0), (2.4, 0.1), (4.2, 0.2), (5.7, 0.3), (7.1, 0.4), (10, 0.5)]

    static func alpha(forSigma s: CGFloat) -> CGFloat {
        let t = alphaForSigma
        guard s > 0 else { return 0 }
        for i in 1..<t.count where s <= t[i].sigma {
            let f = (s - t[i - 1].sigma) / (t[i].sigma - t[i - 1].sigma)
            return t[i - 1].alpha + f * (t[i].alpha - t[i - 1].alpha)
        }
        return t[t.count - 1].alpha
    }

    /// The sigma wanted `depth` points inside the edge.
    static func sigma(atDepth depth: CGFloat, in profile: [Variable.Point]) -> CGFloat {
        guard let first = profile.first else { return 0 }
        guard depth > first.depth else { return first.sigma }
        for i in 1..<profile.count where depth <= profile[i].depth {
            let a = profile[i - 1], b = profile[i]
            return a.sigma + (b.sigma - a.sigma) * (depth - a.depth) / max(b.depth - a.depth, 0.0001)
        }
        return profile[profile.count - 1].sigma
    }

    /// How far inside a rounded rectangle a point is (0 on its edge, negative outside).
    static func depthInside(_ p: CGPoint, of rect: CGRect, cornerRadius r: CGFloat) -> CGFloat {
        let half = CGPoint(x: rect.width / 2, y: rect.height / 2)
        let q = CGPoint(x: abs(p.x - rect.midX) - (half.x - r), y: abs(p.y - rect.midY) - (half.y - r))
        let outside = (max(q.x, 0) * max(q.x, 0) + max(q.y, 0) * max(q.y, 0)).squareRoot()
        return -(outside + min(max(q.x, q.y), 0) - r)
    }

    /// The picture the variable blur reads its radius from: one pixel to the point, alpha the fraction of `variableRadius` wanted there.
    static func variableMask(size: CGSize, shape: CGRect, variable: Variable) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 1, h > 1 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            // the picture's first row is the top; the shape is in the view's coordinates (y up)
            let y = CGFloat(h - 1 - row) + 0.5
            for col in 0..<w {
                let depth = depthInside(CGPoint(x: CGFloat(col) + 0.5, y: y), of: shape, cornerRadius: variable.cornerRadius)
                let a = UInt8((alpha(forSigma: sigma(atDepth: max(depth, 0), in: variable.profile)) * 255).rounded())
                let i = (row * w + col) * 4
                pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a      // premultiplied white at alpha a
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeVariableFilter() -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let made = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        made.setValue(Double(variableRadius), forKey: "inputRadius")
        made.setValue(true, forKey: "inputNormalizeEdges")
        return made
    }

    /// The system's variable blur: its mask picture is set when the view has a size (`updateVariableMask`).
    static func makeVariableLayer() -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type, let made = makeVariableFilter() else { return nil }
        let layer = layerClass.init()
        guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")), layer.responds(to: NSSelectorFromString("setScale:")) else { return nil }
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(1.0, forKey: "scale")
        layer.filters = [made]
        return layer
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
