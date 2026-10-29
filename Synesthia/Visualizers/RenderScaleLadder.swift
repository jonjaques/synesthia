import Foundation
import QuartzCore

/// The adaptive-resolution decision, on its own.
///
/// Dynamic resolution scaling is the trick console engines use to hold frame
/// rate: when the measured GPU time can't fit the frame budget, shrink the
/// drawable instead of dropping frames. Every pixel of these visualizers is
/// computed from scratch by heavy fragment shaders (the tunnel sphere-traces
/// 60 steps of layered noise per pixel), so cost scales directly with area —
/// and the soft, glowing imagery survives upscaling far better than it
/// survives stutter.
///
/// Discrete rungs with hysteresis, not a continuous scale, so the size isn't
/// twitching every adjustment window: over 85% of the budget steps one rung
/// down, a *predicted* cost (area ratio × average) under 60% steps back up.
/// The 85/60 gap is what keeps the scale from ping-ponging at a boundary.
struct RenderScaleLadder {
    /// The drawable renders at this fraction of native pixels per axis, so the
    /// bottom rung costs a quarter of the top one.
    static let scales: [CGFloat] = [0.5, 0.625, 0.75, 0.875, 1.0]

    private(set) var index = Self.scales.count - 1

    var scale: CGFloat { Self.scales[index] }

    /// Every visualizer has its own cost profile, so a freshly built one
    /// starts at full resolution and the ladder re-adapts from fresh
    /// measurements.
    mutating func reset() {
        index = Self.scales.count - 1
    }

    /// One adjustment window's worth of evidence. `average` and `budget` are
    /// both seconds per frame.
    mutating func adjust(averageGPUTime average: Double, budget: Double) {
        if average > budget * 0.85, index > 0 {
            index -= 1
        } else if index < Self.scales.count - 1 {
            let growth = Self.scales[index + 1] / Self.scales[index]
            if average * Double(growth * growth) < budget * 0.6 {
                index += 1
            }
        }
    }
}

/// Lock-guarded accumulator for measured GPU frame times. `record` is called
/// from Metal's command-buffer completion thread, `drain`/`reset` from the
/// main-thread render loop — hence `nonisolated` (the project default would
/// otherwise pin every member to the main actor) and the hand-rolled lock,
/// the same discipline as `AudioAnalyzer`.
nonisolated final class GPUFrameTimer: @unchecked Sendable {
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
