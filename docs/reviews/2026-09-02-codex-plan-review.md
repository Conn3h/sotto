# Performance and latency plan review

This review is grounded in the current `docs/SPEC.md`, `CLAUDE.md`, every existing source and test file named by the plan, and the installed Xcode 26.4.1/macOS 26.4 SDK declarations. No build or test command was run.

## 1. macOS and Swift API correctness

### Periodic timelines do not have a `paused:` overload

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/UI/MainWindow.swift`
- **Plan task:** 4
- **Problem:** The macOS 26.4 SDK exposes `.periodic(from:by:)` only; the plan's claim that `PeriodicTimelineSchedule` gained `paused:` on macOS 15 is false, so the primary snippet does not compile and the flagged fallback concern is real.
- **Correction:** Make the conditional-view implementation mandatory: render `TimelineView(.periodic(from:by:))` only while active and visible, and render an identically styled static idle `Text` otherwise. `.animation(minimumInterval:paused:)` is valid and can remain on the meter.

### A throwaway session is not a documented prewarm for a later session

- **Severity:** P1 blocking
- **File path:** `Sources/Sotto/Cleanup/CleanupModel.swift`, `Sources/Sotto/App/SottoApp.swift`
- **Plan task:** 10
- **Problem:** Apple defines `prewarm(promptPrefix:)` as eagerly loading resources required **for this session** and recommends following it with a response on that session; there is no contract that discarding it transfers the benefit to the fresh session created by `cleanup`, so Task 10 does not reliably fix the cold call ([Apple documentation](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm%28promptprefix%3A%29)).
- **Correction:** Create and retain the exact one-shot `LanguageModelSession` that the ensuing cleanup will consume, prewarm it on the strong user signal, and discard it after that utterance (including timeout/failure). Prewarming does not itself add a user prompt; one session per utterance avoids cross-utterance transcript growth. Treat launch prewarm as a retained first-use session, and log “prewarm requested,” because the API does not guarantee immediate loading.

### `AXValueCreate` failure is assigned the wrong tri-state

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/Core/TextInjector.swift`
- **Plan task:** 11
- **Problem:** The AX function signatures and parameter types are correct, but `AXValueCreate(.cfRange, &range) == nil` returns `.some(nil)`, which means “known start/no preceding character” and suppresses the full-value fallback; the creation failure and parameterized-read failure are also unlogged.
- **Correction:** Log and return outer `nil` on AX value creation failure, AX error, wrong result type, or an unexpectedly empty result so the existing full-value fallback runs. Reserve `.some(nil)` for a genuine no-character case. The `Character??` design itself is valid.

## 2. Task 8: capture-before-engine reorder

### A release during `engine.start()` discards every captured startup buffer

- **Severity:** P1 blocking
- **File path:** `Sources/Sotto/Core/DictationController.swift`
- **Plan task:** 8
- **Problem:** The FIFO preserves pre-start buffers only if setup reaches drain creation; on a release while `engine.start()` is suspended, `terminate` cancels and awaits setup, no drain is ever installed, and the terminal task finishes the continuation and calls `finish` with all queued audio unfed.
- **Correction:** Redesign the release path so it stops capture and seals the audio stream but permits/awaits the engine-readiness task; after a successful start, install exactly one drain and consume task, drain the sealed FIFO, and only then finish the engine. Failure/abort may cancel and discard. Cover a short press released before engine readiness and require its captured buffers to be fed in order.

### Publishing `.listening` before readiness breaks the controller's test and consumer barrier

- **Severity:** P1 blocking
- **File path:** `Sources/Sotto/Core/DictationController.swift`, `Tests/SottoAppTests/DictationControllerTests.swift`, `Tests/SottoAppTests/Fakes.swift`
- **Plan task:** 8
- **Problem:** Current tests and `Harness.pressAndListen()` use `.listening` to mean that engine start, drain, and snapshot consumption are ready; moving it before `engine.start()` makes the new test's “listening” wait return immediately and makes existing publish/feed/release tests race setup.
- **Correction:** Keep the state `.starting` while capture buffers, then install drain/consume after `engine.start()`, set `.listening`, and play the start sound. Measure the latency win at “capture start,” not by redefining “listening.” If early `.listening` is retained instead, add a distinct observable readiness barrier and update every consumer, helper, test, and spec statement that relies on the old meaning.

### The order-sensitive test updates are incomplete

- **Severity:** P1 blocking
- **File path:** `Tests/SottoAppTests/DictationControllerTests.swift`
- **Plan task:** 8
- **Problem:** Besides the suspended-start test, `engineStartFailureShowsErrorThenIdle` currently requires `capture.startCalls == 0` and must expect a start plus stop after the reorder; the proposed early-buffer test also releases as soon as the already-early `.listening` state is observed, before feed readiness.
- **Correction:** Audit all uses of `pressAndListen` and all start/capture assertions, update engine-start-failure cleanup expectations, and make the early-buffer test wait for an explicit drain/feed-ready signal (or retain the existing `.listening` readiness semantics).

### An indefinitely suspended analyzer creates unbounded microphone buffering

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/Core/DictationController.swift`
- **Plan task:** 8
- **Problem:** Capture begins before analyzer readiness and the stream is deliberately unbounded, so a stalled `engine.start()` can retain audio for the entire hold with no consumer and no startup deadline.
- **Correction:** Add a bounded analyzer-start deadline that stops capture and fails the utterance with a logged error. Keep the stream unbounded while startup is valid; do not introduce a dropping buffer policy.

## 3. SPEC contract violations

### Task 8's §6.7 edit does not reconcile the release path with the no-drop invariant

- **Severity:** P1 blocking
- **File path:** `docs/SPEC.md`, `Sources/Sotto/Core/DictationController.swift`
- **Plan task:** 8
- **Problem:** Replacing the §6.7 setup list documents capture-before-start, but it does not cover the startup-release loss above, which contradicts §4 invariant 2 (“nothing is dropped”), and it does not explicitly redefine `.listening` if that state is published before engine readiness.
- **Correction:** Preserve §4 by implementing release-time draining, then update §6.7 with the precise capture/start/drain/consume/terminal order. Keep `.listening` after readiness, or explicitly update the state, HUD, sound, acceptance, and test contracts if its meaning changes.

### Task 9 silently changes the documented history contract

- **Severity:** P1 blocking
- **File path:** `docs/SPEC.md`, `Sources/Sotto/History/HistoryLog.swift`, `Sources/Sotto/History/HistoryStore.swift`
- **Plan task:** 9
- **Problem:** SPEC §6.13 explicitly says `record`, `delete`, and `clear` reload `HistoryStore`, while the plan changes successful `record` to an in-memory prepend and includes no spec edit.
- **Correction:** Edit §6.13 in Task 9 to state that successful append prepends the known run, append failure reloads, and successful rewrites replace the store from the known file order. The last point also brings the spec in line with the current delete/clear implementation.

### Task 10 changes a specified seam and lifecycle without spec edits

- **Severity:** P1 blocking
- **File path:** `docs/SPEC.md`, `Sources/Sotto/Cleanup/CleanupModel.swift`, `Sources/Sotto/App/SottoApp.swift`
- **Plan task:** 10
- **Problem:** SPEC §6.10 defines the complete `CleanupModel` interface without `prewarm()`, and §6.15 defines launch/state observation without cleanup warmup; Task 10 changes both contracts but does not list `docs/SPEC.md`.
- **Correction:** After correcting the same-session design, update §6.10 with its one-shot prewarm/consume lifecycle and §6.15 with the chosen launch/listening hook in the same task.

### Task 12 edits the wrong spec text and leaves the roadmap contradictory

- **Severity:** P1 blocking
- **File path:** `docs/SPEC.md`, `Sources/Sotto/Core/TextInjector.swift`
- **Plan task:** 12
- **Problem:** The quoted claim that the paste path cannot read the target and never adds space exists in the source comment at `TextInjector.needsLeadingSpace`, not in SPEC §6.8; meanwhile SPEC §11 explicitly leaves paste-path leading space for “Later,” so the proposed §6.8 replacement cannot be made and §11 would contradict the new behavior.
- **Correction:** Add the bounded same-app rule and false-positive tradeoff to §6.8, remove the corresponding §11 item, and update the source comment in `TextInjector.swift`.

## 4. Swift 6 strict concurrency and actor isolation

### The notification observer directly calls a main-actor view from an `@Sendable` closure

- **Severity:** P1 blocking
- **File path:** `Sources/Sotto/UI/WindowVisibilityReader.swift`
- **Plan task:** 3
- **Problem:** The macOS 26 Foundation declaration marks the `NotificationCenter.addObserver` block `@Sendable`; `queue: .main` is only a runtime delivery choice, so directly capturing `TrackingView` and calling its main-actor `report()` is not valid Swift 6 isolation.
- **Correction:** Make `TrackingView` explicitly `@MainActor` and hop with `Task { @MainActor [weak self] in self?.report() }`, or use selector-based window notifications. Do not repair this with `MainActor.assumeIsolated`; the HotkeyMonitor C callback remains the sole permitted use.

## 5. Current-code and survey factual errors

### Lazy `HistoryStore.shared` initialization can duplicate the first appended run

- **Severity:** P1 blocking
- **File path:** `Sources/Sotto/History/HistoryLog.swift`, `Sources/Sotto/History/HistoryStore.swift`, `Tests/SottoAppTests/HistoryLogTests.swift`
- **Plan task:** 9
- **Problem:** The proposed success path appends before first accessing `HistoryStore.shared`; if the singleton is still lazy, its initializer reloads the newly appended run and `prepend` inserts that same run again, while the proposed `loadCount` baseline becomes order-dependent.
- **Correction:** Resolve `let store = HistoryStore.shared` before the append, then use that instance for prepend/reload. In `withTemporaryLog`, reset/reload the already-created store after installing the directory override and establish the counter baseline only after forcing singleton initialization.

### Task 3 cannot satisfy its own compile checkpoint

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/UI/MainWindow.swift`, `Sources/Sotto/UI/Components.swift`
- **Plan task:** 3
- **Problem:** Task 3 passes new `windowVisible` arguments before Task 4 adds the corresponding parameters, yet it requires `make build` and a commit; its note also incorrectly says Tasks “4 and 5” add them, although only Task 4 does.
- **Correction:** Keep Task 3 limited to the reader and state, then wire call sites and signatures together in Task 4, or merge Tasks 3 and 4 so the checkpoint is buildable.

### The asset cache is not single-flight and can duplicate the first hot-path work

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/Speech/AppleSpeechEngine.swift`
- **Plan task:** 5
- **Problem:** The check-lock/await/insert sequence permits launch `prepare()` and a quick first press to miss the cache concurrently and both perform locale/asset work, which is exactly the cold-start race this phase is meant to remove.
- **Correction:** Store and await one in-flight preparation task per locale (without holding a mutex across an `await`), mark the locale confirmed only on success, and evict a failed task so a later press can retry.

### Task 7 does not prepare the configured audio graph once as claimed

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/Core/AudioCapture.swift`, `Sources/Sotto/App/AppComposition.swift`, `Sources/Sotto/App/SottoApp.swift`
- **Plan task:** 7
- **Problem:** Launch-time `prepareEngine()` calls `prepare()` on an engine with no input tap/configured graph, while `start()` explicitly retains its existing post-tap `engine.prepare()`; the change reuses allocation but does not eliminate per-start graph preparation.
- **Correction:** Describe and measure this as engine-instance/allocation reuse, or design and validate a genuinely preconfigured persistent graph. Do not remove the post-tap prepare without evidence that the changed graph is prepared correctly.

### Task 13 does not fix the surveyed regular-expression recompilation

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/Dictionary/DictionaryStore.swift`, `Sources/SottoDictionary/DictionaryCorrector.swift`
- **Plan task:** 13
- **Problem:** Memoizing `DictionaryCorrector` only avoids rebuilding candidate pattern strings; current `apply(to:)` still compiles every `NSRegularExpression` for every utterance, and SPEC §6.11 does not require that behavior despite the plan calling it a deliberate spec choice.
- **Correction:** Either relabel this as the smaller candidate-construction optimization and mark regex recompilation unresolved, or cache compiled rules in `SottoDictionary` with library tests. The macOS 26 Foundation header marks immutable, thread-safe `NSRegularExpression` Swift-sendable.

### The Canvas rewrite removes the current recording transition

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/UI/Components.swift`
- **Plan task:** 4
- **Problem:** The current recording bars ease height changes over `DS.Motion.quick`, but the proposed Canvas snaps directly between floor and maximum height, so it changes the look despite the plan's stated visual-parity goal; its active timeline also ticks every frame although active height ignores elapsed time.
- **Correction:** Preserve interpolation with an animatable Canvas value or an explicit level transition, and reserve time-driven ticks for the idle ripple; active level changes can otherwise invalidate the Canvas directly.

### The cached permission menu can remain stale

- **Severity:** P2 should-fix
- **File path:** `Sources/Sotto/UI/MenuBarContent.swift`, `Sources/Sotto/App/SottoApp.swift`
- **Plan task:** 14
- **Problem:** The current menu probes when its body evaluates, but the proposed cache refreshes only through Settings polling or app activation; opening a menu-bar menu need not activate the regular app, so grant items can display stale state.
- **Correction:** Refresh `PermissionStatus.shared` when the menu content appears/opens as well as on app activation, while continuing to render from the cached observable values.

### Task 13's proposed test helper does not exist

- **Severity:** P3 nice-to-have
- **File path:** `Tests/SottoAppTests/DictionaryStoreTests.swift`
- **Plan task:** 13
- **Problem:** The test snippet uses `withTemporaryStore`, but the current file's helper is the synchronous `withSandbox`; the plan acknowledges uncertainty instead of providing a current-code-grounded test.
- **Correction:** Rewrite the planned test in the file's existing `try withSandbox { sandbox in let store = DictionaryStore(fileURL: sandbox.fileURL) ... }` pattern.

### Two task file inventories omit files their steps edit

- **Severity:** P3 nice-to-have
- **File path:** `docs/plans/2026-09-02-performance-and-latency.md`
- **Plan task:** 7 and 14
- **Problem:** Task 7's Files list omits `AppComposition.swift` and `SottoApp.swift`, and Task 14's Files list omits `SottoApp.swift`, although their steps and commit commands edit those files.
- **Correction:** Make each Files list match its actual steps and commit scope so review/ownership checkpoints see every touched file.

## Subtle but correct

- `.animation(minimumInterval:paused:)` is available on macOS 26 (indeed since macOS 12); only the proposed periodic `paused:` overload is nonexistent.
- `GraphicsContext.fill(_:with:)` accepts `.color(SwiftUI.Color)`, so the planned Canvas fill call is valid.
- The Canvas obtains its colour, dimensions, and duration from `DS`. `barWidth / 2` expresses capsule geometry derived from the existing width token rather than introducing an independent design radius, so it does not violate the no-literals-in-views contract.
- `AXValueCreate(.cfRange, &range)`, `kAXStringForRangeParameterizedAttribute`, and `AXUIElementCopyParameterizedAttributeValue` are the correct API combination; `Character??` is a legitimate three-state result once failure branches map to outer `nil`.
- The static cache types are valid under strict concurrency: the SDK declares `Locale: Sendable`, marks immutable `AVAudioFormat` Swift-sendable, and `Synchronization.Mutex` serializes the cache value. These tasks need no isolation escape hatch.
- For a hold that lasts through successful engine startup, Task 8's core queueing is sound: pre-iterator yields remain in the unbounded FIFO, the real audio tap is a single ordered producer, exactly one drain is created after `AppleSpeechEngine.start()` sets `phase = .running`, and the format probe and actual transcriber use the same resolved locale/options. That path neither reorders nor double-feeds and does not introduce a format-mismatch crash.
- Task 1 correctly leaves `make build` and `make test` on their debug paths while making the app bundle's default build release.

## Highest-risk tasks

- **Task 8:** It combines state semantics, release cancellation, an unbounded queue, process-fatal format requirements, and broad test assumptions; as written, quick releases lose the very startup audio the task captures.
- **Task 10:** Its central cross-session prewarm assumption is not an Apple API contract, and a correct one-shot session handoff affects the cleanup seam and lifecycle.
- **Task 9:** It changes an explicit spec contract and can duplicate the first recorded history row through lazy singleton initialization.

Verdict: Needs rework. Blocking audio-loss, session-prewarm, strict-concurrency, test-readiness, singleton-ordering, and spec-contract issues must be corrected before implementation.
