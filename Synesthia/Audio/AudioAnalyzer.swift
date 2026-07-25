import Foundation
import Accelerate
import AVFoundation

/// One frame of analyzed audio, safe to hand to the render thread.
///
/// This is a plain value type on purpose: the render loop takes a *copy* once
/// per frame via `AudioAnalyzer.latest()`, so it can read every field for the
/// rest of the frame with no locking and no chance of the audio thread
/// mutating it mid-read.
///
/// All values are pre-normalized to roughly 0...1 (waveform: -1...1) so
/// visualizers can use them directly as intensities without knowing anything
/// about decibels or FFT bin math.
struct AudioSnapshot: Sendable {
    static let bandCount = 64
    static let waveformCount = 256
    static let componentCount = 8

    /// The frequency spectrum, reduced to 64 bands covering ~30 Hz–16 kHz.
    /// Bands are *log-spaced* (each octave spans the same number of bands)
    /// because that matches how pitch is perceived — linear FFT bins would
    /// cram all the musically interesting low end into the first few entries.
    /// Values are smoothed and normalized to roughly 0...1.
    var bands = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    /// Recent time-domain samples, -1...1 — the raw wiggle of the speaker
    /// cone, downsampled to 256 points. Good for drawing oscilloscope-style
    /// shapes; useless for "how loud is the bass" questions (use `bands`).
    var waveform = [Float](repeating: 0, count: AudioSnapshot.waveformCount)
    /// Overall loudness (RMS mapped through dB), 0...1.
    var level: Float = 0
    /// Average energy of the low / middle / high thirds of the spectrum.
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// Eight named sub-band energies, 0...1 each:
    /// sub-bass, bass, low-mid, mid, high-mid, presence, treble, air.
    /// A finer-grained alternative to bass/mid/treble when a visualizer wants,
    /// say, hi-hats ("air") separately from vocals ("presence").
    var components = [Float](repeating: 0, count: AudioSnapshot.componentCount)
    /// Beat envelope: jumps to 1 on a detected bass transient (a kick drum
    /// hit), then decays exponentially. Multiply things by this for "pulse on
    /// the beat" effects — the decay gives a natural-looking falloff for free.
    var beat: Float = 0
    /// Treble transient envelope (hi-hats, snares' snap); same idea as `beat`
    /// but triggered from the top of the spectrum and decaying faster.
    var trebleBeat: Float = 0
    /// Spectral flux: how much *new* energy arrived this frame, 0...1.
    /// Spikes on any onset (a note starting, a chord change), not just bass
    /// hits, so it catches events `beat` misses.
    var flux: Float = 0
    /// Spectral centroid mapped to 0...1: the "center of mass" of the
    /// spectrum. Low = dark/bassy sound, high = bright/airy. Useful for
    /// steering color temperature.
    var centroid: Float = 0
}

/// Streams mono samples in from any audio thread, runs a windowed FFT, and
/// exposes the latest `AudioSnapshot` under a lock.
///
/// ### The pipeline
/// 1. Capture code (any thread) calls `appendMono(from:)` with raw PCM
///    buffers as they arrive.
/// 2. The analyzer keeps a sliding window of the most recent 2048 samples
///    (~43 ms at 48 kHz). Every 1024 new samples (the "hop") it runs one
///    analysis pass: Hann window → FFT → 64 log-spaced bands → smoothing →
///    derived features (beat, flux, centroid, …).
/// 3. The render loop (display thread, 60 fps) calls `latest()` each frame
///    and gets a value-type copy of the newest snapshot.
///
/// ### Threading model
/// This class is deliberately *not* on the main actor (`nonisolated`) and is
/// shared between the capture threads and the render thread. One `NSLock`
/// guards all mutable state; both `append` and `latest()` hold it briefly.
/// Audio never publishes into SwiftUI — the render loop *pulls*, which keeps
/// per-buffer work tiny and allocation-free on the audio thread.
///
/// `@unchecked Sendable` because the compiler can't verify hand-rolled lock
/// discipline; the invariant is that every access to mutable state happens
/// with `lock` held.
nonisolated final class AudioAnalyzer: @unchecked Sendable {
    static let shared = AudioAnalyzer()

    private let lock = NSLock()
    private var snapshot = AudioSnapshot()

    /// FFT input length. 2048 samples ≈ 43 ms at 48 kHz — long enough to
    /// resolve bass frequencies (bin spacing = sampleRate / fftSize ≈ 23 Hz),
    /// short enough to feel instantaneous. Must be a power of two.
    private let fftSize = 2048
    /// log2(fftSize); vDSP's radix-2 FFT wants the exponent, not the size.
    private let log2n = vDSP_Length(11)
    private let fftSetup: FFTSetup
    /// Hann window: a raised-cosine fade applied to the input so the chunk's
    /// hard edges don't smear energy across the whole spectrum ("spectral
    /// leakage"). Without it, a pure sine tone shows up in every band.
    private var window = [Float](repeating: 0, count: 2048)

    /// Sliding window of the most recent `fftSize` mono samples.
    private var recent = [Float](repeating: 0, count: 2048)
    /// Samples received since the last analysis pass; an analysis runs every
    /// 1024 (so consecutive FFTs overlap by 50%, a standard trade-off between
    /// update rate and cost — ~47 analyses/sec at 48 kHz).
    private var pending = 0
    private var sampleRate: Double = 48_000

    // Scratch buffers for vDSP's split-complex FFT (real and imaginary parts
    // live in separate arrays), reused across passes to avoid allocation.
    private var real = [Float](repeating: 0, count: 1024)
    private var imag = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)
    /// Scratch for the Hann-windowed FFT input, reused every pass.
    private var windowed = [Float](repeating: 0, count: 2048)
    /// This pass's unsmoothed band values. Swapped with `previousRaw` at the
    /// end of each pass (instead of copied) so neither ever reallocates.
    private var raw = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    /// 65 FFT-bin indices delimiting the 64 log-spaced bands.
    private var bandEdges = [Int]()
    /// Which band indices make up each of the 8 named `components`.
    private var componentRanges = [Range<Int>]()
    /// Per-band values after asymmetric attack/release smoothing (see
    /// `processLocked`); this is what ships in `snapshot.bands`.
    private var smoothed = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    /// Previous pass's *unsmoothed* bands, kept for the spectral-flux delta.
    private var previousRaw = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    // Running averages and decaying envelopes for the transient detectors.
    private var beatAverage: Float = 0
    private var beatEnvelope: Float = 0
    private var trebleAverage: Float = 0
    private var trebleEnvelope: Float = 0
    private var fluxEnvelope: Float = 0
    private var centroidSmoothed: Float = 0.4
    /// When samples last arrived; lets `latest()` fade the visuals out
    /// instead of freezing when the source stops.
    private var lastAppendTime: CFAbsoluteTime = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        rebuildBandEdges()
    }

    /// Returns a copy of the newest snapshot. Called once per rendered frame.
    func latest() -> AudioSnapshot {
        lock.lock()
        defer { lock.unlock() }
        // Decay toward silence if the source stopped feeding us: without this
        // the last frame of audio would freeze on screen when capture stops.
        // Repeated multiplication by <1 each frame gives an exponential fade.
        if CFAbsoluteTimeGetCurrent() - lastAppendTime > 0.25 {
            for i in smoothed.indices { smoothed[i] *= 0.92 }
            beatEnvelope *= 0.9
            trebleEnvelope *= 0.85
            fluxEnvelope *= 0.85
            snapshot.bands = smoothed
            snapshot.beat = beatEnvelope
            snapshot.trebleBeat = trebleEnvelope
            snapshot.flux = fluxEnvelope
            snapshot.level *= 0.92
            snapshot.bass *= 0.92
            snapshot.mid *= 0.92
            snapshot.treble *= 0.92
            for i in snapshot.components.indices { snapshot.components[i] *= 0.92 }
            for i in snapshot.waveform.indices { snapshot.waveform[i] *= 0.9 }
        }
        return snapshot
    }

    /// Clears all analysis state; called when the user switches audio sources
    /// so the old source's tail doesn't bleed into the new one.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        snapshot = AudioSnapshot()
        smoothed = [Float](repeating: 0, count: AudioSnapshot.bandCount)
        previousRaw = [Float](repeating: 0, count: AudioSnapshot.bandCount)
        recent = [Float](repeating: 0, count: fftSize)
        beatAverage = 0
        beatEnvelope = 0
        trebleAverage = 0
        trebleEnvelope = 0
        fluxEnvelope = 0
        centroidSmoothed = 0.4
    }

    /// Mixes an arbitrary PCM buffer down to mono and appends it. Callable from any thread.
    ///
    /// Analysis only cares about spectral content, not stereo placement, so
    /// channels are averaged into one signal before the FFT.
    func appendMono(from buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            append(channels[0], count: n, sampleRate: buffer.format.sampleRate)
        } else {
            // Sum all channels then scale by 1/channelCount, using vDSP
            // (Accelerate's SIMD vector math) to stay cheap on the audio thread.
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<channelCount {
                vDSP_vadd(mono, 1, channels[c], 1, &mono, 1, vDSP_Length(n))
            }
            var scale = 1.0 / Float(channelCount)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
            mono.withUnsafeBufferPointer {
                append($0.baseAddress!, count: n, sampleRate: buffer.format.sampleRate)
            }
        }
    }

    /// Appends mono samples to the sliding window and, once enough have
    /// accumulated (one hop of 1024), runs an analysis pass while still
    /// holding the lock.
    func append(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        lastAppendTime = CFAbsoluteTimeGetCurrent()
        // Band edges depend on the sample rate (bin N means a different
        // frequency at 44.1 kHz than at 48 kHz), so rebuild them if it changes.
        if sampleRate != self.sampleRate, sampleRate > 0 {
            self.sampleRate = sampleRate
            rebuildBandEdges()
        }
        if count >= fftSize {
            // More new audio than the window holds: keep only the tail.
            recent = Array(UnsafeBufferPointer(start: samples + (count - fftSize), count: fftSize))
        } else {
            // Slide the window: drop the oldest `count`, append the new ones.
            recent.removeFirst(count)
            recent.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
        pending += count
        if pending >= 1024 {
            pending = 0
            processLocked()
        }
    }

    // MARK: - Analysis (call with lock held)

    /// Precomputes which FFT bins belong to which band.
    ///
    /// The FFT produces linearly spaced bins (bin i = i × sampleRate/fftSize
    /// Hz), but hearing is logarithmic — the octave 60→120 Hz matters as much
    /// as 8k→16k Hz. So the 64 band edges are placed geometrically between
    /// 30 Hz and 16 kHz: each band spans the same *ratio* of frequencies.
    /// `fMax` is capped just under the Nyquist limit (half the sample rate),
    /// above which the FFT contains no information.
    private func rebuildBandEdges() {
        let binCount = fftSize / 2
        let hz = { (bin: Int) in Double(bin) * self.sampleRate / Double(self.fftSize) }
        let fMin = 30.0, fMax = min(16_000.0, sampleRate * 0.45)
        var edges = [Int]()
        for b in 0...AudioSnapshot.bandCount {
            // Geometric interpolation from fMin to fMax.
            let f = fMin * pow(fMax / fMin, Double(b) / Double(AudioSnapshot.bandCount))
            var bin = 0
            while bin < binCount - 1, hz(bin) < f { bin += 1 }
            // At the low end several bands can want the same bin (bins are
            // ~23 Hz apart); force each band to own at least one distinct bin.
            if let last = edges.last { bin = max(bin, last + 1) }
            edges.append(min(bin, binCount - 1))
        }
        bandEdges = edges

        // Map the eight named components onto the log-spaced band axis.
        let componentEdgesHz: [Double] = [30, 60, 150, 400, 1200, 3000, 6000, 10_000, 16_000]
        let bandIndex = { (f: Double) -> Int in
            let t = log(max(f, fMin) / fMin) / log(fMax / fMin)
            return max(0, min(AudioSnapshot.bandCount - 1, Int(t * Double(AudioSnapshot.bandCount))))
        }
        componentRanges = (0..<AudioSnapshot.componentCount).map { c in
            let lo = bandIndex(componentEdgesHz[c])
            let hi = max(bandIndex(componentEdgesHz[c + 1]), lo + 1)
            return lo..<hi
        }
    }

    /// One full analysis pass over the current 2048-sample window.
    private func processLocked() {
        // 1. Window: multiply the samples by the Hann curve so the chunk
        //    fades in/out instead of starting and stopping abruptly.
        vDSP_vmul(recent, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // 2. FFT. vDSP's real-input FFT wants the 2048 real samples packed as
        //    1024 complex numbers (even-indexed samples → real parts,
        //    odd-indexed → imaginary): that's what vDSP_ctoz does. zrip then
        //    transforms in place, and zvmags yields squared magnitudes per
        //    bin — "how much of this frequency is present", phase discarded.
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // 3. Reduce 1024 bins to 64 bands, then map through decibels.
        //    Loudness perception is logarithmic, so raw magnitudes would make
        //    everything but the loudest peak invisible; converting to dB and
        //    normalizing -72 dB → 0, -6 dB → 1 spreads the useful range out.
        let norm = 1.0 / Float(fftSize)
        for b in 0..<AudioSnapshot.bandCount {
            let lo = bandEdges[b], hi = max(bandEdges[b + 1], lo + 1)
            var sum: Float = 0
            for bin in lo..<hi { sum += magnitudes[bin] }
            let mag = sqrt(sum / Float(hi - lo)) * norm
            let db = 20 * log10(max(mag, 1e-9))
            raw[b] = max(0, min(1, (db + 72) / 66))
        }
        // 4. Asymmetric smoothing (an "attack/release" envelope, borrowed
        //    from audio compressors): rise fast when a band jumps (65% of the
        //    way per pass) but fall slowly (12%). Fast attack keeps hits
        //    punchy; slow release stops the visuals flickering.
        for b in 0..<AudioSnapshot.bandCount {
            let v = raw[b]
            smoothed[b] = v > smoothed[b] ? smoothed[b] * 0.35 + v * 0.65
                                          : smoothed[b] * 0.88 + v * 0.12
        }

        func average(_ range: Range<Int>) -> Float {
            var s: Float = 0
            for i in range { s += smoothed[i] }
            return s / Float(range.count)
        }
        let bass = average(0..<10)
        let mid = average(20..<42)
        let treble = average(46..<AudioSnapshot.bandCount)

        var components = [Float](repeating: 0, count: AudioSnapshot.componentCount)
        for (c, range) in componentRanges.enumerated() {
            components[c] = average(range)
        }

        // Spectral flux: sum of per-band energy *increases* since the last
        // pass (decreases don't count). Any onset — new note, chord change,
        // drum hit — shows up as a spike; steady tones contribute nothing.
        var fluxNow: Float = 0
        for b in 0..<AudioSnapshot.bandCount {
            fluxNow += max(0, raw[b] - previousRaw[b])
        }
        fluxEnvelope = max(min(fluxNow * 0.9, 1), fluxEnvelope * 0.86)

        // Spectral centroid: energy-weighted mean band index, i.e. where the
        // energy lives — 0 (dark) ... 1 (bright). Only updated when there's
        // enough total energy for the ratio to mean anything.
        var weighted: Float = 0, total: Float = 0
        for b in 0..<AudioSnapshot.bandCount {
            weighted += raw[b] * Float(b)
            total += raw[b]
        }
        if total > 0.02 {
            let instantCentroid = weighted / (total * Float(AudioSnapshot.bandCount - 1))
            centroidSmoothed = centroidSmoothed * 0.9 + instantCentroid * 0.1
        }

        // Treble-transient envelope (hi-hats/snare snap): same scheme as the
        // bass beat detector below, but over the top of the spectrum and with
        // a faster decay, since treble events are shorter.
        let trebleRange = componentRanges[6].lowerBound..<AudioSnapshot.bandCount
        var trebleInstant: Float = 0
        for b in trebleRange { trebleInstant += raw[b] }
        trebleInstant /= Float(trebleRange.count)
        trebleAverage = trebleAverage * 0.96 + trebleInstant * 0.04
        if trebleInstant > trebleAverage * 1.35, trebleInstant > 0.10 {
            trebleEnvelope = 1
        } else {
            trebleEnvelope *= 0.80
        }

        // Overall loudness: RMS (root-mean-square, the standard "average
        // level" measure) mapped through dB into 0...1, like the bands.
        var rms: Float = 0
        vDSP_rmsqv(recent, 1, &rms, vDSP_Length(fftSize))
        let levelDB = 20 * log10(max(rms, 1e-9))
        let level = max(0, min(1, (levelDB + 60) / 60))

        // Beat detection: compare the instantaneous bass energy to its own
        // slow-moving average; a value 30% above average (and above an
        // absolute floor, so silence can't trigger) means a bass transient —
        // in practice, the kick drum. The envelope latches to 1 and decays.
        let instant = raw[0..<10].reduce(0, +) / 10
        beatAverage = beatAverage * 0.975 + instant * 0.025
        if instant > beatAverage * 1.3, instant > 0.15 {
            beatEnvelope = 1
        } else {
            beatEnvelope *= 0.9
        }

        // Keep this pass's raw bands for the next flux computation. A swap,
        // not an assignment: assignment would share storage and force a
        // copy-on-write allocation when `raw` is refilled next pass.
        swap(&raw, &previousRaw)

        // Downsample the newest 1024 samples to 256 points for the waveform.
        var wave = [Float](repeating: 0, count: AudioSnapshot.waveformCount)
        let stride = max(1, 1024 / AudioSnapshot.waveformCount)
        let start = fftSize - AudioSnapshot.waveformCount * stride
        for i in 0..<AudioSnapshot.waveformCount {
            wave[i] = recent[start + i * stride]
        }

        snapshot.bands = smoothed
        snapshot.waveform = wave
        snapshot.level = level
        snapshot.bass = bass
        snapshot.mid = mid
        snapshot.treble = treble
        snapshot.components = components
        snapshot.beat = beatEnvelope
        snapshot.trebleBeat = trebleEnvelope
        snapshot.flux = min(fluxEnvelope, 1)
        snapshot.centroid = centroidSmoothed
    }
}
