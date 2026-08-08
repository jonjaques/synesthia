import Foundation
import Testing

@testable import Synesthia

/// The `AudioSource` contract, pinned through the suite's own adapter.
///
/// These are rules the three real engines have to honour and nothing else
/// checks: `onStopped` means *died*, never *was stopped*, and only the sources
/// the app plays itself answer to a restart. Both were live bugs before the
/// interface existed — `AppState` had no way to ask an engine whether it was
/// running, and `InputDeviceCapture` had no way to say it had stopped.
@MainActor
struct AudioSourceTests {

    @Test func aNormalStopIsNotReportedAsAnExternalStop() async {
        let source = FakeAudioSource()
        var reported = 0
        source.onStopped = { reported += 1 }

        try? await source.start()
        await source.stop()

        #expect(!source.isRunning)
        #expect(reported == 0, "stop() is the owner asking; there is nothing to report back")
    }

    @Test func aSourceThatDiesReportsItself() async {
        let source = FakeAudioSource()
        var reported = 0
        source.onStopped = { reported += 1 }

        try? await source.start()
        #expect(source.isRunning)
        source.die()

        #expect(!source.isRunning)
        #expect(reported == 1)
    }

    /// The state `AppState` reads back after a failed start. Before the
    /// interface it maintained its own boolean and had to remember to clear it.
    @Test func aFailedStartLeavesTheSourceNotRunning() async {
        let source = FakeAudioSource()
        source.startError = AudioSourceError.microphoneDenied

        await #expect(throws: AudioSourceError.self) { try await source.start() }
        #expect(!source.isRunning)
        #expect(source.startCount == 1)
    }

    /// `restartCurrentSource` is one conditional cast on an existential. If
    /// `RestartableSource` ever grows a `Self` or associated-type requirement
    /// the cast stops compiling; if the conformance moves, it silently starts
    /// returning nil and prev/next quietly do nothing.
    @Test func onlyTheSourcesTheAppPlaysAnswerToARestart() {
        let restartable: any AudioSource = FakeAudioSource()
        let live: any AudioSource = FakeLiveSource()

        try? (restartable as? any RestartableSource)?.restart()
        try? (live as? any RestartableSource)?.restart()

        #expect((restartable as? FakeAudioSource)?.restartCount == 1)
        #expect(live as? any RestartableSource == nil)
    }
}
