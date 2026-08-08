import Foundation
import simd

/// Turns one `AudioSnapshot` plus one `VisualizerTuning` into the
/// `VizUniforms` a visualizer is handed, and owns the small amount of state
/// that takes: last frame's envelopes, the beat and frame counters, and the
/// Reduce Motion smoother.
///
/// It takes `time`, `dt` and `sinceBuild` as values rather than reading a
/// clock, which is what makes it deterministic — the `CACurrentMediaTime()`
/// calls stay in the coordinator, where the frame loop is. Before that split
/// this was three private methods on a `Coordinator` whose only initializer
/// wanted a live `MTLDevice` *and* the `AppState` singleton, so none of it
/// could be exercised at all: `VizUniformsTests` pinned the byte layout, and
/// nothing pinned the values.
struct FrameComposer {
    /// Last frame's transient envelopes, for the rising-edge detection below.
    /// The analyzer publishes `beat`/`trebleBeat` as envelopes that decay
    /// smoothly between hits, so "high" is not the same as "a hit just
    /// landed"; only a frame where the value *jumps* is a new hit. Every
    /// visualizer that wanted impulses used to redo this itself — and a GPU
    /// simulation kernel, which has no memory of the previous frame, could not
    /// have done it at all.
    private var previousBeat: Float = 0
    private var previousTrebleBeat: Float = 0
    private var beatCount: Float = 0
    private var frameCount: Float = 0
    /// Slow-moving copies of the level features, used only in Reduce Motion
    /// so brightness drifts instead of strobing.
    private var smoothed = SIMD4<Float>(repeating: 0)

    /// How long a freshly built visualizer takes to fade in.
    static let introDuration: Float = 0.7

    /// Called when the visualizer is rebuilt: the counters keep running (they
    /// are clocks, and a visualizer switch is not a new session), but the
    /// smoother restarts so a new visualizer doesn't inherit the old one's
    /// level and fade in from the wrong brightness.
    mutating func visualizerChanged() {
        smoothed = .zero
    }

    mutating func compose(
        snapshot: AudioSnapshot,
        tuning: VisualizerTuning,
        descriptor: VisualizerDescriptor,
        resolution: SIMD2<Float>,
        time: Float,
        dt: Float,
        sinceBuild: Float,
        reduceMotion: Bool
    ) -> VizUniforms {
        var uniforms = VizUniforms()
        uniforms.resolution = resolution
        uniforms.time = time
        uniforms.dt = dt
        uniforms.bass = snapshot.bass
        uniforms.mid = snapshot.mid
        uniforms.treble = snapshot.treble
        uniforms.level = snapshot.level
        uniforms.beat = snapshot.beat
        // `components[1]`, `[3]` and `[6]` have no uniform of their own; the
        // eight analyzer components are deliberately narrowed to the five the
        // shaders use. Changing this mapping changes every visualizer, so it
        // is written out rather than looped.
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
        applyFrameState(to: &uniforms, snapshot: snapshot, sinceBuild: sinceBuild)
        uniforms.reduceMotion = reduceMotion ? 1 : 0
        // Deliberately last: it damps `speed` and `sensitivity` *after* they
        // were set from the tuning, and the transients after `applyFrameState`
        // read them. Bars reads the damped `sensitivity` in its CPU simulation.
        applyReduceMotionIfNeeded(to: &uniforms, dt: dt, reduceMotion: reduceMotion)
        return uniforms
    }

    /// Fills in the fields no visualizer should have to derive itself: the
    /// rising edges of the two transient envelopes, the beat and frame
    /// counters, and the entrance ramp.
    ///
    /// The hits are the interesting ones. `beat` and `trebleBeat` decay
    /// smoothly, so a shader or a kernel sees only "loud-ish", never "a kick
    /// landed on *this* frame" — and an impulse (a comet fling, a shockwave
    /// launch) has to happen on exactly one frame or it either misfires or
    /// applies forever. Detecting the jump needs the previous frame's value,
    /// which the host has and the GPU does not.
    private mutating func applyFrameState(
        to uniforms: inout VizUniforms,
        snapshot: AudioSnapshot,
        sinceBuild: Float
    ) {
        // Thresholds, not `>`: the envelopes wobble slightly while decaying,
        // and a bare comparison would fire on the wobble.
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
        uniforms.intro = min(max(sinceBuild / Self.introDuration, 0), 1)
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
    /// so `uniforms.reduceMotion` also tells them outright (see `calm` in
    /// `nebulaStep`).
    private mutating func applyReduceMotionIfNeeded(
        to uniforms: inout VizUniforms,
        dt: Float,
        reduceMotion: Bool
    ) {
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
