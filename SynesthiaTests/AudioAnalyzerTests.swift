import Foundation
import Testing

@testable import Synesthia

/// Tests for the DSP pipeline: the log-spaced band mapping and the derived
/// features (bass/mid/treble split, centroid, transient detectors).
///
/// The analyzer is the one part of Synesthia with a *correct answer* — feed it
/// a 1 kHz sine and the energy belongs in a specific band, computable by hand
/// from the band-edge formula. Everything else in the app is a judgement call
/// about how things look.
///
/// Notes on making these deterministic:
///
/// - `processLocked` only runs once 1024 new samples have accumulated, so
///   every helper feeds whole 2048-sample windows.
/// - Band values are asymmetrically smoothed (65% attack per pass), so a
///   single pass lands at 65% of the true value. The helpers feed several
///   passes to let the envelope converge.
/// - Phase is carried across passes so the input is a continuous tone rather
///   than a series of discontinuities, which would smear energy everywhere.
struct AudioAnalyzerTests {

    // MARK: - Helpers

    static let sampleRate = 48_000.0
    static let windowSize = 2048

    /// Feeds `passes` windows of a continuous sine wave and returns the final
    /// snapshot.
    private func feedSine(
        frequency: Double,
        amplitude: Float = 0.5,
        passes: Int = 16,
        sampleRate: Double = sampleRate,
        into analyzer: AudioAnalyzer = AudioAnalyzer()
    ) -> AudioSnapshot {
        var phase = 0.0
        let delta = 2.0 * .pi * frequency / sampleRate
        var buffer = [Float](repeating: 0, count: Self.windowSize)
        for _ in 0..<passes {
            for i in 0..<Self.windowSize {
                buffer[i] = amplitude * Float(sin(phase))
                phase += delta
            }
            buffer.withUnsafeBufferPointer {
                analyzer.append($0.baseAddress!, count: Self.windowSize, sampleRate: sampleRate)
            }
        }
        return analyzer.latest()
    }

    private func feedSilence(
        passes: Int = 16,
        into analyzer: AudioAnalyzer
    ) -> AudioSnapshot {
        let buffer = [Float](repeating: 0, count: Self.windowSize)
        for _ in 0..<passes {
            buffer.withUnsafeBufferPointer {
                analyzer.append($0.baseAddress!, count: Self.windowSize, sampleRate: Self.sampleRate)
            }
        }
        return analyzer.latest()
    }

    /// The band a frequency should land in under *pure* geometric spacing.
    ///
    /// This only describes the real mapping above ~900 Hz. `rebuildBandEdges`
    /// additionally forces every band to own at least one distinct FFT bin,
    /// and with 23.4 Hz bins at 48 kHz that rule binds for every band below
    /// about 844 Hz — down there the bands are effectively linear, one bin
    /// apart, because a 2048-point FFT physically cannot resolve log-spaced
    /// bands that narrow. See `lowBandsAreBinLimited` for that half of the
    /// contract.
    private func expectedBand(for frequency: Double, sampleRate: Double = sampleRate) -> Int {
        let fMin = 30.0
        let fMax = min(16_000.0, sampleRate * 0.45)
        let t = log(frequency / fMin) / log(fMax / fMin)
        return Int(t * Double(AudioSnapshot.bandCount))
    }

    /// Reproducible broadband noise. Pure sines are the wrong stimulus for the
    /// transient detectors: those average energy across a ten-band range, so a
    /// single-bin tone barely moves the mean. Real hi-hats are broadband, and
    /// so is this.
    private func feedNoise(
        amplitude: Float = 0.5,
        passes: Int = 4,
        into analyzer: AudioAnalyzer
    ) -> AudioSnapshot {
        // Small LCG rather than SystemRandomNumberGenerator, so a failure is
        // always reproducible.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var buffer = [Float](repeating: 0, count: Self.windowSize)
        for _ in 0..<passes {
            for i in 0..<Self.windowSize {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(Double(state >> 33) / Double(1 << 31)) - 0.5
                buffer[i] = amplitude * unit * 2
            }
            buffer.withUnsafeBufferPointer {
                analyzer.append($0.baseAddress!, count: Self.windowSize, sampleRate: Self.sampleRate)
            }
        }
        return analyzer.latest()
    }

    private func peakBand(_ snapshot: AudioSnapshot) -> Int {
        var best = 0
        for i in snapshot.bands.indices where snapshot.bands[i] > snapshot.bands[best] {
            best = i
        }
        return best
    }

    // MARK: - Band mapping

    /// The core claim of the log-spaced mapping: above the bin-resolution
    /// floor, a pure tone peaks in the band geometric spacing predicts.
    @Test(arguments: [1_000.0, 3_000.0, 6_000.0, 12_000.0])
    func pureToneLandsInPredictedBand(frequency: Double) {
        let snapshot = feedSine(frequency: frequency)
        let expected = expectedBand(for: frequency)
        let actual = peakBand(snapshot)
        // ±2 bands: a band near 1 kHz is only ~95 Hz wide and the Hann window
        // spreads a little energy into its neighbours.
        #expect(
            abs(actual - expected) <= 2,
            "\(frequency) Hz peaked at band \(actual), expected ≈\(expected)")
    }

    /// Below ~844 Hz the geometric bands would be narrower than one FFT bin,
    /// so `rebuildBandEdges` forces each to own a distinct bin and the low end
    /// becomes linear instead. That is a deliberate trade, and it has an
    /// observable consequence worth locking in: two tones one bin apart
    /// (~23 Hz) land in *different* bands down there, where pure log spacing
    /// would have merged them.
    @Test func lowBandsAreBinLimited() {
        let low = peakBand(feedSine(frequency: 100))
        let slightlyHigher = peakBand(feedSine(frequency: 125))
        #expect(
            slightlyHigher > low,
            "100 Hz and 125 Hz should occupy different bands, both landed at \(low)")
        // …and they stay near the bottom of the spectrum, which is what the
        // bass/mid/treble split depends on.
        #expect(low < AudioSnapshot.bandCount / 4)
    }

    /// Ordering must hold across the whole range, including the seam between
    /// the bin-limited low end and the geometric region above it.
    @Test func peakBandIncreasesWithFrequency() {
        let peaks = [80.0, 200.0, 500.0, 1_000.0, 4_000.0, 10_000.0]
            .map { peakBand(feedSine(frequency: $0)) }
        for (a, b) in zip(peaks, peaks.dropFirst()) {
            #expect(a < b, "peak bands must increase with frequency, got \(peaks)")
        }
    }

    /// In the geometric region, an octave spans a constant number of bands
    /// however high it sits — measured from the analyzer, not recomputed from
    /// the formula.
    @Test func octavesSpanEqualBandCounts() {
        let low = peakBand(feedSine(frequency: 2_000)) - peakBand(feedSine(frequency: 1_000))
        let high = peakBand(feedSine(frequency: 8_000)) - peakBand(feedSine(frequency: 4_000))
        #expect(
            abs(low - high) <= 2,
            "octave 1k→2k spans \(low) bands, 4k→8k spans \(high)")
    }

    /// The mapping depends on the sample rate — bin N is a different frequency
    /// at 44.1 kHz than at 48 kHz — so the same tone must still land correctly
    /// after a rate change.
    @Test func bandMappingFollowsSampleRate() {
        let snapshot = feedSine(frequency: 1_000, sampleRate: 44_100)
        let expected = expectedBand(for: 1_000, sampleRate: 44_100)
        #expect(abs(peakBand(snapshot) - expected) <= 2)
    }

    // MARK: - Bass / mid / treble split

    @Test func lowToneRegistersAsBass() {
        let snapshot = feedSine(frequency: 60)
        #expect(snapshot.bass > snapshot.treble)
        #expect(snapshot.bass > snapshot.mid)
    }

    @Test func highToneRegistersAsTreble() {
        let snapshot = feedSine(frequency: 9_000)
        #expect(snapshot.treble > snapshot.bass)
    }

    @Test func midToneRegistersAsMid() {
        let snapshot = feedSine(frequency: 900)
        #expect(snapshot.mid > snapshot.bass)
        #expect(snapshot.mid > snapshot.treble)
    }

    // MARK: - Level

    @Test func silenceProducesNoLevel() {
        let analyzer = AudioAnalyzer()
        let snapshot = feedSilence(into: analyzer)
        #expect(snapshot.level == 0)
        #expect(snapshot.bass == 0)
    }

    @Test func louderInputProducesHigherLevel() {
        let quiet = feedSine(frequency: 440, amplitude: 0.05)
        let loud = feedSine(frequency: 440, amplitude: 0.9)
        #expect(loud.level > quiet.level)
        #expect(loud.level <= 1)
        #expect(quiet.level >= 0)
    }

    /// Every published value is documented as roughly 0...1; visualizers use
    /// them directly as intensities, so an out-of-range value is a real bug.
    @Test func featuresStayNormalized() {
        let snapshot = feedSine(frequency: 440, amplitude: 1.0)
        for (index, value) in snapshot.bands.enumerated() {
            #expect(value >= 0 && value <= 1, "band \(index) = \(value)")
        }
        for value in [
            snapshot.level, snapshot.bass, snapshot.mid, snapshot.treble,
            snapshot.beat, snapshot.trebleBeat, snapshot.flux, snapshot.centroid,
        ] {
            #expect(value >= 0 && value <= 1)
        }
        for value in snapshot.components {
            #expect(value >= 0 && value <= 1)
        }
        for value in snapshot.waveform {
            #expect(value >= -1 && value <= 1)
        }
    }

    // MARK: - Centroid

    /// Centroid is the spectrum's centre of mass: dark sounds low, bright high.
    @Test func centroidTracksBrightness() {
        let dark = feedSine(frequency: 80)
        let bright = feedSine(frequency: 10_000)
        #expect(bright.centroid > dark.centroid)
    }

    // MARK: - Transient detection

    /// A bass onset should fire the beat envelope; a treble-only tone should
    /// not. This is the property the "pulse on the beat" visuals depend on.
    @Test func beatFiresOnBassNotTreble() {
        let bass = feedSine(frequency: 60, amplitude: 0.9, passes: 4)
        let treble = feedSine(frequency: 12_000, amplitude: 0.9, passes: 4)
        #expect(
            bass.beat > treble.beat,
            "bass beat \(bass.beat) should exceed treble beat \(treble.beat)")
    }

    /// The treble detector is the mirror image, and is what hi-hats drive.
    ///
    /// It averages energy over the top ten bands, so it deliberately does
    /// *not* fire on a single high-pitched sine — that would make it a tone
    /// detector rather than a transient detector. Broadband noise, which is
    /// what a cymbal actually looks like, is the honest stimulus.
    @Test func trebleBeatFiresOnBroadbandTrebleNotBass() {
        let noise = feedNoise(amplitude: 0.7, into: AudioAnalyzer())
        let bass = feedSine(frequency: 60, amplitude: 0.9, passes: 4)
        #expect(
            noise.trebleBeat > 0,
            "broadband noise should fire the treble transient detector")
        #expect(noise.trebleBeat > bass.trebleBeat)
    }

    /// A single high sine is not a cymbal, and must not be mistaken for one.
    @Test func trebleBeatIgnoresPureHighTone() {
        let tone = feedSine(frequency: 12_000, amplitude: 0.9, passes: 4)
        #expect(tone.trebleBeat == 0)
    }

    /// Flux measures *new* energy. A tone that has been steady for many passes
    /// should settle lower than one that just started.
    @Test func fluxDecaysOnSteadyTone() {
        let analyzer = AudioAnalyzer()
        let onset = feedSine(frequency: 440, amplitude: 0.8, passes: 2, into: analyzer)
        let settled = feedSine(frequency: 440, amplitude: 0.8, passes: 40, into: analyzer)
        #expect(
            settled.flux < onset.flux,
            "flux should fall from \(onset.flux) once the tone is steady, got \(settled.flux)")
    }

    // MARK: - Lifecycle

    @Test func resetClearsAnalysisState() {
        let analyzer = AudioAnalyzer()
        let loud = feedSine(frequency: 440, amplitude: 0.9, into: analyzer)
        #expect(loud.level > 0)

        analyzer.reset()
        let cleared = analyzer.latest()
        #expect(cleared.level == 0)
        #expect(cleared.bass == 0)
        #expect(cleared.beat == 0)
        #expect(cleared.bands.allSatisfy { $0 == 0 })
    }

    /// Buffers shorter than one hop shouldn't crash or corrupt the window —
    /// real capture callbacks arrive in whatever size the device chooses.
    @Test(arguments: [1, 64, 512, 1_023, 4_096])
    func handlesArbitraryBufferSizes(count: Int) {
        let analyzer = AudioAnalyzer()
        var phase = 0.0
        let delta = 2.0 * .pi * 440.0 / Self.sampleRate
        for _ in 0..<32 {
            var buffer = [Float](repeating: 0, count: count)
            for i in 0..<count {
                buffer[i] = 0.5 * Float(sin(phase))
                phase += delta
            }
            buffer.withUnsafeBufferPointer {
                analyzer.append($0.baseAddress!, count: count, sampleRate: Self.sampleRate)
            }
        }
        let snapshot = analyzer.latest()
        #expect(snapshot.bands.count == AudioSnapshot.bandCount)
        #expect(snapshot.bands.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func emptyBufferIsIgnored() {
        let analyzer = AudioAnalyzer()
        let empty = [Float]()
        empty.withUnsafeBufferPointer {
            // A zero-length append must be a no-op, not a crash.
            analyzer.append(
                $0.baseAddress ?? UnsafePointer(bitPattern: 0x1000)!,
                count: 0, sampleRate: Self.sampleRate)
        }
        #expect(analyzer.latest().level == 0)
    }
}
