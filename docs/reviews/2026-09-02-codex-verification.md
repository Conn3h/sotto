# Codex verification review, 2026-09-02

Run: `codex exec --sandbox read-only --ignore-user-config -m gpt-5.6-sol -c model_reasoning_effort=xhigh` against main at b5c1c7e (all batches merged, 141 tests green, installed and exercised by hand: three hotkey dictations into a terminal landed correctly). Codex could not run `make test` inside its read-only sandbox; the orchestrator's own run was green.

## Fix batch 1 (triaged, all accepted unless noted)

Two agents in worktrees, disjoint files. Shared new API, defined here so both can build against it: `DictionaryFile.representabilityIssues(for entry: DictionaryEntry) -> [DictionaryRepresentabilityIssue]` in SottoDictionary, a pure function returning `.blankWrite`, `.blankHear` (corrections only), `.commentPrefix` (write or hear starts with `#`), `.containsArrow` (either side contains `->`), each with a user-readable `message`. `DictionaryStore.add`/`update` refuse and log when the list is non-empty; the panel shows the messages and disables Save.

Agent F1 (session model: concurrency and stores):
- P1 TextInjector: restoration must not escape the utterance lifecycle. Serialise it: keep the pending restore task on the injector, await it before the next paste snapshots the pasteboard, and perform any pending restore synchronously on app termination. Do not extend `.finishing` by 500 ms (rapid re-press must stay possible). `processSeconds` stays pipeline-measured.
- P1 DictionaryStore: set `lastStamp` only after a successful read; keep a `loadFailed` state; refuse mutations while set (logged) until a later reload succeeds.
- P1 HistoryLog: `loadReport()` distinguishes read failure from empty; `delete(ids:)` aborts on read failure; `clear()` may proceed.
- P2 AppleSpeechEngine: a result-stream failure during `.starting` must surface: finish the output continuation for `.starting` as well as `.running`, retain the error, and make `start()` throw it after `analyzer.start` resumes.
- P2 DictionaryCorrector: replace the `try?` regex compile with do/catch and a module logger (`import os` under `#if canImport(os)`), plus a test on the failure path or the logging seam.
- P2 Unlogged Boolean APIs: log failures of `NSPasteboard.setString`, `NSSound.play`, `NSApp.setActivationPolicy`.
- P2 Test signal: make `FakeEngine.feed` suspendable and re-assert order and no-drop with 100 buffers arriving while feed is blocked; rename or strengthen `unknownIdsAreLoggedNoOps` to assert observable state only.
- P2 Pipeline tests: add injectable seams (settings snapshot, corrector, history recorder, injector) and tests for: button utterances are not injected; corrections run with cleanup off; history rows carry source; empty text skips inject and history.
- NEW (from the first hand test): consecutive dictations concatenate with no separating space ("working?5.one"). On the AX path, read the character before the caret and prepend a space when it is not whitespace and the field is not empty. The paste path cannot read the target; leave it and document.
- NEW: `installAssetsIfNeeded` logs "download starting/finished" on every utterance even when nothing downloads (4 ms). Log one line with the elapsed time instead, and only call it a download when it took longer than 250 ms.

Agent S1 (sonnet: UI):
- P1 DictionaryPanel: call `DictionaryFile.representabilityIssues` on the draft, show messages inline, disable Save while non-empty; refresh `draftWrite`/`draftHear` from the entry whenever Edit begins.
- P2 Literal values: add DS tokens (`DS.Color.clear`, `DS.Space.none`, `DS.Font.icon`, `DS.Metric.hudLineCount`) and replace every literal in Components, MainWindow, HistoryPanel, DictionaryPanel, HUDView.
- P3 HistoryPanel copy feedback: store the task, cancel on replacement and disappearance.

Deferred to spec section 11: paste-path leading space; live dictionary file watching.

---

## Findings as reported

- [P1] Pasteboard restoration escapes the serialized utterance lifecycle - Sources/Sotto/Core/TextInjector.swift:125  
  The paste path returns after spawning an untracked 500 ms restoration task. A second short dictation can therefore snapshot the first dictation as the “original” clipboard and restore it permanently; quitting during that window also leaves dictated text on the clipboard. It also under-reports `processSeconds`. Await the completion delay and restoration inside `insertViaPasteboard`; the controller will remain finishing and prevent overlapping utterances without blocking the main actor.

- [P1] A transient initial dictionary read failure can lead to overwriting the existing dictionary - Sources/Sotto/Dictionary/DictionaryStore.swift:45  
  Initialization records `lastStamp` before confirming `read()` succeeded. A later reload then treats the unread file as unchanged, while the UI exposes an empty store; adding an entry can atomically replace the original file with only that entry. Set `lastStamp` only after a successful read, retain a load-failed state, and refuse destructive saves until the existing file has been loaded or explicitly recovered.

- [P1] Deleting one history row can erase the entire log after a read failure - Sources/Sotto/History/HistoryLog.swift:66  
  `loadReport()` represents an I/O read failure as the same empty-run result as a genuinely empty file, so `delete(ids:)` proceeds to rewrite that result. If reading fails while atomic replacement remains possible, all history is lost. Return a success/failure result from `loadReport()` and abort deletion on read failure.

- [P1] The dictionary UI persists entries the file format later discards or reinterprets - Sources/Sotto/UI/DictionaryPanel.swift:195  
  Editing a correction permits a blank `hear` value because Save validates only `draftWrite`; reload then drops the serialized ` -> write` line. Terms beginning with `#` disappear as comments, while terms containing `->` return as corrections, violating semantic round-trip and potentially enabling unintended rewrites. Centralize representability validation in `DictionaryStore`, reject these inputs with a visible warning and log, or extend the file-format contract with escaping and tests.

- [P1] Reloaded dictionary edits can be overwritten by stale row state - Sources/Sotto/UI/DictionaryPanel.swift:132  
  `draftWrite` and `draftHear` are initialized into `@State` only once. When `reloadFromDisk()` preserves an entry ID but changes its text, the row displays the new value while entering Edit resurrects the old draft; Save then overwrites the hand-edited file. Refresh drafts when Edit begins or synchronize them with `entry` changes while not editing.

- [P2] A result-stream failure during analyzer startup is logged but never reaches the controller - Sources/Sotto/Speech/AppleSpeechEngine.swift:274  
  The result drain begins before `analyzer.start` completes, but it finishes the output stream on failure only when `phase == .running`. Actor scheduling can deliver an early failure while phase is `.starting`; startup then reports success and the controller waits on a stream that was never terminated. Finish the output continuation for both `.starting` and `.running`, or retain the error and make `start()` throw after `analyzer.start` resumes.

- [P2] A prohibited `try?` silently removes dictionary correction rules - Sources/SottoDictionary/DictionaryCorrector.swift:85  
  Regex compilation uses `try?` with no adjacent log, directly violating §4.6 and §6.1. Although generated patterns should be valid, any failure silently omits that correction. Replace it with `do`/`catch`, log public diagnostic context through a module logger, and add a test for the failure path.

- [P2] Several fallible Boolean APIs discard failures without logging - Sources/Sotto/UI/HistoryPanel.swift:167  
  History Copy ignores `NSPasteboard.setString`, both start/end sounds ignore `NSSound.play()` at `DictationController.swift:503` and `UtterancePipeline.swift:106`, and launch ignores `NSApp.setActivationPolicy` at `SottoApp.swift:61`. These operations can fail silently despite the every-failure-logged rule. Check each result and log the attempted operation using counts or fixed labels, never transcript text.

- [P2] Views still contain literal visual values outside DS - Sources/Sotto/UI/Components.swift:159  
  `SwiftUI.Color.clear` is used directly, an icon font is constructed with `.system`, and literal zero spacing/minimum lengths appear in `MainWindow.swift:18`, `HistoryPanel.swift:26`, and `DictionaryPanel.swift:15`; `HUDView.swift:37` also hard-codes its line count. Add explicit DS tokens such as clear, none, icon font, and HUD line count, then replace every literal view value.

- [P2] The audio-order test can stay green with implementations that violate the invariant - Tests/SottoAppTests/DictationControllerTests.swift:357  
  `fiftyBuffersArriveInOrder` would pass with a bounded buffer of exactly 50 and can pass a task-per-buffer implementation because `FakeEngine.feed` never suspends. `DictionaryStoreTests.unknownIdsAreLoggedNoOps` likewise never observes logging and passes if every log call is removed. Suspend the fake feed while overflowing a deliberately small bound, introduce reorder-inducing delays, and capture logs or rename/split the logging assertion.

- [P2] Critical cross-module behavior has no test signal - Sources/Sotto/Core/UtterancePipeline.swift:32  
  No test invokes `UtterancePipeline`, real `AudioCapture`, `AppleSpeechEngine`, or `TextInjector`. Consequently all tests remain green if button utterances are injected, corrections stop running when cleanup is off, history source is wrong, bias phrases stop reaching the engine, tap buffers are forwarded without copying, or clipboard restoration overlaps. Add injectable settings/corrector/history seams and focused pipeline tests, plus audio conversion/copy tests and a serialized pasteboard restoration test.

- [P3] Copy-feedback tasks outlive their history row and race repeated clicks - Sources/Sotto/UI/HistoryPanel.swift:169  
  Each Copy click creates an untracked task that later mutates `showCopied`; deleting the row leaves the task alive, and an earlier click can clear feedback less than 1.4 seconds after a later click. Store the task, cancel it before replacement and on disappearance, then clear the handle on completion.

## Verified sound

- HUD configuration is borderless and nonactivating, with both `canBecomeKey` and `canBecomeMain` permanently false.
- Capture converts to the exact engine-provided format and deep-copies buffers when conversion is unnecessary; mutable capture ownership is guarded by `Mutex`.
- The controller uses one unbounded audio stream and one drain task, closes it before engine finish, and preserves feed order.
- One session and terminal task own each generation; stale buffers, levels, snapshots, setup resumptions, duplicate releases, and error timers are guarded appropriately.
- `AppleSpeechEngine.finish()` awaits its result drain before emitting the final snapshot; finish/cancel are phase-idempotent, and bias phrases are installed before audio starts.
- Pipeline code applies dictionary corrections regardless of cleanup, injects only hotkey utterances, records source, and composition forwards current bias phrases to each engine.
- `reloadFromDisk()` preserves IDs by `(kind, hear, write)`, including reordering and enabled-state changes.
- `MainActor.assumeIsolated` appears only in the documented event-tap callback. Logger interpolations inspected carry public privacy where required, and transcript content is logged only by length.
- No gradients or emoji were found. Accent and meter colours are confined to their semantic uses, apart from the specification-mandated TokenSheet previews.
- Deterministic formatter, cleanup guard, dictionary-vector, controller generation, double-finish, timeout, history-source, and ID-preservation tests otherwise assert meaningful outputs.
- `make test` and `make app` were attempted but the read-only sandbox denied `xcrun` temporary/cache writes before compilation; no green execution result is claimed.