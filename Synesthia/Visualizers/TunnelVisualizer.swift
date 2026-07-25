import Metal
import MetalKit

/// A shader-driven flight through a tube whose walls are the live spectrum:
/// each angular slice of the tunnel is one frequency band.
final class TunnelVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "tunnel",
        name: "Spectrum Tunnel",
        tagline: "Fly through rings built from the frequency spectrum",
        options: [
            VisualizerOption(id: "twist", name: "Twist", range: 0.0...3.0, defaultValue: 1.0),
            VisualizerOption(id: "glow", name: "Glow", range: 0.3...2.5, defaultValue: 1.0),
        ],
        make: { try TunnelVisualizer(device: $0, library: $1, pixelFormat: $2) })

    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        pipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "tunnelFragment",
            pixelFormat: pixelFormat)
    }

    func draw(in view: MTKView,
              commandBuffer: MTLCommandBuffer,
              uniforms: VizUniforms,
              snapshot: AudioSnapshot) {
        guard let pass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        snapshot.bands.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
