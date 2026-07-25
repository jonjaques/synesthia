import Metal
import MetalKit
import simd

/// A 3D particle cloud: each particle is bound to a frequency band and flares
/// outward as that band gets loud, with a slow orbiting camera and a smoky
/// audio-reactive background. Closest in spirit to the classic iTunes visualizer.
///
/// Unlike the other two (pure fragment-shader) visualizers, this one runs a
/// small CPU simulation: every frame `update` advances all particles and
/// writes their positions/colors into a shared `MTLBuffer`, which the GPU
/// then draws as point sprites on top of a shader-painted background.
final class NebulaVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "nebula",
        name: "Nebula",
        tagline: "Orbiting particles that flare with each frequency band",
        options: [
            VisualizerOption(id: "density", name: "Density", range: 0.15...1.0, defaultValue: 0.7),
            VisualizerOption(id: "glow", name: "Glow", range: 0.4...2.5, defaultValue: 1.0),
            VisualizerOption(id: "swirl", name: "Swirl", range: 0.0...2.5, defaultValue: 1.0),
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
    /// rotating that direction around its own `axis` at `spin` rad/s, and
    /// listens to one frequency `band`. `phase` desynchronizes the flicker.
    private struct CPUParticle {
        var direction: SIMD3<Float>
        var axis: SIMD3<Float>
        var radius: Float
        var band: Int
        var phase: Float
        var spin: Float
    }

    private static let maxParticles = 4096
    /// Depth of the CPU→GPU buffer ring below.
    private static let inFlightFrames = 3

    private let backgroundPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
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

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        backgroundPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaBackgroundFragment",
            pixelFormat: pixelFormat)
        particlePipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "particleVertex", fragment: "particleFragment",
            pixelFormat: pixelFormat, additiveBlending: true)

        var buffers = [MTLBuffer]()
        for _ in 0..<Self.inFlightFrames {
            guard let buffer = device.makeBuffer(
                length: Self.maxParticles * MemoryLayout<GPUParticle>.stride,
                options: .storageModeShared) else {
                throw NSError(domain: "Synesthia", code: 1,
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
                spin: Float.random(in: 0.15...0.9, using: &rng) * (Bool.random(using: &rng) ? 1 : -1))
        }
    }

    func draw(in view: MTKView,
              commandBuffer: MTLCommandBuffer,
              uniforms: VizUniforms,
              snapshot: AudioSnapshot) {
        let density = uniforms.p0
        let glow = uniforms.p1
        let swirl = uniforms.p2
        let activeCount = max(64, Int(Float(Self.maxParticles) * density))

        guard let pass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Claim the next buffer in the ring; the GPU hands it back (via the
        // semaphore) when this frame's command buffer finishes executing.
        inFlight.wait()
        let inFlight = self.inFlight
        commandBuffer.addCompletedHandler { @Sendable _ in inFlight.signal() }
        bufferIndex = (bufferIndex + 1) % Self.inFlightFrames
        let particleBuffer = particleBuffers[bufferIndex]

        // The simulation writes straight into the GPU-visible buffer
        // (.storageModeShared) — no intermediate array, no copy.
        update(into: particleBuffer.contents().bindMemory(to: GPUParticle.self,
                                                          capacity: Self.maxParticles),
               dt: min(uniforms.dt, 1 / 20),
               swirl: swirl, glow: glow,
               activeCount: activeCount,
               uniforms: uniforms, snapshot: snapshot)

        var u = uniforms
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        snapshot.bands.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(particlePipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: activeCount)
        encoder.endEncoding()
    }

    private func update(into out: UnsafeMutablePointer<GPUParticle>,
                        dt: Float, swirl: Float, glow: Float, activeCount: Int,
                        uniforms: VizUniforms, snapshot: AudioSnapshot) {
        let palette = Int(uniforms.palette)
        let sensitivity = uniforms.sensitivity
        let time = uniforms.time

        // Fill this frame's per-band color table once, up front.
        let hueShift = time * 0.01 + snapshot.centroid * 0.15
        for b in 0..<AudioSnapshot.bandCount {
            bandColors[b] = Palettes.color(Float(b) / Float(AudioSnapshot.bandCount) + hueShift,
                                           palette: palette)
        }

        for i in 0..<activeCount {
            var p = cpuParticles[i]
            let energy = min(snapshot.bands[p.band] * sensitivity, 1.4)

            // Each particle behaves according to the register it listens to:
            // low bands form a heavy pulsing core, mids orbit, highs sparkle out wide.
            let isBass = p.band < 12
            let isTreble = p.band >= 47

            var swirlRate = 0.25 + energy + 0.4 * snapshot.flux
            if isBass { swirlRate *= 0.55 }
            if isTreble { swirlRate *= 1.6 }
            let angle = p.spin * swirlRate * dt * swirl * uniforms.speed
            if angle != 0 {
                let q = simd_quatf(angle: angle, axis: p.axis)
                p.direction = simd_normalize(q.act(p.direction))
            }

            // The band's energy sets a target distance from the center; the
            // radius eases toward it exponentially (frame-rate-independent
            // spring-like motion), so hits fling particles out and silence
            // lets them drift back in.
            var target: Float
            if isBass {
                target = 0.50 + 1.1 * energy + 0.75 * snapshot.beat
            } else if isTreble {
                target = 1.00 + 1.6 * energy + 0.55 * snapshot.trebleBeat
            } else {
                target = 0.75 + 1.5 * energy + 0.45 * snapshot.beat
            }
            p.radius += (target - p.radius) * min(1, dt * (isBass ? 7 : 5))
            cpuParticles[i] = p

            let position = p.direction * p.radius
            var size: Float
            var alpha: Float
            if isBass {
                let pulse = 1 + 0.5 * snapshot.beat
                size = glow * (4.5 + 15 * energy) * pulse
                alpha = 0.16 + 0.84 * energy
            } else if isTreble {
                let flicker = 0.55 + 0.45 * sin(p.phase + time * 30)
                size = glow * (1.4 + 6 * energy + 5 * snapshot.trebleBeat * flicker)
                alpha = 0.06 + 0.94 * min(energy + snapshot.trebleBeat * 0.6, 1.2)
            } else {
                let flicker = 0.75 + 0.25 * sin(p.phase + time * 18)
                size = glow * (2.2 + 11 * energy + 4 * snapshot.components[5] * sensitivity * flicker)
                alpha = 0.10 + 0.90 * energy
            }

            var color = bandColors[p.band]
            color = simd_mix(color, SIMD3<Float>(1, 1, 1), SIMD3<Float>(repeating: min(energy * 0.45, 0.6)))

            out[i] = GPUParticle(
                posSize: SIMD4(position.x, position.y, position.z, size),
                color: SIMD4(color.x, color.y, color.z, alpha))
        }
    }

    /// Uniformly distributed direction: sample the unit cube, reject points
    /// outside the unit sphere, normalize. (Normalizing raw cube samples
    /// would cluster directions toward the corners.)
    private static func randomUnitVector(_ rng: inout SystemRandomNumberGenerator) -> SIMD3<Float> {
        while true {
            let v = SIMD3<Float>(Float.random(in: -1...1, using: &rng),
                                 Float.random(in: -1...1, using: &rng),
                                 Float.random(in: -1...1, using: &rng))
            let len = simd_length(v)
            if len > 0.05, len <= 1 { return v / len }
        }
    }
}
