import AppKit
import Metal
import QuartzCore

// ── Lid Glass: the frosted glass ────────────────────────────────────────────
//
// One fullscreen pass over the picture taken when the lid started to close. The picture is uploaded once with a
// full mip chain, and the shader reads it through a disc of taps at a mip level chosen per pixel: the level
// (and the disc) grows with `blur`, and is largest at the top edge and smallest at the bottom, where the hinge
// is, the way the far edge of a tilting pane drifts out of focus. On top of that: refraction through a gently
// domed pane (Snell's law), Schlick Fresnel brightening, a faint dispersion between channels, a thin tint and
// fine noise. All of it is scaled by `blur`, so at 0 the output is the picture, unchanged.
//
// The shader is compiled from a string at run time: the package builds with `swift build`, which does not
// produce a .metallib.

final class LidGlassRenderer {

    struct Uniforms {
        var blur: Float
        var width: Float
        var height: Float
        var padding: Float = 0
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // ── Tuning constants ──
    constant float kIOR            = 1.5;    // glass
    constant float kThickness      = 0.020;  // refraction reach, in uv, at full frost
    constant float kDome           = 0.9;    // how strongly the pane curves
    constant float kMaxRadius      = 0.045;  // frost disc radius at full frost, as a share of the picture's height
    constant float kHingeFrost     = 0.15;   // share of the frost that reaches the hinge edge
    constant float kDispersion     = 0.0016; // channel split, in uv, at full frost
    constant float kFresnelGain    = 0.10;   // how much sky the Fresnel term adds
    constant float kTint           = 0.05;   // share of the cool tint at full frost
    constant float kNoise          = 1.5 / 255.0;
    constant int   kTaps           = 10;

    struct Uniforms { float blur; float width; float height; float padding; };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut lidGlassVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);          // (0,0) (2,0) (0,2): one triangle over the screen
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);                        // uv.y = 0 is the top of the picture
        return o;
    }

    float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    fragment float4 lidGlassFragment(VOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 size = float2(u.width, u.height);
        float2 uv = in.position.xy / size;                    // pixel centres, so blur 0 hits texels exactly
        if (u.blur <= 0.0001) { return float4(tex.sample(s, uv, level(0)).rgb, 1.0); }

        float blur = clamp(u.blur, 0.0, 1.0);

        // How far this row is from the hinge: 0 at the bottom, 1 at the top.
        float awayFromHinge = clamp(1.0 - uv.y, 0.0, 1.0);
        float mask = mix(kHingeFrost, 1.0, smoothstep(0.0, 0.85, awayFromHinge));

        // A gently domed pane: the normal leans away from the middle, and the ray bends by Snell's law.
        float2 d = uv - 0.5;
        float3 n = normalize(float3(d * kDome, 1.0));
        float3 refracted = refract(float3(0.0, 0.0, -1.0), n, 1.0 / kIOR);
        float2 shift = refracted.xy / max(-refracted.z, 0.2) * kThickness * blur;
        float2 centre = clamp(uv + shift, 0.0, 1.0);

        // The frost: a Vogel disc of taps, each read from the mip level whose texels match the disc's spacing.
        float radius = kMaxRadius * blur * mask * u.height;   // in pixels
        float lod = clamp(log2(max(radius, 1.0)) - 1.0, 0.0, 9.0);
        float2 dir = normalize(float2(1.0, 0.35));
        float2 split = dir * kDispersion * blur;
        float3 sum = float3(0.0);
        for (int i = 0; i < kTaps; i++) {
            float r = sqrt((float(i) + 0.5) / float(kTaps));
            float a = float(i) * 2.399963;
            float2 off = float2(cos(a), sin(a)) * r * radius / size;
            sum.r += tex.sample(s, centre + off + split, level(lod)).r;
            sum.g += tex.sample(s, centre + off,         level(lod)).g;
            sum.b += tex.sample(s, centre + off - split, level(lod)).b;
        }
        float3 color = sum / float(kTaps);

        // Schlick Fresnel: glass reflects more at a grazing view.
        float cosTheta = clamp(n.z, 0.0, 1.0);
        float fresnel = 0.04 + 0.96 * pow(1.0 - cosTheta, 5.0);
        color += fresnel * kFresnelGain * blur * float3(0.95, 0.97, 1.0) * mask;

        // A thin cool tint, and noise so the smooth gradients do not band.
        color = mix(color, color * float3(0.94, 0.97, 1.0) + 0.02, kTint * blur * mask);
        color += (hash12(in.position.xy) - 0.5) * kNoise * blur;
        return float4(clamp(color, 0.0, 1.0), 1.0);
    }
    """

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "lidGlassVertex"),
              let fragment = library.makeFunction(name: "lidGlassFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    var hasImage: Bool { texture != nil }

    /// Upload the picture, with its mip chain. Replaces any earlier one.
    func setImage(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { texture = nil; return }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            texture = nil; return
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { texture = nil; return }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        texture = t
    }

    func clearImage() { texture = nil }

    /// Draw one frame into a drawable.
    func draw(blur: Double, into drawable: CAMetalDrawable) {
        encode(blur: blur, target: drawable.texture, present: drawable)
    }

    /// The frame as an image the size of the picture, for tests and for tuning against references.
    func renderOffscreen(blur: Double) -> CGImage? {
        guard let source = texture else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: source.width,
                                                            height: source.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc),
              encode(blur: blur, target: target, present: nil) else { return nil }
        let w = target.width, h = target.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        return ctx.makeImage()
    }

    @discardableResult
    private func encode(blur: Double, target: MTLTexture, present: CAMetalDrawable?) -> Bool {
        guard let texture, let cb = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var u = Uniforms(blur: Float(blur), width: Float(target.width), height: Float(target.height))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if let present { cb.present(present) }
        cb.commit()
        if present == nil { cb.waitUntilCompleted() }
        return true
    }
}
