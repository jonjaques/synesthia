import AVFoundation
import AppKit
import SwiftUI

/// First-run explainer, styled after the welcome panes of Apple's own apps:
/// app icon, greeting, one clickable row per audio source stating its value
/// and its permission cost up front, a privacy note, and a single Continue.
///
/// Two jobs, in this order of importance:
///
/// 1. Prove the app works before asking for anything. The bundled demo track
///    is already playing behind this sheet, so the visuals are visibly alive
///    on a machine that has granted zero permissions. An App Review tester who
///    grants nothing must still see the app function — the alternative is a
///    black canvas and a 2.1 "app does not function" rejection.
/// 2. Deliver each permission's value proposition *before* macOS asks for it.
///    Choosing a source here is exactly what triggers the system prompt, so
///    the reasons get read first.
///
/// See docs/app-store-launch-plan.md §B4.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    sourceRows
                        .padding(.top, 24)
                    privacyNote
                        .padding(.top, 20)
                }
                .padding(.horizontal, 44)
                .padding(.top, 32)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: 560, height: 680)
        .onAppear { appState.refreshPermissions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)
            Text("Welcome to Synesthia")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 14)
            Text(
                "Live, GPU-rendered visuals for whatever you're listening to. Choose where the sound comes from:"
            )
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
    }

    /// The rows carry their own horizontal inset so the hover wash extends
    /// past the text column; the negative padding keeps the text itself on
    /// the page margin.
    private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AudioSourceKind.selectable) { kind in
                SourceRow(kind: kind, blurb: Self.blurb(for: kind), footnote: footnote(for: kind))
            }
        }
        .padding(.horizontal, -14)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(
                "Synesthia analyzes audio in the moment and keeps nothing — no recordings, no uploads. System audio arrives through macOS's screen-recording engine, so that one permission covers it; the video frames are discarded. [Privacy Policy…](https://synesthia.app/privacy)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                appState.completeWelcome()
            } label: {
                Text("Continue")
                    .frame(minWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if appState.sourceKind == .demo, appState.isDemoPlaying {
                Text("The demo track is playing behind this window. Reopen this guide from the Help menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button("Play the Demo Track") {
                    appState.playDemo()
                    appState.completeWelcome()
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private static func blurb(for kind: AudioSourceKind) -> String {
        switch kind {
        case .demo:
            ""
        case .systemAudio:
            "Anything your Mac is playing — Music, Spotify, a browser, a game. Track titles appear on their own when a player is recognized."
        case .inputDevice:
            "Live sound from a microphone, an instrument, or an audio interface."
        case .audioFile:
            "Pick an audio file from your Mac and let it loop."
        }
    }

    private func footnote(for kind: AudioSourceKind) -> PermissionFootnote? {
        switch kind {
        case .demo:
            nil
        case .systemAudio:
            appState.screenAudioGranted
                ? PermissionFootnote(
                    text: "Ready — access granted", symbol: "checkmark.seal.fill", ready: true)
                : PermissionFootnote(
                    text: "Asks for Screen & System Audio Recording",
                    symbol: "lock.fill", ready: false)
        case .inputDevice:
            switch appState.microphoneStatus {
            case .authorized:
                PermissionFootnote(text: "Ready — access granted", symbol: "checkmark.seal.fill", ready: true)
            case .denied, .restricted:
                PermissionFootnote(
                    text: "Microphone access is turned off in System Settings",
                    symbol: "lock.fill", ready: false)
            default:
                PermissionFootnote(text: "Asks for Microphone access", symbol: "lock.fill", ready: false)
            }
        case .audioFile:
            PermissionFootnote(
                text: "No permission needed — you choose the file", symbol: "checkmark.seal.fill", ready: true
            )
        }
    }
}

/// The permission line under a source row: the cost before it's paid, the
/// green seal after.
private struct PermissionFootnote {
    let text: String
    let symbol: String
    let ready: Bool
}

/// One clickable source row: symbol, name, what it buys, and what it asks
/// for. Clicking selects the source and dismisses the sheet — for permission
/// sources that is what fires the system prompt, right after the pitch.
private struct SourceRow: View {
    @Environment(AppState.self) private var appState
    let kind: AudioSourceKind
    let blurb: String
    let footnote: PermissionFootnote?
    @State private var hovering = false

    var body: some View {
        Button {
            appState.completeWelcome()
            appState.selectSource(kind)
            if kind == .audioFile, appState.fileURL == nil {
                // Give the sheet a beat to start dismissing before the modal
                // open panel takes over the run loop.
                Task { appState.openFilePanel() }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                        .font(.headline)
                    Text(blurb)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote {
                        Label {
                            Text(footnote.text)
                        } icon: {
                            Image(systemName: footnote.symbol)
                                .foregroundStyle(
                                    footnote.ready ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.45)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(hovering ? 0.55 : 0), in: .rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .accessibilityHint("Switches to this source and closes the welcome window")
    }
}
