import Foundation
import Accelerate
import AVFoundation

/// One frame of analyzed audio, safe to hand to the render thread.
struct AudioSnapshot: Sendable {
    static let bandCount = 64
    static let waveformCount = 256
    static let componentCount = 8

    /// Log-spaced frequency bands, smoothed, roughly 0...1.
    var bands = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    /// Recent time-domain samples, -1...1.
    var waveform = [Float](repeating: 0, count: AudioSnapshot.waveformCount)
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// Eight named sub-band energies, 0...1 each:
    /// sub-bass, bass, low-mid, mid, high-mid, presence, treble, air.
    var components = [Float](repeating: 0, count: AudioSnapshot.componentCount)
    /// Beat envelope: jumps to 1 on a detected bass transient, decays.
    var beat: Float = 0
    /// Treble transient envelope (hi-hats, snares' snap); decays faster than `beat`.
    var trebleBeat: Float = 0
    /// Spectral flux: how much new energy arrived this frame, 0...1. Spikes on onsets.
    var flux: Float = 0
    /// Spectral centroid mapped to 0...1 (dark/bassy → bright/airy).
    var centroid: Float = 0
}

/// Streams mono samples in from any audio thread, runs a windowed FFT, and
/// exposes the latest `AudioSnapshot` under a lock.
nonisolated final class AudioAnalyzer: @unchecked Sendable {
    static let shared = AudioAnalyzer()

    private let lock = NSLock()
    private var snapshot = AudioSnapshot()

    private let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: 2048)

    private var recent = [Float](repeating: 0, count: 2048)
    private var pending = 0
    private var sampleRate: Double = 48_000

    private var real = [Float](repeating: 0, count: 1024)
    private var imag = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)
    private var bandEdges = [Int]()
    private var componentRanges = [Range<Int>]()
    private var smoothed = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    private var previousRaw = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    private var beatAverage: Float = 0
    private var beatEnvelope: Float = 0
    private var trebleAverage: Float = 0
    private var trebleEnvelope: Float = 0
    private var fluxEnvelope: Float = 0
    private var centroidSmoothed: Float = 0.4
    private var lastAppendTime: CFAbsoluteTime = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        rebuildBandEdges()
    }

    func latest() -> AudioSnapshot {
        lock.lock()
        defer { lock.unlock() }
        // Decay toward silence if the source stopped feeding us.
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
    func appendMono(from buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            append(channels[0], count: n, sampleRate: buffer.format.sampleRate)
        } else {
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

    func append(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        lastAppendTime = CFAbsoluteTimeGetCurrent()
        if sampleRate != self.sampleRate, sampleRate > 0 {
            self.sampleRate = sampleRate
            rebuildBandEdges()
        }
        if count >= fftSize {
            recent = Array(UnsafeBufferPointer(start: samples + (count - fftSize), count: fftSize))
        } else {
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

    private func rebuildBandEdges() {
        let binCount = fftSize / 2
        let hz = { (bin: Int) in Double(bin) * self.sampleRate / Double(self.fftSize) }
        let fMin = 30.0, fMax = min(16_000.0, sampleRate * 0.45)
        var edges = [Int]()
        for b in 0...AudioSnapshot.bandCount {
            let f = fMin * pow(fMax / fMin, Double(b) / Double(AudioSnapshot.bandCount))
            var bin = 0
            while bin < binCount - 1, hz(bin) < f { bin += 1 }
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

    private func processLocked() {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(recent, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

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

        let norm = 1.0 / Float(fftSize)
        var raw = [Float](repeating: 0, count: AudioSnapshot.bandCount)
        for b in 0..<AudioSnapshot.bandCount {
            let lo = bandEdges[b], hi = max(bandEdges[b + 1], lo + 1)
            var sum: Float = 0
            for bin in lo..<hi { sum += magnitudes[bin] }
            let mag = sqrt(sum / Float(hi - lo)) * norm
            let db = 20 * log10(max(mag, 1e-9))
            raw[b] = max(0, min(1, (db + 72) / 66))
        }
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

        // Spectral flux: positive per-band energy change, spikes on any onset.
        var fluxNow: Float = 0
        for b in 0..<AudioSnapshot.bandCount {
            fluxNow += max(0, raw[b] - previousRaw[b])
        }
        previousRaw = raw
        fluxEnvelope = max(min(fluxNow * 0.9, 1), fluxEnvelope * 0.86)

        // Spectral centroid: where the energy lives, 0 (dark) ... 1 (bright).
        var weighted: Float = 0, total: Float = 0
        for b in 0..<AudioSnapshot.bandCount {
            weighted += raw[b] * Float(b)
            total += raw[b]
        }
        if total > 0.02 {
            let instantCentroid = weighted / (total * Float(AudioSnapshot.bandCount - 1))
            centroidSmoothed = centroidSmoothed * 0.9 + instantCentroid * 0.1
        }

        // Treble-transient envelope (hi-hats/snare snap) against its own running average.
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

        var rms: Float = 0
        vDSP_rmsqv(recent, 1, &rms, vDSP_Length(fftSize))
        let levelDB = 20 * log10(max(rms, 1e-9))
        let level = max(0, min(1, (levelDB + 60) / 60))

        // Bass-transient beat detection against a running average.
        let instant = raw[0..<10].reduce(0, +) / 10
        beatAverage = beatAverage * 0.975 + instant * 0.025
        if instant > beatAverage * 1.3, instant > 0.15 {
            beatEnvelope = 1
        } else {
            beatEnvelope *= 0.9
        }

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
