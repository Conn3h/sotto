import AppKit
import Foundation
import SottoDictionary
import SottoText

/// Everything that happens after a transcript is final: format, dictionary corrections,
/// injection into the focused app (hotkey utterances only), the history record, and the
/// end sound. The controller awaits `process` before returning to idle.
@MainActor
final class UtterancePipeline {
    /// The settings one utterance runs under, read once at the top of `process` so a
    /// change made mid-utterance cannot split the run.
    struct SettingsSnapshot: Sendable {
        let cleanupEnabled: Bool
        let smartCleanup: Bool
        let soundEnabled: Bool
    }

    typealias SettingsReader = @MainActor () -> SettingsSnapshot
    typealias CorrectorProvider = @MainActor () -> DictionaryCorrector
    typealias HistoryRecorder = @MainActor (DictationRun) -> Void
    typealias Injector = @MainActor (String) async -> Void
    typealias SoundPlayer = @MainActor () -> Void

    private static let endSoundName = "Pop"

    private let engineName: String
    private let readSettings: SettingsReader
    private let makeCorrector: CorrectorProvider
    private let recordHistory: HistoryRecorder
    private let inject: Injector
    private let playEndSound: SoundPlayer
    private let clock = ContinuousClock()

    /// Every closure is a seam for tests. The app uses the defaults: the shared settings
    /// and dictionary, the history log, the focused app, and the system end sound.
    init(
        engineName: String = "Apple",
        readSettings: @escaping SettingsReader = UtterancePipeline.readSharedSettings,
        makeCorrector: @escaping CorrectorProvider = { DictionaryStore.shared.corrector },
        recordHistory: @escaping HistoryRecorder = { run in HistoryLog.record(run) },
        inject: @escaping Injector = { text in await TextInjector.insert(text) },
        playEndSound: @escaping SoundPlayer = UtterancePipeline.playSystemEndSound
    ) {
        self.engineName = engineName
        self.readSettings = readSettings
        self.makeCorrector = makeCorrector
        self.recordHistory = recordHistory
        self.inject = inject
        self.playEndSound = playEndSound
    }

    func process(raw: String, utterance: Utterance) async {
        let entered = clock.now
        let settings = readSettings()
        let formatter = Self.formatter(cleanupEnabled: settings.cleanupEnabled, smartCleanup: settings.smartCleanup)
        let formatted = await formatter.text.format(raw)

        // Corrections run regardless of the cleanup setting: biasing only raises the odds
        // of the right word, the correction pass guarantees it.
        let corrected = makeCorrector().apply(to: formatted)
        let text = corrected.text
        Log.app.info(
            "pipeline: \(formatter.name, privacy: .public) cleanup, \(raw.count, privacy: .public) -> \(text.count, privacy: .public) chars, \(corrected.applied.count, privacy: .public) corrections applied"
        )
        guard !text.isEmpty else {
            Log.app.info("pipeline: nothing left after cleanup; nothing inserted or recorded")
            return
        }

        // Pressing Record in Sotto's own window focuses that button, so a button-started
        // utterance is recorded to history (Copy is one click away) and never injected.
        switch utterance.source {
        case .hotkey:
            await inject(text)
        case .button:
            Log.app.info("pipeline: button utterance recorded, not typed (\(text.count, privacy: .public) chars)")
        }

        let processSeconds = Self.seconds(clock.now - entered)
        let run = DictationRun(
            date: utterance.releasedAt,
            engine: engineName,
            source: utterance.source.rawValue,
            audioSeconds: utterance.heldSeconds,
            processSeconds: processSeconds,
            text: text,
            corrections: corrected.applied.isEmpty ? nil : corrected.applied
        )
        recordHistory(run)

        if settings.soundEnabled {
            playEndSound()
        }
        Log.app.info(
            "pipeline: done in \(processSeconds, format: .fixed(precision: 3), privacy: .public)s (\(utterance.source.rawValue, privacy: .public), \(text.count, privacy: .public) chars)"
        )
    }

    /// The production settings reader: one snapshot of `Settings.shared`.
    static func readSharedSettings() -> SettingsSnapshot {
        let settings = Settings.shared
        return SettingsSnapshot(
            cleanupEnabled: settings.cleanupEnabled,
            smartCleanup: settings.smartCleanup,
            soundEnabled: settings.soundEnabled
        )
    }

    /// Cleanup off: passthrough. Smart cleanup on and the model available: the Foundation
    /// Model formatter. Otherwise the rules.
    private static func formatter(cleanupEnabled: Bool, smartCleanup: Bool) -> (name: String, text: any TextFormatter) {
        guard cleanupEnabled else {
            return ("passthrough", PassthroughFormatter())
        }
        if smartCleanup {
            if FoundationModelFormatter.isAvailable {
                return ("smart", FoundationModelFormatter())
            }
            let reason = FoundationModelFormatter.unavailableReason ?? "no reason given"
            Log.app.info("smart cleanup is on but unavailable (\(reason, privacy: .public)); using rules")
        }
        return ("rules", RuleBasedFormatter())
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// The system "Pop" sound marks the moment the text has landed.
    static func playSystemEndSound() {
        guard let sound = NSSound(named: NSSound.Name(endSoundName)) else {
            Log.app.error("end sound \(endSoundName, privacy: .public) not found")
            return
        }
        if !sound.play() {
            Log.app.error("end sound \(endSoundName, privacy: .public) did not play")
        }
    }
}
