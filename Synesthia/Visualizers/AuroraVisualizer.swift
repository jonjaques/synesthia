import Metal
import MetalKit

/// Layered aurora ribbons: each ribbon rides the live waveform and glows with
/// the energy of its own slice of the spectrum, over a smoky noise backdrop.
///
/// Like Spectrum Tunnel this is a fullscreen-shader visualizer (see
/// `auroraFragment` in Shaders.metal); it's the only one that also feeds
/// the shader the 256-point waveform, which shapes the ribbons.
final class AuroraVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "aurora",
        name: "Aurora",
        tagline: "Waveform ribbons glowing with their slice of the spectrum",
        options: [
            VisualizerOption(id: "layers", name: "Ribbons", range: 2...10, defaultValue: 7),
            VisualizerOption(id: "height", name: "Wave height", range: 0.05...0.6, defaultValue: 0.28),
        ],
        make: { try AuroraVisualizer(device: $0, library: $1, pixelFormat: $2) })

    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        pipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "auroraFragment",
            pixelFormat: pixelFormat)
    }

    func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot
    ) {
        guard let pass = view.currentRenderPassDescriptor,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        snapshot.bands.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        snapshot.waveform.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
