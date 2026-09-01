# Codex spec review, 2026-09-01

Run: `codex exec --sandbox read-only --ignore-user-config -m gpt-5.6-sol -c model_reasoning_effort=xhigh` against docs/SPEC.md v1.0. Every P1 and P2 was folded into v1.1 except where noted in the commit message.

- [P1] A released start can resume into a later utterance - docs/SPEC.md:289  
  The setup task suspends for permission, engine startup, and format lookup, while release can complete teardown and return to `.idle`; after a new press, the stale task’s single late check sees `.starting` again and can install its old engine/capture into the new utterance. This can record after key-up and overwrite a later transcript. Give every utterance a generation ID, validate it after every suspension and in every callback, and never return to `.idle` until that generation’s setup task is cancelled and joined.

- [P1] Terminal transitions are not single-flight - docs/SPEC.md:299  
  Release, engine failure, result-stream failure, and `deactivate()` can interleave at each `await` and independently stop capture, finish/drop the engine, change state, or invoke `onFinalTranscript`; idempotent entry checks do not protect an already-suspended finalizer. Store one terminal task per generation and route every terminal event through it, with exactly one owner of stream closure, engine finish/cancel, final callback, and the transition to `.idle`.

- [P1] Engine finish can discard queued final results - docs/SPEC.md:255  
  `finish()` finalizes the analyzer and immediately yields its own final snapshot, finishes the output stream, and releases the analyzer, but the separately spawned `transcriber.results` task is never specified as awaited. Apple notes that already-published module results may remain to be iterated after the analyzer finishes, so the committed text can still be stale at that point. Await the stored result-drain task after analyzer finalization and before reading committed text or finishing the output stream. [Apple’s SpeechAnalyzer lifecycle documentation](https://developer.apple.com/documentation/speech/speechanalyzer)

- [P1] Failure and quit have no engine-abort contract - docs/SPEC.md:305  
  Cancelling controller tasks and dropping the engine does not terminate the analyzer’s autonomous input processing or its result task; those tasks can retain the actor and continuations indefinitely, especially after startup or capture failure. Add an idempotent `cancel()`/`shutdown()` requirement to `TranscriptionEngine` that closes input, calls `cancelAndFinishNow()`, cancels and awaits the result task, and terminates the output stream; `fail` and `deactivate` must await or otherwise explicitly own that cleanup.

- [P1] Throwing transcript streams have no failure transition - docs/SPEC.md:297  
  The consumer must use `for try await`, yet the specification only says to copy snapshots and never defines what happens when `transcriber.results` throws. An implementation can silently end the consumer while capture and state remain `.listening`, or race `fail` against release. Require the consumer to catch and log the error, associate it with its generation, and enter the same single-flight terminal path.

- [P1] `AudioCapture` suppresses rather than solves data races - docs/SPEC.md:201  
  `@unchecked Sendable` and `nonisolated(unsafe)` provide no synchronization while the audio tap reads converter/callback state and main-actor teardown concurrently stops the engine and clears that state; this is Swift undefined behavior and can crash. Specify a lock or a dedicated serial execution domain around shared state, define the stop-versus-callback handshake, and make level delivery hop to the main actor with a generation check rather than mutating controller state directly.

- [P2] The bounded stream silently drops captured speech - docs/SPEC.md:293  
  `.bufferingNewest(64)` discards the oldest unconsumed buffers when full, contradicting the ordered, lossless data path implied by §4; the return value of `yield` is not checked, so the transcript can omit arbitrary middle sections without a log. Use an unbounded stream for this fast handoff, or explicitly treat `.dropped` as a logged utterance failure and test that policy.

- [P2] `TranscriptSnapshot.isFinal` has no defined meaning - docs/SPEC.md:220  
  A `SpeechTranscriber.Result` can be final for one phrase while the utterance remains active, whereas the engine also emits an utterance-level final snapshot during `finish()`. Independent engines can therefore set `isFinal` incompatibly. Define it as either “this revision is nonvolatile” or “no further snapshots will follow”; for this controller seam, the latter is clearer, with only the terminal snapshot set to `true`.

- [P1] Reloading the hotkey during a hold can leave recording active - docs/SPEC.md:281  
  Settings calls `reloadHotkey()` immediately, while `HotkeyMonitor.stop()` resets `isPressed` without emitting a release. If the selected key changes during a hold, the old physical release is ignored by the new monitor and the microphone can remain open, violating §1. Require reload to terminate the current utterance first, or defer the new key until the controller returns to `.idle`.

- [P2] First-use setup loses speech spoken during the hold - docs/SPEC.md:290  
  Capture starts only after microphone authorization, locale resolution, model download, analyzer startup, and format lookup, which can take seconds or minutes on first use. Everything spoken meanwhile is lost even though the product says “hold a key, speak.” Install/prepare assets before accepting a hold, or explicitly make `.starting` a “wait for the start cue” phase and add acceptance coverage for a cold machine.

- [P2] The Speech setup order cannot be followed literally - docs/SPEC.md:245  
  `assetInstallationRequest(supporting:)` requires an already-configured module and returns `AssetInstallationRequest?`, with `nil` meaning the assets are installed, but the spec places installation before transcriber creation and implies an unconditional `downloadAndInstall()`. Specify: resolve locale; construct `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with exact option sets; `if let` installation request, download it; then obtain the format, create/contextualize the analyzer, streams, and start it. [Apple’s AssetInventory documentation](https://developer.apple.com/documentation/speech/assetinventory/assetinstallationrequest%28supporting%3A%29)

- [P2] The `en-US` fallback is not validated - docs/SPEC.md:244  
  `supportedLocale(equivalentTo:)` returns an optional, and nothing guarantees the fallback itself is supported or allocatable. Constructing the module with an unchecked locale can fail later in asset installation or analyzer startup under the wrong error. Resolve both the requested locale and `Locale(identifier: "en-US")`, guard the final optional, and otherwise throw `localeUnsupported` with the originally requested locale.

- [P2] “No network” contradicts mandatory model fetching - docs/SPEC.md:5  
  `AssetInventory.downloadAndInstall()` may fetch speech assets from Apple; inference is on-device, but first-use provisioning is not necessarily offline. Apple explicitly describes the model as on-device but requiring assets to be fetched. Change the promise to “no app server and no audio/text leaves the device; macOS may download Apple-managed model assets,” or require preinstalled assets and remove downloading. [Apple’s SpeechAnalyzer presentation](https://developer.apple.com/videos/play/wwdc2025/277/)

- [P2] The four-second model timeout is not implementable as an ordinary task-group race - docs/SPEC.md:423  
  Swift structured task groups do not leave scope until all children finish, so cancelling a stalled `respond` child after the timer wins can still block beyond four seconds. Define a concrete timeout primitive using an unstructured request task whose late result is ignored, cancel it on timeout, and specify how outstanding tasks are retained/cleaned up; add a wall-time test so “four seconds” is an actual guarantee.

- [P1] The app has no contract for sharing one controller instance - docs/SPEC.md:615  
  AppDelegate, HUD wiring, SwiftUI scenes, Settings, menu-bar content, and main-window controls must all observe and operate the same controller, but `Composition.makeController()` can create a new instance whenever a consumer calls it and no initializer/environment contract is provided. Define one composition root that owns exactly one controller and pipeline, then state exactly how that instance is passed to AppDelegate and every scene.

- [P2] Later UI agents need design tokens they are not assigned to edit - docs/SPEC.md:665  
  A4 exclusively owns `DesignSystem.swift`, but its required token list omits HUD dimensions/offset/floor and main-window dimensions, while B2/C1 must not place those literals in views and are not assigned that file. Either make A4 define every numeric value named in §6.14 or explicitly give B2 and C1 permission to extend `DesignSystem.swift` in their later batches.

- [P2] Timing lacks a monotonic source and a UI-facing start value - docs/SPEC.md:264  
  `releasedAt: Date` is the only release timestamp, so B1 may calculate latency using wall time—which can jump—and C1 has no controller value from which to render the specified elapsed counter, especially if the window appears mid-hold. Use `ContinuousClock` for held/process durations, retain `Date` only for history display, inject the clock for tests, and expose a read-only current start instant or elapsed duration.

- [P1] Main-window Record cannot preserve the insertion target - docs/SPEC.md:590  
  Clicking Record activates Sotto and focuses the button before recording begins, so `TextInjector` later queries Sotto’s focus rather than the field in the previously active app; paste may consequently do nothing or modify Sotto’s own UI. Remove the main-window transport for v1, or define a target-capture/restore contract that records the external focused element before activation and injects into that same target.

- [P2] Error state is excluded from the HUD state that should display it - docs/SPEC.md:270  
  `isActive` excludes `.error`, app lifecycle says state drives HUD presentation/dismissal, and HUD content is nevertheless required to show the error for the controller’s three-second error period. Define a separate `shouldShowHUD` that includes `.error`, or include error in the presentation condition while keeping recording activity semantics separate.

- [P2] `DictionaryStore` mutation APIs are not actual contracts - docs/SPEC.md:511  
  `func add(_:) func update(_:) func delete(_:)` omits parameter types and leaves C1 unable to know whether deletion accepts an entry, UUID, or index, while B1 can legitimately implement any of them. Spell out the exact signatures, such as `add(_ entry:)`, `update(_ entry:)`, `delete(id:)`, and `delete(ids:)`, including behavior for unknown IDs.

- [P2] Clipboard restoration can overwrite newer user data - docs/SPEC.md:342  
  Restoring the saved pasteboard unconditionally after a fixed delay clobbers anything copied by the user or target application during that window, and 500 ms is not proof that a slow target has consumed the paste. Record `changeCount` immediately after Sotto writes, restore only if it remains unchanged, log when restoration is skipped, and include this race in acceptance testing.

- [P2] Spoken paragraph replacement leaves unspecified horizontal whitespace - docs/SPEC.md:369  
  For `hello new paragraph world`, literal rule application produces `Hello \n\n World.` because the whitespace-collapse rule never removes spaces adjacent to newlines, while a reasonable implementation produces `Hello\n\nWorld.`. Specify normalization of horizontal whitespace immediately before and after every newline and add exact vectors for `new line`, `new paragraph`, leading/trailing phrases, and repeated phrases.

- [P2] CleanupGuard’s filler denominator is ambiguous and can become zero - docs/SPEC.md:390  
  The list can be read as individual tokens or phrases (`i mean`, `you know`, `kind of`, `sort of`); for `I know`, token-wise discounting produces a zero denominator while phrase-wise discounting does not. Define the exact Unicode tokenization and normalization, represent multiword fillers explicitly, say whether the formatter’s base fillers are also included, and define the verdict when the discounted denominator is zero.

- [P2] The dictionary boundary regex contradicts its stated behavior - docs/SPEC.md:471  
  The proposed letter/digit lookarounds still treat hyphens and apostrophes as boundaries, so a `cloud` correction fires inside `cloud-native` and `John` fires inside `John’s`, exactly what the rationale says must not happen. Decide the intended result and make the fence include combining marks, hyphens, and apostrophes if those neighbors must block a match; preserve internal optional separators only within a multi-part trigger.

- [P2] Correction replacement semantics permit incompatible outputs - docs/SPEC.md:470  
  It does not define whether replacements can trigger later rules, how equal-length triggers tie, or what “case-preserving replacement” means. With `foo -> bar` and `bar -> baz`, input `foo` may become `bar` or `baz`; with `cloud -> Claude`, input `CLOUD` may become `Claude` or `CLAUDE`. Specify one-pass versus cascading behavior, the exact length metric and file-order tie-break, and whether replacement casing is always the stored `write` string.

- [P2] The dictionary file API cannot provide the requested round-trip - docs/SPEC.md:442  
  `parse` returns only entries, so ordinary comments are irretrievably discarded even though tests require round-tripping comments; the grammar also does not define which arrow is structural in `x -> y -> z` or how a literal arrow is represented. Either define semantic round-trip with comments intentionally discarded and a first-arrow rule, or introduce a line/document model that preserves comments and escaping.

- [P2] Dictionary warning behavior is deliberately nondeterministic - docs/SPEC.md:490  
  A “short list of ~150 obvious” common words and unspecified message strings allow implementations to warn on different entries, while `id` is the message and tests must cover each warning. Put the exact list and exact stable messages in the spec or a scaffolded resource; alternatively remove the common-word heuristic and retain only the objective length and equality warnings.

- [P2] A1 acceptance does not prove the state-machine invariants - docs/SPEC.md:647  
  The listed log sequence can pass while setup resumes after release, a buffer is dropped, finalization runs twice, a stale task mutates the next utterance, or internal tasks leak; “does not crash” is also not a task-liveness assertion. Add deterministic tests with fake permission, capture, engine, clock, and pipeline dependencies covering release at every suspension point, release/failure/quit races, duplicate release, stale callbacks, feed order, exactly one final callback, and zero live tasks after teardown.

- [P2] A3 has no independent test oracle - docs/SPEC.md:649  
  The producer owns both implementation and tests, and the existing `vectors.json` is empty; category-only requirements let the agent choose whichever interpretation its code already implements, including the boundary and cascade ambiguities above. Populate exact input/expected/applied-correction vectors before A3 begins, and replace the undefined phrase “store test in §6.11” with the specific parser, corrector, bias, and warning tests required.

- [P2] B1 fallback acceptance is neither complete nor repeatable - docs/SPEC.md:651  
  It checks only whichever model availability the test machine happens to have and does not prove the four-second bound, thrown generation errors, guard rejection, cancellation, or late-response suppression. Introduce an injectable model client/availability source and require deterministic cases for unavailable, timeout, each error category, rejected output, successful output, and a measured upper latency bound.

- [P2] The file watcher’s `isSaving` guard cannot suppress its own events - docs/SPEC.md:520  
  Dispatch-source events are delivered asynchronously, normally after the save has cleared `isSaving`, so Sotto can reload its own atomic replacement, regenerate entry IDs, and bump revision unexpectedly. This live inode-rearming watcher is also unnecessary for the basic “editable as a file” product: prefer reload on activation or an explicit Reload command, or specify debouncing plus content fingerprints and descriptor replacement precisely.

- [P3] The regex portability restriction serves no v1 behavior - docs/SPEC.md:481  
  Dictionary triggers are literal and escaped, no public regex syntax exists, and another platform is explicitly a non-goal, so restricting internal regex features for a hypothetical second engine adds constraints without a consumer. Remove this paragraph and specify only the observable matching behavior and test vectors.

## Sound as written

- The macOS 26/Xcode 26 spellings for `SpeechAnalyzer`, `SpeechTranscriber`, `AnalysisContext`, `AnalyzerInput`, analyzer finalization/cancellation, and the named Foundation Models types/options are correct.
- Full transcript snapshots that replace rather than append, plus committed-versus-volatile accumulation, are the right abstraction.
- One ordered audio drain task, deep-copying tap buffers, and converting to the analyzer’s preferred format are essential and should remain.
- The device-specific right-modifier flags, fn pass-through, tap re-enabling, and sole `MainActor.assumeIsolated` exception are correct.
- The nonactivating HUD and its refusal to become key/main are foundational and should not be relaxed.
- Keeping formatting, dictionary correction, injection, and history outside `DictationController`, while applying dictionary corrections even when cleanup is disabled, is the right module boundary.
- Reusing `SottoApp.swift` and `Composition.swift` across successive batches is safe because those edits are sequential, not parallel.