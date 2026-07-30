import Metal
import MetalKit
import simd

/// A 3D particle cloud simulated entirely on the GPU: each particle is bound to
/// a frequency band and flares outward as that band gets loud, with a slow
/// orbiting camera and a smoky audio-reactive background. Closest in spirit to
/// the classic iTunes visualizer, at a scale it never reached.
///
/// Each register gets its own body so the mix is legible at a glance: bass is
/// a tight pulsing core, the mids form a flattened galaxy disc with
/// differential rotation (inner particles orbit faster, shearing the disc
/// into spiral streaks), and the treble is a spherical halo that throws
/// comets on hi-hat/snare transients. Every kick launches a shockwave that
/// sweeps outward through all three. The bodies themselves drift: the heavy
/// core lurches on kicks while the disc and halo counter-orbit around it, and
/// the background paints a colored halo behind each, with a dust lane lying in
/// the disc's own plane.
///
/// **This is the app's compute visualizer**, and the Swift here is only
/// plumbing — every particle is advanced by `nebulaStep` in Shaders.metal.
/// What that bought, beyond the count:
///
/// - **~130k particles instead of ~4k.** The old simulation was a serial Swift
///   loop on the render thread; this one is one GPU thread per particle and
///   costs the render thread a single dispatch.
/// - **Force-based motion.** Particles have velocity and are *pulled* toward
///   the shape their band asks for, while divergence-free turbulence, comet
///   impulses and the kick shockwave push them off it — so they overshoot,
///   lag, and stream instead of tracking a formula.
/// - **One shockwave, not two.** The front is derived analytically from the
///   decaying `beat` envelope, exactly as the background ring always was, so
///   the particles and the background now ride the same wave rather than two
///   that merely resemble each other.
/// - **No CPU mirror to keep in sync.** `nebulaOrbCenter` lives only in MSL
///   now; the kernel and the background shader both call it.
///
/// Rendering is HDR: background and particles draw into a float16 offscreen
/// target so additive pile-ups accumulate past 1.0, its mip chain is generated
/// with a blit (a free stack of wider and wider blurs), and the final tonemap
/// pass reads two levels of that chain for bloom before mapping to the display
/// with vibrance, Reinhard, and an S-curve — bright cores bloom instead of
/// clipping.
final class NebulaVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "nebula",
        name: "Nebula",
        tagline: "A hundred thousand particles orbiting a bass core, galaxy disc, and comet halo",
        options: [
            VisualizerOption(id: "density", name: "Density", range: 0.1...1.0, defaultValue: 0.7),
            VisualizerOption(id: "glow", name: "Glow", range: 0.4...2.5, defaultValue: 1.0),
            VisualizerOption(id: "trails", name: "Trails", range: 0.0...2.0, defaultValue: 0.9),
            VisualizerOption(
                id: "turbulence", name: "Turbulence", range: 0.0...2.5, defaultValue: 1.0),
            VisualizerOption(id: "swirl", name: "Swirl", range: 0.0...2.5, defaultValue: 1.0),
            VisualizerOption(id: "orbits", name: "Orbit speed", range: 0.0...2.5, defaultValue: 1.0),
            VisualizerOption(id: "spread", name: "Spread", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "halos", name: "Halos", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "impact", name: "Impact", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "form", name: "Form", range: 0.0...2.0, defaultValue: 1.0),
        ],
        make: { try NebulaVisualizer(device: $0, library: $1, pixelFormat: $2) })

    /// Mirror of `NebulaParticle` in Shaders.metal. The CPU never reads or
    /// writes one — the buffers are `.storageModePrivate` and it *can't* — so
    /// this exists for two reasons: the buffer stride comes from a layout
    /// rather than a magic number, and the layout is written down once in
    /// Swift where the rest of the contract lives. The shader asserts the same
    /// 96 bytes on its side.
    private struct GPUParticle {
        var posSize = SIMD4<Float>()
        var color = SIMD4<Float>()
        var velHeat = SIMD4<Float>()
        var dirSpin = SIMD4<Float>()
        var axisBand = SIMD4<Float>()
        var traits = SIMD4<Float>()
    }

    /// Bytes of simulation state per particle, straight from the mirror's
    /// layout. Exposed so the test suite can pin it against the
    /// `static_assert` on the MSL side.
    static let particleStride = MemoryLayout<GPUParticle>.stride

    /// Buffer capacity. 2^17 particles × 96 bytes × 2 (ping-pong) ≈ 25 MB of
    /// GPU memory — less than the HDR target it draws into at 4K, and the
    /// Density option decides how many of them actually run.
    private static let capacity = 1 << 17
    /// Density can't reach zero: below a few thousand particles the bodies stop
    /// reading as bodies at all.
    private static let minimumCount = 3_000

    private let device: MTLDevice
    private let particles: GPUParticleSystem
    private let backgroundPipeline: MTLRenderPipelineState
    private let spritePipeline: MTLRenderPipelineState
    /// Blurs a coarse mip of the scene into `bloomTexture`.
    private let bloomPipeline: MTLRenderPipelineState
    /// Maps the HDR scene texture (plus the bloom) to the drawable.
    private let tonemapPipeline: MTLRenderPipelineState
    /// Offscreen float16 target the scene renders into, with a mip chain the
    /// bloom pass reads; recreated whenever the drawable size changes
    /// (including adaptive-resolution steps).
    private var hdrTexture: MTLTexture?
    /// The blurred highlights, at an eighth of the scene's resolution in each
    /// axis. Bloom is a wide, smooth thing by definition, so computing it at
    /// 1/64 the pixels costs nothing and loses nothing.
    private var bloomTexture: MTLTexture?
    private static let bloomDivisor = 8

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        // The scene pipelines target the float16 HDR texture, not the view's
        // format; only the tonemap pass draws to the drawable.
        backgroundPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaBackgroundFragment",
            pixelFormat: .rgba16Float)
        spritePipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "nebulaSpriteVertex", fragment: "nebulaSpriteFragment",
            pixelFormat: .rgba16Float, additiveBlending: true)
        bloomPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaBloomFragment",
            pixelFormat: .rgba16Float)
        tonemapPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaTonemapFragment",
            pixelFormat: pixelFormat)
        particles = try GPUParticleSystem(
            device: device, library: library,
            capacity: Self.capacity,
            stateStride: Self.particleStride,
            seedFunction: "nebulaSeed",
            stepFunction: "nebulaStep")
    }

    func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot
    ) {
        // Every option except Density is consumed inside the shaders (see the
        // `kNebula…` slot constants in Shaders.metal); this one decides how
        // much work there is to encode.
        let density = uniforms[parameter: 0]
        let count = max(Self.minimumCount, Int(Float(Self.capacity) * density))

        guard let hdr = hdrTarget(for: view), let bloom = bloomTarget(for: hdr) else { return }

        // Pass 1: the simulation. Run it — and the whole scene — before
        // touching the drawable: `currentRenderPassDescriptor` blocks until
        // Core Animation hands over one of its few drawables, so encoding
        // everything else first keeps that scarce drawable held only for the
        // final pass instead of for the whole frame.
        particles.step(in: commandBuffer, count: count, uniforms: uniforms, snapshot: snapshot)

        // Pass 2: the scene, into the offscreen HDR texture.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = hdr
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else {
            return
        }
        var u = uniforms
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        snapshot.bands.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        snapshot.waveform.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(spritePipeline)
        encoder.setVertexBytes(
            &u, length: MemoryLayout<VizUniforms>.stride,
            index: GPUParticleSystem.VertexBinding.uniforms)
        particles.encodeSprites(into: encoder, count: count)
        encoder.endEncoding()

        // Pass 3: the bloom's downsample, for free. `generateMipmaps` is a box
        // filter down the chain, so level 4 is already a 16×-reduced copy of
        // the scene; the blit costs a fraction of what a chain of half-scale
        // render passes would.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: hdr)
            blit.endEncoding()
        }

        // Pass 4: blur that coarse level into the small bloom target (see
        // `nebulaBloomFragment` for why the blur has to happen at this
        // resolution rather than during the upsample).
        let bloomPass = MTLRenderPassDescriptor()
        bloomPass.colorAttachments[0].texture = bloom
        // Every pixel of this target is written, so there is nothing to load.
        bloomPass.colorAttachments[0].loadAction = .dontCare
        bloomPass.colorAttachments[0].storeAction = .store
        if let blur = commandBuffer.makeRenderCommandEncoder(descriptor: bloomPass) {
            blur.setRenderPipelineState(bloomPipeline)
            blur.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
            blur.setFragmentTexture(hdr, index: 0)
            blur.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            blur.endEncoding()
        }

        // Pass 5: tonemap to the drawable. If no drawable is available this
        // frame the work above still commits harmlessly.
        guard let viewPass = view.currentRenderPassDescriptor,
            let post = commandBuffer.makeRenderCommandEncoder(descriptor: viewPass)
        else { return }
        post.setRenderPipelineState(tonemapPipeline)
        post.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        post.setFragmentTexture(hdr, index: 0)
        post.setFragmentTexture(bloom, index: 1)
        post.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        post.endEncoding()
    }

    /// Returns the cached HDR scene texture, recreating it when the drawable
    /// size changes (window resizes, adaptive-resolution steps).
    private func hdrTarget(for view: MTKView) -> MTLTexture? {
        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return nil }
        if let texture = hdrTexture, texture.width == width, texture.height == height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: descriptor)
        // The bloom target is derived from the scene's size, so it has to be
        // rebuilt with it.
        bloomTexture = nil
        return hdrTexture
    }

    /// The small blur target, sized from the scene texture.
    private func bloomTarget(for scene: MTLTexture) -> MTLTexture? {
        let width = max(scene.width / Self.bloomDivisor, 16)
        let height = max(scene.height / Self.bloomDivisor, 16)
        if let texture = bloomTexture, texture.width == width, texture.height == height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        bloomTexture = device.makeTexture(descriptor: descriptor)
        return bloomTexture
    }
}
