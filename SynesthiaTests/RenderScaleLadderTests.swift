import Foundation
import Testing

@testable import Synesthia

/// Tests for the adaptive-resolution decision and the measurement it runs on.
///
/// Both used to be unreachable — the ladder as arithmetic inside a private
/// `Coordinator` method, `GPUFrameTimer` as a file-private class that
/// `@testable import` couldn't see. The hysteresis is the part worth pinning:
/// it is one `else if` away from a scale that ping-pongs between two rungs
/// every half second, which looks like the app breathing.
@MainActor
struct RenderScaleLadderTests {

    /// One frame at 60 Hz.
    private let budget = 1.0 / 60

    @Test func itStartsAtFullResolution() {
        #expect(RenderScaleLadder().scale == 1.0)
        #expect(RenderScaleLadder.scales.last == 1.0)
    }

    @Test func overBudgetStepsDown() {
        var ladder = RenderScaleLadder()
        ladder.adjust(averageGPUTime: 0.9 * budget, budget: budget)
        #expect(ladder.scale < 1.0)
    }

    /// Between 60% and 85% nothing moves. That gap is the whole reason the
    /// scale doesn't oscillate at a boundary: stepping up multiplies the cost
    /// by the area ratio, which would immediately put it back over 85%.
    @Test func theHysteresisGapHoldsTheCurrentRung() {
        var ladder = RenderScaleLadder()
        ladder.adjust(averageGPUTime: 0.9 * budget, budget: budget)
        let held = ladder.scale
        ladder.adjust(averageGPUTime: 0.7 * budget, budget: budget)
        #expect(ladder.scale == held)
    }

    /// Stepping back up asks what the *next* rung would cost, not what this
    /// one costs — area, so the square of the size ratio.
    @Test func aCheapFrameStepsBackUp() {
        var ladder = RenderScaleLadder()
        ladder.adjust(averageGPUTime: 0.9 * budget, budget: budget)
        let stepped = ladder.scale
        ladder.adjust(averageGPUTime: 0.1 * budget, budget: budget)
        #expect(ladder.scale > stepped)
    }

    @Test func itClampsAtBothEnds() {
        var ladder = RenderScaleLadder()
        for _ in 0..<20 { ladder.adjust(averageGPUTime: 5 * budget, budget: budget) }
        #expect(ladder.scale == RenderScaleLadder.scales[0])

        for _ in 0..<20 { ladder.adjust(averageGPUTime: 0, budget: budget) }
        #expect(ladder.scale == 1.0)
    }

    @Test func aRebuiltVisualizerStartsFromTheTopAgain() {
        var ladder = RenderScaleLadder()
        for _ in 0..<20 { ladder.adjust(averageGPUTime: 5 * budget, budget: budget) }
        ladder.reset()
        #expect(ladder.scale == 1.0)
    }

    // MARK: - The measurement

    /// A failed or empty command buffer reports zero timestamps. Counting
    /// those would drag the average toward "everything is fine" and hold the
    /// scale at full resolution on a machine that can't keep up.
    @Test func theTimerIgnoresZeroSamples() {
        let timer = GPUFrameTimer()
        timer.record(0)
        timer.record(-1)
        #expect(timer.drain(minimumSamples: 1) == nil)
    }

    @Test func theTimerHonoursItsMinimumAndThenAverages() {
        let timer = GPUFrameTimer()
        for _ in 0..<9 { timer.record(0.01) }
        #expect(timer.drain(minimumSamples: 10) == nil, "nine samples is not a window")

        timer.record(0.02)
        let average = timer.drain(minimumSamples: 10)
        #expect(average != nil)
        #expect(abs((average ?? 0) - 0.011) < 0.0001)
    }

    /// Draining starts a fresh window, so the next adjustment can't be shaped
    /// by frames the last one already acted on.
    @Test func drainingStartsAFreshWindow() {
        let timer = GPUFrameTimer()
        timer.record(0.01)
        #expect(timer.drain(minimumSamples: 1) != nil)
        #expect(timer.drain(minimumSamples: 1) == nil)
    }

    @Test func resetDiscardsWhateverWasMeasured() {
        let timer = GPUFrameTimer()
        for _ in 0..<10 { timer.record(0.01) }
        timer.reset()
        #expect(timer.drain(minimumSamples: 1) == nil)
    }
}
