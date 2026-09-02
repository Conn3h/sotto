# Sotto Performance and Latency Implementation Plan

> **For agentic workers:** Implement this plan task-by-task with a review checkpoint after each task (fresh subagent per task, or inline execution with checkpoints). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the measured idle-CPU drain, cut key-down-to-listening latency, and clear a set of smaller per-utterance inefficiencies, without changing what the app does or how it looks.

**Architecture:** The work is grouped into seven independent phases. Each phase leaves the app building, tested, and shippable on its own, so the user can stop after any phase. Phase 1 removes the idle drain; Phase 2 (Tasks 5-7) cuts the felt start-of-hold latency. Two items the Codex review found need their own dedicated design and are deferred with corrected design sketches, not implemented here: the capture-before-engine reorder (Task 8) and the ahead-of-time cleanup prewarm (Task 10, Phase 4). Tasks 9, 12, and 13 change documented `docs/SPEC.md` contracts and carry the matching spec edits.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation (`AVAudioEngine`), Speech (`SpeechAnalyzer`/`SpeechTranscriber`), FoundationModels (`LanguageModelSession`), Swift Testing, `Synchronization.Mutex`, `make`.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from `CLAUDE.md` and `docs/SPEC.md`.

- **Clean room.** Author prompts, test vectors and copy fresh. Do not read or copy code from any other dictation project.
- **Build with `make`**, never bare `swift build`. Products live in `~/Library/Caches/SottoBuild`. `make test` runs the library tests.
- **Swift 6 language mode, strict concurrency.** `MainActor.assumeIsolated` is allowed in exactly one place: the C event-tap callback in `HotkeyMonitor`, with a comment.
- **Tests first for the library targets** (`SottoText`, `SottoDictionary`). Confirm a new test fails before making it pass. App-target logic gets tests where it can be exercised without a running app, a microphone, or macOS UI; framework-bound code (`AppleSpeechEngine`, `AudioCapture`, `TextInjector`, `LanguageModelSession`) is verified by running the app and reading the log.
- **Every failure is logged.** No `try?` without a log line. Non-user values are logged with `privacy: .public`. Transcript text is never logged; log its length.
- **No literal values in views.** Colours, sizes, radii, fonts and durations come from `DS` in `UI/DesignSystem.swift`. Add a token rather than inlining a number. Never rename or remove an existing token.
- **Red means recording** and nothing else. Meter colours (`meterLow`, `meterHigh`) appear only in meters. No gradients, no glow.
- **The HUD never becomes key.** Do not change `canBecomeKey` / `canBecomeMain`.
- **`docs/SPEC.md` is a contract.** A behaviour change that contradicts the spec includes the spec edit in the same task.
- Conventional commits (`feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `chore:`). No AI attribution in commit messages. No emojis in code, comments, or logs.
- Diagnostics: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.conn3h.sotto"' --style compact` (spell out `/usr/bin/log`; `log` is often shadowed).

## Revision note (after Codex plan review, 2026-09-02)

This is revision 2. Codex reviewed revision 1 (`docs/reviews/2026-09-02-codex-plan-review.md`, verdict "Needs rework") and the following corrections are folded in:

- **Task 3/4:** the visibility reader now hops to the main actor from the `@Sendable` notification block (Swift 6 isolation). Task 3 no longer changes call sites (so its build checkpoint holds); Task 4 adds the view parameters and their call sites together.
- **Task 4:** there is no `TimelineView(.periodic(from:by:paused:))` overload, so the idle/static split is mandatory (not a fallback); the recording meter keeps its eased level transition in the `Canvas`.
- **Task 5:** the locale/asset prep is single-flight (one in-flight task per locale) so launch prepare and a first press cannot both do the work.
- **Task 7:** scoped and described honestly as engine-instance/allocation reuse; it does not claim to remove the post-tap `prepare()`. `AppComposition.swift` and `SottoApp.swift` added to its Files.
- **Task 8:** reworked so state stays `.starting` until the engine is ready (`.listening` keeps its meaning), a release during startup drains the sealed FIFO before finishing (no dropped audio, honouring invariant 2), and a bounded start deadline caps microphone buffering. Latency is measured at the "capture start" log line. All order-sensitive tests, including the engine-start-failure test, are updated.
- **Task 9:** resolves `HistoryStore.shared` before the append to avoid double-counting the first run through lazy singleton init; adds the spec §6.13 edit.
- **Task 10:** reworked to retain the exact one-shot `LanguageModelSession` the next cleanup consumes and prewarm that session (Apple's `prewarm(promptPrefix:)` warms resources for its own session); adds spec §6.10 and §6.15 edits.
- **Task 11:** an AX value-creation or read failure now returns the outer `nil` (fall back) and is logged; `.some(nil)` is reserved for a genuine no-preceding-character case.
- **Task 12:** edits spec §6.8 and removes the §11 "Later" item and updates the source comment in `TextInjector.swift` (the "never adds a space" text is a source comment, not §6.8).
- **Task 13:** caches compiled `NSRegularExpression` rules in `SottoDictionary` (immutable `NSRegularExpression` is `Sendable` on macOS 26), with library tests, so the per-utterance regex recompile is actually removed; uses the existing `withSandbox` test helper.
- **Task 14:** refreshes `PermissionStatus.shared` when the menu opens as well as on app activation (opening a menu-bar menu need not activate the app); `SottoApp.swift` added to its Files.

---

## Phase 1 — Build and idle CPU

The installed app is a debug build, and the open main window burns roughly a third of a core at rest. A stack sample attributes the idle drain to the masthead meter's at-rest ripple: `TimelineView(.animation)` at `Sources/Sotto/UI/Components.swift:207` rebuilds forty `Capsule().frame(height:)` bars every display frame, and each rebuild forces a full `NSHostingView.layout()` pass of the window. The elapsed readout ticks at 10 Hz even when idle. This phase ships release builds and stops both animations from doing per-frame layout when nothing needs it.

### Task 1: Default `make app` / `run` / `install` to a release build

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Produces: `make app`, `make run`, `make install` build with `-c release`; `make build` and `make test` stay `debug`.

- [ ] **Step 1: Read the current recipe**

Run: `sed -n '1,110p' Makefile`
Confirm `CONFIG := debug`, `BUILD := $(SCRATCH)/$(CONFIG)/$(EXEC)`, and that `app` depends on `build` and copies `$(BUILD)`.

- [ ] **Step 2: Introduce a release path for the app bundle**

Change the config lines near the top (currently `CONFIG := debug`):

```makefile
# `build` and `test` stay debug for fast iteration; the shipped bundle is release.
CONFIG   := debug
APP_CONFIG := release
```

Add, next to `BUILD`:

```makefile
BUILD      := $(SCRATCH)/$(CONFIG)/$(EXEC)
APP_BUILD  := $(SCRATCH)/$(APP_CONFIG)/$(EXEC)
```

- [ ] **Step 3: Make `app` build release itself**

Replace the `app:` recipe's dependency and copy. Change the target line from `app: signing-identity build` to `app: signing-identity`, insert a release build as the first recipe line, and copy from `$(APP_BUILD)`:

```makefile
app: signing-identity
	swift build -c $(APP_CONFIG) --scratch-path "$(SCRATCH)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(APP_BUILD)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
	    --entitlements Resources/$(EXEC).entitlements \
	    --options runtime \
	    --timestamp=none \
	    "$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID), config: $(APP_CONFIG)]"
```

- [ ] **Step 4: Verify the plan of record is release**

Run: `make -n app | grep -c 'swift build -c release'`
Expected: `1`

- [ ] **Step 5: Build for real and confirm the release binary is used**

Run: `make app && test -f ~/Library/Caches/SottoBuild/scratch/release/Sotto && echo RELEASE_OK`
Expected: ends with `built ... [signed: ..., config: release]` then `RELEASE_OK`

- [ ] **Step 6: Confirm tests still run debug**

Run: `make -n test | grep -c release`
Expected: `0`

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "perf(make): ship a release build from app/run/install; keep test debug"
```

### Task 2: Extract the meter's animation gate as a pure, tested function

**Files:**
- Modify: `Sources/Sotto/UI/Components.swift` (add a small `enum MeterAnimation`)
- Test: `Tests/SottoAppTests/MeterAnimationTests.swift` (create)

**Interfaces:**
- Produces: `MeterAnimation.shouldAnimate(isActive: Bool, reduceMotion: Bool, windowVisible: Bool) -> Bool`, consumed by Tasks 3 and 4.

- [ ] **Step 1: Write the failing test**

Create `Tests/SottoAppTests/MeterAnimationTests.swift`:

```swift
import Testing
@testable import Sotto

@Suite
struct MeterAnimationTests {
    @Test func stillWhenWindowHidden() {
        #expect(!MeterAnimation.shouldAnimate(isActive: true, reduceMotion: false, windowVisible: false))
        #expect(!MeterAnimation.shouldAnimate(isActive: false, reduceMotion: false, windowVisible: false))
    }

    @Test func idleRippleOnlyWhenVisibleAndMotionAllowed() {
        #expect(MeterAnimation.shouldAnimate(isActive: false, reduceMotion: false, windowVisible: true))
        #expect(!MeterAnimation.shouldAnimate(isActive: false, reduceMotion: true, windowVisible: true))
    }

    @Test func recordingAnimatesEvenWithReduceMotionWhenVisible() {
        // The recording meter still needs to track level with reduce motion on; it just
        // does not add decorative motion. Visibility still gates it.
        #expect(MeterAnimation.shouldAnimate(isActive: true, reduceMotion: true, windowVisible: true))
        #expect(!MeterAnimation.shouldAnimate(isActive: true, reduceMotion: true, windowVisible: false))
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `make test 2>&1 | grep -A2 MeterAnimation`
Expected: FAIL, `MeterAnimation` not found.

- [ ] **Step 3: Add the function**

At the top of the `// MARK: - Masthead meter` section in `Sources/Sotto/UI/Components.swift`, above `struct MastheadMeterView`:

```swift
/// Whether the masthead meter should run its per-frame `TimelineView`. Pure so the gate is
/// tested without a host. Off whenever the window's pixels are not on screen (dictating into
/// another app, minimised, covered): the level still updates, the meter just stops
/// repainting. At rest the ripple is decoration, so reduce-motion turns it off; while
/// recording the meter must track level even with reduce motion, so only visibility gates it.
enum MeterAnimation {
    static func shouldAnimate(isActive: Bool, reduceMotion: Bool, windowVisible: Bool) -> Bool {
        guard windowVisible else { return false }
        return isActive || !reduceMotion
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `make test 2>&1 | grep -A2 MeterAnimation`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Sotto/UI/Components.swift Tests/SottoAppTests/MeterAnimationTests.swift
git commit -m "refactor(ui): extract MeterAnimation.shouldAnimate as a tested gate"
```

### Task 3: Report the main window's on-screen visibility to the view tree

**Files:**
- Create: `Sources/Sotto/UI/WindowVisibilityReader.swift`
- Modify: `Sources/Sotto/UI/MainWindow.swift`

**Interfaces:**
- Produces: `WindowVisibilityReader(isVisible: Binding<Bool>)` view; `MainWindow` holds `@State private var windowVisible = true`. This task adds only the reader and the state; Task 4 adds the view parameters and their call sites, so this task builds on its own.
- Consumes: `MeterAnimation.shouldAnimate` (Task 2).

- [ ] **Step 1: Create the reader**

`Sources/Sotto/UI/WindowVisibilityReader.swift`. On macOS 26 the `NotificationCenter.addObserver` block is `@Sendable` (the `queue: .main` argument is only a delivery choice, not a compile-time isolation guarantee), so the observer must hop to the main actor before touching main-actor state. `TrackingView` is `@MainActor`, and the observer body does `MainActor.assumeIsolated`-free hopping via `Task { @MainActor in }`:

```swift
import AppKit
import SwiftUI

/// Reports whether the hosting window's pixels are actually on screen, via
/// `NSWindow.occlusionState` plus miniaturisation. Placed as a zero-size background of a
/// view; drives an idle animation gate so a covered or minimised window costs nothing.
/// AppKit occlusion has no SwiftUI environment key, so a tiny representable bridges it.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Main-actor isolated: `report()` and `onChange` touch main-actor-only state, and the
    /// notification block on macOS 26 is `@Sendable`, so the block hops here explicitly. This
    /// is a plain `Task { @MainActor }` hop, not `MainActor.assumeIsolated` (the one
    /// permitted `assumeIsolated` site stays the HotkeyMonitor C callback).
    @MainActor
    private final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else {
                onChange?(false)
                return
            }
            let center = NotificationCenter.default
            for name: NSNotification.Name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.report() }
                    }
                )
            }
            report()
        }

        private func report() {
            guard let window else {
                onChange?(false)
                return
            }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
```

- [ ] **Step 2: Hold the flag in `MainWindow` (state and reader only)**

In `Sources/Sotto/UI/MainWindow.swift`, add state to `struct MainWindow`:

```swift
    @State private var windowVisible = true
```

Attach the reader as a background of the outer `VStack` (which already ends `.background(DS.Color.ground)`), by inserting before that line:

```swift
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .background(DS.Color.ground)
```

Do NOT change the `Masthead`, `MastheadMeterView`, or `ElapsedReadout` call sites here: those views do not yet take a `windowVisible` parameter, and adding the argument now would not compile. Task 4 adds the parameters and the call sites together. `windowVisible` is unused after this task and will draw an "unused" warning until Task 4; that is expected and gone by the next task.

- [ ] **Step 3: Build (compile-only gate; the reader is not unit-testable)**

Run: `make build`
Expected: `Build complete!` (a benign unused-`windowVisible` warning is fine; Task 4 consumes it.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Sotto/UI/WindowVisibilityReader.swift Sources/Sotto/UI/MainWindow.swift
git commit -m "feat(ui): report main-window on-screen visibility to gate idle animation"
```

### Task 4: Draw the masthead meter in a `Canvas` and pause it when hidden

**Files:**
- Modify: `Sources/Sotto/UI/Components.swift` (`MastheadMeterView`)
- Modify: `Sources/Sotto/UI/MainWindow.swift` (`ElapsedReadout`)

**Interfaces:**
- Consumes: `MeterAnimation.shouldAnimate` (Task 2), `windowVisible` (Task 3).
- Produces: `MastheadMeterView(level:isActive:reduceMotion:windowVisible:)`, `ElapsedReadout(holdStartedAt:isActive:windowVisible:)`, and the `MainWindow`/`Masthead` call sites that pass `windowVisible`.

- [ ] **Step 1: Wire the call sites (deferred from Task 3)**

In `Sources/Sotto/UI/MainWindow.swift`: add `let windowVisible: Bool` to `private struct Masthead`, change the `Masthead(controller: controller)` call to `Masthead(controller: controller, windowVisible: windowVisible)`, and pass `windowVisible` into the two views inside `Masthead`:

```swift
                MastheadMeterView(
                    level: controller.level,
                    isActive: controller.state.isActive,
                    reduceMotion: reduceMotion,
                    windowVisible: windowVisible
                )
```

```swift
            ElapsedReadout(
                holdStartedAt: controller.holdStartedAt,
                isActive: controller.state.isActive,
                windowVisible: windowVisible
            )
```

- [ ] **Step 2: Replace the meter body with a single `Canvas` driven by one gated timeline**

In `Sources/Sotto/UI/Components.swift`, add `let windowVisible: Bool` to `MastheadMeterView` and replace its `var body` with a Canvas that repaints instead of relaying out. The Canvas eases the recording level from a clock (preserving the old `.animation(value: litCount)` rise; a Canvas closure is not itself animatable, so the ease lives in the clock) and reserves the ripple for the idle case:

```swift
    let level: Float
    let isActive: Bool
    let reduceMotion: Bool
    let windowVisible: Bool

    @State private var clock = MastheadRippleClock()

    var body: some View {
        let animate = MeterAnimation.shouldAnimate(
            isActive: isActive, reduceMotion: reduceMotion, windowVisible: windowVisible
        )
        // A Canvas repaints on each tick WITHOUT a layout pass; the previous HStack of
        // capsules forced a full NSHostingView.layout() every frame (spec trap: keep
        // per-frame work off the layout engine). Paused (hidden, or idle + reduce motion)
        // the TimelineView renders once with the clock's held values: a single static draw.
        TimelineView(.animation(paused: !animate)) { context in
            let target = CGFloat(max(0, min(1, level)))
            let tick = animate
                ? clock.advance(to: context.date, toward: target)
                : (elapsed: clock.elapsed, level: clock.level)
            Canvas { gc, size in
                draw(into: gc, size: size, elapsed: tick.elapsed, level: tick.level)
            }
        }
        .frame(height: DS.Metric.mastheadBarMaxHeight)
    }

    private func draw(into gc: GraphicsContext, size: CGSize, elapsed: TimeInterval, level: CGFloat) {
        let barCount = DS.Metric.mastheadBarCount
        let spacing = spacing(for: size.width, barCount: barCount)
        let barWidth = DS.Metric.mastheadBarWidth
        let lit = litCount(for: level)
        for index in 0..<barCount {
            let x = CGFloat(index) * (barWidth + spacing)
            let height = barHeight(index: index, elapsed: elapsed, lit: lit)
            let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
            gc.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(barColor(index: index, lit: lit)))
        }
    }

    private func barHeight(index: Int, elapsed: TimeInterval, lit: Int) -> CGFloat {
        if isActive {
            return index < lit ? DS.Metric.mastheadBarMaxHeight : DS.Metric.mastheadBarFloor
        }
        if reduceMotion {
            return DS.Metric.mastheadBarFloor
        }
        return rippleHeight(index: index, elapsed: elapsed)
    }

    private func barColor(index: Int, lit: Int) -> SwiftUI.Color {
        guard isActive else { return DS.Color.inkTertiary }
        guard index < lit else { return DS.Color.hairline }
        let lastIndex = DS.Metric.mastheadBarCount - 1
        let position = lastIndex > 0 ? Double(index) / Double(lastIndex) : 0
        return DS.Color.meterLow.mix(with: DS.Color.meterHigh, by: position)
    }

    private func litCount(for level: CGFloat) -> Int {
        let clamped = max(0, min(1, level))
        return Int((clamped * CGFloat(DS.Metric.mastheadBarCount)).rounded())
    }
```

Delete the old `bars(spacing:barCount:bar:)` helper and the `if isActive { ... } else if reduceMotion { ... } else { TimelineView ... }` block it served, plus the old `litCount` computed property, `height(forLitIndex:)`, and the old `recordingColor(for:)` (folded into `barColor(index:lit:)` above). Keep `spacing(for:barCount:)` and `rippleHeight(index:elapsed:)`.

- [ ] **Step 3: Ease the recording level in the clock**

Extend `MastheadRippleClock` (still a plain reference type held via `@State`, never mutated as a `@State` value) to advance ripple time and ease a displayed level toward the target each frame, so the recording meter keeps a smooth rise over `DS.Motion.quick`:

```swift
@MainActor
private final class MastheadRippleClock {
    private var last: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: CGFloat = 0

    /// Advances ripple time and eases the displayed level toward `target`. `dt / quick`
    /// gives roughly the same settling time the old `.animation(.easeOut(quick))` did.
    @discardableResult
    func advance(to date: Date, toward target: CGFloat) -> (elapsed: TimeInterval, level: CGFloat) {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        elapsed += dt
        let k = DS.Motion.quick > 0 ? min(1, dt / DS.Motion.quick) : 1
        level += (target - level) * CGFloat(k)
        return (elapsed, level)
    }
}
```

- [ ] **Step 4: Split the elapsed readout (no `.periodic(paused:)` overload exists)**

In `Sources/Sotto/UI/MainWindow.swift`, add `let windowVisible: Bool` to `ElapsedReadout`. There is no `TimelineView(.periodic(from:by:paused:))` on macOS 26, so the conditional split is mandatory: run the periodic timeline only while live and visible, and render an identically styled static `Text` otherwise:

```swift
    let holdStartedAt: Date?
    let isActive: Bool
    let windowVisible: Bool

    var body: some View {
        // No per-frame text rebuilds at rest, or behind another window while recording.
        if isActive && windowVisible {
            TimelineView(.periodic(from: .now, by: DS.Motion.elapsedTick)) { context in
                readout(text(now: context.date))
            }
        } else {
            readout(isActive ? text(now: Date()) : Self.idleText)
        }
    }

    private func readout(_ string: String) -> some View {
        Text(string)
            .font(DS.Font.readoutLarge)
            .foregroundStyle(DS.Color.ink)
    }
```

- [ ] **Step 5: Build**

Run: `make build`
Expected: `Build complete!`

- [ ] **Step 6: Measure idle CPU before/after by running the app**

Run:
```bash
make install
sleep 3
top -l 4 -s 1 -pid "$(pgrep -x Sotto)" -stats pid,cpu | grep -E '^[0-9]'
```
Expected: with the main window open and unoccluded, idle CPU is in low single digits, not ~30%. Cover the window with another app and confirm it drops to roughly 0.

- [ ] **Step 7: Visual check that nothing regressed**

Run: `make run` and confirm: the masthead ripple still travels at rest, the meter still lights green-to-amber while recording with the same smooth rise, and the elapsed counter still ticks while holding. Reduce Motion (System Settings) stills the ripple.

- [ ] **Step 8: Commit**

```bash
git add Sources/Sotto/UI/Components.swift Sources/Sotto/UI/MainWindow.swift
git commit -m "perf(ui): draw the masthead meter in a Canvas and pause it when the window is hidden"
```

---

## Phase 2 — Key-down-to-listening latency

Logged holds this morning opened the microphone 127-240 ms after key-down; anything spoken in that gap is lost. The cost is serial setup: resolving the locale and re-checking speech assets on every press, then, between analyzer start and capture start, `bestAvailableAudioFormat` plus building and starting a fresh `AVAudioEngine`. Tasks 5-7 remove those serial costs without touching ordering, and are the latency work this plan ships. Task 8 (the capture-before-engine reorder) is deferred to its own plan; measure after 5-7 to decide whether the remaining gap justifies it.

### Task 5: Cache the resolved locale and skip the repeat asset-inventory check

**Files:**
- Modify: `Sources/Sotto/Speech/AppleSpeechEngine.swift`

**Interfaces:**
- Produces: `AppleSpeechEngine.resolveLocale` returns a memoised result; asset preparation is single-flight per locale and no-ops after the first confirmed install.

- [ ] **Step 1: Add process-lifetime caches**

`AppleSpeechEngine` is an actor, so the caches must be `Sendable`; `Synchronization.Mutex` provides that (`Locale` is `Sendable`, confirmed by the Codex review). Add, near the top of the `actor`, using the already-imported `Synchronization` (add `import Synchronization` if absent):

```swift
    /// Resolving a locale and confirming assets both cross into the Speech daemon. Neither
    /// answer changes for the life of the process, so both are memoised. `assetPrep` holds
    /// the single in-flight preparation per resolved locale so a launch `prepare()` and a
    /// quick first press coalesce onto one download instead of racing two.
    private static let resolvedLocales = Mutex<[String: Locale]>([:])
    private static let confirmedAssets = Mutex<Set<String>>([])
    private static let assetPrep = Mutex<[String: Task<Void, Error>]>([:])
```

- [ ] **Step 2: Memoise `resolveLocale`**

Wrap the existing body:

```swift
    private static func resolveLocale(requestedLocale: Locale) async -> Locale? {
        let key = requestedLocale.identifier
        if let cached = resolvedLocales.withLock({ $0[key] }) {
            return cached
        }
        let resolved: Locale?
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            resolved = match
        } else {
            Log.speech.info(
                "locale \(requestedLocale.identifier, privacy: .public) unsupported; trying \(fallbackLocale.identifier, privacy: .public)"
            )
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: fallbackLocale)
        }
        if let resolved {
            resolvedLocales.withLock { $0[key] = resolved }
        }
        return resolved
    }
```

- [ ] **Step 3: Skip the inventory check once confirmed, and single-flight the first prep**

Rename the current body to `performAssetInstall(for:locale:)` (the inventory request, the `guard let request else { return }` already-installed branch, and the timed `downloadAndInstall()`), then wrap it so concurrent callers coalesce and a confirmed locale short-circuits. The `withLock` blocks only guard synchronous map access; the `await` is outside the lock:

```swift
    private static func installAssetsIfNeeded(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let key = locale.identifier
        if confirmedAssets.withLock({ $0.contains(key) }) {
            return
        }
        // Coalesce a launch prepare() and a first press onto one preparation task.
        let task: Task<Void, Error> = assetPrep.withLock { inFlight in
            if let existing = inFlight[key] {
                return existing
            }
            let created = Task { try await performAssetInstall(for: transcriber, locale: locale) }
            inFlight[key] = created
            return created
        }
        do {
            try await task.value
            confirmedAssets.withLock { $0.insert(key) }
            assetPrep.withLock { $0[key] = nil }
        } catch {
            // Evict on failure so a later press can retry rather than reusing a dead task.
            assetPrep.withLock { $0[key] = nil }
            throw error
        }
    }
```

Keep the existing logging inside `performAssetInstall`. Update the two call sites (`prepare` and `performStart`) to pass the resolved `locale`. Both already have it in scope.

- [ ] **Step 4: Build**

Run: `make build`
Expected: `Build complete!` (no unit tests: `AppleSpeechEngine` talks to the Speech daemon and is not covered by the fakes.)

- [ ] **Step 5: Verify by running**

Run: `make install`, then hold the key three times and read the log:
```bash
/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.conn3h.sotto" AND eventMessage CONTAINS "speech assets"' --style compact | grep -v '^Timestamp'
```
Expected: at most one "speech assets checked" or "nothing to download" line total, not one per press.

- [ ] **Step 6: Commit**

```bash
git add Sources/Sotto/Speech/AppleSpeechEngine.swift
git commit -m "perf(speech): memoise locale resolution and asset confirmation per process"
```

### Task 6: Cache the preferred input format from `prepare()`

**Files:**
- Modify: `Sources/Sotto/Speech/AppleSpeechEngine.swift`

**Interfaces:**
- Produces: `preferredInputFormat()` returns a cached `AVAudioFormat` without building a probe transcriber or calling `bestAvailableAudioFormat` on the hot path.

- [ ] **Step 1: Add the format cache**

```swift
    /// The analyzer's preferred capture format is fixed per resolved locale. Computing it
    /// calls into the Speech framework; cache it so a press does not pay that between
    /// analyzer start and capture start. AVAudioFormat is an immutable reference type; the
    /// Mutex confines access.
    private static let preferredFormats = Mutex<[String: AVAudioFormat]>([:])
```

- [ ] **Step 2: Populate the cache in `prepare()`**

After `try await installAssetsIfNeeded(for: transcriber, locale: resolved)` succeeds in `prepare`, compute and store the format:

```swift
        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            preferredFormats.withLock { $0[resolved.identifier] = format }
        }
```

- [ ] **Step 3: Serve `preferredInputFormat()` from the cache first**

Rewrite `preferredInputFormat()` so the cache is checked before any framework call:

```swift
    func preferredInputFormat() async -> AVAudioFormat? {
        guard let locale = await Self.resolveLocale(requestedLocale: requestedLocale) else {
            Log.speech.error("preferredInputFormat: no supported locale for \(self.requestedLocale.identifier, privacy: .public)")
            return nil
        }
        if let cached = Self.preferredFormats.withLock({ $0[locale.identifier] }) {
            return cached
        }
        let source = transcriber ?? Self.makeTranscriber(locale: locale)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [source])
        if let format {
            Self.preferredFormats.withLock { $0[locale.identifier] = format }
        } else {
            Log.speech.error("preferredInputFormat: no compatible audio format reported")
        }
        return format
    }
```

- [ ] **Step 4: Build and verify by running**

Run: `make build && make install`. Hold the key and read:
```bash
/usr/bin/log show --last 1m --info --predicate 'subsystem == "com.conn3h.sotto" AND (eventMessage CONTAINS "listening" OR eventMessage CONTAINS "analyzer start" OR eventMessage CONTAINS "capture start")' --style compact | grep -v '^Timestamp'
```
Expected: the gap between "analyzer start" and "capture start" is smaller than the 80-165 ms seen before.

- [ ] **Step 5: Commit**

```bash
git add Sources/Sotto/Speech/AppleSpeechEngine.swift
git commit -m "perf(speech): cache the preferred input format so a press skips bestAvailableAudioFormat"
```

### Task 7: Reuse one `AVAudioEngine` instance across utterances

Scope note (from the Codex review): this is engine-instance/allocation reuse, not a preconfigured persistent audio graph. `start()` keeps its post-tap `engine.prepare()`; the tap is still installed per start and removed per stop. The only saved work per press is allocating a fresh `AVAudioEngine`. Do not claim or attempt to remove the post-tap prepare without measuring a correctly preconfigured graph.

**Files:**
- Modify: `Sources/Sotto/Core/AudioCapture.swift`
- Modify: `Sources/Sotto/App/AppComposition.swift`
- Modify: `Sources/Sotto/App/SottoApp.swift`

**Interfaces:**
- Produces: `AudioCapture` reuses a single `AVAudioEngine` instance across `start`/`stop`; `prepareEngine()` pre-allocates the instance at launch. The post-tap `prepare()` in `start()` is unchanged, and the `AudioCapturing` protocol is unchanged.

- [ ] **Step 1: Hold the engine in `Storage` and reuse it**

In `Sources/Sotto/Core/AudioCapture.swift`, the `Storage` struct already holds `engine: AVAudioEngine?` and `isRunning`. Change `start` so it reuses an existing engine rather than allocating one each call, and change `stop` so it stops the engine but keeps the instance:

In `start(...)`, replace `let engine = AVAudioEngine()` with:

```swift
            let engine = storage.engine ?? AVAudioEngine()
```

Leave the rest of the tap install and `engine.start()` as-is (the tap is installed fresh each start and removed each stop, which is correct). At the end where it sets `storage.engine = engine`, that now also caches a reused instance.

In `stop()`, change the teardown so the instance survives:

```swift
    func stop() {
        storage.withLock { storage in
            guard storage.isRunning, let engine = storage.engine else {
                return
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            storage.isRunning = false
            Log.audio.info("capture stop")
        }
    }
```

(The only change from today is dropping `storage.engine = nil`, so the prepared engine is kept.)

- [ ] **Step 2: Add a launch-time pre-allocation hook**

Add a method that allocates the reusable engine ahead of the first hold, so the first press does not pay `AVAudioEngine()` allocation. It does not call `prepare()` here: a tapless engine has no configured graph to prepare, and `start()` still prepares after installing the tap:

```swift
    /// Pre-allocates the reusable engine so the first hold does not pay allocation. The
    /// per-start `prepare()` still runs in `start()` after the tap is installed. Idempotent;
    /// safe to call at launch.
    func prepareEngine() {
        storage.withLock { storage in
            guard storage.engine == nil else { return }
            storage.engine = AVAudioEngine()
            Log.audio.info("audio engine pre-allocated")
        }
    }
```

- [ ] **Step 3: Call it at launch**

In `Sources/Sotto/App/SottoApp.swift`, inside `applicationDidFinishLaunching`, next to the existing `Task { await AppleSpeechEngine.prepare() }`, warm capture. The composition's capture is a concrete `AudioCapture`; expose it or call through. Add to `AppComposition` a stored `let capture: AudioCapture` (it currently builds `AudioCapture()` inline in the `DictationController(...)` call) and call `composition.capture.prepareEngine()` at launch:

In `Sources/Sotto/App/AppComposition.swift`, hoist the capture:

```swift
    let capture: AudioCapture

    init() {
        let capture = AudioCapture()
        self.capture = capture
        let pipeline = UtterancePipeline()
        let controller = DictationController(
            hotkey: HotkeyMonitor(),
            capture: capture,
            ...
```

In `applicationDidFinishLaunching`:

```swift
        composition.capture.prepareEngine()
```

- [ ] **Step 4: Build**

Run: `make build`
Expected: `Build complete!` (No unit test: `AudioCapture` needs real audio hardware; `FakeCapture` in the tests is unaffected by this change.)

- [ ] **Step 5: Verify by running**

Run: `make install`. Read the log after launch and after a few holds:
```bash
/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.conn3h.sotto" AND (eventMessage CONTAINS "pre-allocated" OR eventMessage CONTAINS "capture start")' --style compact | grep -v '^Timestamp'
```
Expected: one "audio engine pre-allocated" at launch; holds still log "capture start"; dictation still transcribes correctly.

- [ ] **Step 6: Commit**

```bash
git add Sources/Sotto/Core/AudioCapture.swift Sources/Sotto/App/AppComposition.swift Sources/Sotto/App/SottoApp.swift
git commit -m "perf(audio): reuse one AVAudioEngine instance across utterances"
```

### Task 8 (deferred to its own plan): capture-before-engine reorder

**Recommendation: do not implement this as part of this plan.** Ship Tasks 5-7, measure the key-down-to-"capture start" gap in the log, and only then decide whether the reorder is worth its risk. The Codex review found three P1 defects in the revision-1 reorder plus an unbounded-buffering risk, and a correct version rewrites the controller's terminal state machine, which is the app's most safety-critical code and a `docs/SPEC.md` §6.7 / §4 invariant-2 contract. That deserves its own spec RFC and plan, not a rider on a performance-cleanup batch.

**Why Tasks 5-7 already cover most of item 3:** the measured 80-165 ms between "analyzer start" and "capture start" is dominated by `bestAvailableAudioFormat` (removed by Task 6's format cache) and per-press `AVAudioEngine` allocation (reduced by Task 7). The 6-12 ms before "analyzer start" is removed by Task 5. Measure after 5-7 before spending the reorder's risk budget; the remaining gap may not justify it.

**Design sketch for the future plan** (recorded so it is not re-derived, and correcting every review finding):
- Keep `state = .starting` until the engine is ready; set `.listening` only after `engine.start()` returns AND the drain and consume tasks are installed. `.listening` keeps its current meaning, so existing tests and `Harness.pressAndListen()` are untouched. Measure the win at the "capture start" log line, never by moving `.listening` earlier.
- Order: mic -> makeEngine -> cached `preferredInputFormat()` -> unbounded stream + `capture.start` (mic live) -> `engine.start()` -> install drain + consume -> `.listening`.
- No-drop on release during startup (SPEC §4 invariant 2): a release after capture has started must not discard buffered audio. The terminal path stops capture immediately, then awaits engine readiness, seals the stream, awaits the drain so every buffered chunk is fed, then calls `engine.finish()`. This requires the setup path to install the drain even when the session is already terminating (it must not `isLive`-return before the drain exists); only `.aborted` / `.failed` may discard. This is the crux the revision-1 plan got wrong.
- Bounded start deadline: a stalled `engine.start()` must not buffer the microphone for the whole hold. Add a deadline that stops capture and fails the utterance with a logged error; keep the stream unbounded while startup is valid (no dropping buffer policy).
- Tests: besides the `releaseWhileSuspendedAt*` tests, `engineStartFailureShowsErrorThenIdle` (currently `capture.startCalls == 0`) would need to expect a start plus a stop; add tests that buffers captured before readiness are fed in order both after a normal release and after an early release.
- Spec: update §6.7's setup order and state explicitly that it preserves invariant 2 (nothing dropped), keeping `.listening` after readiness.

No code, tests, or spec edits are made for Task 8 in this plan.

---

## Phase 3 — History write path

`HistoryLog.record` appends one line, then `HistoryStore.reload()` re-reads and re-decodes the entire file on the pipeline's critical path before the end sound. Invisible at 52 rows, linear in history size forever.

### Task 9: Update the history store in memory on append instead of re-reading the file

**Files:**
- Modify: `Sources/Sotto/History/HistoryStore.swift` (add `prepend`)
- Modify: `Sources/Sotto/History/HistoryLog.swift` (`record`, add a test-visible `loadCount`)
- Modify: `docs/SPEC.md` (§6.13)
- Test: `Tests/SottoAppTests/HistoryLogTests.swift`

**Interfaces:**
- Produces: `HistoryStore.prepend(_ run: DictationRun)` inserts at the front (newest-first); `HistoryLog.record` resolves `HistoryStore.shared` before the append (so lazy init cannot double-count), calls `prepend` on a successful append, and reloads only on append failure; `HistoryLog.loadCount` counts full-file reads for tests.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SottoAppTests/HistoryLogTests.swift`. Force the `HistoryStore.shared` singleton to initialise before the baseline, so a first, lazy init (which reads the file once) is counted in `before` rather than inside the measured window:

```swift
    @Test func recordDoesNotReReadTheWholeFile() async throws {
        try await withTemporaryLog { _ in
            _ = HistoryStore.shared          // force lazy init before measuring reads
            let before = HistoryLog.loadCount
            HistoryLog.record(makeRun(text: "first"))
            HistoryLog.record(makeRun(text: "second"))
            #expect(HistoryLog.loadCount == before)   // record no longer re-reads the file

            // load() itself reads (bumping loadCount, which is fine) and round-trips both
            // runs in append order.
            let loaded = HistoryLog.load()
            #expect(loaded.map(\.text) == ["first", "second"])
        }
    }
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `make test 2>&1 | grep -A3 recordDoesNotReRead`
Expected: FAIL, `loadCount` not found (or the count increased, once `loadCount` exists but `record` still reloads).

- [ ] **Step 3: Add `prepend` to the store**

In `Sources/Sotto/History/HistoryStore.swift`:

```swift
    /// `HistoryLog.record` calls this after a successful append: the new run is the newest,
    /// so it goes to the front, with no disk read.
    func prepend(_ run: DictationRun) {
        runs = [run] + runs
        Log.history.debug("history store prepended: \(self.runs.count, privacy: .public) runs")
    }
```

- [ ] **Step 4: Count loads and stop re-reading on the success path**

In `Sources/Sotto/History/HistoryLog.swift`, add a counter and bump it once per full read. Near the other static state:

```swift
    /// Full-file reads, for tests that assert `record` no longer re-reads.
    private(set) static var loadCount = 0
```

In `loadReport()`, immediately after the missing-file guard's `else` path is passed (i.e., at the point a real read begins), increment: add `loadCount += 1` right before `let data: Data`. (Counts real reads; the missing-file early success does not read.)

Restructure `record` so it resolves the store first, then prepends on success and reloads only on failure. Resolving `let store = HistoryStore.shared` before the append is load-bearing: if the singleton is still lazy, resolving it here makes its one-time initializer read the pre-append file; deferring the first access to the `prepend`/`reload` line below would let init read the just-appended run and then `prepend` add the same run a second time.

```swift
    static func record(_ run: DictationRun) {
        // Resolve (and possibly lazily initialise) the store BEFORE the append, so a first
        // init reads the pre-append file and cannot double-count this run.
        let store = HistoryStore.shared
        do {
            let data = try encoder.encode(run)
            try AppSupportDirectory.ensureExists(directoryURL)
            try append(data + newline)
            Log.history.info(
                "recorded run \(run.id.uuidString, privacy: .public): \(run.text.count, privacy: .public) chars, source \(run.source, privacy: .public), \(run.corrections?.count ?? 0, privacy: .public) corrections"
            )
            store.prepend(run)
        } catch {
            Log.history.error(
                "record failed for run \(run.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            store.reload()
        }
    }
```

- [ ] **Step 5: Update the spec (§6.13)**

SPEC §6.13 currently says `record`, `delete`, and `clear` all reload `HistoryStore`. Edit that sentence so it matches the new and existing behaviour: a successful `record` prepends the known run to the store (no read); an append failure reloads; `delete` and `clear` rewrite the file atomically and replace the store from the known file order (this also brings the spec in line with the current delete/clear implementation, which already replaces from known order rather than re-reading).

- [ ] **Step 6: Run the test to confirm it passes**

Run: `make test 2>&1 | grep -A3 recordDoesNotReRead`
Expected: PASS. Run the whole `HistoryLogTests` suite too; the existing round-trip, delete, and clear tests still pass (delete/clear keep their reload/replace paths).

- [ ] **Step 7: Commit**

```bash
git add Sources/Sotto/History/HistoryStore.swift Sources/Sotto/History/HistoryLog.swift docs/SPEC.md Tests/SottoAppTests/HistoryLogTests.swift
git commit -m "perf(history): update the store in memory on append instead of re-reading the file"
```

---

## Phase 4 — Smart-cleanup warmup (deferred)

With Smart cleanup on, `SystemCleanupModel.cleanup` builds a new `LanguageModelSession` per utterance and never prewarms, so model load is paid inside the four-second timeout, on the critical path after release.

### Task 10 (deferred to its own plan): prewarm the exact session cleanup consumes

**Recommendation: do not implement this as part of this plan.** The Codex review established (against Apple's docs) that `prewarm(promptPrefix:)` warms the resources of the session it is called on; there is no documented contract that prewarming a throwaway session speeds up a different session created later. So the revision-1 design (prewarm a throwaway at launch/listening, then build a fresh session in `cleanup`) does not reliably remove the cold call. A correct version must prewarm the very session `cleanup` will consume, ahead of time, which means retaining that session from the listening window to the release-time cleanup.

That retention collides with the current isolation: `cleanup` is invoked off the main actor from `FoundationModelFormatter.race`'s unstructured task (deliberately, so model inference does not block the main actor and can be raced against the timeout), while the natural prewarm trigger (`.listening`) is on the main actor. Getting a `LanguageModelSession` safely from one to the other under Swift 6 strict concurrency depends on that type's Sendability/isolation, which must be verified against the FoundationModels headers first. Smart cleanup is also off by default, so this is the lowest-priority item; it is not worth shipping an uncertain-benefit change or a strict-concurrency workaround inside a performance-cleanup batch.

**Design sketch for the future plan** (correcting the review's findings):
- Add `prewarm()` to the `CleanupModel` seam (and an empty `prewarm()` to `FakeCleanupModel`).
- Make `SystemCleanupModel` a shared reference type that retains one prewarmed one-shot `LanguageModelSession`. `prewarm()` creates the session if none is held and calls `session.prewarm()` on it; `cleanup` consumes that exact session, then discards it (sets the held session back to nil) so the next utterance prewarms a fresh one and no transcript accumulates. On timeout/failure it also discards.
- Trigger `prewarm()` on the `.listening` transition (via a sibling of `AppDelegate.observeHUDVisibility`'s `withObservationTracking` observer) when `Settings.shared.smartCleanup` and `FoundationModelFormatter.isAvailable`.
- Isolation: verify whether `LanguageModelSession` is `Sendable`. If it is, hold it in a `Synchronization.Mutex` on the shared model. If it is not, redesign the handoff (for example, an actor that owns the session and exposes an async `consume`/`prewarm`) rather than reaching for `@unchecked Sendable` or a second `MainActor.assumeIsolated` site.
- Spec: add `prewarm()` to the §6.10 `CleanupModel` interface and its one-shot prewarm/consume lifecycle, and add the launch/`.listening` warmup hook to §6.15.

No code, tests, or spec edits are made for Task 10 in this plan.

---

## Phase 5 — Accessibility insert cost

`TextInjector.needsLeadingSpace` reads the entire focused element value over the AX connection to look at one character before the caret. In a long editor buffer or a web document that is slow and allocates the whole text.

### Task 11: Read one character before the caret with the range-parameterized attribute

**Files:**
- Modify: `Sources/Sotto/Core/TextInjector.swift` (`needsLeadingSpace`)

**Interfaces:**
- Produces: `needsLeadingSpace` reads only the character at `range.location - 1` via `kAXStringForRangeParameterizedAttribute`, falling back to the current full-value read when the parameterized read is unavailable, fails, or returns empty (each logged).

- [ ] **Step 1: Add a bounded read that returns the single preceding character**

In `Sources/Sotto/Core/TextInjector.swift`, add a helper that asks for exactly one character. Every failure path (value-creation failure, AX error, wrong type, empty result) returns the OUTER `nil` so the caller falls back to the full-value read; `.some(nil)` is reserved for the genuine "no preceding character" case:

```swift
    /// The single character immediately before `location`, read with the range-parameterized
    /// attribute so the whole document is never copied.
    /// - Returns `nil` (outer) when the read cannot be trusted (value-creation failure, AX
    ///   error, unexpected type, or empty result): the caller falls back to the full-value read.
    /// - Returns `.some(nil)` only when there is genuinely no preceding character.
    /// - Returns `.some(char)` with the character otherwise.
    private static func character(before location: Int, in element: AXUIElement) -> Character?? {
        guard location > 0 else { return .some(nil) }  // genuine: at the start of the field
        var range = CFRange(location: location - 1, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &range) else {
            Log.inject.debug("could not create an AXValue range for the preceding character; falling back")
            return nil
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &value
        )
        guard error == .success, let string = value as? String else {
            Log.inject.debug("string-for-range unavailable (AXError \(error.rawValue, privacy: .public)); falling back")
            return nil
        }
        guard let first = string.first else {
            // A successful but empty read is not proof of a field start; fall back.
            return nil
        }
        return .some(first)
    }
```

The double optional distinguishes three cases: outer `nil` means "cannot trust this read, fall back"; `.some(nil)` means "there is genuinely no preceding character" (start of field); `.some(char)` is the character.

- [ ] **Step 2: Use it first in `needsLeadingSpace`, keep the full read as fallback**

Rewrite the top of `needsLeadingSpace(in:before:)` to try the bounded read first:

```swift
    private static func needsLeadingSpace(in element: AXUIElement, before range: CFRange) -> Bool {
        guard range.location > 0 else {
            return false
        }
        switch character(before: range.location, in: element) {
        case .some(.some(let scalarChar)):
            return !scalarChar.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
        case .some(.none):
            return false
        case .none:
            break  // attribute unsupported; fall back to the full-value read below
        }
        // ... existing full-value read (kAXValueAttribute) stays here as the fallback ...
```

Keep the entire existing `kAXValueAttribute` body below as the fallback for apps that do not implement the parameterized attribute.

- [ ] **Step 3: Build**

Run: `make build`
Expected: `Build complete!` (No unit test: `TextInjector` drives live AX APIs.)

- [ ] **Step 4: Verify behaviour parity by running**

Run: `make install`. In TextEdit, place the caret mid-word, dictate, and confirm a leading space is still inserted where it was before. Dictate at the very start of an empty document and confirm no leading space. Read the log:
```bash
/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.conn3h.sotto" AND eventMessage CONTAINS "via accessibility"' --style compact | grep -v '^Timestamp'
```
Expected: the "inserted ... via accessibility (leading space: ...)" line reports the same leading-space decisions as before.

- [ ] **Step 5: Commit**

```bash
git add Sources/Sotto/Core/TextInjector.swift
git commit -m "perf(inject): read one character before the caret instead of the whole document"
```

---

## Phase 6 (optional, changes a spec contract) — Paste-path run-on spacing

The pasteboard fallback never adds a leading space, so consecutive dictations into Chromium and Electron apps (Slack, VS Code, browsers) run together. The "cannot read the target at all, so it never does this" statement lives in a source comment on `TextInjector.needsLeadingSpace`, not in spec §6.8; separately, spec §11 ("Later") lists paste-path leading space as a future item. So this task adds the rule to §6.8, removes it from the §11 backlog, and updates the source comment. It is a judgement call: it misfires (a spurious leading space) if the user moved the caret between two dictations into the same app. Scope it narrowly and default it conservatively. Drop this phase entirely if the misfire risk is not worth it.

### Task 12: Add a leading space when a paste immediately follows our own paste into the same app

**Files:**
- Modify: `Sources/Sotto/Core/TextInjector.swift` (paste-path rule and the `needsLeadingSpace` source comment)
- Modify: `docs/SPEC.md` (§6.8 paste path, and remove the §11 "Later" item)

**Interfaces:**
- Produces: on the paste path, `insert` prepends a single space when the previous injection was ours, into the same frontmost app, within `pasteRunOnWindow`, and did not end in whitespace.

- [ ] **Step 1: Record the last-injection context**

In `Sources/Sotto/Core/TextInjector.swift`, add state and a token, near the other `private static var` declarations:

```swift
    /// Only treat back-to-back dictations into the same app as a run-on. Beyond this the
    /// user has almost certainly moved on, and a leading space would be wrong.
    private static let pasteRunOnWindow: Duration = .seconds(8)

    private struct LastInjection {
        let bundleID: String?
        let at: ContinuousClock.Instant
        let endedInWhitespace: Bool
    }
    private static var lastInjection: LastInjection?
    private static let injectionClock = ContinuousClock()
```

Record it at the end of both successful paths. After a verified AX write (end of `insertViaAccessibility` returning nil) and after a successful paste, set:

```swift
        lastInjection = LastInjection(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            at: injectionClock.now,
            endedInWhitespace: inserted.last?.isWhitespace ?? false
        )
```

(For the paste path, use the pasted `text` for the last-character check.)

- [ ] **Step 2: Prepend a space on a qualifying paste**

In `insertViaPasteboard(_:)`, before writing to the pasteboard, compute whether this is a run-on and adjust the text:

```swift
        let outgoing = Self.pasteRunOnLeadingSpaceNeeded() ? " " + text : text
```

Add the predicate:

```swift
    /// True when this paste immediately follows our own injection into the same frontmost
    /// app, recently, and that text did not already end in whitespace. Conservative on
    /// purpose: it never fires across apps or after a pause, so a moved caret in a different
    /// context cannot trigger a spurious space.
    private static func pasteRunOnLeadingSpaceNeeded() -> Bool {
        guard let last = lastInjection, !last.endedInWhitespace else { return false }
        let now = injectionClock.now
        guard now - last.at <= pasteRunOnWindow else { return false }
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return current != nil && current == last.bundleID
    }
```

Use `outgoing` in place of `text` for the `setString` call and the change-count logging; keep restoring the user's pasteboard exactly as today.

- [ ] **Step 3: Build**

Run: `make build`
Expected: `Build complete!`

- [ ] **Step 4: Verify by running**

Run: `make install`. In Slack (or VS Code): dictate a sentence, then, without clicking away, dictate a second. Confirm the second arrives with a leading space instead of glued to the first. Then click elsewhere, wait, and dictate again; confirm no stray leading space at a fresh caret. Confirm single dictations into native fields (TextEdit) are unaffected (they take the AX path).

- [ ] **Step 5: Update the spec and the source comment**

Three edits so the contract, backlog, and code agree:
- `docs/SPEC.md` §6.8: add the bounded rule to the paste-path description: the paste path adds one leading space only when the previous injection was Sotto's own, into the same frontmost application, within eight seconds, and did not end in whitespace; otherwise it pastes the text unchanged. Note the deliberate tradeoff (a moved caret within that window and app is a rare false positive, preferred over reliably-glued run-ons in Electron and Chromium apps).
- `docs/SPEC.md` §11 ("Later"): remove the paste-path leading-space item, since it now ships.
- `Sources/Sotto/Core/TextInjector.swift`: update the `needsLeadingSpace` comment that says the paste path "cannot read the target at all, so it never does this" to describe the new bounded same-app run-on rule.

- [ ] **Step 6: Commit**

```bash
git add Sources/Sotto/Core/TextInjector.swift docs/SPEC.md
git commit -m "feat(inject): space consecutive pastes into the same app to stop run-ons"
```

---

## Phase 7 — Minor per-utterance cleanups

Two small inefficiencies the survey flagged. Neither is felt today; both are cheap to remove.

### Task 13: Memoise the corrector by revision and compile its rules once

The survey named two costs: rebuilding the corrector's candidate patterns per hold, and (the larger one) recompiling every `NSRegularExpression` inside `DictionaryCorrector.apply` per hold. The original code recompiled per call on the belief that `NSRegularExpression` is not `Sendable`; the Codex review confirms the macOS 26 Foundation header marks immutable, thread-safe `NSRegularExpression` `Sendable`, so the rules can be compiled once and reused. This task fixes both, so there is no per-utterance regex compile left.

**Files:**
- Modify: `Sources/Sotto/Dictionary/DictionaryStore.swift` (memoise `corrector` by `revision`)
- Modify: `Sources/SottoDictionary/DictionaryCorrector.swift` (compile rules once at init)
- Test: `Tests/SottoAppTests/DictionaryStoreTests.swift` (memoisation)
- Test: `Tests/SottoDictionaryTests/DictionaryCorrectorCompileTests.swift` (behaviour unchanged after compile-at-init)

**Interfaces:**
- Produces: `DictionaryStore.corrector` rebuilds only when `revision` changes (`correctorBuildCount` for tests); `DictionaryCorrector` compiles its `NSRegularExpression` rules once at init and reuses them in `apply`, removing the per-utterance recompile.

- [ ] **Step 1: Write the failing store-memoisation test**

Add to `Tests/SottoAppTests/DictionaryStoreTests.swift`, using the file's existing `withSandbox` helper (match its exact signature; the surrounding tests build a store as `DictionaryStore(fileURL: sandbox.fileURL)`):

```swift
    @Test func correctorIsRebuiltOnlyWhenEntriesChange() throws {
        try withSandbox { sandbox in
            let store = DictionaryStore(fileURL: sandbox.fileURL)
            store.add(.correction(hear: "cloud code", write: "Claude Code"))
            let baseline = store.correctorBuildCount
            _ = store.corrector
            _ = store.corrector
            #expect(store.correctorBuildCount == baseline + 1)

            store.add(.correction(hear: "vs code", write: "VS Code"))
            _ = store.corrector
            #expect(store.correctorBuildCount == baseline + 2)
        }
    }
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `make test 2>&1 | grep -A3 correctorIsRebuilt`
Expected: FAIL, `correctorBuildCount` not found.

- [ ] **Step 3: Cache the built corrector in the store**

In `Sources/Sotto/Dictionary/DictionaryStore.swift`, replace the computed `corrector` with a memoised one:

```swift
    /// Rebuilds only when `entries` change. Building parses and compiles each trigger, so
    /// doing it once per dictionary edit, not once per hold, keeps the press path clean.
    @ObservationIgnored private var cachedCorrector: (revision: Int, value: DictionaryCorrector)?
    @ObservationIgnored private(set) var correctorBuildCount = 0

    var corrector: DictionaryCorrector {
        if let cached = cachedCorrector, cached.revision == revision {
            return cached.value
        }
        let built = DictionaryCorrector(entries: entries)
        cachedCorrector = (revision, built)
        correctorBuildCount += 1
        return built
    }
```

`revision` already bumps on every edit and every reload that changes entries, so the cache invalidates correctly.

- [ ] **Step 4: Compile the rules once at init (library target)**

In `Sources/SottoDictionary/DictionaryCorrector.swift`, move compilation from `apply` to `init` so it happens once per corrector (which, with Step 3, is once per dictionary change):

- Mark the compiled-rule type `Sendable`: `struct CompiledRule: Sendable { let regex: NSRegularExpression; let write: String }`. Immutable `NSRegularExpression` is `Sendable` on macOS 26, so this keeps `DictionaryCorrector` a `Sendable` value.
- Store `private let rules: [CompiledRule]` on the corrector. In both `init(entries:)` and the test seam `init(candidates:)`, call `Self.compile(candidates)`, log each failure once via `logCompileFailure`, and keep `compiled.rules`.
- In `apply(to:)`, delete the `let compiled = Self.compile(candidates)` line and its per-call failure logging; use `self.rules` directly (keep the existing `guard !rules.isEmpty else { return (normalized, []) }`).
- Update the doc comment on `CompiledRule` that says it is "not `Sendable` (`NSRegularExpression`), so it is never stored on the corrector" to note it is compiled once at init and reused.

- [ ] **Step 5: Guard the compile-at-init change with a library test**

Add `Tests/SottoDictionaryTests/DictionaryCorrectorCompileTests.swift` asserting a corrector built once applies the same corrections across repeated `apply` calls (a regression net for moving compilation to init), following the existing `DictionaryCorrectorTests` style:

```swift
import Testing
@testable import SottoDictionary

@Suite
struct DictionaryCorrectorCompileTests {
    @Test func repeatedApplyIsStableAfterCompileAtInit() {
        let corrector = DictionaryCorrector(entries: [
            .correction(hear: "cloud code", write: "Claude Code"),
        ])
        let first = corrector.apply(to: "open cloud code now")
        let second = corrector.apply(to: "open cloud code now")
        #expect(first.text == "open Claude Code now")
        #expect(second.text == first.text)
        #expect(first.applied == second.applied)
    }
}
```

If `DictionaryEntry.correction(hear:write:)` is a test-only convenience in the app tests rather than `SottoDictionary`, construct the entry with the real `DictionaryEntry` initializer the library tests already use.

- [ ] **Step 6: Run the tests to confirm they pass**

Run: `make test 2>&1 | grep -A3 -E 'correctorIsRebuilt|repeatedApplyIsStable'`
Expected: PASS. The existing `DictionaryCorrector` and `DictionaryStore` suites stay green (behaviour is unchanged).

- [ ] **Step 7: Commit**

```bash
git add Sources/Sotto/Dictionary/DictionaryStore.swift Sources/SottoDictionary/DictionaryCorrector.swift Tests/SottoAppTests/DictionaryStoreTests.swift Tests/SottoDictionaryTests/DictionaryCorrectorCompileTests.swift
git commit -m "perf(dictionary): memoise the corrector by revision and compile its rules once"
```

### Task 14: Cache permission status instead of an IPC per menu render

**Files:**
- Create: `Sources/Sotto/Support/PermissionStatus.swift`
- Modify: `Sources/Sotto/UI/MenuBarContent.swift`
- Modify: `Sources/Sotto/UI/SettingsWindow.swift`
- Modify: `Sources/Sotto/App/SottoApp.swift`
- Test: `Tests/SottoAppTests/PermissionStatusTests.swift` (create)

**Interfaces:**
- Produces: `@MainActor @Observable final class PermissionStatus` with `hasAccessibility`, `hasMicrophone`, `refresh()`, and `static let shared`; injectable probes for tests. `MenuBarContent` and `SettingsWindow` read the shared instance instead of calling `Permissions` per body, and both refresh it when they appear so a menu open (which need not activate the app) shows current state.

- [ ] **Step 1: Write the failing test**

`Tests/SottoAppTests/PermissionStatusTests.swift`:

```swift
import Testing
@testable import Sotto

@MainActor
@Suite
struct PermissionStatusTests {
    @Test func refreshReflectsTheProbes() {
        var accessibility = false
        var microphone = false
        let status = PermissionStatus(
            accessibility: { accessibility },
            microphone: { microphone }
        )
        #expect(!status.hasAccessibility)
        #expect(!status.hasMicrophone)

        accessibility = true
        microphone = true
        status.refresh()
        #expect(status.hasAccessibility)
        #expect(status.hasMicrophone)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `make test 2>&1 | grep -A2 PermissionStatus`
Expected: FAIL, `PermissionStatus` not found.

- [ ] **Step 3: Add the observable**

`Sources/Sotto/Support/PermissionStatus.swift`:

```swift
import Foundation
import Observation

/// A cached, observable view of the two grants, so a SwiftUI body does not call
/// `AXIsProcessTrusted` (an IPC round trip to tccd) on every evaluation. Refreshed when the
/// app becomes active and by the Settings poll. Probes are injectable for tests.
@MainActor
@Observable
final class PermissionStatus {
    static let shared = PermissionStatus()

    private(set) var hasAccessibility: Bool
    private(set) var hasMicrophone: Bool

    @ObservationIgnored private let accessibility: () -> Bool
    @ObservationIgnored private let microphone: () -> Bool

    init(
        accessibility: @escaping () -> Bool = { Permissions.hasAccessibility },
        microphone: @escaping () -> Bool = { Permissions.hasMicrophone }
    ) {
        self.accessibility = accessibility
        self.microphone = microphone
        hasAccessibility = accessibility()
        hasMicrophone = microphone()
    }

    func refresh() {
        let newAccessibility = accessibility()
        let newMicrophone = microphone()
        if newAccessibility != hasAccessibility { hasAccessibility = newAccessibility }
        if newMicrophone != hasMicrophone { hasMicrophone = newMicrophone }
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `make test 2>&1 | grep -A2 PermissionStatus`
Expected: PASS.

- [ ] **Step 5: Read the shared status from the menu and settings**

In `Sources/Sotto/UI/MenuBarContent.swift`, replace `Permissions.hasAccessibility` / `Permissions.hasMicrophone` with `PermissionStatus.shared.hasAccessibility` / `.hasMicrophone`. Add `@State private var status = PermissionStatus.shared` and read through it so the menu observes changes. Because opening a menu-bar menu need not activate the regular app (so app-activation refresh alone can leave it stale), refresh when the menu content appears: attach `.onAppear { PermissionStatus.shared.refresh() }` to the menu content (wrap the items in a `Group` if needed so the modifier has something to attach to). The refresh is one IPC per menu open, not one per body evaluation, which is the cost this task removes.

In `Sources/Sotto/UI/SettingsWindow.swift`, replace the two `@State private var has...` fields and `refreshPermissions()` so they drive `PermissionStatus.shared.refresh()` and read its properties; keep the existing `onAppear`, `.task` poll, and `didBecomeActive` refresh, each now calling `PermissionStatus.shared.refresh()`.

- [ ] **Step 6: Refresh on activation app-wide**

In `Sources/Sotto/App/SottoApp.swift`, `applicationDidBecomeActive` already reloads the dictionary; add `PermissionStatus.shared.refresh()` there so the menu's cache is current whenever the app comes forward.

- [ ] **Step 7: Build, test, and spot-check**

Run: `make build && make test` (all green), then `make run`. Revoke and re-grant Accessibility in System Settings and confirm the menu's "Grant Accessibility..." item appears and disappears on app activation as before.

- [ ] **Step 8: Commit**

```bash
git add Sources/Sotto/Support/PermissionStatus.swift Sources/Sotto/UI/MenuBarContent.swift Sources/Sotto/UI/SettingsWindow.swift Sources/Sotto/App/SottoApp.swift Tests/SottoAppTests/PermissionStatusTests.swift
git commit -m "perf(ui): cache permission status instead of an IPC per menu render"
```

---

## Self-review

- **Idle CPU (survey item 1):** Tasks 2-4 (Canvas render + visibility pause + gated elapsed readout). Covered.
- **Debug install (item 2):** Task 1. Covered.
- **Capture latency (item 3):** Tasks 5-7 (locale/asset cache with single-flight, format cache, engine-instance reuse) cover the serial costs. Task 8's overlap reorder is deferred to its own plan; measure after 5-7 to decide if it is even needed.
- **History re-read (item 4):** Task 9 (in-memory prepend, store resolved before append, §6.13 edit). Covered.
- **Cleanup cold start (item 5):** deferred (Task 10). The reliable fix needs a retained-session design and an isolation check that do not belong in this batch; sketch recorded. Not covered in this plan.
- **AX full-document read (item 6):** Task 11 (bounded read with correct fall-back tri-state). Covered.
- **Paste run-ons (item 7):** Task 12 (optional; §6.8 + §11 + source-comment edits). Covered.
- **Corrector/regex recompile (minor):** Task 13 memoises the corrector by revision AND compiles the regex rules once at init (the per-`apply` recompile is removed, not deferred). Covered.
- **`AXIsProcessTrusted` per render (minor):** Task 14 (cached status, refreshed on menu open and activation). Covered.
- **Type consistency:** `MeterAnimation.shouldAnimate` (Task 2) is consumed by Tasks 3-4 with the same signature. `windowVisible` threads MainWindow -> Masthead -> MastheadMeterView/ElapsedReadout, wired in Task 4 (Task 3 adds only the reader and state, so Task 3 builds alone). `HistoryStore.prepend` / `HistoryLog.loadCount` (Task 9) match their test. `PermissionStatus` init/`refresh` (Task 14) match its test. `AudioCapture.prepareEngine` and the hoisted `AppComposition.capture` (Task 7) are used at SottoApp launch.
- **Risk order:** Phase 1 and Tasks 9/13/14 are low risk. Tasks 5-7 are moderate (framework-bound, verified by running). Tasks 8 and 10 are deferred as needing their own design. Task 12 changes a spec contract and is optional.
- **Codex review status:** revision 2 folds in every P1/P2/P3 from `docs/reviews/2026-09-02-codex-plan-review.md`. The two P1s that were design-level (Task 8 audio loss, Task 10 prewarm semantics) are resolved by deferral with corrected sketches; the rest are fixed in place.
