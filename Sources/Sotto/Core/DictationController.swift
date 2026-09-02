import AppKit
import AVFoundation
import Foundation
import Observation

enum UtteranceSource: String, Sendable {
    case hotkey
    case button
}

struct Utterance: Sendable {
    let source: UtteranceSource
    /// Key down to key up, measured with `ContinuousClock`.
    let heldSeconds: TimeInterval
    /// Wall clock, for history display only.
    let releasedAt: Date
}

/// The one-utterance-at-a-time state machine between the hotkey, capture and the engine.
/// Each press starts a generation; every terminal event funnels into one terminal task per
/// generation, which is the only code that finishes the engine, fires the final callback,
/// and returns the controller to idle.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }

        var showsHUD: Bool {
            if case .error = self {
                return true
            }
            return isActive
        }
    }

    private enum TerminalReason {
        case released
        /// A release too brief to be dictation. Cancels the engine like `.aborted`, but is
        /// its own case so the log and the SPEC can tell a mis-tap from a real abort.
        case tapped
        case failed(String)
        case aborted

        /// True only for `.released`: the path that finalizes the engine, fires the callback,
        /// and shows `.finishing`. A tap is deliberately not a release.
        var isRelease: Bool {
            if case .released = self {
                return true
            }
            return false
        }

        var label: String {
            switch self {
            case .released: "released"
            case .tapped: "tapped"
            case .failed: "failed"
            case .aborted: "aborted"
            }
        }
    }

    /// One utterance. Created on press, cleared by the terminal task and by nothing else.
    @MainActor
    private final class Session {
        let id: Int
        let source: UtteranceSource
        let pressedAt: ContinuousClock.Instant
        var releasedAt: ContinuousClock.Instant?
        var releasedDate: Date?
        var engine: (any TranscriptionEngine)?
        var audioContinuation: AsyncStream<AudioChunk>.Continuation?
        var setupTask: Task<Void, Never>?
        var drainTask: Task<Void, Never>?
        var consumeTask: Task<Void, Never>?
        var terminalTask: Task<Void, Never>?

        init(id: Int, source: UtteranceSource, pressedAt: ContinuousClock.Instant) {
            self.id = id
            self.source = source
            self.pressedAt = pressedAt
        }

        var isTerminating: Bool { terminalTask != nil }

        func heldSeconds(now: ContinuousClock.Instant) -> TimeInterval {
            let duration = (releasedAt ?? now) - pressedAt
            let (seconds, attoseconds) = duration.components
            return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
        }
    }

    static let microphoneDeniedMessage =
        "Microphone access is off. Enable it in System Settings > Privacy & Security > Microphone."
    private static let levelSmoothing: Float = 0.35
    private static let startSoundName = "Tink"

    private(set) var state: State = .idle
    /// Live transcript, drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0...1 meter level.
    private(set) var level: Float = 0
    /// For the main window's elapsed counter.
    private(set) var holdStartedAt: Date?
    /// Number of tasks belonging to any utterance that have not completed. Exposed for tests.
    private(set) var liveTaskCount = 0

    /// Receives the final raw transcript once per utterance. Awaited before returning to idle.
    @ObservationIgnored var onFinalTranscript: (@MainActor (String, Utterance) async -> Void)?

    @ObservationIgnored private let hotkey: any HotkeySource
    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let requestMicrophone: @MainActor () async -> Bool
    @ObservationIgnored private let makeEngine: @MainActor () -> any TranscriptionEngine
    @ObservationIgnored private let errorDisplayDuration: Duration
    /// A cap on `engine.finish()` in the terminal path. The engine's
    /// `finalizeAndFinishThroughEndOfInput` can stall when finishing an analyzer that saw
    /// almost no audio (a quick tap released just after listening began), which used to
    /// wedge the controller in `.finishing` forever, ignoring Stop and new presses. If
    /// finish does not return within this, the engine is cancelled and the utterance ends.
    @ObservationIgnored private let engineFinishTimeout: Duration
    /// A release held for less than this is a mis-tap, not dictation: the engine is
    /// cancelled instead of finalized, the state never enters `.finishing`, and no final
    /// callback fires. This is the instant-recovery path for a quick tap (the finalize would
    /// otherwise stall, and even bounded by `engineFinishTimeout` it flashes "Transcribing..."
    /// for the length of the timeout). Real speech, even one short word, comfortably clears
    /// this; anything longer that still captured no usable audio falls back to the bounded
    /// finish. Zero disables the fast path, so a release is always finalized.
    @ObservationIgnored private let minimumHold: Duration
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?

    init(
        hotkey: any HotkeySource,
        capture: any AudioCapturing,
        requestMicrophone: @escaping @MainActor () async -> Bool,
        makeEngine: @escaping @MainActor () -> any TranscriptionEngine,
        errorDisplayDuration: Duration = .seconds(3),
        engineFinishTimeout: Duration = .seconds(2),
        minimumHold: Duration = .milliseconds(250)
    ) {
        self.hotkey = hotkey
        self.capture = capture
        self.requestMicrophone = requestMicrophone
        self.makeEngine = makeEngine
        self.errorDisplayDuration = errorDisplayDuration
        self.engineFinishTimeout = engineFinishTimeout
        self.minimumHold = minimumHold
    }

    // MARK: Public controls

    /// Installs the hotkey from Settings. False means the tap could not be created, which
    /// means Accessibility is not granted.
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in
            self?.press(source: .hotkey)
        }
        hotkey.onRelease = { [weak self] in
            self?.release()
        }
        let started = hotkey.start()
        if !started {
            Log.hotkey.error("hotkey activation failed; Accessibility is required")
        }
        return started
    }

    /// Ends any utterance without a final callback, then stops the hotkey.
    func deactivate() {
        if let session {
            terminate(session, reason: .aborted)
        }
        hotkey.stop()
        Log.app.info("controller deactivated")
    }

    /// Ends any utterance as a release (the physical release will be invisible to the new
    /// monitor), then re-arms the hotkey with the key from Settings.
    @discardableResult
    func reloadHotkey() -> Bool {
        if let session {
            terminate(session, reason: .released)
        }
        hotkey.stop()
        hotkey.key = Settings.shared.pushToTalkKey
        let started = hotkey.start()
        Log.hotkey.info(
            "hotkey reloaded to \(self.hotkey.key.displayName, privacy: .public); running: \(started, privacy: .public)"
        )
        return started
    }

    func startButtonRecording() {
        press(source: .button)
    }

    func stopButtonRecording() {
        release()
    }

    // MARK: Press and release

    private func press(source: UtteranceSource) {
        if let session {
            Log.app.debug(
                "press ignored: utterance \(session.id, privacy: .public) still \(String(describing: self.state), privacy: .public)"
            )
            return
        }
        switch state {
        case .idle, .error:
            break
        case .starting, .listening, .finishing:
            Log.app.error("press ignored: state \(String(describing: self.state), privacy: .public) without a session")
            return
        }
        errorResetTask?.cancel()
        errorResetTask = nil
        generation += 1
        let session = Session(id: generation, source: source, pressedAt: clock.now)
        self.session = session
        state = .starting
        transcript = ""
        level = 0
        holdStartedAt = Date()
        Log.app.info("utterance \(session.id, privacy: .public) press (\(source.rawValue, privacy: .public))")
        session.setupTask = track { [weak self] in
            await self?.runSetup(session)
        }
    }

    private func release() {
        guard let session else {
            Log.app.debug("release ignored: no utterance")
            return
        }
        guard !session.isTerminating else {
            Log.app.debug("release ignored: utterance \(session.id, privacy: .public) already ending")
            return
        }
        terminate(session, reason: .released)
    }

    // MARK: Setup task

    /// True while `session` is the current generation, has no terminal event yet, and this
    /// task has not been cancelled. Checked after every suspension point.
    private func isLive(_ session: Session) -> Bool {
        session === self.session
            && session.id == generation
            && !session.isTerminating
            && !Task.isCancelled
    }

    private func runSetup(_ session: Session) async {
        let microphoneAllowed = await requestMicrophone()
        guard isLive(session) else {
            return
        }
        guard microphoneAllowed else {
            Log.audio.error("microphone access denied; utterance \(session.id, privacy: .public) failed")
            terminate(session, reason: .failed(Self.microphoneDeniedMessage))
            return
        }

        let engine = makeEngine()
        session.engine = engine
        let snapshots: AsyncThrowingStream<TranscriptSnapshot, Error>
        do {
            snapshots = try await engine.start()
        } catch {
            guard isLive(session) else {
                return
            }
            Log.speech.error(
                "engine start failed for utterance \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            terminate(session, reason: .failed(error.localizedDescription))
            return
        }
        guard isLive(session) else {
            return
        }

        guard let format = await engine.preferredInputFormat() else {
            guard isLive(session) else {
                return
            }
            let failure = TranscriptionError.noAudioFormat
            Log.speech.error("utterance \(session.id, privacy: .public): \(failure.localizedDescription, privacy: .public)")
            terminate(session, reason: .failed(failure.localizedDescription))
            return
        }
        guard isLive(session) else {
            return
        }

        // One unbounded stream drained by exactly one task keeps audio in capture order.
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        session.audioContinuation = continuation
        session.drainTask = trackDetached {
            for await chunk in audio {
                if Task.isCancelled {
                    break
                }
                await engine.feed(chunk)
            }
        }

        // The continuation is the generation carrier for buffers: once the terminal task
        // finishes it, late yields from this session's tap are dropped by the stream.
        let generation = session.id
        do {
            try capture.start(
                outputFormat: format,
                onBuffer: { chunk in
                    continuation.yield(chunk)
                },
                onLevel: { [weak self] value in
                    Task { @MainActor in
                        self?.applyLevel(value, generation: generation)
                    }
                }
            )
        } catch {
            Log.audio.error(
                "capture start failed for utterance \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            terminate(session, reason: .failed(error.localizedDescription))
            return
        }

        state = .listening
        Log.app.info("utterance \(session.id, privacy: .public) listening")
        if Settings.shared.soundEnabled {
            playStartSound()
        }
        session.consumeTask = track { [weak self] in
            await self?.consume(snapshots, for: session)
        }
    }

    private func consume(
        _ snapshots: AsyncThrowingStream<TranscriptSnapshot, Error>,
        for session: Session
    ) async {
        do {
            for try await snapshot in snapshots {
                guard session === self.session, !Task.isCancelled else {
                    return
                }
                transcript = snapshot.text
            }
            Log.speech.debug("snapshot stream ended for utterance \(session.id, privacy: .public)")
        } catch is CancellationError {
            Log.speech.debug("snapshot stream cancelled for utterance \(session.id, privacy: .public)")
        } catch {
            Log.speech.error(
                "snapshot stream failed for utterance \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            terminate(session, reason: .failed(error.localizedDescription))
        }
    }

    private func applyLevel(_ value: Float, generation: Int) {
        guard let session, session.id == generation, !session.isTerminating else {
            return
        }
        level += (value - level) * Self.levelSmoothing
    }

    // MARK: Terminal task

    /// The only path out of an utterance. The first terminal event wins; a failure after a
    /// release is logged and ignored.
    private func terminate(_ session: Session, reason requestedReason: TerminalReason) {
        guard session === self.session else {
            Log.app.debug("terminal event \(requestedReason.label, privacy: .public) for stale utterance \(session.id, privacy: .public) ignored")
            return
        }
        if session.isTerminating {
            if case .failed(let message) = requestedReason {
                Log.app.error(
                    "utterance \(session.id, privacy: .public) failure after terminal event ignored: \(message, privacy: .public)"
                )
            }
            return
        }
        session.setupTask?.cancel()
        let releasedInstant = clock.now
        session.releasedAt = releasedInstant
        session.releasedDate = Date()

        // A release held for less than `minimumHold` is a mis-tap, not dictation: cancel the
        // engine instead of finalizing it, so the utterance never enters `.finishing` and
        // recovery is instant. `minimumHold == .zero` never triggers this (a hold is never
        // negative), so tests that release immediately keep the finalize path.
        let reason: TerminalReason
        if requestedReason.isRelease, (releasedInstant - session.pressedAt) < minimumHold {
            reason = .tapped
            Log.app.info(
                "utterance \(session.id, privacy: .public) released after \(session.heldSeconds(now: releasedInstant), privacy: .public)s; treating as a tap, cancelling"
            )
        } else {
            reason = requestedReason
        }

        capture.stop()
        level = 0
        if reason.isRelease {
            state = .finishing
        }
        Log.app.info("utterance \(session.id, privacy: .public) terminal event: \(reason.label, privacy: .public)")
        session.terminalTask = track { [weak self] in
            await self?.runTerminal(session, reason: reason)
        }
    }

    private func runTerminal(_ session: Session, reason: TerminalReason) async {
        // 1. A suspended setup must not resume into a dead utterance.
        session.setupTask?.cancel()
        await session.setupTask?.value

        // 2. Close the audio path; on release the drain still delivers everything captured.
        capture.stop()
        session.audioContinuation?.finish()
        if !reason.isRelease {
            session.drainTask?.cancel()
        }
        await session.drainTask?.value

        // 3. Finish or cancel the engine; this is the only place either happens. On a
        // release, finish is bounded so a stalled finalize (a quick tap) cannot wedge the
        // utterance in `.finishing` forever.
        if let engine = session.engine {
            if reason.isRelease {
                await finishBounded(engine, utterance: session.id)
            } else {
                await engine.cancel()
            }
        }

        // 4. The consume task ends when the snapshot stream finishes.
        await session.consumeTask?.value

        // 5. Hand over the final text.
        if reason.isRelease {
            let raw = transcript
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.app.info("utterance \(session.id, privacy: .public) blank transcript; no callback")
            } else {
                let utterance = Utterance(
                    source: session.source,
                    heldSeconds: session.heldSeconds(now: clock.now),
                    releasedAt: session.releasedDate ?? Date()
                )
                Log.app.info(
                    "utterance \(session.id, privacy: .public) final transcript ready: \(raw.count, privacy: .public) chars, held \(utterance.heldSeconds, privacy: .public)s"
                )
                await onFinalTranscript?(raw, utterance)
            }
        }

        // 6. Back to idle (or error).
        guard session === self.session else {
            Log.app.error("utterance \(session.id, privacy: .public) was replaced before its terminal task finished")
            return
        }
        self.session = nil
        holdStartedAt = nil
        switch reason {
        case .released, .tapped, .aborted:
            state = .idle
        case .failed(let message):
            state = .error(message)
            scheduleErrorReset(message, generation: session.id)
        }
        // This terminal task is still counted until it returns, so the number after it
        // completes is one less.
        Log.app.info(
            "utterance \(session.id, privacy: .public) ended (\(reason.label, privacy: .public)); liveTaskCount after this task: \(self.liveTaskCount - 1, privacy: .public)"
        )
    }

    private func scheduleErrorReset(_ message: String, generation: Int) {
        errorResetTask?.cancel()
        errorResetTask = Task { @MainActor [weak self, errorDisplayDuration] in
            do {
                try await Task.sleep(for: errorDisplayDuration)
            } catch {
                Log.app.debug("error display timer cancelled")
                return
            }
            guard let self, self.generation == generation, self.state == .error(message) else {
                return
            }
            self.state = .idle
        }
    }

    // MARK: Task bookkeeping

    /// Awaits `engine.finish()` but never lets it hang the utterance. If finish does not
    /// return within `engineFinishTimeout`, cancel the engine (its abort path ends the
    /// analyzer and unblocks the stalled finalize) and stop waiting, so the terminal task
    /// proceeds and the controller leaves `.finishing`. The finish task then completes on
    /// its own once cancel unblocks it.
    private func finishBounded(_ engine: any TranscriptionEngine, utterance: Int) async {
        let latch = RaceLatch()
        let finish = Task { @MainActor in
            await engine.finish()
            latch.resolve(true)
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: engineFinishTimeout)
            latch.resolve(false)
        }
        if await latch.value() {
            timer.cancel()
        } else {
            Log.app.error(
                "utterance \(utterance, privacy: .public) engine finish timed out; cancelling to unblock"
            )
            await engine.cancel()
            finish.cancel()
        }
    }

    /// A one-shot latch: the first `resolve` wins and wakes the single waiter; later resolves
    /// are dropped. Main-actor isolated, so it needs no lock. Used to race `engine.finish()`
    /// against a timeout without a structured task group (which would wait for the stalled
    /// finish child).
    @MainActor
    private final class RaceLatch {
        private var result: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        func resolve(_ value: Bool) {
            guard result == nil else { return }
            result = value
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: value)
            }
        }

        func value() async -> Bool {
            if let result {
                return result
            }
            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    private func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        liveTaskCount += 1
        return Task { @MainActor [weak self] in
            await body()
            self?.liveTaskCount -= 1
        }
    }

    private func trackDetached(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        liveTaskCount += 1
        return Task.detached(priority: .userInitiated) { [weak self] in
            await body()
            await self?.detachedTaskCompleted()
        }
    }

    private func detachedTaskCompleted() {
        liveTaskCount -= 1
    }

    private func playStartSound() {
        guard let sound = NSSound(named: NSSound.Name(Self.startSoundName)) else {
            Log.app.error("start sound \(Self.startSoundName, privacy: .public) not found")
            return
        }
        if !sound.play() {
            Log.app.error("start sound \(Self.startSoundName, privacy: .public) did not play")
        }
    }
}
