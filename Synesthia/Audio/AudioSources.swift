import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreAudio
import CoreMedia

/// The four places audio can come from. Exactly one is active at a time
/// (`AppState.sourceKind`); all of them end up funneling PCM buffers into the
/// same `AudioAnalyzer`.
///
/// - `musicApp`: control Music.app over Apple Events for transport/metadata,
///   while *hearing* it through the same system-audio tap as `systemAudio`
///   (Music doesn't expose its audio stream directly).
/// - `systemAudio`: everything the Mac plays, captured with ScreenCaptureKit.
/// - `inputDevice`: a microphone/line-in, tapped with AVAudioEngine.
/// - `audioFile`: a local file played by this app itself.
enum AudioSourceKind: String, CaseIterable, Identifiable, Codable {
    case musicApp
    case systemAudio
    case inputDevice
    case audioFile

    var id: String { rawValue }

    /// User-facing name in the source menu.
    var label: String {
        switch self {
        case .musicApp: "Music app"
        case .systemAudio: "System audio"
        case .inputDevice: "Audio input"
        case .audioFile: "Audio file"
        }
    }

    /// SF Symbol shown next to the label.
    var symbol: String {
        switch self {
        case .musicApp: "music.note"
        case .systemAudio: "speaker.wave.3"
        case .inputDevice: "mic"
        case .audioFile: "waveform"
        }
    }
}

enum AudioSourceError: LocalizedError {
    case noDisplay
    case noInputDevice
    case microphoneDenied
    case noFileLoaded

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available for system audio capture."
        case .noInputDevice: "No audio input device found."
        case .microphoneDenied: "Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .noFileLoaded: "No audio file loaded."
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
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let analyzer = self.analyzer
        // Wrap the sample buffer's audio memory directly (no copy); it stays
        // valid for the duration of the closure, and appendMono copies out.
        // (Copy-based extraction via CMSampleBufferCopyPCMDataIntoAudioBufferList
        // silently fails here — see CLAUDE.md — so don't "simplify" this.)
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  asbd.mSampleRate > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             bufferListNoCopy: audioBufferList.unsafePointer) else { return }
            analyzer.appendMono(from: pcm)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream was torn down externally (e.g. permission revoked); UI state
        // resyncs the next time the user toggles capture.
    }
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
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
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
              let cf = name?.takeRetainedValue() else { return nil }
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
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.noInputDevice
        }
        let analyzer = self.analyzer
        // The tap closure runs on an audio thread; capture the analyzer
        // reference outside so the closure doesn't retain `self`.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            analyzer.appendMono(from: buffer)
        }
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
                let analyzer = self.analyzer
                engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    analyzer.appendMono(from: buffer)
                }
                tapInstalled = true
            }
            engine.prepare()
            try engine.start()
        }
        if !player.isPlaying {
            scheduleLoop(file)
            player.play()
        }
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.stop()
        isPlaying = false
    }

    func togglePlayPause() throws {
        if isPlaying { pause() } else { try play() }
    }

    /// Jump back to the start of the file (used as "previous/next track").
    func restart() throws {
        guard file != nil else { throw AudioSourceError.noFileLoaded }
        player.stop()
        isPlaying = false
        try play()
    }

    /// Schedules one full pass of the file; when it finishes, hops back to
    /// the main actor and schedules the next pass — an infinite loop that
    /// stops naturally when `isPlaying` goes false or the file is swapped.
    private func scheduleLoop(_ file: AVAudioFile) {
        player.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, let file = self.file else { return }
                self.scheduleLoop(file)
            }
        }
    }
}
