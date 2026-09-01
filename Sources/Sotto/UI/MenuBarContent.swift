import AppKit
import SwiftUI

/// The menu bar item's dropdown (spec §6.14). `SottoApp` swaps the item's own icon between
/// `waveform` and `waveform.circle.fill` as `controller.state.isActive` changes; this view is
/// only the menu below it.
@MainActor
struct MenuBarContent: View {
    let controller: DictationController

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
            .disabled(true)

        Divider()

        Button("Open Sotto") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        SettingsLink {
            Text("Settings…")
        }

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") {
                Permissions.openAccessibilitySettings()
            }
        }

        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") {
                Permissions.openMicrophoneSettings()
            }
        }

        Divider()

        Button("Quit Sotto") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
