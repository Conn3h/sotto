import AppKit
import SwiftUI

/// The standard `Settings` scene (⌘,), spec §6.14: push-to-talk key, cleanup, sound, and
/// permission status. `SwiftUI.Settings` is spelled out where this view is installed, in
/// `SottoApp`, because the app has its own `Settings` type.
@MainActor
struct SettingsWindow: View {
    let controller: DictationController

    @Bindable private var settings = Settings.shared
    @State private var status = PermissionStatus.shared
    @State private var parakeet = ParakeetModels.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                pushToTalkSection
                engineSection
                cleanupSection
                soundSection
                permissionsSection
            }
            .padding(DS.Space.panel)
        }
        .background(DS.Color.ground)
        .onAppear {
            refreshPermissions()
        }
        .task {
            await pollPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var pushToTalkSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Push to talk")
                SegmentedChoice(
                    options: PushToTalkKey.allCases,
                    selection: Binding(
                        get: { settings.pushToTalkKey },
                        set: { newValue in
                            settings.pushToTalkKey = newValue
                            controller.reloadHotkey()
                        }
                    )
                ) { $0.displayName }
                Text("Hold this key anywhere to dictate.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkTertiary)
            }
        }
    }

    private var engineSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Engine")
                SegmentedChoice(
                    options: SpeechEngineChoice.allCases,
                    selection: Binding(
                        get: { settings.speechEngine },
                        set: { newValue in
                            settings.speechEngine = newValue
                            if newValue == .parakeet {
                                parakeet.prepare()
                            }
                        }
                    )
                ) { $0.displayName }
                Text(engineCaption)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkTertiary)
            }
        }
    }

    private var engineCaption: String {
        switch settings.speechEngine {
        case .apple:
            return "Apple's on-device recognizer. Dictionary words bias recognition."
        case .parakeet:
            return parakeetCaption
        }
    }

    private var parakeetCaption: String {
        switch parakeet.state {
        case .idle:
            return "NVIDIA Parakeet, on device. Models download on first use."
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded(.down))
            return "Downloading Parakeet models, \(percent)%."
        case .loading:
            return "Loading Parakeet models."
        case .ready:
            return "NVIDIA Parakeet, on device. Dictionary corrections still apply; bias phrases do not."
        case .failed(let reason):
            return "Parakeet failed to load: \(reason)"
        }
    }

    private var cleanupSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Cleanup")
                Toggle("Clean up dictated text", isOn: $settings.cleanupEnabled)
                    .toggleStyle(.switch)
                    .tint(DS.Color.ink)

                if settings.cleanupEnabled {
                    VStack(alignment: .leading, spacing: DS.Space.tight) {
                        Toggle("Smart cleanup", isOn: $settings.smartCleanup)
                            .toggleStyle(.switch)
                            .tint(DS.Color.ink)
                            .disabled(!FoundationModelFormatter.isAvailable)
                        if !FoundationModelFormatter.isAvailable,
                           let reason = FoundationModelFormatter.unavailableReason {
                            Text(reason)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.inkTertiary)
                        }
                    }
                    .padding(.leading, DS.Space.roomy)
                }
            }
        }
    }

    private var soundSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Sound")
                Toggle("Play a sound when listening starts", isOn: $settings.soundEnabled)
                    .toggleStyle(.switch)
                    .tint(DS.Color.ink)
            }
        }
    }

    private var permissionsSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Permissions")
                permissionRow(
                    title: "Accessibility",
                    granted: status.hasAccessibility,
                    open: Permissions.openAccessibilitySettings
                )
                permissionRow(
                    title: "Microphone",
                    granted: status.hasMicrophone,
                    open: Permissions.openMicrophoneSettings
                )
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Space.base) {
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if granted {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DS.Color.ink)
                    Text("Granted")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkTertiary)
                }
            } else {
                Text("Not granted")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkTertiary)
            }
            Spacer()
            if !granted {
                Button("Grant\u{2026}", action: open)
            }
        }
    }

    private func refreshPermissions() {
        PermissionStatus.shared.refresh()
    }

    private func pollPermissions() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(DS.Motion.permissionPollInterval))
            } catch {
                Log.app.debug("permission poll cancelled")
                return
            }
            refreshPermissions()
        }
    }
}
