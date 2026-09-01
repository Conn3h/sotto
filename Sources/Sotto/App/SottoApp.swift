import AppKit
import Observation
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
    /// Batch B2. Created at launch, presented/dismissed as `controller.state.showsHUD`
    /// changes. Held here rather than on `AppComposition` because this batch owns only
    /// `SottoApp.swift`.
    private var hud: HUDPanel?

    override init() {
        composition = AppComposition()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let hud = HUDPanel(controller: composition.controller)
        self.hud = hud
        observeHUDVisibility()
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

    /// Batch B2. Presents or dismisses the HUD as `controller.state.showsHUD` changes.
    /// `withObservationTracking`'s `onChange` fires once and then stops observing, so it
    /// must re-register itself on every call to keep tracking future changes (§6.15).
    private func observeHUDVisibility() {
        withObservationTracking {
            _ = composition.controller.state
        } onChange: { [weak self] in
            // `onChange` is not guaranteed MainActor-isolated by its signature, even though
            // `state` only ever changes on the main actor; hop explicitly before touching
            // any main-actor state.
            Task { @MainActor in
                guard let self else {
                    return
                }
                if self.composition.controller.state.showsHUD {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeHUDVisibility()
            }
        }
    }
}
