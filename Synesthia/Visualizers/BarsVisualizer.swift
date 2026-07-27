import Metal
import MetalKit

/// The studio console: a mixing desk seen from the producer's chair, where
/// every piece of hardware is playing the track.
///
/// The meter bridge stands vertically at the back — a wall of segmented LED
/// columns reading the 64-band spectrum, with peak-hold caps, over-lamps, and
/// a printed dB scale — flanked by two lamp-lit analog VU meters (program on
/// the left, peak on the right) with a phosphor scope between them carrying
/// the waveform. In front of it the desk surface recedes in perspective:
/// one channel strip per slice of the spectrum, each with a moving fader, an
/// EQ knob with an LED collar, and a channel lamp, all lit by the colored
/// spill of the meter wall above.
///
/// Everything a real console does with a *time constant* is simulated on the
/// CPU here rather than in the shader, because those behaviors need memory
/// between frames: attack/release ballistics per column, peak-hold caps that
/// hang and then accelerate downward, fader smoothing, slow knob drift, and
/// the second-order spring that gives the VU needles their overshoot and
/// bounce. `state` is the result — one small float buffer handed to
/// `barsFragment` each frame, which does nothing but draw it.
///
/// The shader is a single fullscreen pass; the console is composed from
/// signed-distance fields, so it costs a handful of SDF evaluations per pixel
/// (each pixel only evaluates the widgets of the zone it lands in) rather
/// than the raymarch the tunnel does.
final class BarsVisualizer: Visualizer {
    static let descriptor = VisualizerDescriptor(
        id: "bars",
        name: "Bars",
        tagline: "A producer's console: LED spectrum wall, VU meters, and moving faders",
        options: [
            VisualizerOption(id: "columns", name: "Columns", range: 8...64, defaultValue: 40),
            VisualizerOption(id: "segments", name: "LED segments", range: 0...40, defaultValue: 22),
            VisualizerOption(id: "peaks", name: "Peak hold", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "glow", name: "Glow", range: 0.3...2.5, defaultValue: 1.0),
            VisualizerOption(id: "desk", name: "Desk", range: 0.0...1.0, defaultValue: 0.6),
            VisualizerOption(id: "channels", name: "Channels", range: 4...16, defaultValue: 8),
            VisualizerOption(id: "meters", name: "Meters", range: 0.0...2.0, defaultValue: 1.0),
            VisualizerOption(id: "room", name: "Room", range: 0.0...2.0, defaultValue: 1.0),
        ],
        make: { try BarsVisualizer(device: $0, library: $1, pixelFormat: $2) })

    /// Offsets into `state`, in floats. Mirrored by the `kBars…` constants in
    /// Shaders.metal — the two must stay in sync.
    private enum Slot {
        /// 64 column heights after attack/release ballistics, 0…1.
        static let heights = 0
        /// 64 peak-hold caps, 0…1.
        static let peaks = 64
        /// 16 channel-strip fader positions, 0…1.
        static let faders = 128
        /// 16 slow-drifting knob values, 0…1.
        static let knobs = 144
        /// The two VU needle positions (program, peak), 0…1.
        static let vu = 160
        /// Console lamp brightness (a smoothed kick), 0…1.
        static let lamp = 162
        static let count = 163
    }

    static let maxChannels = 16

    private let pipeline: MTLRenderPipelineState
    /// The whole per-frame simulation result; copied to the GPU as one small
    /// constant buffer (well under the 4 KB `setFragmentBytes` limit).
    private var state = [Float](repeating: 0, count: Slot.count)
    /// Remaining hang time per column before its peak cap starts to fall.
    private var holdTimers = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    /// Downward velocity of each peak cap; grows while falling, so caps drop
    /// slowly at first and then accelerate, like a real PPM's release.
    private var fallSpeed = [Float](repeating: 0, count: AudioSnapshot.bandCount)
    /// Needle angular velocities for the second-order VU ballistics.
    private var needleVelocity = SIMD2<Float>(0, 0)
    /// Last frame's column/channel counts, so changing them re-zeroes the
    /// meters instead of leaving a stale cap hanging over a new column.
    private var columnCount = 0
    private var channelCount = 0

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        pipeline = try makeRenderPipeline(
            device: device, library: library,
            vertex: "fullscreenVertex", fragment: "barsFragment",
            pixelFormat: pixelFormat)
    }

    func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        uniforms: VizUniforms,
        snapshot: AudioSnapshot
    ) {
        // Simulate before touching the drawable: `currentRenderPassDescriptor`
        // blocks until Core Animation hands one over, so the scarce drawable
        // is held only for encode-and-commit.
        update(uniforms: uniforms, snapshot: snapshot)

        guard let pass = view.currentRenderPassDescriptor,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VizUniforms>.stride, index: 0)
        // No band array at index 1: the shader reads its columns from `state`,
        // already aggregated and shaped by the ballistics above. The waveform
        // keeps index 2 so it means the same thing in every visualizer.
        snapshot.waveform.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        state.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    static func columns(_ u: VizUniforms) -> Int {
        min(max(Int(u.p0.rounded()), 8), AudioSnapshot.bandCount)
    }

    static func channels(_ u: VizUniforms) -> Int {
        min(max(Int(u.p5.rounded()), 4), maxChannels)
    }

    // MARK: - Meter simulation

    /// Advances one frame of console physics.
    ///
    /// Audio arrives already smoothed by `AudioAnalyzer`, but a meter's
    /// character *is* its ballistics, so the bands get a second, deliberately
    /// hardware-shaped envelope here: a ~12 ms attack so hits snap up instantly
    /// and a ~300 ms release so they fall back at a readable rate.
    ///
    /// Accents read from `uniforms` rather than `snapshot` wherever both
    /// carry the value, because the host damps the uniform copy when Reduce
    /// Motion is on; the per-band data has no uniform equivalent, so it is
    /// scaled by `sensitivity` (also damped) instead.
    private func update(uniforms u: VizUniforms, snapshot: AudioSnapshot) {
        let dt = min(max(u.dt, 0), 1.0 / 20)
        let cols = Self.columns(u)
        let chans = Self.channels(u)
        if cols != columnCount || chans != channelCount {
            columnCount = cols
            channelCount = chans
            resetMeters()
        }

        let sensitivity = max(u.sensitivity, 0.01)
        let attack = 1 - exp(-dt / 0.012)
        let release = 1 - exp(-dt / 0.30)
        // Peak hold slider: how long a cap hangs before it falls, and how
        // fast it accelerates once it does — caps drop slowly at first and
        // then run, like a real PPM's release. At 0 they collapse onto the
        // bars, and the shader fades them out entirely on the same slider.
        let holdAmount = min(max(u.p2, 0), 2)
        let hangTime = 0.85 * holdAmount
        let fallAcceleration = 0.55 / max(holdAmount, 0.25)

        var loudest: Float = 0
        for column in 0..<cols {
            let range = Self.bandRange(column, of: cols)
            var sum: Float = 0
            var peak: Float = 0
            for band in range {
                let value = snapshot.bands[band]
                sum += value
                peak = max(peak, value)
            }
            let mean = sum / Float(range.count)
            // Analyzer "slope": music is pink, so the top of the spectrum
            // sits well below the bottom. A gentle tilt toward the treble is
            // what hardware analyzers do to make the whole wall live.
            let tilt = 1 + 0.38 * Float(column) / Float(max(cols - 1, 1))
            let target = min(1, (0.35 * mean + 0.65 * peak) * tilt * sensitivity * 1.05)

            var height = state[Slot.heights + column]
            height += (target - height) * (target > height ? attack : release)
            state[Slot.heights + column] = height
            loudest = max(loudest, height)

            var cap = state[Slot.peaks + column]
            if height >= cap {
                cap = height
                holdTimers[column] = hangTime
                fallSpeed[column] = 0
            } else if holdTimers[column] > 0 {
                holdTimers[column] -= dt
            } else {
                fallSpeed[column] += fallAcceleration * dt
                cap = max(height, cap - fallSpeed[column] * dt)
            }
            state[Slot.peaks + column] = cap
        }

        // Channel strips: faders ride their slice of the spectrum with the
        // lag of a motorized fader, knobs drift on a multi-second average as
        // if someone were slowly riding the EQ.
        let faderAttack = 1 - exp(-dt / 0.10)
        let faderRelease = 1 - exp(-dt / 0.40)
        let knobDrift = 1 - exp(-dt / 2.2)
        for channel in 0..<chans {
            let range = Self.bandRange(channel, of: chans)
            var sum: Float = 0
            for band in range { sum += snapshot.bands[band] }
            let target = min(1, sum / Float(range.count) * sensitivity * 1.6)
            var fader = state[Slot.faders + channel]
            fader += (target - fader) * (target > fader ? faderAttack : faderRelease)
            state[Slot.faders + channel] = fader
            state[Slot.knobs + channel] += (target - state[Slot.knobs + channel]) * knobDrift
        }

        // The needles. A VU movement is a damped mass on a spring, which is
        // why it overshoots a hit and settles back — an exponential smoother
        // can't do that at any coefficient. Left reads program level at the
        // standard VU ballistic (~300 ms to full scale, so it reports average
        // loudness and ignores transients); right is a peak-reading meter,
        // 50 ms to rise and deliberately slow to return.
        integrateNeedle(0, target: min(1, u.level * sensitivity * 1.15), dt: dt, rise: 9.5, fall: 9.5)
        integrateNeedle(1, target: min(1, loudest), dt: dt, rise: 44, fall: 7)

        // The console lamp: a smoothed kick that pulses the VU backlights and
        // lifts the whole room a little.
        let lampFollow = 1 - exp(-dt / 0.11)
        let lampTarget = min(1, max(u.beat, 0.55 * u.flux) * 0.85 + 0.15 * u.level)
        state[Slot.lamp] += (lampTarget - state[Slot.lamp]) * lampFollow
    }

    /// One needle of the VU pair, integrated as a damped harmonic oscillator.
    ///
    /// `rise`/`fall` are the spring's natural frequencies while the needle is
    /// chasing upward vs. falling back; the asymmetry is what separates a VU
    /// (symmetric) from a peak meter (snap up, drift down). Damping ratio
    /// 0.68 gives about 5% overshoot — more ring than the real ±1.5% VU spec,
    /// because on a screen that small kick is what reads as a live needle.
    ///
    /// The damping term uses at least half the *rise* frequency even in the
    /// falling regime. Without that floor a needle that overshoots its target
    /// suddenly loses 40× of its restoring force and coasts on past the end
    /// of the scale; the peak meter overshot by 40% instead of 5%.
    ///
    /// Stepped at a fixed 1/240 s because an explicit integrator goes unstable
    /// once `omega * dt` approaches 1, and the peak needle's omega is 44.
    private func integrateNeedle(_ index: Int, target: Float, dt: Float, rise: Float, fall: Float) {
        let slot = Slot.vu + index
        var position = state[slot]
        var velocity = needleVelocity[index]
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let step = dt / Float(steps)
        for _ in 0..<steps {
            let omega = target > position ? rise : fall
            let damping = 2 * 0.68 * max(omega, rise * 0.5)
            velocity += (omega * omega * (target - position) - damping * velocity) * step
            position += velocity * step
        }
        state[slot] = min(max(position, 0), 1.15)
        needleVelocity[index] = velocity
    }

    /// The contiguous slice of the 64 bands that column/channel `index` of
    /// `count` displays.
    private static func bandRange(_ index: Int, of count: Int) -> Range<Int> {
        let low = index * AudioSnapshot.bandCount / count
        let high = max((index + 1) * AudioSnapshot.bandCount / count, low + 1)
        return low..<min(high, AudioSnapshot.bandCount)
    }

    /// Zeroes the meters so a changed column count can't leave a peak cap
    /// hanging over a column that now shows a different part of the spectrum.
    private func resetMeters() {
        for i in 0..<AudioSnapshot.bandCount {
            state[Slot.heights + i] = 0
            state[Slot.peaks + i] = 0
            holdTimers[i] = 0
            fallSpeed[i] = 0
        }
    }
}
