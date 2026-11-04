import AppKit
import Metal
import MetalPerformanceShaders
import PowerKit
import QuartzCore
import simd

// ── Lid Glass: the fold, drawn ──────────────────────────────────────────────
//
// One fullscreen pass over a picture of the screen taken when the lid started to close. The picture sits on a
// black margin inside one mipmapped texture, with a Gaussian pyramid over it. Every glass pixel is mapped back
// into that frozen picture through the inverse of the fold's projective map (see `LidFold`), so the picture
// holds still in the room while the glass tilts in front of it. Frost, dimming and the dissolve at the edges
// follow the picture's own height above the hinge: the far edge goes first, the hinge stays readable.
//
// The look is a port of Mac Duo's renderer (github.com/ninobc/mac-duo, MIT; see LidFold.swift for the notice),
// without its live-picture, sheen and preset machinery: the picture here is one frozen frame, and the look is
// not user-tunable.
//
// The shader is compiled from a string at run time: the package builds with `swift build`, which does not
// produce a .metallib.

final class LidGlassRenderer {

    /// Display P3 shares sRGB's transfer curve, so an sRGB texture view decodes it. Stills are handed over in it.
    static let colourSpaceName = CGColorSpace.displayP3

    /// Black margin around the picture, in points. Kept above the widest blur so the picture's edges dissolve
    /// into the dark instead of clamping.
    static let padding: CGFloat = 176

    private struct Uniforms {
        var column0: SIMD4<Float>
        var column1: SIMD4<Float>
        var column2: SIMD4<Float>
        var screenAndOrigin: SIMD4<Float>   // screen size (pt), padded origin (pt)
        var paddedAndBlur: SIMD4<Float>     // padded size (pt), max radius (px), blur strength
        var shape: SIMD4<Float>             // blur floor, max dim, pixel scale, max mip level
        var light: SIMD4<Float>             // dim start, dim strength, grain, dim reach
        var more: SIMD4<Float>              // dim floor at the hinge, recede, picture top edge on the glass
    }

    /// A picture prepared for drawing: the padded, mipmapped texture and what the shader needs to know of it.
    struct Picture {
        let texture: MTLTexture
        let screenSize: CGSize
        let pixelScale: CGFloat
        let maxLevel: Float
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Glass, on top of the fold. Every one is scaled by the fold's strength (`glass`), so the unfolded picture is untouched.
    constant float kChroma  = 7.0;    // colour fringing at the top of the glass at full fold, in points
    constant float kRimWidth = 0.07;  // the lens rim along the far edge, as a share of the screen's height (LidGlassLens)
    constant float kRimDepth = 0.85;  // how far inside the lookup lands at the very edge, as a share of the rim
    constant float kRimLift = 0.55;   // how much of the dimming the rim cancels, at the very edge
    constant float kEdgeLine = 0.05;  // a barely-there sheen right at the glass's edge; no ruled lines, the rim shows through the picture

    struct Uniforms {
        float4 column0;
        float4 column1;
        float4 column2;
        float4 screenAndOrigin;
        float4 paddedAndBlur;
        float4 shape;
        float4 light;
        float4 more;
    };

    vertex float4 lidGlassVertex(uint id [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[id], 0.0, 1.0);
    }

    static inline float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 lidGlassFragment(float4 position [[position]],
                                     constant Uniforms &u [[buffer(0)]],
                                     texture2d<float> picture [[texture(0)]]) {
        constexpr sampler smooth(filter::linear, mip_filter::linear, address::clamp_to_edge);

        const float2 screenSize   = u.screenAndOrigin.xy;
        const float2 paddedOrigin = u.screenAndOrigin.zw;
        const float2 paddedSize   = u.paddedAndBlur.xy;
        const float  maxRadius    = u.paddedAndBlur.z;
        const float  blurStrength = u.paddedAndBlur.w;
        const float  blurFloor    = u.shape.x;
        const float  maxDim       = u.shape.y;
        const float  pixelScale   = u.shape.z;
        const float  maxLevel     = u.shape.w;
        const float  dimStart     = u.light.x;
        const float  dimStrength  = u.light.y;
        const float  grain        = u.light.z;
        const float  dimReach     = u.light.w;
        const float  dimHinge     = u.more.x;
        const float  recede       = u.more.y;
        const float  topEdge      = u.more.z;
        const float  lens         = u.more.w;

        // Fragments are pixels with y down; the geometry is points with y up.
        float2 screenPoint = float2(position.x / pixelScale, screenSize.y - position.y / pixelScale);
        // Above the picture's far edge the glass carries the edge's own light, fading in screen space, so there
        // is never a hard line where the picture ends.
        float above = max(screenPoint.y - topEdge, 0.0);
        screenPoint.y = min(screenPoint.y, topEdge);
        float3x3 toPicture = float3x3(u.column0.xyz, u.column1.xyz, u.column2.xyz);
        float3 mapped = toPicture * float3(screenPoint, 1.0);
        if (abs(mapped.z) < 1e-6 || mapped.z < 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 picturePoint = mapped.xy / mapped.z;

        // Where this pixel is on the glass, 0 at the hinge and 1 at the far edge; and across it, 0 to 1.
        float glassY = clamp((screenSize.y - position.y / pixelScale) / screenSize.y, 0.0, 1.0);
        float glassX = clamp(position.x / pixelScale / screenSize.x, 0.0, 1.0);

        // The rim lens: along the glass's far edge the picture is looked up from further inside the screen, by an amount
        // that falls to nothing across the rim, so near the edge the content is seen flipped and compressed (see
        // LidGlassLens). Strength follows the fold, so an unfolded picture is untouched.
        float rimWidth = kRimWidth * screenSize.y * lens;
        float fromEdge = (1.0 - glassY) * screenSize.y;
        if (rimWidth > 0.5 && fromEdge < rimWidth) {
            float k = 1.0 - fromEdge / rimWidth;
            picturePoint.y -= kRimDepth * rimWidth * k * k;
        }

        // Outside the padded picture there is only the dark.
        float2 unit = (picturePoint - paddedOrigin) / paddedSize;
        if (any(unit < 0.0) || any(unit > 1.0)) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 clampedPoint = clamp(picturePoint, float2(0.0), screenSize);
        float2 texCoord = float2(unit.x, 1.0 - unit.y);

        // Height above the hinge in the picture: 0 at the hinge, 1 at the far edge.
        float g = clamp(clampedPoint.y / screenSize.y, 0.0, 1.0);

        // Dimming, in linear light so the far edge fades into the dark rather than going grey. It reaches full strength
        // at `dimReach`; the hinge sinks a little too, so the whole picture recedes.
        float spread = smoothstep(dimStart, max(dimReach, dimStart + 0.05), g);
        float dim = dimStrength * (dimHinge + (1.0 - dimHinge) * spread) * maxDim;
        // The rim catches and focuses light, so what it shows is brighter than what surrounds it: the dimming eases
        // toward the edge, most at the edge itself.
        float rimGain = (rimWidth > 0.5 && fromEdge < rimWidth) ? (1.0 - fromEdge / rimWidth) : 0.0;
        dim *= 1.0 - kRimLift * rimGain;

        // So dark there is nothing to read: skip the picture altogether (a large part of a deep fold).
        // A faint sheen right at the glass's edge.
        float edgeLines = exp(-pow(fromEdge / 4.0, 2.0)) * kEdgeLine * lens;
        if (dim >= 0.985) {
            return float4(float3(0.9, 0.94, 1.0) * edgeLines, 1.0);
        }

        // Frost. The far edge dissolves first; the hinge stays readable.
        float blur = blurStrength * (blurFloor + (1.0 - blurFloor) * g);
        float radius = blur * maxRadius;
        float mip = clamp(log2(max(radius, 1.0)), 0.0, maxLevel);

        float3 colour;
        if (radius < 0.75) {
            colour = picture.sample(smooth, texCoord, level(0.0)).rgb;
        } else {
            // Four trilinear taps hide the pyramid's steps. At +-0.71 of the stride they spread the blur as widely as
            // the 3x3 tent they replace, for under half the reads.
            float2 texel = 1.0 / (paddedSize * pixelScale);
            float2 stride = texel * radius * 0.45 * 0.71;
            colour = (picture.sample(smooth, texCoord + float2(-1.0, -1.0) * stride, level(mip)).rgb
                    + picture.sample(smooth, texCoord + float2( 1.0, -1.0) * stride, level(mip)).rgb
                    + picture.sample(smooth, texCoord + float2(-1.0,  1.0) * stride, level(mip)).rgb
                    + picture.sample(smooth, texCoord + float2( 1.0,  1.0) * stride, level(mip)).rgb) * 0.25;
        }

        // Chromatic aberration: the glass splits the colours a little, red one way and blue the other, more toward its
        // far edge and sides where the rays meet it at a steeper angle. Two extra reads of the blurred picture.
        if (dimStrength > 0.001) {
            // None at the hinge, where the picture ends and there is nothing past it to read.
            float2 fringe = float2((glassX - 0.5) * 0.5, 1.0) * dimStrength * kChroma * (0.3 + 0.7 * glassY)
                          * smoothstep(0.0, 0.3, glassY);
            float2 shift = float2(fringe.x, -fringe.y) / paddedSize;
            colour.r = picture.sample(smooth, texCoord + shift, level(mip)).r;
            colour.b = picture.sample(smooth, texCoord - shift, level(mip)).b;
        }

        colour *= pow(1.0 - dim, 2.1) * recede;
        colour *= exp(-pow(above / max(0.22 * screenSize.y, 1.0), 1.4));

        // The lines of light at the glass's edge, where a thick pane catches the light.
        colour += float3(0.9, 0.94, 1.0) * edgeLines;

        // Grain, so a dark gradient does not band. Scaled by the dimming, so an unfolded picture is untouched.
        float noise = hash(position.xy) - 0.5;
        colour += noise * grain * dimStrength * (2.5 / 255.0);

        return float4(max(colour, 0.0), 1.0);
    }
    """

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var picture: Picture?
    private let inFlightLock = NSLock()
    private var _framesInFlight = 0

    /// Frames handed to the GPU and not yet finished. The overlay skips a tick rather than queue a third: asking
    /// the layer for a drawable when none is free blocks the main thread, and everything else waits behind it.
    var framesInFlight: Int { inFlightLock.lock(); defer { inFlightLock.unlock() }; return _framesInFlight }

    var hasImage: Bool { picture != nil }
    var metalDevice: MTLDevice { device }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "lidGlassVertex"),
              let fragment = library.makeFunction(name: "lidGlassFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        d.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Build the padded, mipmapped texture for one still. Safe off the main thread: it touches no renderer state.
    func makePicture(from image: CGImage, scale: CGFloat) -> Picture? {
        let screen = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let padded = CGSize(width: screen.width + 2 * Self.padding, height: screen.height + 2 * Self.padding)
        let width = Int((padded.width * scale).rounded()), height = Int((padded.height * scale).rounded())
        let inset = Int((Self.padding * scale).rounded())
        guard width > 0, height > 0, image.width > 0, image.height > 0,
              let space = CGColorSpace(name: Self.colourSpaceName) else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // The frame on a black margin, drawn straight into the texture's own memory.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: inset, y: inset, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)

        var inPlace: MTLTexture = texture
        guard let commands = queue.makeCommandBuffer() else { return nil }
        MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
            .encode(commandBuffer: commands, inPlaceTexture: &inPlace, fallbackCopyAllocator: nil)
        commands.commit()
        commands.waitUntilCompleted()
        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        return Picture(texture: inPlace, screenSize: screen, pixelScale: scale, maxLevel: Float(levels - 1))
    }

    func adopt(_ picture: Picture) { self.picture = picture }

    /// Prepare and adopt `image`, taken at `scale` pixels per point. Replaces any earlier one.
    func setImage(_ image: CGImage, scale: CGFloat) {
        picture = makePicture(from: image, scale: scale)
    }

    func clearImage() { picture = nil }

    /// `gpuSeconds` is called, off the main thread, with how long the GPU took on the frame.
    func draw(_ frame: LidFoldFrame, into drawable: CAMetalDrawable, gpuSeconds: ((Double) -> Void)? = nil) {
        encode(frame, target: drawable.texture, present: drawable, gpuSeconds: gpuSeconds)
    }

    /// The frame as an image the size of the screen, for tests and for tuning against references.
    func renderOffscreen(_ frame: LidFoldFrame) -> CGImage? {
        guard let picture else { return nil }
        let w = Int((picture.screenSize.width * picture.pixelScale).rounded())
        let h = Int((picture.screenSize.height * picture.pixelScale).rounded())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc),
              encode(frame, target: target, present: nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let space = CGColorSpace(name: Self.colourSpaceName),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        return ctx.makeImage()
    }

    @discardableResult
    private func encode(_ frame: LidFoldFrame, target: MTLTexture, present: CAMetalDrawable?,
                        gpuSeconds: ((Double) -> Void)? = nil) -> Bool {
        guard let picture, let commands = queue.makeCommandBuffer() else { return false }
        let screen = picture.screenSize, scale = picture.pixelScale
        let padded = CGSize(width: screen.width + 2 * Self.padding, height: screen.height + 2 * Self.padding)
        let inverse = LidHomography.matrix(width: Double(screen.width), height: Double(screen.height), to: frame.corners).inverse
        func column(_ i: Int) -> SIMD4<Float> {
            let c = inverse[i]
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
        }
        var uniforms = Uniforms(
            column0: column(0), column1: column(1), column2: column(2),
            screenAndOrigin: SIMD4(Float(screen.width), Float(screen.height), Float(-Self.padding), Float(-Self.padding)),
            paddedAndBlur: SIMD4(Float(padded.width), Float(padded.height), Float(frame.maxBlurRadius * Double(scale)), Float(frame.blurStrength)),
            shape: SIMD4(Float(frame.blurFloor), Float(frame.maxDim), Float(scale), picture.maxLevel),
            // No grain. It was added in linear light, where a step near black becomes a large step on screen:
            // measured 7.8 levels of pixel-to-pixel speckle in the dark of a deep fold over a flat grey picture.
            light: SIMD4(0, Float(frame.dimStrength), 0, Float(frame.dimReach)),
            more: SIMD4(Float(frame.dimHingeFloor), 1, Float(frame.topEdge), Float(frame.lens)))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let present {
            commands.present(present)
            inFlightLock.lock(); _framesInFlight += 1; inFlightLock.unlock()
            commands.addCompletedHandler { [weak self] cb in
                self?.inFlightLock.lock(); self?._framesInFlight -= 1; self?.inFlightLock.unlock()
                if cb.status != .completed { FeatureLog.append("lidglass.log", "frame ended \(cb.status.rawValue): \(cb.error?.localizedDescription ?? "no error")") }
                gpuSeconds?(cb.gpuEndTime - cb.gpuStartTime)
            }
        }
        commands.commit()
        if present == nil { commands.waitUntilCompleted() }
        return true
    }
}
