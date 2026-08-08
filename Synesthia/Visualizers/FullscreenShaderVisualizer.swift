import Metal
import MetalKit

/// A visualizer that is nothing but one fullscreen fragment shader, fed the
/// standard three bindings: uniforms at 0, the 64-band array at 1, the
/// waveform at 2.
///
/// Aurora and Spectrum Tunnel encoded exactly these ten lines, character for
/// character, differing only in which fragment function they named. So the
/// ordering rule they both depended on — take the drawable as *late* as
/// possible, because `currentRenderPassDescriptor` blocks until Core Animation
/// hands one over — was a comment each conformer had to remember rather than
/// something the code enforced. Here there is one encode path and it is
/// correct; a new fullscreen shader gets that for free by naming its function.
///
/// This is not the shape of every visualizer, and it is not meant to be.
/// `BarsVisualizer` runs a CPU update before acquiring the drawable and binds
/// an extra buffer, and `NebulaVisualizer` encodes compute passes and an HDR
/// chain — they are what the `Visualizer` protocol exists for and they stay
/// classes of their own.
final class FullscreenShaderVisualizer: Visualizer {
    private let pipeline: MTLRenderPipelineState

    /// - Parameter fragment: the MSL function name in `Shaders.metal`. A typo
    ///   here is a *runtime* failure, not a build one — `makeRenderPipeline`
    ///   throws `VisualizerError.missingFunction` and the host swallows it with
    ///   `try?`, so the only symptom is a black canvas.
    init(
        fragment: String,
        device: MTLDevice,
        library: MTLLibrary,
        pixelFormat: MTLPixelFormat
    ) throws {
        pipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: fragment,
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
