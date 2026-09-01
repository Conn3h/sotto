import AppKit
import SwiftUI

/// The standard `Settings` scene (⌘,), spec §6.14: push-to-talk key, cleanup, sound, and
/// permission status. `SwiftUI.Settings` is spelled out where this view is installed, in
/// `SottoApp`, because the app has its own `Settings` type.
@MainActor
struct SettingsWindow: View {
    let controller: DictationController

    @Bindable private var settings = Settings.shared
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasMicrophone = Permissions.hasMicrophone

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                pushToTalkSection
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
                    granted: hasAccessibility,
                    open: Permissions.openAccessibilitySettings
                )
                permissionRow(
                    title: "Microphone",
                    granted: hasMicrophone,
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
            Text(granted ? "Granted" : "Not granted")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
            Spacer()
            if !granted {
                Button("Open System Settings", action: open)
            }
        }
    }

    private func refreshPermissions() {
        hasAccessibility = Permissions.hasAccessibility
        hasMicrophone = Permissions.hasMicrophone
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
