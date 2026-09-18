import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT (CoreML, via FluidAudio) behind the engine seam. Experimental, for
/// side-by-side accuracy testing against `AppleSpeechEngine`. One instance serves one
/// utterance: `start()` once, `feed()` many times, then `finish()` or `cancel()`.
///
/// Live text comes from FluidAudio's sliding-window manager, which decodes overlapping
/// windows of the audio so far and keeps a confirmed prefix plus a volatile tail, the same
/// shape as Apple's final and volatile results. The final transcript is whatever
/// `finish()` returns after the remaining audio is flushed.
actor ParakeetSpeechEngine: TranscriptionEngine {
    private enum Phase: Sendable {
        case idle
        case starting
        case running
        case finishing
        case finished
        case cancelled
        case failed
    }

    /// Parakeet consumes 16 kHz mono Float32. Capture converts to this once, so the
    /// library's own converter takes its no-op fast path.
    private static let sampleRate: Double = 16_000
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )

    private var phase: Phase = .idle
    private var manager: SlidingWindowAsrManager?
    private var outputContinuation: AsyncThrowingStream<TranscriptSnapshot, Error>.Continuation?
    private var drainTask: Task<Void, Never>?
    /// The last transcript shown, kept so a failed `finish()` still hands something back.
    private var latest = ""

    init() {}

    // MARK: TranscriptionEngine

    func preferredInputFormat() async -> AVAudioFormat? {
        if Self.inputFormat == nil {
            Log.speech.error("parakeet: could not build the 16 kHz mono input format")
        }
        return Self.inputFormat
    }

    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        switch phase {
        case .idle:
            break
        case .cancelled:
            Log.speech.info("parakeet start skipped: already cancelled")
            throw CancellationError()
        default:
            Log.speech.error("parakeet start called in phase \(String(describing: self.phase), privacy: .public)")
            throw TranscriptionError.notRunning
        }
        phase = .starting
        do {
            return try await performStart()
        } catch {
            await abandonStart(after: error)
            throw error
        }
    }

    func feed(_ chunk: AudioChunk) async {
        guard phase == .running, let manager else {
            Log.speech.debug("parakeet feed ignored in phase \(String(describing: self.phase), privacy: .public)")
            return
        }
        await manager.streamAudio(chunk.buffer)
    }

    func finish() async {
        switch phase {
        case .finished, .finishing, .cancelled:
            Log.speech.debug("parakeet finish ignored in phase \(String(describing: self.phase), privacy: .public)")
            return
        case .idle, .failed:
            Log.speech.info("parakeet finish with nothing running (phase \(String(describing: self.phase), privacy: .public))")
            phase = .finished
            outputContinuation?.finish()
            await release()
            return
        case .starting:
            Log.speech.info("parakeet finish during start: cancelling instead")
            await cancel()
            return
        case .running:
            break
        }
        phase = .finishing
        var text = latest
        if let manager {
            do {
                text = try await manager.finish()
            } catch {
                Log.speech.error(
                    "parakeet finalize failed: \(error.localizedDescription, privacy: .public); keeping the last live text"
                )
            }
        }
        // The library never ends its update stream on finish; stop the drain by hand once
        // the flush has published everything.
        drainTask?.cancel()
        await drainTask?.value
        guard phase == .finishing else {
            Log.speech.info("parakeet finish pre-empted by cancel")
            return
        }
        let trimmed = Self.trimmed(text)
        outputContinuation?.yield(TranscriptSnapshot(text: trimmed, isFinal: true))
        outputContinuation?.finish()
        phase = .finished
        Log.speech.info("parakeet finished: \(trimmed.count, privacy: .public) chars")
        await release()
    }

    func cancel() async {
        switch phase {
        case .cancelled, .finished:
            return
        default:
            break
        }
        let startInFlight = phase == .starting
        phase = .cancelled
        await manager?.cancel()
        drainTask?.cancel()
        await drainTask?.value
        outputContinuation?.finish(throwing: CancellationError())
        if startInFlight {
            Log.speech.info("parakeet cancelled during start; start releases on resume")
        } else {
            await release()
            Log.speech.info("parakeet cancelled")
        }
    }

    // MARK: Start sequence

    private func performStart() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error> {
        let models = try await ParakeetModels.shared.readyModels()
        try checkLive()

        // The streaming preset is tuned for live feedback; the blank id must match the
        // model version or the decoder falls back to guessing it.
        let config = SlidingWindowAsrConfig.streaming
            .applying(tdtConfig: TdtConfig(blankId: models.version.blankId))
        let manager = SlidingWindowAsrManager(config: config)
        self.manager = manager
        try await manager.loadModels(models)
        try checkLive()

        // The update stream must be taken before streaming starts or early windows are lost.
        let updates = await manager.transcriptionUpdates
        let (output, outputContinuation) = AsyncThrowingStream<TranscriptSnapshot, Error>.makeStream()
        self.outputContinuation = outputContinuation
        latest = ""
        drainTask = Task {
            await self.drainUpdates(updates, from: manager)
        }

        try await manager.startStreaming(source: .microphone)
        try checkLive()
        phase = .running
        Log.speech.info("parakeet start: model \(String(describing: models.version), privacy: .public)")
        return output
    }

    /// Throws when the engine was cancelled or the calling task was, so a suspended
    /// `start()` stops at its next checkpoint instead of finishing a dead session.
    private func checkLive() throws {
        if phase == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func abandonStart(after error: Error) async {
        if error is CancellationError {
            Log.speech.info("parakeet start abandoned: cancelled")
        } else {
            Log.speech.error("parakeet start failed: \(error.localizedDescription, privacy: .public)")
        }
        await manager?.cancel()
        drainTask?.cancel()
        await drainTask?.value
        outputContinuation?.finish(throwing: error)
        if phase != .cancelled {
            phase = .failed
        }
        await release()
    }

    private func release() async {
        drainTask = nil
        outputContinuation = nil
        if let manager {
            await manager.cleanup()
        }
        manager = nil
    }

    // MARK: Results

    /// Each update carries only the window it came from; the running transcript lives on
    /// the manager as a confirmed prefix and a volatile tail, read after every update.
    private func drainUpdates(
        _ updates: AsyncStream<SlidingWindowTranscriptionUpdate>,
        from manager: SlidingWindowAsrManager
    ) async {
        for await update in updates {
            if Task.isCancelled {
                break
            }
            let confirmed = await manager.confirmedTranscript
            let volatile = await manager.volatileTranscript
            let text = Self.trimmed(Self.join(confirmed, volatile))
            latest = text
            outputContinuation?.yield(TranscriptSnapshot(text: text, isFinal: false))
            Log.speech.debug(
                "parakeet update: confirmed \(update.isConfirmed, privacy: .public), confidence \(update.confidence, privacy: .public), \(text.count, privacy: .public) chars"
            )
        }
        Log.speech.debug("parakeet update stream ended")
    }

    /// Concatenates two transcript pieces with a single space between words when neither
    /// side already provides one.
    private static func join(_ head: String, _ tail: String) -> String {
        if head.isEmpty {
            return tail
        }
        if tail.isEmpty {
            return head
        }
        let headEndsInSpace = head.last?.isWhitespace ?? false
        let tailStartsWithSpace = tail.first?.isWhitespace ?? false
        if headEndsInSpace || tailStartsWithSpace {
            return head + tail
        }
        return head + " " + tail
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
