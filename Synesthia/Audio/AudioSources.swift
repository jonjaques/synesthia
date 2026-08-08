import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The places audio can come from. Exactly one is active at a time
/// (`AppState.sourceKind`); all of them end up funneling PCM buffers into the
/// same `AudioAnalyzer`.
///
/// - `demo`: a short loop bundled with the app, played by this app itself.
///   The only source that needs **no** permission at all, which is why it is
///   the first-launch default — the visuals are provably alive before any TCC
///   prompt fires (see docs/app-store-launch-plan.md §B4).
/// - `systemAudio`: everything the Mac plays, captured with ScreenCaptureKit.
///   This is also where now-playing lives: `NowPlayingObserver` recognizes
///   whatever media player is producing that audio and the badge names the
///   track. There is deliberately no separate "Music app" source any more —
///   it was never a distinct *audio* path (Music exposes no stream, so it went
///   through this same tap), and making it a source meant a user had to know
///   which one to pick. See docs/macos-integration.md.
/// - `inputDevice`: a microphone/line-in, tapped with AVAudioEngine.
/// - `audioFile`: a local file played by this app itself.
enum AudioSourceKind: String, CaseIterable, Identifiable, Codable {
    case demo
    case systemAudio
    case inputDevice
    case audioFile

    var id: String { rawValue }

    /// The sources offered in the source picker. The demo track is
    /// deliberately not one of them — it lives in the welcome window and the
    /// Help menu, so the picker only lists things a user would genuinely
    /// listen to.
    static var selectable: [AudioSourceKind] {
        allCases.filter { $0 != .demo }
    }

    /// User-facing name in the source menu.
    var label: String {
        switch self {
        case .demo: "Demo Track"
        case .systemAudio: "System Audio"
        case .inputDevice: "Audio Input"
        case .audioFile: "Audio File"
        }
    }

    /// SF Symbol shown next to the label.
    var symbol: String {
        switch self {
        case .demo: "music.quarternote.3"
        case .systemAudio: "speaker.wave.3"
        case .inputDevice: "mic"
        case .audioFile: "waveform"
        }
    }

    /// The macOS privacy permission this source needs before it can produce
    /// sound, or `nil` when it needs none. Drives the first-run explainer.
    var requiredPermission: PrivacyPermission? {
        switch self {
        case .demo, .audioFile: nil
        case .systemAudio: .screenAndSystemAudio
        case .inputDevice: .microphone
        }
    }
}

/// The privacy permissions Synesthia can ask for, with the System Settings
/// pane each one lives in. `x-apple.systempreferences:` URLs open Settings
/// directly at the relevant pane, which is far kinder than describing a path.
enum PrivacyPermission: String, Identifiable, CaseIterable {
    case screenAndSystemAudio
    case automation
    case microphone

    var id: String { rawValue }

    /// Names the permission the way System Settings does, so a user hunting
    /// for it in the sidebar sees the same words.
    var title: String {
        switch self {
        case .screenAndSystemAudio: "Screen & System Audio Recording"
        case .automation: "Automation"
        case .microphone: "Microphone"
        }
    }

    /// The imperative form, for the explainer card's heading: `title` names
    /// the permission, this one asks for it.
    var actionTitle: String {
        switch self {
        case .screenAndSystemAudio: "Allow System Audio Recording"
        case .automation: "Allow Control of Music"
        case .microphone: "Allow Microphone Access"
        }
    }

    var explanation: String {
        switch self {
        case .screenAndSystemAudio:
            "macOS gives an app no way to hear another app's sound on its own. The only route it provides is screen recording, which can carry the sound alongside the picture — so that is the permission it asks for. Synesthia keeps the sound and throws the picture away: it is captured at 2×2 pixels and every frame is discarded."
        case .automation:
            "Optional. Synesthia already knows what's playing without this. Granting it adds play, pause, and skip buttons for your music player, and pulls in real album artwork. Nothing is written back to your library."
        case .microphone:
            "Lets Synesthia listen to a microphone, line-in, or instrument interface. The sound drives the visuals as it arrives and is never recorded."
        }
    }

    var symbol: String {
        switch self {
        case .screenAndSystemAudio: "rectangle.inset.filled.and.person.filled"
        case .automation: "gearshape.2"
        case .microphone: "mic"
        }
    }

    /// Deep link into the exact System Settings pane.
    var settingsURL: URL? {
        let anchor =
            switch self {
            case .screenAndSystemAudio: "Privacy_ScreenCapture"
            case .automation: "Privacy_Automation"
            case .microphone: "Privacy_Microphone"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

// MARK: - Bundled demo track

/// The royalty-free loop bundled with the app, generated by
/// `scripts/make_demo_loop.py`. Playing it needs no permission of any kind,
/// so it is what a brand-new user (or an App Review tester) sees first.
enum DemoTrack {
    static let title = "Synesthia Demo Loop"
    static let subtitle = "Bundled demo — no permissions needed"

    static var url: URL? {
        Bundle.main.url(forResource: "DemoLoop", withExtension: "m4a")
    }
}

enum AudioSourceError: LocalizedError {
    case noDisplay
    case noInputDevice
    case microphoneDenied
    case noFileLoaded

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display to listen through. macOS carries system audio alongside a screen capture, so it needs at least one display available."
        case .noInputDevice: "No audio input device found. Connect a microphone or interface and try again."
        case .microphoneDenied:
            "Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .noFileLoaded: "No audio file chosen yet. Pick one with Open Audio File… (⌘O)."
        }
    }
}

// MARK: - System audio (ScreenCaptureKit)

/// Captures the Mac's system audio output (everything except this app) and
/// feeds it to the analyzer. Requires the System Audio Recording permission.
///
/// macOS has no plain "record system audio" API; the sanctioned route is
/// ScreenCaptureKit (SCK), the *screen*-recording framework, which can attach
/// an audio stream to a display capture. So this class sets up a nominal
/// screen capture of the main display — shrunk to 2×2 px at 5 fps, with the
/// video frames thrown away — purely to get the audio leg. That's also why
/// the permission users must grant is "Screen & System Audio Recording".
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let analyzer: AudioAnalyzer
    private var stream: SCStream?
    /// Serial queue SCK delivers sample buffers on (off the main thread).
    private let sampleQueue = DispatchQueue(label: "synesthia.system-audio")
    private(set) var isRunning = false
    /// Called (on the main actor) after the stream is torn down *externally* —
    /// permission revoked, display reconfigured — never for a normal `stop()`.
    /// Lets the owner resync `isCapturing`, the power assertion, and the UI,
    /// which would otherwise all stay stuck claiming capture is live.
    var onExternalStop: (() -> Void)?

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
        super.init()
    }

    func start() async throws {
        guard stream == nil else { return }
        // Enumerate capturable content; this is also the call that fails if
        // the Screen & System Audio Recording permission is missing.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw AudioSourceError.noDisplay }
        // Capture the whole display, excluding no apps: system-wide audio.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Don't capture our own output (e.g. the file player), which would
        // feed back into the analysis.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We only attach an audio output; keep the (unused) video leg minimal.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // Register a (discarded) screen output too, or SCStream logs a
        // "stream output NOT found" error for every video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        isRunning = false
        try? await stream.stopCapture()
    }

    /// SCK's per-buffer callback, invoked on `sampleQueue`. `nonisolated`
    /// because the project defaults everything to the main actor and this
    /// must run on the capture queue instead.
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let analyzer = self.analyzer
        // Wrap the sample buffer's audio memory directly (no copy); it stays
        // valid for the duration of the closure, and appendMono copies out.
        // (Copy-based extraction via CMSampleBufferCopyPCMDataIntoAudioBufferList
        // silently fails here — see CLAUDE.md — so don't "simplify" this.)
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                asbd.mSampleRate > 0,
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: asbd.mSampleRate,
                    channels: asbd.mChannelsPerFrame),
                let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            analyzer.appendMono(from: pcm)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream was torn down externally (e.g. permission revoked). Identity
        // travels as an ObjectIdentifier because SCStream itself isn't
        // Sendable, so it can't cross into the main-actor task.
        let stopped = ObjectIdentifier(stream)
        Task { @MainActor in self.handleExternalStop(of: stopped) }
    }

    /// Ignores errors from a stream we already replaced or shut down: only the
    /// *current* stream dying means capture state must resync.
    private func handleExternalStop(of stopped: ObjectIdentifier) {
        guard let stream, ObjectIdentifier(stream) == stopped else { return }
        self.stream = nil
        isRunning = false
        onExternalStop?()
    }
}

// MARK: - Audio-thread callbacks

/// Builds the block AVAudioEngine calls with each captured buffer.
///
/// This **must** be created from a `nonisolated` context. The project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a closure written inline
/// inside a main-actor method is itself inferred main-actor — and AVFAudio
/// invokes tap blocks on a realtime audio thread. Under Swift 6 the resulting
/// isolation check *traps*: `EXC_BREAKPOINT` inside
/// `swift_task_checkIsolatedSwift`, on the first buffer, every time. Building
/// the block out here, outside any actor, is what keeps it off the main actor.
///
/// Same reasoning as the `nonisolated` SCStreamOutput callbacks below and
/// `nonisolated final class AudioAnalyzer` — see CLAUDE.md.
private nonisolated func makeAnalyzerTap(_ analyzer: AudioAnalyzer) -> AVAudioNodeTapBlock {
    { buffer, _ in analyzer.appendMono(from: buffer) }
}

// MARK: - Input device (mic / line-in)

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Enumerates audio *input* devices via the Core Audio HAL — a C API driven
/// by property queries: build an `AudioObjectPropertyAddress` (selector +
/// scope + element) naming the property you want, ask for its size, then
/// fetch the data into a buffer of that size. Every function below is one
/// instance of that pattern.
enum AudioInputDeviceList {
    static func all() -> [AudioInputDevice] {
        // "All audio devices on the system" is a property of the system object.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        // The list includes outputs (speakers, displays); keep only devices
        // that actually have input streams.
        return ids.compactMap { id in
            guard hasInputStreams(id), let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, name: name)
        }
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
            let cf = name?.takeRetainedValue()
        else { return nil }
        return cf as String
    }
}

/// Taps an audio input device (microphone, line-in, virtual loopback device…).
///
/// Uses `AVAudioEngine`, Apple's node-graph audio framework: the engine's
/// built-in `inputNode` represents the capture device, and an installed "tap"
/// is a callback handed every buffer flowing through that node. Nothing is
/// connected downstream, so the input is analyzed but never played back
/// (no feedback squeal when using the built-in mic).
final class InputDeviceCapture {
    private let analyzer: AudioAnalyzer
    private var engine: AVAudioEngine?
    private(set) var isRunning = false

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    func start(deviceID: AudioDeviceID?) async throws {
        guard engine == nil else { return }
        // Triggers the microphone-permission prompt (TCC) on first use.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioSourceError.microphoneDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // AVAudioEngine always opens the *default* input; picking a specific
        // device means reaching under the hood and pointing the input node's
        // underlying audio unit at that device ID.
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &id,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.noInputDevice
        }
        // The tap block runs on an audio thread, so it is built by a
        // nonisolated factory (see makeAnalyzerTap) rather than written inline;
        // it captures only the analyzer, never `self`.
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format,
            block: makeAnalyzerTap(analyzer))
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }
}

// MARK: - Local file player

/// Plays a local audio file out the default output device while feeding the
/// analyzer from a tap, so the visuals track exactly what you hear.
///
/// The engine graph is `player → mainMixerNode → (output)`; the analyzer tap
/// sits on the mixer, i.e. post-mix, right before the speakers. The file
/// loops forever: each time playback of one scheduled pass completes, the
/// completion handler schedules the next (see `scheduleLoop`).
final class FilePlayer {
    private let analyzer: AudioAnalyzer
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var tapInstalled = false
    private(set) var currentURL: URL?
    private(set) var isPlaying = false
    /// Whether the player still holds scheduled audio. `player.isPlaying` is
    /// false both when *paused* (queue intact) and when *stopped* (queue
    /// cleared); scheduling on resume-from-pause would queue a duplicate pass
    /// of the file on top of the paused one's remainder.
    private var hasQueuedAudio = false
    /// Bumped whenever the queue is cleared (`stop()` / `load()`), so a loop
    /// completion fired by the *old* queue can tell it's stale and must not
    /// schedule into the new one.
    private var generation = 0

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    func load(url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        self.file = file
        currentURL = url
        // Reconnect with the file's own format so the engine resamples
        // correctly if the new file's sample rate differs from the old one's.
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    }

    func play() throws {
        guard let file else { throw AudioSourceError.noFileLoaded }
        if !engine.isRunning {
            if !tapInstalled {
                engine.mainMixerNode.installTap(
                    onBus: 0, bufferSize: 1024, format: nil,
                    block: makeAnalyzerTap(analyzer))
                tapInstalled = true
            }
            engine.prepare()
            try engine.start()
        }
        if !hasQueuedAudio {
            scheduleLoop(file)
            hasQueuedAudio = true
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.stop()
        generation += 1
        hasQueuedAudio = false
        isPlaying = false
    }

    func togglePlayPause() throws {
        if isPlaying { pause() } else { try play() }
    }

    /// Jump back to the start of the file (used as "previous/next track").
    func restart() throws {
        guard file != nil else { throw AudioSourceError.noFileLoaded }
        stop()
        try play()
    }

    /// Schedules one full pass of the file; when it finishes, hops back to
    /// the main actor and schedules the next pass — an infinite loop that
    /// stops naturally when `isPlaying` goes false or the file is swapped.
    private func scheduleLoop(_ file: AVAudioFile) {
        player.scheduleFile(file, at: nil, completionHandler: loopCompletion(generation: generation))
    }

    /// The completion block AVAudioEngine calls when one pass finishes.
    ///
    /// `nonisolated` for the same reason as `makeAnalyzerTap`: AVFAudio invokes
    /// this from its own queue, and a block created in a main-actor context
    /// would trap on Swift 6's isolation check *before* reaching the `Task`
    /// that hops back. Building it here means the hop actually happens.
    ///
    /// Spelled `@Sendable () -> Void` rather than `AVAudioNodeCompletionHandler`
    /// because that SDK typealias is not itself marked `@Sendable`, which the
    /// concurrency checker flags at the call site.
    private nonisolated func loopCompletion(generation: Int) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation, self.isPlaying,
                    let file = self.file
                else { return }
                self.scheduleLoop(file)
            }
        }
    }
}
