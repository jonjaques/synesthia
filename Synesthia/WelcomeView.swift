import SwiftUI

/// First-run explainer.
///
/// Two jobs, in this order of importance:
///
/// 1. Prove the app works before asking for anything. The bundled demo track
///    is already playing behind this sheet, so the visuals are visibly alive
///    on a machine that has granted zero permissions. An App Review tester who
///    grants nothing must still see the app function — the alternative is a
///    black canvas and a 2.1 "app does not function" rejection.
/// 2. Name each permission, say plainly what it buys and why macOS requires
///    it, and offer a one-click deep link into the right System Settings pane.
///
/// See docs/app-store-launch-plan.md §B4.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    /// The sources worth putting in front of someone on first launch, paired
    /// with what it costs to use them.
    private var options: [SourceOption] {
        var items: [SourceOption] = [
            SourceOption(
                kind: .demo,
                blurb: "A short loop bundled with the app. Playing right now, behind this window.",
                permission: nil)
        ]
        #if MUSIC_APP_SOURCE
        items.append(
            SourceOption(
                kind: .musicApp,
                blurb:
                    "Visualize the Music app and control playback, with the track name and artwork on screen.",
                permission: .screenAndSystemAudio,
                extraPermission: .automation))
        #endif
        items.append(
            SourceOption(
                kind: .systemAudio,
                blurb: "Visualize anything your Mac is playing — a browser tab, a streaming app, a game.",
                permission: .screenAndSystemAudio))
        items.append(
            SourceOption(
                kind: .inputDevice,
                blurb: "Visualize a microphone, line-in, or an instrument interface.",
                permission: .microphone))
        items.append(
            SourceOption(
                kind: .audioFile,
                blurb: "Open any audio file from your Mac. No permission needed — you pick the file.",
                permission: nil))
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(options) { option in
                        SourceRow(option: option)
                    }
                    permissionFootnote
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 580)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Synesthia")
                .font(.title2.weight(.semibold))
            Text(
                "The demo track is already playing — the visuals you can see behind this window need no permissions at all. When you're ready to visualize your own audio, here's what each source needs."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var permissionFootnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Why screen recording?", systemImage: "questionmark.circle")
                .font(.callout.weight(.semibold))
            Text(PrivacyPermission.screenAndSystemAudio.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Text("You can reopen this from the Help menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Continue with the demo") {
                appState.completeWelcome()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

/// One row of the welcome sheet: a source, what it does, and the permission
/// (if any) standing between the user and it.
private struct SourceOption: Identifiable {
    let kind: AudioSourceKind
    let blurb: String
    let permission: PrivacyPermission?
    var extraPermission: PrivacyPermission?

    var id: String { kind.rawValue }

    var permissions: [PrivacyPermission] {
        [permission, extraPermission].compactMap { $0 }
    }
}

private struct SourceRow: View {
    @Environment(AppState.self) private var appState
    let option: SourceOption

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: option.kind.symbol)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(option.kind.label)
                        .font(.headline)
                    if option.permissions.isEmpty {
                        Text("No permission needed")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.22), in: .capsule)
                    }
                }
                Text(option.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !option.permissions.isEmpty {
                    ForEach(option.permissions) { permission in
                        Button {
                            appState.openPermissionSettings(permission)
                        } label: {
                            Label("Allow “\(permission.title)”…", systemImage: permission.symbol)
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .accessibilityHint("Opens System Settings at the \(permission.title) pane")
                    }
                }
            }

            Spacer(minLength: 8)

            Button("Use") {
                appState.selectSource(option.kind)
                appState.completeWelcome()
            }
            .accessibilityLabel("Use \(option.kind.label)")
        }
        .padding(.vertical, 2)
    }
}
