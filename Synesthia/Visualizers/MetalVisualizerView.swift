import MetalKit
import QuartzCore
import SwiftUI

/// The process-wide Metal objects every visualizer needs.
///
/// Built once, lazily, and **optional on purpose**: `MTLCreateSystemDefaultDevice()`
/// returns nil on a Mac with no usable Metal device — most plausibly a virtual
/// machine, which is exactly where App Review sometimes runs. Crashing there
/// would be an automatic rejection with no diagnostic attached, so the whole
/// app degrades to an explanatory view instead (see `MetalUnavailableView`).
struct MetalRenderContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    /// All shader functions, compiled at build time from Shaders.metal into
    /// the app's default library.
    let library: MTLLibrary

    static let shared: MetalRenderContext? = {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary()
        else { return nil }
        return MetalRenderContext(device: device, queue: queue, library: library)
    }()
}

/// Hosts an MTKView and forwards each frame to the currently selected visualizer.
///
/// `MTKView` is MetalKit's AppKit view that owns the drawable surface and
/// calls its delegate once per display refresh; `NSViewRepresentable` is the
/// SwiftUI bridge that lets it sit inside the SwiftUI hierarchy. The
/// `Coordinator` is the long-lived object behind the value-type view struct —
/// it owns all the Metal machinery and acts as the MTKView's delegate.
///
/// This is the *pull* end of the audio pipeline: nothing pushes audio data at
/// the UI; every frame the coordinator asks the analyzer for the latest
/// snapshot and hands it to the visualizer.
struct MetalVisualizerView: NSViewRepresentable {
    let appState: AppState
    let context: MetalRenderContext

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, context: context)
    }

    func makeNSView(context: Context) -> MTKView {
        let coordinator = context.coordinator
        let view = MTKView()
        view.device = coordinator.context.device
        view.delegate = coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Drive continuously from an internal display link rather than on
        // demand — the visuals animate even when SwiftUI has nothing to update.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // We never read the framebuffer back; letting Metal know enables
        // memoryless/optimized storage for it.
        view.framebufferOnly = true
        // The coordinator owns the drawable size (see updateDrawableSize):
        // it renders at a fraction of native resolution when the GPU can't
        // hold the frame budget, and the layer scales the result up.
        view.autoResizeDrawable = false
        view.layer?.backgroundColor = .black
        coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let appState: AppState
        let context: MetalRenderContext

        private weak var view: MTKView?
        private var visualizer: (any Visualizer)?
        private var visualizerID: String?
        private let startTime = CACurrentMediaTime()
        private var lastFrameTime = CACurrentMediaTime()

        /// Cached because it is read every frame; refreshed from the workspace
        /// accessibility notification.
        private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        /// Slow-moving copies of the level features, used only in Reduce Motion
        /// so brightness drifts instead of strobing.
        private var smoothed = SIMD4<Float>(repeating: 0)

        /// Last frame's transient envelopes, for the rising-edge detection
        /// below. The analyzer publishes `beat`/`trebleBeat` as envelopes that
        /// decay smoothly between hits, so "high" is not the same as "a hit
        /// just landed"; only a frame where the value *jumps* is a new hit.
        /// Every visualizer that wanted impulses used to redo this itself —
        /// and a GPU simulation kernel, which has no memory of the previous
        /// frame, could not have done it at all.
        private var previousBeat: Float = 0
        private var previousTrebleBeat: Float = 0
        private var beatCount: Float = 0
        private var frameCount: Float = 0
        /// When the current visualizer was built, for the `intro` ramp.
        private var visualizerBuiltAt = CACurrentMediaTime()
        /// How long a freshly built visualizer takes to fade in.
        private static let introDuration = 0.7

        /// The rungs of the adaptive-resolution ladder (see `adaptResolution`):
        /// the drawable renders at this fraction of native pixels per axis, so
        /// the bottom rung costs a quarter of the top one. Discrete steps with
        /// hysteresis, not a continuous scale, so the size isn't twitching
        /// every adjustment window.
        private static let renderScales: [CGFloat] = [0.5, 0.625, 0.75, 0.875, 1.0]
        private var renderScaleIndex = renderScales.count - 1
        /// Measured GPU time per frame, fed by command-buffer completion
        /// handlers on Metal's completion thread and drained on the main
        /// thread every adjustment window.
        private let gpuTimer = GPUFrameTimer()
        private var lastScaleCheck = CACurrentMediaTime()

        init(appState: AppState, context: MetalRenderContext) {
            self.appState = appState
            self.context = context
            super.init()
        }

        /// Wires up the notifications that govern pausing. Frame *rate* is
        /// recomputed inside `draw`, but pausing cannot be: a paused view stops
        /// being drawn, so nothing inside the draw loop could ever un-pause it.
        func attach(to view: MTKView) {
            self.view = view
            let center = NotificationCenter.default
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSApplication.didHideNotification,
                NSApplication.didUnhideNotification,
            ] {
                center.addObserver(
                    self, selector: #selector(pacingChanged),
                    name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(accessibilityChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil)
            // Selector-based observers are removed automatically when the
            // observer deallocates, so there is no deinit to write.
            updatePauseState()
        }

        @objc private func pacingChanged(_ note: Notification) {
            updatePauseState()
        }

        @objc private func accessibilityChanged(_ note: Notification) {
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// Stop rendering entirely when no pixel we draw can be seen. Without
        /// this the view renders at full rate behind other windows and in the
        /// Dock — the classic laptop-fan complaint.
        private func updatePauseState() {
            guard let view, let window = view.window else { return }
            let visible = window.occlusionState.contains(.visible)
            view.isPaused = !visible || window.isMiniaturized
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Called by the MTKView once per display refresh. Each frame:
        /// (re)build the visualizer if the selection changed, gather the
        /// audio snapshot + tuning into a `VizUniforms`, let the visualizer
        /// encode its drawing, then present.
        func draw(in view: MTKView) {
            updateFrameRate(view)
            adaptResolution(view)
            updateDrawableSize(view)
            guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }

            // Visualizers are built lazily and torn down on switch; only the
            // selected one holds GPU resources.
            let wantedID = appState.visualizerID
            if visualizerID != wantedID || visualizer == nil {
                guard let descriptor = VisualizerRegistry.descriptor(id: wantedID) else { return }
                visualizer = try? descriptor.make(context.device, context.library, view.colorPixelFormat)
                visualizerID = wantedID
                // Every visualizer has its own cost profile; start the new one
                // at full resolution and let the controller re-adapt from
                // fresh measurements.
                renderScaleIndex = Self.renderScales.count - 1
                gpuTimer.reset()
                visualizerBuiltAt = CACurrentMediaTime()
            }
            guard let visualizer,
                let descriptor = VisualizerRegistry.descriptor(id: wantedID)
            else { return }

            // Frame delta, clamped so a hiccup (debugger pause, window drag)
            // doesn't produce one giant simulation step.
            let now = CACurrentMediaTime()
            let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
            lastFrameTime = now

            let snapshot = appState.analyzer.latest()
            let tuning = appState.settings.tuning(for: wantedID)

            var uniforms = VizUniforms()
            uniforms.resolution = SIMD2(
                Float(view.drawableSize.width),
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
            // Each option names its own slot, so the popover's order is free to
            // change without remapping what the shader reads. `setParameter` is
            // bounds-checked, so a runtime-registered plugin declaring a slot
            // outside the block loses that option rather than trapping.
            for option in descriptor.options {
                uniforms.setParameter(option.slot, to: Float(tuning.value(for: option)))
            }
            applyFrameState(to: &uniforms, snapshot: snapshot, now: now)
            applyReduceMotionIfNeeded(to: &uniforms, dt: dt)

            // Standard Metal frame: record GPU work into a command buffer,
            // schedule the drawable (the screen surface) for presentation,
            // and commit. `commit` is asynchronous — the CPU moves on while
            // the GPU renders.
            guard let commandBuffer = context.queue.makeCommandBuffer() else { return }
            let timer = gpuTimer
            commandBuffer.addCompletedHandler { @Sendable buffer in
                timer.record(buffer.gpuEndTime - buffer.gpuStartTime)
            }
            visualizer.draw(
                in: view, commandBuffer: commandBuffer,
                uniforms: uniforms, snapshot: snapshot)
            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
            commandBuffer.commit()
        }

        /// Match the display — including 120 Hz ProMotion panels — while audio
        /// is actually playing, and back off hard when it isn't. An idle or
        /// backgrounded window has nothing to say at 120 fps.
        private func updateFrameRate(_ view: MTKView) {
            let displayMax = view.window?.screen?.maximumFramesPerSecond ?? 60
            let wanted: Int
            if !NSApp.isActive {
                wanted = min(30, displayMax)
            } else if !appState.isCaptureActive {
                wanted = min(30, displayMax)
            } else {
                wanted = displayMax
            }
            if view.preferredFramesPerSecond != wanted {
                view.preferredFramesPerSecond = wanted
            }
        }

        /// Dynamic resolution scaling, the trick console engines use to hold
        /// frame rate: when the measured GPU time can't fit the frame budget,
        /// shrink the drawable instead of dropping frames. Every pixel of
        /// these visualizers is computed from scratch by heavy fragment
        /// shaders (the tunnel sphere-traces 60 steps of layered noise per
        /// pixel), so cost scales directly with area — and the soft, glowing
        /// imagery survives upscaling far better than it survives stutter.
        ///
        /// Every half second, compare the average measured GPU time against
        /// the current budget (1 / `preferredFramesPerSecond`): over 85% of
        /// budget steps one rung down the ladder; a *predicted* cost (area
        /// ratio × average) under 60% steps back up. The 85/60 gap is the
        /// hysteresis that keeps the scale from ping-ponging at a boundary.
        private func adaptResolution(_ view: MTKView) {
            let now = CACurrentMediaTime()
            guard now - lastScaleCheck >= 0.5 else { return }
            lastScaleCheck = now
            guard let average = gpuTimer.drain(minimumSamples: 10) else { return }
            let budget = 1.0 / Double(max(view.preferredFramesPerSecond, 1))
            let scales = Self.renderScales
            if average > budget * 0.85, renderScaleIndex > 0 {
                renderScaleIndex -= 1
            } else if renderScaleIndex < scales.count - 1 {
                let growth = scales[renderScaleIndex + 1] / scales[renderScaleIndex]
                if average * Double(growth * growth) < budget * 0.6 {
                    renderScaleIndex += 1
                }
            }
        }

        /// Keeps the drawable at (view bounds × backing scale × render
        /// scale). `autoResizeDrawable` is off, so nothing else writes
        /// `drawableSize`; run every frame, this also covers live resize and
        /// the window moving to a display with a different backing scale.
        /// The shaders need no cooperation — `uniforms.resolution` is derived
        /// from `drawableSize`, so aspect math stays correct automatically.
        private func updateDrawableSize(_ view: MTKView) {
            let backingScale =
                view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let scale = backingScale * Self.renderScales[renderScaleIndex]
            let target = CGSize(
                width: (view.bounds.width * scale).rounded(),
                height: (view.bounds.height * scale).rounded())
            guard target.width >= 1, target.height >= 1 else { return }
            if view.drawableSize != target {
                view.drawableSize = target
            }
        }

        /// Fills in the fields no visualizer should have to derive itself: the
        /// rising edges of the two transient envelopes, the beat and frame
        /// counters, the Reduce Motion flag, and the entrance ramp.
        ///
        /// The hits are the interesting ones. `beat` and `trebleBeat` decay
        /// smoothly, so a shader or a kernel sees only "loud-ish", never "a
        /// kick landed on *this* frame" — and an impulse (a comet fling, a
        /// shockwave launch) has to happen on exactly one frame or it either
        /// misfires or applies forever. Detecting the jump needs the previous
        /// frame's value, which the host has and the GPU does not.
        private func applyFrameState(
            to uniforms: inout VizUniforms,
            snapshot: AudioSnapshot,
            now: CFTimeInterval
        ) {
            // Thresholds, not `>`: the envelopes wobble slightly while
            // decaying, and a bare comparison would fire on the wobble.
            let beatHit = snapshot.beat > previousBeat + 0.25
            let trebleHit = snapshot.trebleBeat > previousTrebleBeat + 0.30
            previousBeat = snapshot.beat
            previousTrebleBeat = snapshot.trebleBeat
            if beatHit { beatCount += 1 }
            // Wrapped well inside the range where a Float still counts whole
            // numbers exactly (2^24), so a long session can't start skipping.
            if beatCount >= 1_048_576 { beatCount = 0 }
            frameCount += 1
            if frameCount >= 1_048_576 { frameCount = 0 }

            uniforms.beatHit = beatHit ? 1 : 0
            uniforms.trebleHit = trebleHit ? 1 : 0
            uniforms.beatCount = beatCount
            uniforms.frame = frameCount
            uniforms.reduceMotion = reduceMotion ? 1 : 0
            uniforms.intro = Float(
                min(max((now - visualizerBuiltAt) / Self.introDuration, 0), 1))
        }

        /// Honors the system Reduce Motion setting. A beat-reactive visualizer
        /// that flashes on every transient carries a genuine photosensitivity
        /// risk, so when Reduce Motion is on we damp the transient features
        /// (which drive the flashing), slow the animation clock, and smooth the
        /// sustained ones so brightness drifts rather than strobes.
        ///
        /// Damping the *inputs* covers most of it, and it needs no cooperation
        /// from any shader. Some effects can only be toned down structurally,
        /// though — a particle sim's turbulence has no audio feature to damp —
        /// so `uniforms.reduceMotion` also tells them outright (see
        /// `applyFrameState`, and `calm` in `nebulaStep`).
        private func applyReduceMotionIfNeeded(to uniforms: inout VizUniforms, dt: Float) {
            guard reduceMotion else { return }
            uniforms.speed *= 0.5
            uniforms.sensitivity *= 0.75
            // Transients are the flash source; keep a hint of them, no punch.
            uniforms.beat *= 0.25
            uniforms.trebleBeat *= 0.25
            uniforms.flux *= 0.25

            // One-pole smoothing with a ~0.4 s time constant, frame-rate
            // independent so it behaves the same at 60 and 120 fps.
            let alpha = 1 - exp(-dt / 0.4)
            let target = SIMD4(uniforms.bass, uniforms.mid, uniforms.treble, uniforms.level)
            smoothed += (target - smoothed) * alpha
            uniforms.bass = smoothed.x
            uniforms.mid = smoothed.y
            uniforms.treble = smoothed.z
            uniforms.level = smoothed.w
        }
    }
}

/// Lock-guarded accumulator for measured GPU frame times. `record` is called
/// from Metal's command-buffer completion thread, `drain`/`reset` from the
/// main-thread render loop — hence `nonisolated` (the project default would
/// otherwise pin every member to the main actor) and the hand-rolled lock,
/// the same discipline as `AudioAnalyzer`.
private nonisolated final class GPUFrameTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Double = 0
    private var count = 0

    func record(_ seconds: Double) {
        // A failed or empty command buffer reports zero timestamps; don't
        // let it drag the average toward "everything is fine".
        guard seconds > 0 else { return }
        lock.lock()
        total += seconds
        count += 1
        lock.unlock()
    }

    /// Average seconds of GPU time per frame since the last drain, then
    /// starts a fresh window; nil until `minimumSamples` frames have
    /// reported, so one adjustment window can't act on noise.
    func drain(minimumSamples: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard count >= minimumSamples else { return nil }
        let average = total / Double(count)
        total = 0
        count = 0
        return average
    }

    func reset() {
        lock.lock()
        total = 0
        count = 0
        lock.unlock()
    }
}

/// Shown instead of the canvas when this Mac has no usable Metal device.
/// Rare on real hardware, plausible in a VM — and infinitely better than the
/// launch crash this replaces.
struct MetalUnavailableView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Metal is unavailable on this Mac")
                .font(.title3.weight(.semibold))
            Text(
                "Synesthia draws on the graphics card, and this system offers no Metal device to draw with. That usually means it is running in a virtual machine without graphics acceleration."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}
