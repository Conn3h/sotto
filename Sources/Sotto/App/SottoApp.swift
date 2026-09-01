import AppKit
import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Sotto", systemImage: "waveform") {
            Button("Quit Sotto") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let accessibilityPollInterval: Duration = .seconds(1)

    let composition: AppComposition
    private var accessibilityPollTask: Task<Void, Never>?

    override init() {
        composition = AppComposition()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // A cold machine pays the speech asset download now rather than on the first hold.
        Task {
            await AppleSpeechEngine.prepare()
        }
        if composition.controller.activate() {
            Log.app.info("hotkey active")
        } else {
            Log.app.error("hotkey activation failed; prompting for Accessibility and polling")
            Permissions.promptForAccessibility()
            startAccessibilityPoll()
        }
        Log.app.info("Sotto ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityPollTask?.cancel()
        composition.controller.deactivate()
        Log.app.info("Sotto terminating")
    }

    /// There is no notification for an Accessibility grant, so poll once a second until the
    /// process is trusted, then activate.
    private func startAccessibilityPoll() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { @MainActor [weak self] in
            var polls = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.accessibilityPollInterval)
                } catch {
                    Log.app.debug("accessibility poll cancelled")
                    return
                }
                polls += 1
                guard let self else {
                    return
                }
                guard Permissions.hasAccessibility else {
                    continue
                }
                if self.composition.controller.activate() {
                    Log.app.info("Accessibility granted after \(polls, privacy: .public) polls; hotkey active")
                    return
                }
                Log.app.error("Accessibility trusted but hotkey activation failed; retrying")
            }
        }
    }

    /// The dictionary file may have been hand-edited while another app was frontmost.
    func applicationDidBecomeActive(_ notification: Notification) {
        DictionaryStore.shared.reloadFromDisk()
    }
}
