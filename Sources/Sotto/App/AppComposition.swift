import Foundation

/// The composition root. Exactly one instance for the life of the process, owned by the
/// AppDelegate; every scene reaches it through the delegate adaptor.
@MainActor
final class AppComposition {
    let controller: DictationController

    init() {
        let controller = DictationController(
            hotkey: HotkeyMonitor(),
            capture: AudioCapture(),
            requestMicrophone: { await Permissions.requestMicrophone() },
            makeEngine: { AppleSpeechEngine(locale: .current, biasPhrases: []) }
        )
        // Batch A1 only logs; the pipeline replaces this closure in batch B1.
        controller.onFinalTranscript = { text, utterance in
            Log.app.info(
                "final transcript: \(text.count, privacy: .public) chars (source: \(utterance.source.rawValue, privacy: .public), held \(utterance.heldSeconds, privacy: .public)s)"
            )
        }
        self.controller = controller
    }
}
