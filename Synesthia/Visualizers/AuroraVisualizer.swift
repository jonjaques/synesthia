import Metal
import MetalKit

/// A night sky where every element is an instrument. Up to eight aurora
/// ribbons, one per register — sub-bass at the bottom of the sky through air
/// at the top — each with its own motion personality (lows fat and slow,
/// jumping on the kick; mids carrying the waveform and answering onsets;
/// highs thin and fast, shivering on hi-hats) and each shaded along its
/// length by the fine spectrum inside its own range. Above them a
/// three-depth star field twinkles with the air band, and every hi-hat and
/// kick lights a different constellation.
///
/// Like Spectrum Tunnel this is a fullscreen-shader visualizer (see
/// `auroraFragment` in Shaders.metal), fed the uniforms, the 64-band array,
/// and the 256-point waveform that shapes the ribbons.
final class AuroraVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "aurora",
        name: "Aurora",
        tagline: "One ribbon per instrument, under a sky that flashes with the drums",
        options: [
            VisualizerOption(id: "layers", name: "Ribbons", range: 2...8, defaultValue: 8, slot: 0),
            VisualizerOption(
                id: "height", name: "Wave height", range: 0.05...0.6, defaultValue: 0.28, slot: 1),
            VisualizerOption(id: "stars", name: "Stars", range: 0.0...2.0, defaultValue: 1.0, slot: 2),
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
