import Foundation

/// The composition root. Exactly one instance for the life of the process, owned by the
/// AppDelegate; every scene reaches it through the delegate adaptor.
@MainActor
final class AppComposition {
    let controller: DictationController
    let pipeline: UtterancePipeline
    // hud is added by milestone B2

    init() {
        let pipeline = UtterancePipeline()
        let controller = DictationController(
            hotkey: HotkeyMonitor(),
            capture: AudioCapture(),
            requestMicrophone: { await Permissions.requestMicrophone() },
            // Read per press so a dictionary edit biases the very next hold.
            makeEngine: { AppleSpeechEngine(locale: .current, biasPhrases: DictionaryStore.shared.biasPhrases) }
        )
        controller.onFinalTranscript = { raw, utterance in
            await pipeline.process(raw: raw, utterance: utterance)
        }
        self.controller = controller
        self.pipeline = pipeline
    }
}
