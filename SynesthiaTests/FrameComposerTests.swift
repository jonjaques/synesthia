import Foundation
import Testing
import simd

@testable import Synesthia

/// Tests for the per-frame state every visualizer is handed.
///
/// `VizUniformsTests` pins the byte *layout*; this pins the *values*. Nothing
/// did before, because all of it lived in private methods on a `Coordinator`
/// whose only initializer wanted a live `MTLDevice` and the `AppState`
/// singleton — which builds four audio engines and starts notification
/// observers. Taking the clock as an argument is what made it reachable.
@MainActor
struct FrameComposerTests {

    private let descriptor = BarsVisualizer.descriptor

    private func compose(
        _ composer: inout FrameComposer,
        beat: Float = 0,
        trebleBeat: Float = 0,
        level: Float = 0,
        dt: Float = 1.0 / 60,
        sinceBuild: Float = 10,
        speed: Double = 1.0,
        reduceMotion: Bool = false,
        tuning: VisualizerTuning? = nil
    ) -> VizUniforms {
        var snapshot = AudioSnapshot()
        snapshot.beat = beat
        snapshot.trebleBeat = trebleBeat
        snapshot.level = level
        snapshot.bass = level
        snapshot.mid = level
        snapshot.treble = level
        var settings = tuning ?? VisualizerTuning()
        if tuning == nil { settings.speed = speed }
        return composer.compose(
            snapshot: snapshot,
            tuning: settings,
            descriptor: descriptor,
            resolution: SIMD2(1920, 1200),
            time: 1,
            dt: dt,
            sinceBuild: sinceBuild,
            reduceMotion: reduceMotion)
    }

    // MARK: - Hits

    /// The whole reason the host derives hits: the envelope decays smoothly,
    /// so a shader sees "loud-ish" for thirty frames after one kick. An
    /// impulse has to land on exactly one of them.
    @Test func aSustainedEnvelopeFiresExactlyOneBeatHit() {
        var composer = FrameComposer()
        var hits = 0
        let envelope = [Float(0)] + stride(from: Float(0.9), to: 0.3, by: -0.02).map { $0 }
        for value in envelope where compose(&composer, beat: value).beatHit == 1 {
            hits += 1
        }
        #expect(hits == 1)
    }

    /// The envelopes wobble while decaying; the +0.25 threshold exists for
    /// exactly this, and a bare `>` would fire on the wobble.
    @Test func wobbleBelowTheThresholdDoesNotFire() {
        var composer = FrameComposer()
        _ = compose(&composer, beat: 0.5)
        #expect(compose(&composer, beat: 0.6).beatHit == 0)
        #expect(compose(&composer, beat: 0.9).beatHit == 1)
    }

    /// Treble has its own, higher bar than bass — 0.30 against 0.25 — so a
    /// jump can be a kick without being a hi-hat.
    @Test func trebleHasItsOwnHigherThreshold() {
        var composer = FrameComposer()
        let both = compose(&composer, beat: 0.28, trebleBeat: 0.28)
        #expect(both.beatHit == 1)
        #expect(both.trebleHit == 0)

        var other = FrameComposer()
        #expect(compose(&other, trebleBeat: 0.31).trebleHit == 1)
    }

    // MARK: - Counters

    /// Both counters wrap well inside 2^24, where a Float still counts whole
    /// numbers exactly — past that a long session would start skipping values
    /// and anything stepping per beat would stutter.
    @Test func beatCountWrapsInsideExactFloatIntegers() {
        var composer = FrameComposer()
        var last: Float = 0
        // A rising envelope is one hit per frame — the previous value is
        // whatever the last frame reported, so any step over the threshold
        // keeps clearing it. No real envelope climbs forever; this is the
        // cheapest way to drive the counter a million times, and whole
        // integers keep the comparison exact the whole way up.
        for i in 1...1_048_576 {
            last = compose(&composer, beat: Float(i)).beatCount
        }
        #expect(last == 0)
        #expect(compose(&composer, beat: 1_048_578).beatCount == 1)
    }

    @Test func theFrameCounterAdvancesEveryFrame() {
        var composer = FrameComposer()
        #expect(compose(&composer).frame == 1)
        #expect(compose(&composer).frame == 2)
    }

    // MARK: - Intro ramp

    @Test func introRampsZeroToOneAcrossTheBuildWindow() {
        var composer = FrameComposer()
        #expect(compose(&composer, sinceBuild: 0).intro == 0)
        #expect(
            abs(compose(&composer, sinceBuild: FrameComposer.introDuration / 2).intro - 0.5) < 0.001)
        #expect(compose(&composer, sinceBuild: FrameComposer.introDuration).intro == 1)
        // Clamped: a visualizer that has been up for an hour is not at 5000.
        #expect(compose(&composer, sinceBuild: 3600).intro == 1)
    }

    // MARK: - Reduce Motion

    /// Damping the inputs is what makes Reduce Motion work without any
    /// cooperation from a shader, and the transients are the flash source, so
    /// they are damped hardest.
    @Test func reduceMotionDampsTheTransientsAndHalvesSpeed() {
        var plainComposer = FrameComposer()
        var calmComposer = FrameComposer()
        let plain = compose(&plainComposer, beat: 0.8, speed: 1.0)
        let calm = compose(&calmComposer, beat: 0.8, speed: 1.0, reduceMotion: true)

        #expect(calm.speed == plain.speed * 0.5)
        #expect(calm.sensitivity == plain.sensitivity * 0.75)
        #expect(calm.beat == plain.beat * 0.25)
        #expect(calm.reduceMotion == 1)
        #expect(plain.reduceMotion == 0)
    }

    /// One-pole smoothing over the same wall time must land in the same place
    /// at 60 and 120 fps — the reason it is written as `1 - exp(-dt / 0.4)`
    /// rather than a fixed per-frame fraction.
    @Test func reduceMotionSmoothingIsFrameRateIndependent() {
        var slow = FrameComposer()
        var fast = FrameComposer()
        var slowLevel: Float = 0
        var fastLevel: Float = 0
        for _ in 0..<60 {
            slowLevel = compose(&slow, level: 1, dt: 1.0 / 60, reduceMotion: true).level
        }
        for _ in 0..<120 {
            fastLevel = compose(&fast, level: 1, dt: 1.0 / 120, reduceMotion: true).level
        }
        #expect(abs(slowLevel - fastLevel) < 0.01)
        // …and it is actually smoothing, not passing the level through.
        #expect(slowLevel < 0.95)
    }

    /// A new visualizer starts its smoother from zero rather than inheriting
    /// the level the previous one had drifted to. Behaviour this PR *adds* —
    /// everything else about a visualizer switch (the render-scale ladder, the
    /// GPU timer, the intro ramp) already resets.
    @Test func aVisualizerSwitchRestartsTheReduceMotionSmoother() {
        var composer = FrameComposer()
        for _ in 0..<120 { _ = compose(&composer, level: 1, reduceMotion: true) }
        let settled = compose(&composer, level: 1, reduceMotion: true).level
        #expect(settled > 0.5)

        composer.visualizerChanged()
        #expect(compose(&composer, level: 1, reduceMotion: true).level < settled / 2)
    }

    // MARK: - Options

    /// Guards the descriptor → `p[]` mapping that `VizUniformsTests` can only
    /// pin structurally: the option's *declared* slot is what the value lands
    /// in, not its position in the popover.
    @Test func optionValuesReachTheSlotsTheyDeclare() {
        var composer = FrameComposer()
        var tuning = VisualizerTuning()
        for (index, option) in descriptor.options.enumerated() {
            tuning.options[option.id] = Double(index) + 1
        }
        let uniforms = compose(&composer, tuning: tuning)
        for (index, option) in descriptor.options.enumerated() {
            #expect(uniforms[parameter: option.slot] == Float(index) + 1, "\(option.id)")
        }
    }

    /// An option the user hasn't touched arrives at its default, not zero.
    @Test func untouchedOptionsArriveAtTheirDefaults() {
        var composer = FrameComposer()
        let uniforms = compose(&composer, tuning: VisualizerTuning())
        for option in descriptor.options {
            #expect(uniforms[parameter: option.slot] == Float(option.defaultValue), "\(option.id)")
        }
    }
}
