import Metal
import MetalKit
import simd

/// A 3D particle cloud: each particle is bound to a frequency band and flares
/// outward as that band gets loud, with a slow orbiting camera and a smoky
/// audio-reactive background. Closest in spirit to the classic iTunes visualizer.
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

    private struct GPUParticle {
        var posSize: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private struct CPUParticle {
        var direction: SIMD3<Float>
        var axis: SIMD3<Float>
        var radius: Float
        var band: Int
        var phase: Float
        var spin: Float
    }

    private static let maxParticles = 4096

    private let backgroundPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer
    private var cpuParticles: [CPUParticle] = []
    private var gpuParticles: [GPUParticle]

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        backgroundPipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "nebulaBackgroundFragment",
            pixelFormat: pixelFormat)
        particlePipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "particleVertex", fragment: "particleFragment",
            pixelFormat: pixelFormat, additiveBlending: true)

        gpuParticles = Array(repeating: GPUParticle(posSize: .zero, color: .zero),
                             count: Self.maxParticles)
        guard let buffer = device.makeBuffer(
            length: Self.maxParticles * MemoryLayout<GPUParticle>.stride,
            options: .storageModeShared) else {
            throw NSError(domain: "Synesthia", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate particle buffer"])
        }
        particleBuffer = buffer

        var rng = SystemRandomNumberGenerator()
        cpuParticles = (0..<Self.maxParticles).map { i in
            let direction = Self.randomUnitVector(&rng)
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

        update(dt: min(uniforms.dt, 1 / 20),
               swirl: swirl, glow: glow,
               activeCount: activeCount,
               uniforms: uniforms, snapshot: snapshot)

        guard let pass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

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

    private func update(dt: Float, swirl: Float, glow: Float, activeCount: Int,
                        uniforms: VizUniforms, snapshot: AudioSnapshot) {
        let palette = Int(uniforms.palette)
        let sensitivity = uniforms.sensitivity
        let time = uniforms.time

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

            let hue = Float(p.band) / Float(AudioSnapshot.bandCount)
            var color = Palettes.color(hue + time * 0.01 + snapshot.centroid * 0.15, palette: palette)
            color = simd_mix(color, SIMD3<Float>(1, 1, 1), SIMD3<Float>(repeating: min(energy * 0.45, 0.6)))

            gpuParticles[i] = GPUParticle(
                posSize: SIMD4(position.x, position.y, position.z, size),
                color: SIMD4(color.x, color.y, color.z, alpha))
        }

        gpuParticles.withUnsafeBytes {
            particleBuffer.contents().copyMemory(
                from: $0.baseAddress!,
                byteCount: activeCount * MemoryLayout<GPUParticle>.stride)
        }
    }

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
