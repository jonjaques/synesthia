import Metal
import MetalKit
import simd

/// A 3D particle cloud: each particle is bound to a frequency band and flares
/// outward as that band gets loud, with a slow orbiting camera and a smoky
/// audio-reactive background. Closest in spirit to the classic iTunes visualizer.
///
/// Each register gets its own body so the mix is legible at a glance: bass is
/// a tight pulsing core, the mids form a flattened galaxy disc with
/// differential rotation (inner particles orbit faster, shearing the disc
/// into spiral streaks), and the treble is a spherical halo that throws
/// comets on hi-hat/snare transients. Every kick launches a shockwave that
/// sweeps outward through all three. The bodies themselves drift: the heavy
/// core lurches on kicks while the disc and halo counter-orbit around it
/// (see `orbCenter`), and the background paints a colored halo behind each.
///
/// Unlike the other two (pure fragment-shader) visualizers, this one runs a
/// small CPU simulation: every frame `update` advances all particles and
/// writes their positions/colors into a shared `MTLBuffer`, which the GPU
/// then draws as point sprites on top of a shader-painted background.
///
/// Rendering is HDR: background and particles draw into a float16 offscreen
/// target so additive pile-ups accumulate past 1.0, and a final tonemap pass
/// (`nebulaTonemapFragment`) maps the result to the display with vibrance,
/// Reinhard, and an S-curve — bright cores bloom instead of clipping.
final class NebulaVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "nebula",
        name: "Nebula",
        tagline: "A bass core, galaxy disc, and comet halo orbiting to the music",
        options: [
            VisualizerOption(id: "density", name: "Density", range: 0.15...1.0, defaultValue: 0.7),
            VisualizerOption(id: "glow", name: "Glow", range: 0.4...2.5, defaultValue: 1.0),
            VisualizerOption(id: "swirl", name: "Swirl", range: 0.0...2.5, defaultValue: 1.0),
            VisualizerOption(id: "orbits", name: "Orbit speed", range: 0.0...2.5, defaultValue: 1.0),
            VisualizerOption(id: "spread", name: "Spread", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "halos", name: "Halos", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "impact", name: "Impact", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "form", name: "Form", range: 0.0...2.0, defaultValue: 1.0),
        ],
        make: { try NebulaVisualizer(device: $0, library: $1, pixelFormat: $2) })

    /// What the GPU sees; must match the `Particle` struct in
    /// Shaders.metal (xyz position + point size, rgb color + intensity).
    private struct GPUParticle {
        var posSize: SIMD4<Float>
        var color: SIMD4<Float>
    }

    /// CPU-side simulation state. Each particle lives on a ray from the
    /// origin (`direction`, a unit vector) at distance `radius`, orbits by
    /// rotating that direction around an axis at `spin` rad/s, and listens to
    /// one frequency `band`. `phase` desynchronizes the flicker and picks the
    /// comet subset; `kick` is an outward impulse velocity (comets, the beat
    /// shockwave) that decays exponentially while the radius spring below
    /// reels the particle back in.
    private struct CPUParticle {
        var direction: SIMD3<Float>
        var axis: SIMD3<Float>
        var radius: Float
        var band: Int
        var phase: Float
        var spin: Float
        var kick: Float
        /// Per-particle multiplier on the body's target radius (the Form
        /// slider scales its influence): shells become ragged clouds instead
        /// of crisp spheres.
        var bias: Float
    }

    private static let maxParticles = 4096
    /// Depth of the CPU→GPU buffer ring below.
    private static let inFlightFrames = 3

    private let device: MTLDevice
    private let backgroundPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    /// Maps the HDR scene texture to the drawable (vibrance + tone mapping).
    private let tonemapPipeline: MTLRenderPipelineState
    /// Offscreen float16 target the scene renders into; recreated whenever
    /// the drawable size changes (including adaptive-resolution steps).
    private var hdrTexture: MTLTexture?
    /// Triple-buffered particle storage: each frame the CPU writes directly
    /// into the next buffer of the ring while the GPU may still be reading
    /// the previous frames' buffers. The semaphore blocks the CPU only if it
    /// gets a whole ring ahead, so a buffer is never rewritten while the GPU
    /// is reading it (a single shared buffer would race).
    private let particleBuffers: [MTLBuffer]
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: NebulaVisualizer.inFlightFrames)
    private var cpuParticles: [CPUParticle] = []
    /// This frame's color per band: the cosine palette — the most expensive
    /// math in the update loop — is evaluated once per band (64×) instead of
    /// once per particle (4096×), since hue depends only on the band.
    private var bandColors = [SIMD3<Float>](repeating: .zero, count: AudioSnapshot.bandCount)
    /// Rising-edge trackers for the transient envelopes: the envelopes decay
    /// smoothly between hits, so "a new hit" is a frame where the value jumps
    /// back up rather than any frame where it is merely high.
    private var previousBeat: Float = 0
    private var previousTrebleBeat: Float = 0
    /// Radius of the expanding kick shockwave front, in world units; parked
    /// beyond the cloud's extent (inactive) until the next kick resets it.
    private var shockRadius: Float = 10

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        // The scene pipelines target the float16 HDR texture, not the view's
        // format; only the tonemap pass draws to the drawable.
        backgroundPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaBackgroundFragment",
            pixelFormat: .rgba16Float)
        particlePipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "particleVertex", fragment: "particleFragment",
            pixelFormat: .rgba16Float, additiveBlending: true)
        tonemapPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaTonemapFragment",
            pixelFormat: pixelFormat)

        var buffers = [MTLBuffer]()
        for _ in 0..<Self.inFlightFrames {
            guard
                let buffer = device.makeBuffer(
                    length: Self.maxParticles * MemoryLayout<GPUParticle>.stride,
                    options: .storageModeShared)
            else {
                throw NSError(
                    domain: "Synesthia", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not allocate particle buffer"])
            }
            buffers.append(buffer)
        }
        particleBuffers = buffers

        var rng = SystemRandomNumberGenerator()
        cpuParticles = (0..<Self.maxParticles).map { i in
            let direction = Self.randomUnitVector(&rng)
            // Orbit axis: any vector perpendicular to the direction (the
            // cross product with a random vector), so each particle circles
            // the origin in its own plane. Bands are dealt round-robin so
            // every band gets an equal share of particles.
            var axis = simd_normalize(simd_cross(direction, Self.randomUnitVector(&rng)))
            if !axis.x.isFinite { axis = SIMD3(0, 1, 0) }
            return CPUParticle(
                direction: direction,
                axis: axis,
                radius: Float.random(in: 0.6...1.4, using: &rng),
                band: i % AudioSnapshot.bandCount,
                phase: Float.random(in: 0...6.28318, using: &rng),
                spin: Float.random(in: 0.15...0.9, using: &rng) * (Bool.random(using: &rng) ? 1 : -1),
                kick: 0,
                bias: Float.random(in: 0.7...1.35, using: &rng))
        }
    }

    func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot
    ) {
        // p3 (orbit speed) and p4 (spread) are consumed inside `orbCenter`,
        // p5 (halos) by the background shader, p6 (impact) and p7 (form)
        // in `update`.
        let density = uniforms.p0
        let glow = uniforms.p1
        let swirl = uniforms.p2
        let activeCount = max(64, Int(Float(Self.maxParticles) * density))

        guard let hdr = hdrTarget(for: view) else { return }

        // Claim the next buffer in the ring; the GPU hands it back (via the
        // semaphore) when this frame's command buffer finishes executing.
        inFlight.wait()
        bufferIndex = (bufferIndex + 1) % Self.inFlightFrames
        let particleBuffer = particleBuffers[bufferIndex]

        // The simulation writes straight into the GPU-visible buffer
        // (.storageModeShared) — no intermediate array, no copy. Run it
        // *before* touching the drawable: `currentRenderPassDescriptor`
        // blocks until Core Animation hands over one of its few drawables,
        // so simulating first keeps that scarce drawable held only for
        // encode-and-commit instead of for the whole frame's CPU work.
        update(
            into: particleBuffer.contents().bindMemory(
                to: GPUParticle.self,
                capacity: Self.maxParticles),
            dt: min(uniforms.dt, 1 / 20),
            swirl: swirl, glow: glow,
            activeCount: activeCount,
            uniforms: uniforms, snapshot: snapshot)

        // Pass 1: the scene, into the offscreen HDR texture (no drawable
        // needed yet).
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = hdr
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else {
            // The GPU never sees this frame's buffer, so no completed
            // handler will ever hand it back — do it here.
            inFlight.signal()
            return
        }
        let inFlight = self.inFlight
        commandBuffer.addCompletedHandler { @Sendable _ in inFlight.signal() }

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

        encoder.setRenderPipelineState(particlePipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: activeCount)
        encoder.endEncoding()

        // Pass 2: tonemap the HDR texture to the drawable. If no drawable is
        // available this frame the scene work still commits harmlessly and
        // the completed handler above returns the ring buffer.
        guard let viewPass = view.currentRenderPassDescriptor,
            let post = commandBuffer.makeRenderCommandEncoder(descriptor: viewPass)
        else { return }
        post.setRenderPipelineState(tonemapPipeline)
        post.setFragmentTexture(hdr, index: 0)
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
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: descriptor)
        return hdrTexture
    }

    private func update(
        into out: UnsafeMutablePointer<GPUParticle>,
        dt: Float, swirl: Float, glow: Float, activeCount: Int,
        uniforms: VizUniforms, snapshot: AudioSnapshot
    ) {
        let palette = Int(uniforms.palette)
        let sensitivity = uniforms.sensitivity
        let time = uniforms.time
        /// The Impact slider: scales the transient theatrics (comet flings
        /// and the shockwave) without touching the steady-state motion.
        let impact = uniforms.p6
        /// The Form slider: how irregular the bodies are — 0 gives crisp
        /// spheres and a flat disc, 2 ragged clouds, a strongly warped disc,
        /// and a hard-stretched core.
        let form = uniforms.p7

        // Fill this frame's per-band color table once, up front. The spectral
        // centroid steers the hue, so brighter music literally shifts color.
        let hueShift = time * 0.012 + snapshot.centroid * 0.35
        for b in 0..<AudioSnapshot.bandCount {
            bandColors[b] = Palettes.color(
                Float(b) / Float(AudioSnapshot.bandCount) + hueShift,
                palette: palette)
        }

        // A fresh kick launches a shockwave from the core that sweeps outward
        // through the cloud, flaring and nudging every particle it passes.
        if snapshot.beat > previousBeat + 0.25 { shockRadius = 0 }
        previousBeat = snapshot.beat
        let trebleHit = snapshot.trebleBeat > previousTrebleBeat + 0.3
        previousTrebleBeat = snapshot.trebleBeat
        if shockRadius < 5 { shockRadius += dt * 3.4 * uniforms.speed }

        // The shared axis the mid disc orbits: tilted off vertical and slowly
        // precessing, so the disc leans and wanders over the course of a song.
        let precession = time * 0.02
        let galacticAxis = simd_normalize(
            SIMD3<Float>(0.30 * cos(precession), 1, 0.30 * sin(precession)))

        // Where the three bodies sit this frame; each particle orbits its own
        // body's center rather than the world origin.
        let bassCenter = Self.orbCenter(0, uniforms: uniforms)
        let midCenter = Self.orbCenter(1, uniforms: uniforms)
        let trebleCenter = Self.orbCenter(2, uniforms: uniforms)

        // The core's stretch axis tumbles slowly; kicks elongate the core
        // along it, so it reads as a pulsing ellipsoid, not a static ball.
        let stretchAxis = simd_normalize(SIMD3<Float>(sin(time * 0.11), 0.35, cos(time * 0.13)))
        let coreStretch = form * (0.30 + 0.35 * snapshot.beat)

        // Loop-invariant: one transcendental call instead of 4096.
        let kickDecay = exp(-dt * 2.8)

        for i in 0..<activeCount {
            var p = cpuParticles[i]
            let energy = min(snapshot.bands[p.band] * sensitivity, 1.4)

            // Each register gets its own body: bass is a tight pulsing core,
            // mids form a flattened rotating galaxy disc, treble is a
            // spherical halo that throws comets on hi-hat/snare transients.
            let isBass = p.band < 12
            let isTreble = p.band >= 47
            let isMid = !isBass && !isTreble

            var swirlRate = 0.25 + energy + 0.4 * snapshot.flux
            var axis = p.axis
            var spin = p.spin
            if isBass {
                swirlRate *= 0.55
            } else if isTreble {
                swirlRate *= 1.6
            } else {
                // Mids share one axis (blended with a little per-particle
                // tilt for disc thickness) and all turn the same way; inner
                // particles orbit faster than outer ones, shearing the disc
                // into spiral streaks like a galaxy's differential rotation.
                axis = simd_normalize(galacticAxis + p.axis * 0.22)
                spin = abs(p.spin)
                swirlRate *= 1.5 / (0.45 + p.radius)
            }
            let angle = spin * swirlRate * dt * swirl * uniforms.speed
            if angle != 0 {
                let q = simd_quatf(angle: angle, axis: axis)
                p.direction = simd_normalize(q.act(p.direction))
            }

            // The band's energy sets a target distance from the center; the
            // radius eases toward it exponentially (frame-rate-independent
            // spring-like motion), so hits fling particles out and silence
            // lets them drift back in.
            // (Radii are a bit smaller than when everything shared one
            // center, so the drifting bodies stay distinct instead of
            // permanently enveloping each other.)
            var target: Float
            if isBass {
                target = 0.40 + 0.9 * energy + 0.6 * snapshot.beat
            } else if isTreble {
                target = 0.80 + 1.3 * energy + 0.5 * snapshot.trebleBeat
            } else {
                target = 0.60 + 1.2 * energy + 0.35 * snapshot.beat
            }
            // Per-particle radius bias (Form slider): shells become ragged
            // clouds instead of crisp spheres.
            target *= 1 + (p.bias - 1) * form
            p.radius += (target - p.radius) * min(1, dt * (isBass ? 7 : 5))

            // Comets: a new treble transient flings a pseudo-random ~30% of
            // the halo outward; the impulse decays in about a third of a
            // second and the spring above reels the particle back in.
            if isTreble, trebleHit, p.phase.truncatingRemainder(dividingBy: 1) < 0.3 {
                p.kick = (1.8 + 2.2 * energy) * impact
            }
            // The shockwave front flares and pushes particles as it passes.
            var shockBoost: Float = 0
            if shockRadius < 4 {
                let d = p.radius - shockRadius
                shockBoost = exp(-d * d * 9) * snapshot.beat * impact
                p.kick = max(p.kick, shockBoost * 0.9)
            }
            p.radius = min(p.radius + p.kick * dt, 5)
            p.kick *= kickDecay
            cpuParticles[i] = p

            var offset = p.direction * p.radius
            if isMid {
                // Flatten the mid shell into the disc by squashing the
                // component along the galactic axis...
                offset -= galacticAxis * simd_dot(offset, galacticAxis) * 0.55
                // ...then warp it like a real galaxy: an m=2 corrugation
                // that slowly precesses, lifting opposite edges out of the
                // plane (Form slider).
                let azimuth: Float = atan2(offset.z, offset.x)
                let corrugation: Float = sin(2 * azimuth + time * 0.35)
                let warp: Float = 0.14 * form * corrugation * p.radius
                offset += galacticAxis * warp
            } else if isBass {
                offset += stretchAxis * simd_dot(offset, stretchAxis) * coreStretch
            }
            let position = (isBass ? bassCenter : isTreble ? trebleCenter : midCenter) + offset
            var size: Float
            var alpha: Float
            if isBass {
                let pulse = 1 + 0.5 * snapshot.beat
                size = glow * (4.5 + 15 * energy) * pulse
                alpha = 0.16 + 0.84 * energy
            } else if isTreble {
                let flicker = 0.55 + 0.45 * sin(p.phase + time * 30)
                size = glow * (1.4 + 6 * energy + 5 * snapshot.trebleBeat * flicker + 2.5 * p.kick)
                alpha = 0.06 + 0.94 * min(energy + snapshot.trebleBeat * 0.6 + p.kick * 0.4, 1.2)
            } else {
                let flicker = 0.75 + 0.25 * sin(p.phase + time * 18)
                size = glow * (2.2 + 11 * energy + 4 * snapshot.components[5] * sensitivity * flicker)
                alpha = 0.10 + 0.90 * min(energy + 0.25 * snapshot.flux, 1.1)
            }
            size += glow * 7 * shockBoost
            alpha = min(alpha + 0.6 * shockBoost, 1.5)

            var color = bandColors[p.band]
            color = simd_mix(color, SIMD3<Float>(1, 1, 1), SIMD3<Float>(repeating: min(energy * 0.45, 0.6)))
            if isBass {
                // Kicks flash the core toward warm white...
                color = simd_mix(
                    color, SIMD3<Float>(1.0, 0.90, 0.72), SIMD3<Float>(repeating: 0.45 * snapshot.beat))
            } else if isTreble {
                // ...while comets streak cool white.
                color = simd_mix(
                    color, SIMD3<Float>(0.85, 0.93, 1.0), SIMD3<Float>(repeating: min(p.kick * 0.4, 0.6)))
            }

            out[i] = GPUParticle(
                posSize: SIMD4(position.x, position.y, position.z, size),
                color: SIMD4(color.x, color.y, color.z, alpha))
        }
    }

    /// Where each of the three bodies (0 = bass core, 1 = mid disc,
    /// 2 = treble halo) sits at this frame's time: the core wanders near the
    /// middle and lurches on kicks; the disc and halo counter-orbit around
    /// it, swinging wider as their register gets louder. The Orbit speed
    /// slider (p3) scales how fast they travel, Spread (p4) how far they
    /// roam — 0 collapses them back into one centered cloud. CPU mirror of
    /// `nebulaOrbCenter` in Shaders.metal — keep the two in sync, the
    /// background shader draws each body's halo at the same spot.
    private static func orbCenter(_ body: Int, uniforms u: VizUniforms) -> SIMD3<Float> {
        let t = u.time * u.speed * u.p3
        let spread = u.p4
        switch body {
        case 0:
            let c = SIMD3<Float>(
                0.20 * sin(t * 0.42), 0.10 * sin(t * 0.31 + 1.7), 0.16 * cos(t * 0.36))
            let lurch = SIMD3<Float>(sin(t * 0.5), 0.3 * cos(t * 0.37), cos(t * 0.5))
            return (c + simd_normalize(lurch) * (0.10 * u.beat)) * spread
        case 1:
            let a = t * 0.23
            let radius = (0.45 + 0.30 * u.mid) * spread
            return SIMD3<Float>(cos(a), 0.22 * sin(a * 1.3), sin(a)) * radius
        default:
            let a = -t * 0.35 + 2.1
            let radius = (0.70 + 0.45 * u.treble) * spread
            return SIMD3<Float>(radius * cos(a), 0.30 * sin(t * 0.55) * spread, radius * sin(a))
        }
    }

    /// Uniformly distributed direction: sample the unit cube, reject points
    /// outside the unit sphere, normalize. (Normalizing raw cube samples
    /// would cluster directions toward the corners.)
    private static func randomUnitVector(_ rng: inout SystemRandomNumberGenerator) -> SIMD3<Float> {
        while true {
            let v = SIMD3<Float>(
                Float.random(in: -1...1, using: &rng),
                Float.random(in: -1...1, using: &rng),
                Float.random(in: -1...1, using: &rng))
            let len = simd_length(v)
            if len > 0.05, len <= 1 { return v / len }
        }
    }
}
