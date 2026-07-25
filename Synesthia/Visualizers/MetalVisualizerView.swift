import SwiftUI
import MetalKit
import QuartzCore

/// Hosts an MTKView and forwards each frame to the currently selected visualizer.
///
/// `MTKView` is MetalKit's AppKit view that owns the drawable surface and
/// calls its delegate 60 times a second; `NSViewRepresentable` is the SwiftUI
/// bridge that lets it sit inside the SwiftUI hierarchy. The `Coordinator` is
/// the long-lived object behind the value-type view struct — it owns all the
/// Metal machinery and acts as the MTKView's delegate.
///
/// This is the *pull* end of the audio pipeline: nothing pushes audio data at
/// the UI; every frame the coordinator asks the analyzer for the latest
/// snapshot and hands it to the visualizer.
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
        // Drive continuously from an internal display link rather than on
        // demand — the visuals animate even when SwiftUI has nothing to update.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // We never read the framebuffer back; letting Metal know enables
        // memoryless/optimized storage for it.
        view.framebufferOnly = true
        view.layer?.backgroundColor = .black
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let appState: AppState
        let device: MTLDevice
        /// Feeds encoded command buffers to the GPU; one per app is plenty.
        private let queue: MTLCommandQueue
        /// All shader functions, compiled at build time from Shaders.metal
        /// into the app's default library.
        private let library: MTLLibrary

        private var visualizer: (any Visualizer)?
        private var visualizerID: String?
        private let startTime = CACurrentMediaTime()
        private var lastFrameTime = CACurrentMediaTime()

        init(appState: AppState) {
            self.appState = appState
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary() else {
                fatalError("Metal is unavailable on this Mac")
            }
            self.device = device
            self.queue = queue
            self.library = library
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Called by the MTKView once per display refresh. Each frame:
        /// (re)build the visualizer if the selection changed, gather the
        /// audio snapshot + tuning into a `VizUniforms`, let the visualizer
        /// encode its drawing, then present.
        func draw(in view: MTKView) {
            guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }

            // Visualizers are built lazily and torn down on switch; only the
            // selected one holds GPU resources.
            let wantedID = appState.visualizerID
            if visualizerID != wantedID || visualizer == nil {
                guard let descriptor = VisualizerRegistry.descriptor(id: wantedID) else { return }
                visualizer = try? descriptor.make(device, library, view.colorPixelFormat)
                visualizerID = wantedID
            }
            guard let visualizer,
                  let descriptor = VisualizerRegistry.descriptor(id: wantedID) else { return }

            // Frame delta, clamped so a hiccup (debugger pause, window drag)
            // doesn't produce one giant simulation step.
            let now = CACurrentMediaTime()
            let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
            lastFrameTime = now

            let snapshot = appState.analyzer.latest()
            let tuning = appState.settings.tuning(for: wantedID)

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
            uniforms.sensitivity = Float(tuning.sensitivity)
            uniforms.speed = Float(tuning.speed)
            uniforms.palette = Float(tuning.paletteIndex)
            for (index, option) in descriptor.options.prefix(4).enumerated() {
                uniforms.setParameter(index, to: Float(tuning.value(for: option)))
            }

            // Standard Metal frame: record GPU work into a command buffer,
            // schedule the drawable (the screen surface) for presentation,
            // and commit. `commit` is asynchronous — the CPU moves on while
            // the GPU renders.
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
