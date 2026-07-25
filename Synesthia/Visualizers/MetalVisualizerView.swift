import SwiftUI
import MetalKit
import QuartzCore

/// Hosts an MTKView and forwards each frame to the currently selected visualizer.
struct MetalVisualizerView: NSViewRepresentable {
    let appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.layer?.backgroundColor = .black
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let appState: AppState
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let library: MTLLibrary

        private var visualizer: (any Visualizer)?
        private var visualizerID: String?
        private let startTime = CACurrentMediaTime()
        private var lastFrameTime = CACurrentMediaTime()

        init(appState: AppState) {
            self.appState = appState
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: ShaderSource.library, options: nil) else {
                fatalError("Metal is unavailable on this Mac")
            }
            self.device = device
            self.queue = queue
            self.library = library
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }

            let wantedID = appState.visualizerID
            if visualizerID != wantedID || visualizer == nil {
                guard let descriptor = VisualizerRegistry.descriptor(id: wantedID) else { return }
                visualizer = try? descriptor.make(device, library, view.colorPixelFormat)
                visualizerID = wantedID
            }
            guard let visualizer,
                  let descriptor = VisualizerRegistry.descriptor(id: wantedID) else { return }

            let now = CACurrentMediaTime()
            let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
            lastFrameTime = now

            let snapshot = appState.analyzer.latest()
            let settings = appState.settings

            var uniforms = VizUniforms()
            uniforms.resolution = SIMD2(Float(view.drawableSize.width),
                                        Float(view.drawableSize.height))
            uniforms.time = Float(now - startTime)
            uniforms.dt = dt
            uniforms.bass = snapshot.bass
            uniforms.mid = snapshot.mid
            uniforms.treble = snapshot.treble
            uniforms.level = snapshot.level
            uniforms.beat = snapshot.beat
            uniforms.subBass = snapshot.components[0]
            uniforms.lowMid = snapshot.components[2]
            uniforms.highMid = snapshot.components[4]
            uniforms.presence = snapshot.components[5]
            uniforms.air = snapshot.components[7]
            uniforms.trebleBeat = snapshot.trebleBeat
            uniforms.flux = snapshot.flux
            uniforms.centroid = snapshot.centroid
            uniforms.sensitivity = Float(settings.sensitivity)
            uniforms.speed = Float(settings.speed)
            uniforms.palette = Float(settings.paletteIndex)
            for (index, option) in descriptor.options.prefix(4).enumerated() {
                uniforms.setParameter(index, to: Float(settings.value(visualizer: wantedID, option: option)))
            }

            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            visualizer.draw(in: view, commandBuffer: commandBuffer,
                            uniforms: uniforms, snapshot: snapshot)
            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
            commandBuffer.commit()
        }
    }
}
