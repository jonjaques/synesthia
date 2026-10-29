import Foundation

@testable import Synesthia

/// The suite's own `AudioSource`, and the second adapter that justifies the
/// interface existing at all: the real ones are ScreenCaptureKit, an
/// AVAudioEngine input node and an AVAudioPlayerNode graph, none of which can
/// be built in a test — one needs a TCC grant, one needs hardware, and the
/// third needs an output device.
///
/// It counts calls rather than only recording the last one, because the
/// mistakes worth catching are extra calls, not missing ones: a stop that
/// happens twice, a restart that also restarts the source the user just
/// switched away from.
/// The explicit `@MainActor` on the conformance is required, and only on this
/// one: Swift infers an isolated conformance for `AudioSource` (the type is
/// main-actor isolated, like everything else here), but a refinement whose
/// conformance *depends* on an isolated one has to say so out loud.
final class FakeAudioSource: @MainActor RestartableSource {
    var isRunning = false
    var onStopped: (() -> Void)?
    /// Set to make the next `start()` throw, standing in for a denied
    /// permission or an absent device.
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var restartCount = 0

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }

    func stop() async {
        stopCount += 1
        isRunning = false
    }

    func restart() throws {
        restartCount += 1
    }

    /// Simulates the interface being unplugged or the permission being
    /// revoked — the one thing a source does that nobody asked it to.
    func die() {
        isRunning = false
        onStopped?()
    }
}

/// A source with no top to go back to, like a microphone. Exists so the
/// `RestartableSource` cast has something to *fail* on.
final class FakeLiveSource: AudioSource {
    var isRunning = false
    var onStopped: (() -> Void)?

    func start() async throws { isRunning = true }

    func stop() async { isRunning = false }
}
