# Sotto — v1 specification

Push-to-talk dictation for macOS, entirely on-device. Hold a key, talk, release, and
cleaned-up text lands in whatever text field has focus. Native Swift 6, SwiftUI, Apple's
`SpeechAnalyzer`, no third-party dependencies, no network.

This document is the source of truth for v1. Implementers work from it, not from any other
dictation app. Interfaces below are contracts between milestones that are built in
parallel; do not rename them without updating every consumer named in §9.

---

## 1. Product definition

- **Hold a key, speak, release.** Right Option by default; Right Command and fn are the
  alternatives. Nothing is ever recorded unless the key is down.
- **Live text while speaking** in a small floating HUD that never steals focus.
- **Cleanup before insertion.** Deterministic rules always; optionally Apple's on-device
  Foundation Model for smarter cleanup, with the rules as fallback.
- **A personal dictionary.** Words the engine should know, and "when you hear X, write Y"
  corrections. Editable in the app and as a plain text file.
- **History.** Every dictation kept locally, searchable, copyable, deletable.
- **A real app.** Dock icon, main window, Settings on ⌘, and a menu bar item for status.

## 2. Non-goals for v1

Explicitly out: Windows, any non-Apple speech engine (the engine seam exists; only one
implementation ships), comparison tooling against other dictation apps, command mode
("make this more formal"), onboarding flow, notarization, an installer, cloud anything,
GitHub Actions (tests run locally via `make test`; CI stays off for now).

## 3. Clean-room rule

Sotto is written from this spec. **Do not read, search, or copy code from any other
dictation project**, including anything elsewhere on this machine. The spec was written by
someone who studied prior art; the implementation is written by someone who has not. Test
vectors, prompts, and copy are authored fresh. If the spec is ambiguous, choose the simplest
behaviour that satisfies the acceptance criteria and note the choice in your report.

## 4. Architecture and data path

```
 key down ─► HotkeyMonitor ──► DictationController ◄── Settings
                                    │
                        ┌───────────┼─────────────┐
                        ▼           ▼             ▼
                  AudioCapture   HUD (observes)  TranscriptionEngine
                        │                          (AppleSpeechEngine)
                   AudioChunk ──ordered stream──►  │
                                                   ▼
                                           TranscriptSnapshot (full text so far)
                                                   │
 key up ──► controller drains, finishes engine, hands the final text to:
                                                   ▼
                                          UtterancePipeline
                                    format ─► dictionary ─► inject ─► history
                                                   │
                                            TextInjector ─► focused app
```

Invariants that the whole design rests on:

1. **The HUD never becomes key.** If it took focus, the target text field would lose it and
   there would be nothing to insert into.
2. **Audio reaches the engine in capture order.** One `AsyncStream` drained by exactly one
   task. Never spawn a task per buffer.
3. **Audio buffers are copied before crossing threads.** `AVAudioEngine` reuses the buffer
   it hands a tap the moment the callback returns.
4. **The engine's preferred format wins.** Apple's analyzer has a hard precondition on
   sample format (it terminates the process on a mismatch rather than throwing), so capture
   converts to whatever the engine asks for.
5. **Release is idempotent.** A second release, or a press during the finishing phase,
   must not run the tail twice.
6. **Every failure is logged**, with enough public context to diagnose from the unified log
   without a debugger. `try?` without a log line is not allowed anywhere in this codebase.

## 5. Package layout

```
Package.swift                 tools 6.2, macOS 26, three targets + two test targets
Makefile                      build / test / app / run / install / clean (see §7)
Resources/                    Info.plist, Sotto.entitlements, AppIcon.icns (later)
Sources/
  SottoText/                  Foundation-only. TextFormatter, RuleBasedFormatter,
                              PassthroughFormatter, CleanupGuard.
  SottoDictionary/            Foundation-only. DictionaryEntry, DictionaryFile,
                              DictionaryCorrector, AppliedCorrection, DictionaryWarning.
  Sotto/
    App/                      SottoApp.swift (scenes, AppDelegate), Composition.swift
    Core/                     DictationController, HotkeyMonitor, AudioCapture, TextInjector,
                              UtterancePipeline
    Speech/                   TranscriptionEngine (protocol, AudioChunk, TranscriptSnapshot),
                              AppleSpeechEngine
    Cleanup/                  FoundationModelFormatter
    Dictionary/               DictionaryStore
    History/                  DictationRun, HistoryLog, HistoryStore
    UI/                       DesignSystem, HUDPanel, HUDView, MainWindow, SettingsWindow,
                              DictionaryPanel, HistoryPanel, MenuBarContent, Components
    Support/                  Log, Settings, Permissions
Tests/
  SottoTextTests/
  SottoDictionaryTests/       includes vectors.json (authored here, see §6.9)
docs/SPEC.md                  this file
```

Identifiers: app name **Sotto**, executable `Sotto`, bundle id `com.conn3h.sotto`, log
subsystem `com.conn3h.sotto`, Application Support directory
`~/Library/Application Support/Sotto/` holding `dictionary.txt` and `history.jsonl`.

## 6. Module specifications

Types are Swift 6 language mode, strict concurrency. `@MainActor` where stated. Public API
of the two library targets is `public`; everything in the app target is internal.

### 6.1 Logging — `Support/Log.swift` (exists)

`enum Log` with one `os.Logger` per category: `app`, `hotkey`, `audio`, `speech`, `inject`,
`dictionary`, `history`. Rules: interpolate non-user values with `privacy: .public`; never
log transcript text (log `text.count` instead); every caught error is logged at `.error`
with what was being attempted.

### 6.2 Settings — `Support/Settings.swift`

```swift
@MainActor @Observable final class Settings {
    static let shared: Settings
    var pushToTalkKey: PushToTalkKey     // default .rightOption
    var cleanupEnabled: Bool             // default true
    var smartCleanup: Bool               // default false (Foundation Model cleanup)
    var soundEnabled: Bool               // default true
}
```

Backed by `UserDefaults.standard`; each setter persists immediately. Read per-utterance by
consumers, so a change applies to the very next hold without a restart.

### 6.3 Permissions — `Support/Permissions.swift`

```swift
@MainActor enum Permissions {
    static var hasAccessibility: Bool            // AXIsProcessTrusted()
    static var hasMicrophone: Bool               // AVCaptureDevice status == .authorized
    @discardableResult static func promptForAccessibility() -> Bool   // AXIsProcessTrustedWithOptions with the prompt option
    static func requestMicrophone() async -> Bool
    static func openAccessibilitySettings()      // x-apple.systempreferences:… Privacy_Accessibility
    static func openMicrophoneSettings()
}
```

Note: `kAXTrustedCheckOptionPrompt` imports as a mutable global and is unusable from
strictly-concurrent code; spell the key out as the string `"AXTrustedCheckOptionPrompt"`.

### 6.4 Hotkey — `Core/HotkeyMonitor.swift`

```swift
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption, rightCommand, fn
    var keyCode: Int64          // kVK_RightOption 61, kVK_RightCommand 54, kVK_Function 63
    var flag: CGEventFlags      // see below
    var displayName: String     // "Right ⌥", "Right ⌘", "fn"
    var consumesEvent: Bool     // true for the two right-hand modifiers, false for fn
}

@MainActor final class HotkeyMonitor {
    var key: PushToTalkKey
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    @discardableResult func start() -> Bool   // false when the tap cannot be created (no Accessibility)
    func stop()
}
```

Behaviour:

- A `CGEvent.tapCreate` session tap (`.cgSessionEventTap`, `.headInsertEventTap`,
  `.defaultTap`) for `.flagsChanged` only, added to the main run loop in common modes.
  `NSEvent` global monitors cannot distinguish left from right modifiers or see fn, which
  is why a tap is required and why Accessibility is a hard requirement.
- **Use the device-specific modifier bits, not the public masks.** `.maskAlternate` is set
  when *either* Option key is down, so with Left Option held a Right Option release is
  invisible and the mic would stay open. Right Option is raw flag `0x40`, Right Command is
  `0x10`, fn is `.maskSecondaryFn`. Pressed state is `flags.contains(key.flag)` on an event
  whose keycode equals `key.keyCode`.
- Only transitions fire callbacks (track `isPressed`; ignore repeats).
- On `.tapDisabledByTimeout` or `.tapDisabledByUserInput`, re-enable the tap and pass the
  event through.
- Return `nil` from the callback to swallow the event when `consumesEvent`, otherwise pass
  it through untouched. fn is never swallowed: swallowing it breaks fn-arrow, fn-delete and
  the emoji picker.
- The C callback runs on the main thread because the run loop source is on the main run
  loop. Extract plain values (`keyCode`, `flags`, `type`) from the `CGEvent` first, then
  cross into the main actor. `MainActor.assumeIsolated` is permitted **here only**, with a
  comment saying why; nowhere else in the app.
- `stop()` disables the tap, removes the run loop source, and resets `isPressed`.

### 6.5 Audio — `Core/AudioCapture.swift`

```swift
struct AudioChunk: @unchecked Sendable { let buffer: AVAudioPCMBuffer }   // lives in Speech/TranscriptionEngine.swift

final class AudioCapture {   // @unchecked Sendable; all mutable state touched by the audio thread is nonisolated(unsafe)
    func start(outputFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AudioChunk) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void) throws
    func stop()
}
```

Behaviour: `AVAudioEngine` input node tap, buffer size 2048 frames in the node's native
format; an `AVAudioConverter` to `outputFormat` when they differ (output capacity =
frames × rate ratio, rounded up, plus headroom). When no conversion is needed the buffer is
**deep-copied** (invariant 3); conversion already allocates fresh storage. `onLevel` gets an
RMS level mapped from roughly −50…0 dBFS onto 0…1 so quiet speech still moves the meter.
Logs the native → engine sample rates on start, and every conversion error. `stop()` is
idempotent and clears the callbacks.

### 6.6 Transcription — `Speech/TranscriptionEngine.swift`, `Speech/AppleSpeechEngine.swift`

```swift
struct TranscriptSnapshot: Sendable {
    let text: String      // the FULL transcript so far, not a delta; consumers replace, never append
    let isFinal: Bool
}

protocol TranscriptionEngine: Actor {
    func preferredInputFormat() async -> AVAudioFormat?
    func start() async throws -> AsyncThrowingStream<TranscriptSnapshot, Error>
    func feed(_ chunk: AudioChunk) async
    func finish() async      // close input, flush, finish the stream
}

enum TranscriptionError: LocalizedError { case localeUnsupported(Locale), modelInstallFailed(String), noAudioFormat, notRunning }

actor AppleSpeechEngine: TranscriptionEngine {
    init(locale: Locale = .current, biasPhrases: [String] = [])
}
```

`AppleSpeechEngine` behaviour:

- Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26). `preferredInputFormat()` returns
  `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`.
- `start()`: throw `localeUnsupported` if `SpeechTranscriber.isAvailable` is false; resolve
  the locale with `supportedLocale(equivalentTo:)`, falling back to `en-US`; ensure the
  model assets are installed (`AssetInventory.assetInstallationRequest(supporting:)` then
  `downloadAndInstall()`, logging both ends, wrapping errors as `modelInstallFailed`);
  create the transcriber with `reportingOptions: [.volatileResults]` so text appears while
  speaking; if `biasPhrases` is non-empty, set an `AnalysisContext` whose
  `contextualStrings[.general]` is the phrase list **before any audio arrives**; start the
  analyzer with an `AsyncStream<AnalyzerInput>` as the input sequence; drain
  `transcriber.results` on a task that yields snapshots.
- Snapshot accumulation: final results are appended to a committed string; a volatile
  result is displayed appended to the committed text but never stored, so the next revision
  replaces it cleanly. Each snapshot's `text` is committed + volatile, trimmed.
- `feed` yields `AnalyzerInput(buffer:)`. `finish` ends the input stream, calls
  `finalizeAndFinishThroughEndOfInput()` (on error, log and `cancelAndFinishNow()`), yields
  a final snapshot, finishes the output stream, and releases the analyzer. Safe to call
  twice.
- Never log transcript text.

### 6.7 Controller — `Core/DictationController.swift`

```swift
struct UtteranceTiming: Sendable {
    let heldSeconds: TimeInterval   // key down → key up
    let releasedAt: Date
}

@MainActor @Observable final class DictationController {
    enum State: Equatable { case idle, starting, listening, finishing, error(String); var isActive: Bool }  // active = starting|listening|finishing
    private(set) var state: State
    private(set) var transcript: String     // live, drives the HUD
    private(set) var level: Float           // smoothed 0…1

    init(makeEngine: @escaping @MainActor () -> any TranscriptionEngine)
    /// Receives the final raw transcript once per utterance. Awaited before returning to idle.
    var onFinalTranscript: (@MainActor (String, UtteranceTiming) async -> Void)?

    @discardableResult func activate() -> Bool    // installs the hotkey from Settings; false = no Accessibility
    func deactivate()
    @discardableResult func reloadHotkey() -> Bool
    func startButtonRecording()                    // same path as key down
    func stopButtonRecording()                     // same path as key up
}
```

State machine:

- **press** (only from `.idle`): state `.starting`, clear transcript, stamp hold start.
  Then, on a main-actor task: request microphone (fail with a user-readable message if
  denied); build the engine via `makeEngine()`; `start()` it; get its preferred format
  (fail with `noAudioFormat` if nil); create the audio stream with
  `.bufferingNewest(64)`; start one detached drain task that feeds every chunk to the engine
  in order; start capture with `onBuffer` yielding into the stream and `onLevel` smoothing
  into `level` (`level += (new - level) * 0.35`); if the state is no longer `.starting`
  (the user already let go) tear down and return; else state `.listening`, play the start
  sound if enabled, and start a consumer task that copies each snapshot's text into
  `transcript`.
- **release** (only when active and not already `.finishing`): state `.finishing`, stop
  capture, zero the level, stamp release. Then: finish the audio stream, await the drain
  task, `await engine.finish()`, await the consumer task, drop the engine. If the transcript
  is blank, go `.idle`. Otherwise `await onFinalTranscript?(raw, timing)`, then `.idle` and
  clear the transcript. The controller does **not** know about formatting, the dictionary,
  injection, or history; that is the pipeline's job (§6.8).
- **fail(message)**: log, stop capture, cancel tasks, drop the engine, state
  `.error(message)`, and auto-return to `.idle` after 3 seconds unless the state changed.
- **deactivate**: stop the hotkey and cancel any in-flight dictation.
- No `MainActor.assumeIsolated` anywhere in this file.

### 6.8 Pipeline and injection — `Core/UtterancePipeline.swift`, `Core/TextInjector.swift`

```swift
@MainActor final class UtterancePipeline {
    init(engineName: String = "Apple")
    func process(raw: String, timing: UtteranceTiming) async
}

@MainActor enum TextInjector {
    static func insert(_ text: String)
}
```

`process`: choose the formatter per utterance (`Settings.cleanupEnabled` off →
`PassthroughFormatter`; on and `smartCleanup` and the Foundation Model available →
`FoundationModelFormatter`; otherwise `RuleBasedFormatter`); format; apply
`DictionaryStore.shared.corrector` **regardless of the cleanup setting** (biasing only
raises the odds of the right word, the correction pass guarantees it, so it must not be
switchable off by accident); record a `DictationRun` (§6.12) with `processSeconds` measured
from `releasedAt` to now, which is the latency the user actually feels; inject; play the end
sound if enabled. Log the count of corrections applied and the character count injected.

`TextInjector.insert` tries two strategies in order:

1. **Accessibility, verified.** Get the system-wide focused element; require
   `kAXSelectedTextAttribute` to be settable; read `kAXSelectedTextRangeAttribute` before
   the write; set the selected text to `text`; read the range again. **Only trust the write
   if the selection range moved.** Many apps (Electron, Chrome, most terminals) report the
   attribute settable, return success, and drop the text. The check is "moved", not "moved
   by exactly `text.utf16.count`", because autocorrect and newline normalisation can shift
   the caret by a different amount, and falling back after a write that did land would paste
   the text twice, which is worse than a missing paragraph.
2. **Pasteboard + ⌘V.** Save every pasteboard item's data by type; write `text` as a plain
   string; wait ~40 ms so the target observes the new pasteboard generation; post ⌘V as
   `CGEvent`s from a `.privateState` source with `flags = .maskCommand` set explicitly (do
   not inherit live hardware modifier state; the user may still be resting a finger on a
   key); wait ~500 ms for the asynchronous paste; restore the saved items.

Log which strategy was used and why the AX path was not trusted, with the character count.

### 6.9 SottoText — `Sources/SottoText/`

```swift
public protocol TextFormatter: Sendable { func format(_ raw: String) async -> String }
public struct RuleBasedFormatter: TextFormatter { public init() }
public struct PassthroughFormatter: TextFormatter { public init() }   // trims only

public enum CleanupVerdict: Sendable, Equatable { case accepted; case rejected(reason: String) }
public enum CleanupGuard {
    public static func evaluate(original: String, cleaned: String) -> CleanupVerdict
}
```

`RuleBasedFormatter.format`, in order:

1. Trim; empty in → empty out.
2. **Strip standalone fillers** `um, uh, erm, uhm, hmm, mhm` as whole words,
   case-insensitive, together with one trailing comma if present. Must not touch words that
   merely contain them (`umbrella`, `hummus`, `ums`).
3. **Spoken punctuation**: `new paragraph` → `\n\n`, `new line` → `\n` (whole-phrase,
   case-insensitive).
4. **Collapse whitespace**: runs of spaces/tabs to one space; remove spaces before
   `, . ! ? ; :`; three or more newlines to two; trim.
5. **Capitalise sentence starts.** The first letter of the text, and the first letter after
   a terminator (`.`, `!`, `?`) **that is followed by whitespace or end of text**, and after
   a newline. A terminator with a non-space character after it is not a sentence boundary,
   so `3.5 million` stays `3.5 million`, `www.example.com` is untouched, and `e.g.` is not
   turned into `E.G.` (the word after `e.g. ` will still be capitalised; that is an accepted
   limitation, not a bug). Text beginning with a digit (`3 apples`) capitalises nothing.
6. **Terminal punctuation**: if the last character is a letter or digit, append `.`.

`CleanupGuard.evaluate` decides whether a model-produced cleanup is recognisably a cleanup
of the input rather than an *answer* to it (dictate "what is the capital of France" and a
helpful model returns "The capital of France is Paris."). Three checks, in order:

1. **No invented content words.** Tokenise both strings to lowercase alphanumeric words,
   drop a small stop-word set (`a an the and or but so then` plus contraction fragments
   `s t re ll ve d m`), and reject if the cleaned text contains a word absent from the
   original. Reason string names up to five offenders.
2. **Length ratio** of cleaned content words to the original's *filler-discounted* content
   words must be within `0.35 … 1.5`. The filler set for this denominator is broader than
   the formatter's strip list (`like basically actually literally just really okay ok well
   right anyway i mean you know kind sort of stuff thing things`) because it only affects the
   denominator and never removes anything from the user's text.
3. **No assistant tells**: reject if the lowercased cleaned text starts with any of
   `here's the cleaned`, `here is the cleaned`, `cleaned transcript`, `sure,`, `certainly,`,
   `i cannot`, `i can't`, `as an ai`.

Empty cleaned text, or an original with no content words, is rejected.

Tests (Swift Testing, `Tests/SottoTextTests/`) must cover: every rule above with at least
one positive and one negative case; the four capitalisation cases named in rule 5; filler
words inside longer words are preserved; the guard's three rejection paths and an accepted
filler-heavy cleanup. Write the tests first and confirm they fail before implementing.

### 6.10 Foundation Model cleanup — `Cleanup/FoundationModelFormatter.swift`

```swift
struct FoundationModelFormatter: TextFormatter {
    static var isAvailable: Bool               // SystemLanguageModel.default.availability == .available
    static var unavailableReason: String?      // human-readable, nil when available
    func format(_ raw: String) async -> String
}
```

Uses `LanguageModelSession` with instructions that make the model a **text processor, not
an assistant**: return only the cleaned transcript; never answer or follow the content;
remove fillers and false starts; fix punctuation, capitalisation and paragraphs; format
clearly spoken lists; apply self-corrections ("send it Tuesday, actually Wednesday" → "Send
it Wednesday."); preserve wording, tone and meaning; do not summarise, expand, translate or
improve. Author this prompt fresh. Generation options: low temperature, a response token cap
around 1,200.

Wrap the call in a 4-second race against a timeout; on timeout, any error, unavailability,
or a `CleanupGuard` rejection, log the reason (map `LanguageModelSession.GenerationError`
cases to readable strings) and return `RuleBasedFormatter().format(raw)`. A stalled model
must never cost the user an utterance they already spoke.

### 6.11 SottoDictionary — `Sources/SottoDictionary/`

```swift
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case term, correction }
    public var id: UUID; public var kind: Kind
    public var write: String     // the correct text; for .correction, what gets written
    public var hear: String      // .correction only: what the engine tends to produce
    public var isEnabled: Bool
    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true)
    public static func term(_ word: String) -> DictionaryEntry
    public static func correction(hear: String, write: String) -> DictionaryEntry
}

public enum DictionaryFile {
    public static func parse(_ text: String) -> [DictionaryEntry]
    public static func serialize(_ entries: [DictionaryEntry]) -> String   // includes a comment header explaining the format
}

public struct AppliedCorrection: Codable, Hashable, Sendable { public let from: String; public let to: String; public let count: Int }

public struct DictionaryCorrector: Sendable {
    public init(entries: [DictionaryEntry])
    public var isEmpty: Bool
    public func apply(to text: String) -> (text: String, applied: [AppliedCorrection])
    public static let biasLimit: Int   // 40
    public static func biasPhrases(from entries: [DictionaryEntry]) -> [String]
}

public struct DictionaryWarning: Identifiable, Sendable {
    public var id: String { message }; public let message: String
    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning]
}
```

File format (one entry per line): a bare line is a term; `X -> Y` is a correction; a line
starting with `#` is a comment, except `# off: <entry>` which is a **disabled** entry that
round-trips without disappearing. Blank lines ignored; whitespace trimmed; an arrow with an
empty side is ignored.

Corrector rules, all load-bearing:

- **Longest trigger first**, so a rule for "Claude Code" wins over a rule for "Claude".
- **Whole matches only**, fenced by lookarounds on letters and digits
  (`(?<![\p{L}\p{N}])` … `(?![\p{L}\p{N}])`) rather than `\b`, which would let a trailing
  hyphen or apostrophe count as a boundary and let a rule bite into a longer word.
- **Glued words still match**: split the trigger on spaces and hyphens, escape each part,
  and join with `[\s\-]*`, so "cloud code" also matches "CloudCode" and "cloud-code".
- Case-insensitive. Replacement text is template-escaped.
- **NFC-normalise both the text and each trigger** before matching. macOS returns
  decomposed strings from several APIs; an accented trigger otherwise silently never fires.
- `applied` records what the engine actually produced (the matched substring of the first
  match), the replacement, and the match count, one entry per rule that fired.
- Regex features are restricted to: `\b \d \w \s`, character classes, greedy/lazy
  quantifiers, alternation, named groups, fixed-length lookbehind, lookahead, `\p{L}`,
  `$1`–`$9`. (Keeps the door open for a second implementation on another regex engine.)

`biasPhrases`: the `write` side of every enabled entry, trimmed, de-duplicated
case-insensitively, in file order, capped at `biasLimit`. Kept short on purpose: long
context lists make speech models drift and invent primed words on quiet audio, which is
worse than the misspelling they were meant to fix.

`DictionaryWarning.check`: only corrections can misfire. Warn when the trigger is a single
common English word (keep a short list of ~150 obvious ones), when it is a single word of
three characters or fewer, and when `write` equals `hear` case-insensitively. Never blocks.

Tests (`Tests/SottoDictionaryTests/`): a **vector file** `vectors.json` authored here,
an array of `{ "name", "entries": [{kind, write, hear?, enabled?}], "input", "expected" }`
with at least twenty cases covering: longest-first, whole-word fencing (prefix, suffix,
hyphenated neighbour), glued and hyphenated forms, case-insensitivity with case-preserving
replacement, NFC vs NFD input, disabled entries, multiple rules in one text, a trigger that
appears as part of a longer word and must not fire, and an applied-corrections count. Plus
direct tests for `DictionaryFile` round-tripping (including `# off:` and comments), bias
phrase capping and de-duplication, and each warning. Tests first.

### 6.12 Dictionary store — `Dictionary/DictionaryStore.swift`

```swift
@MainActor @Observable final class DictionaryStore {
    static let shared: DictionaryStore
    static var fileURL: URL                      // App Support/Sotto/dictionary.txt
    private(set) var entries: [DictionaryEntry]
    private(set) var revision: Int               // bumps on every change
    func add(_:)  func update(_:)  func delete(_:)  func delete(ids: Set<UUID>)
    func filtered(by query: String) -> [DictionaryEntry]   // localizedStandardContains on both sides
    var corrector: DictionaryCorrector           // rebuilt on demand; cheap
    var biasPhrases: [String]
}
```

Loads on init. Saves atomically after every edit via `DictionaryFile.serialize`; **a failed
save is logged at error level** (it means the UI shows an entry that will be gone on
relaunch). Watches the file with a `DispatchSource` file-system object source on the main
queue for write/delete/rename/extend, re-armed after every event because an atomic write
replaces the inode; an `isSaving` flag stops our own save from reading back as an external
edit. Hand edits in a text editor therefore show up in the UI live.

### 6.13 History — `History/`

```swift
struct DictationRun: Codable, Sendable, Identifiable {
    var id: UUID                   // decoded leniently: missing → fresh UUID, persisted on next rewrite
    let date: Date                 // releasedAt
    let engine: String
    let audioSeconds: Double       // key held
    let processSeconds: Double     // release → text ready
    let text: String
    var corrections: [AppliedCorrection]?
}

@MainActor enum HistoryLog {      // App Support/Sotto/history.jsonl
    static func record(_ run: DictationRun)
    static func load() -> [DictationRun]
    static func delete(ids: Set<UUID>)
    static func clear()
}

@MainActor @Observable final class HistoryStore {   // the UI's view of the log
    static let shared: HistoryStore
    private(set) var runs: [DictationRun]
    func reload()
}
```

Append one JSON line per run (ISO-8601 dates). `load` skips undecodable lines but logs how
many were skipped. `delete`/`clear` rewrite the whole file atomically. Every write failure is
logged. `record` reloads `HistoryStore`. There is no HTML dashboard.

### 6.14 UI

**Design direction: "quiet instrument".** Sotto is a tool you glance at, not a toy. Matte
surfaces, one accent, generous whitespace, tabular numerals for timings. In light
appearance: warm off-white panels on a slightly darker ground with ink-black text. In dark
appearance: near-black panels on true black with off-white text. Two rules that are not
negotiable: **the accent (a muted coral red) means "recording" and is used for nothing
else**, and **level meters use a restrained green-to-amber scale that appears nowhere else
in the chrome**. No gradients, no glow, no blur-heavy glass except the HUD's material
background, no decorative skeuomorphism. Depth comes from flat fills and hairline borders.

`UI/DesignSystem.swift` defines every token under `enum DS`: `Color` (ground, panel,
panelRaised, ink, inkSecondary, inkTertiary, hairline, accent, meterLow, meterHigh,
selection), `Space` (2, 4, 8, 12, 16, 24, 32), `Radius` (control 6, panel 10, hud 22),
`Font` (title, body, label, caption, readout — readout is monospaced digits), `Border`
(hairline 1), `Motion` (quick 0.12 s, panel 0.2 s, hud 0.16 s). **Views must not contain
literal colours, sizes, radii or durations.** If a component needs a value that is not a
token, add the token. Colours adapt to light/dark via `NSColor(name:dynamicProvider:)` or
asset-free dynamic colours; verify both appearances.

**HUD** — `UI/HUDPanel.swift`, `UI/HUDView.swift`. An `NSPanel` with
`[.borderless, .nonactivatingPanel]`, `isFloatingPanel`, level `.statusBar`,
`collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
`hidesOnDeactivate = false`, `ignoresMouseEvents = true`, transparent background, **and
`canBecomeKey` / `canBecomeMain` overridden to `false`** (invariant 1). Size 340 × 76,
positioned bottom-centre of the screen with the key window (fall back to the first screen),
96 pt above the visible frame's bottom. `present()` fades in over `DS.Motion.hud` and is a
no-op when already fully visible (state changes mid-utterance must not flicker);
`dismiss()` fades out and orders out on completion. Content: a 12-bar level meter (each bar
with a fixed phase offset so the group ripples rather than pumps; bars rest at a 3 pt floor
when inactive) and the live transcript, two lines, head-truncated, or "Listening…" /
"Transcribing…" / the error message depending on state. Hosted with `NSHostingView`.

**Main window** — `UI/MainWindow.swift`, single `Window` scene (not a `WindowGroup`),
default 860 × 620, minimum 720 × 520. Top: a transport strip with Record/Stop (same code
path as the hotkey), a recording lamp in the accent colour, a live level meter, and an
elapsed counter in readout digits. Below: a two-tab area, **History** and **Dictionary**.
History (`UI/HistoryPanel.swift`): search field, newest first, each row showing engine,
process time, time of day, the text (selectable), correction badges when any fired
(strikethrough "heard" → "written" ×count), a Copy button with a 1.4 s "Copied" state, and
a hover-only delete without confirmation; a footer with the count and a "Delete all" that
confirms. Dictionary (`UI/DictionaryPanel.swift`): search, an add row with a kind toggle
(term / correction), inline edit, enable toggle, delete, and the `DictionaryWarning`
messages shown inline when adding. Also a File-menu item "Reveal Dictionary File".

**Settings** — `UI/SettingsWindow.swift`, the standard `Settings` scene (⌘,). Sections:
Push to talk (segmented choice of the three keys; changing it calls
`controller.reloadHotkey()`), Cleanup (toggle; when on, a Smart cleanup toggle disabled with
the `unavailableReason` shown when the Foundation Model is unavailable), Sound (toggle), and
a Permissions section showing Accessibility and Microphone status with "Open System
Settings" buttons when either is missing. Fully qualify `SwiftUI.Settings` because the app
has its own `Settings` type.

**Menu bar** — `UI/MenuBarContent.swift`: icon `waveform` / `waveform.circle.fill` when
active; "Hold ⟨key⟩ to dictate"; Open Sotto; Settings…; Grant Accessibility… / Grant
Microphone… when missing; Quit.

### 6.15 App lifecycle — `App/SottoApp.swift`, `App/Composition.swift`

`Composition.makeController()` builds the controller with `makeEngine` returning
`AppleSpeechEngine(biasPhrases: DictionaryStore.shared.biasPhrases)` and sets
`onFinalTranscript` to the pipeline's `process`. `AppDelegate.applicationDidFinishLaunching`:
activation policy `.regular`; create the HUD; `controller.activate()`; if that fails, show
the Accessibility prompt and **poll once a second until trusted, then activate** (there is
no notification for the grant); observe `controller.state` with `withObservationTracking`
(re-registering on each change) to present/dismiss the HUD. `applicationWillTerminate`
deactivates the controller.

## 7. Build, signing, permissions

`make build` / `make test` / `make app` / `make run` / `make install` / `make clean`, see the
Makefile. Build products and the staged bundle live in `~/Library/Caches/SottoBuild`, never
in the repo. The bundle is signed with the first Developer ID Application identity found,
falling back to ad-hoc, with `--options runtime` and the entitlements file. Two grants are
needed and neither can be requested silently: Accessibility (event tap and AX insert) and
Microphone (prompted on first dictation). Because TCC keys grants to the code signature,
Developer ID signing is what makes a grant survive a rebuild. If a grant wedges, reset that
one row, always passing the bundle id (a bare `tccutil reset Accessibility` wipes every
app): `tccutil reset Accessibility com.conn3h.sotto`, then quit System Settings fully.

## 8. Testing and acceptance

- Library targets: Swift Testing, tests written before implementation, `make test` green.
- App target: no unit tests in v1 (it needs a window, a mic, and TCC). Acceptance is by
  running the app and reading `/usr/bin/log show --predicate 'subsystem == "com.conn3h.sotto"' --info --last 5m`
  (spell out `/usr/bin/log`; `log` is often shadowed in shells).

Milestone acceptance:

| Milestone | Done when |
|---|---|
| A1 core loop | Hold the key, speak, release: the log shows `listening for Right ⌥`, capture start with sample rates, analyzer start, capture stop, and `final transcript: N chars`. Holding Left Option while tapping Right Option still logs a release. A tap shorter than the engine start-up produces no error. Quitting during a hold does not crash. |
| A2 SottoText | `make test` passes every rule and guard case in §6.9. |
| A3 SottoDictionary | `make test` passes every vector and store test in §6.11. |
| A4 design tokens | `DS` compiles, colours resolve in both appearances, and a one-file `TokenSheet` preview view exists for later visual checks. |
| B1 pipeline | Dictating into TextEdit uses the AX path; dictating into Terminal uses paste and the clipboard is restored; the run appears in `history.jsonl`; a dictionary correction fires and is recorded; Smart cleanup falls back to rules when the model is unavailable, with the reason logged. |
| B2 HUD | The HUD appears bottom-centre on press without the target field losing focus (dictation still lands), shows live text, and disappears on idle without flicker across the starting→listening→finishing transitions. |
| C app shell | Main window, Settings, Dictionary and History panels work end to end with no literal values in views; both appearances checked. |
| V verification | Independent review confirms §4 invariants, §6.1 logging rules, no `try?` without a log, `MainActor.assumeIsolated` only in the tap callback, and the design rules in §6.14. |

## 9. Milestones and ownership

Batches run in order; agents within a batch run in parallel and own disjoint files.

| Batch | Agent | Owns (creates or edits) | Depends on |
|---|---|---|---|
| A | A1 core loop | `Support/Settings.swift`, `Support/Permissions.swift`, `Core/HotkeyMonitor.swift`, `Core/AudioCapture.swift`, `Core/DictationController.swift`, `Speech/*`, `App/SottoApp.swift` (AppDelegate wiring + retry poll), `App/Composition.swift` (initial: logging `onFinalTranscript`) | scaffold |
| A | A2 text | `Sources/SottoText/*`, `Tests/SottoTextTests/*` | scaffold |
| A | A3 dictionary | `Sources/SottoDictionary/*`, `Tests/SottoDictionaryTests/*` | scaffold |
| A | A4 tokens | `UI/DesignSystem.swift`, `UI/TokenSheet.swift` | scaffold |
| B | B1 pipeline | `Core/UtterancePipeline.swift`, `Core/TextInjector.swift`, `Cleanup/FoundationModelFormatter.swift`, `Dictionary/DictionaryStore.swift`, `History/*`, `App/Composition.swift` | A1–A3 |
| B | B2 HUD | `UI/HUDPanel.swift`, `UI/HUDView.swift`, `App/SottoApp.swift` (HUD create/present/dismiss only) | A1, A4 |
| C | C1 shell | `UI/MainWindow.swift`, `UI/HistoryPanel.swift`, `UI/DictionaryPanel.swift`, `UI/SettingsWindow.swift`, `UI/MenuBarContent.swift`, `UI/Components.swift`, `App/SottoApp.swift` (scenes) | B1, B2 |
| V | verifier | read-only review + `make test` + `make app` | C1 |

Agents do not commit; the orchestrator commits after each batch. Agents must not edit
`Package.swift`, the Makefile, or files owned by another agent in the same batch.

## 10. Traps checklist

Things that look wrong and are not, or look fine and will bite:

- Ad-hoc signatures reset TCC grants on every build (§7). Sign with a Developer ID.
- The public `.maskAlternate` cannot tell Right Option from Left Option (§6.4).
- Apple's analyzer kills the process on the wrong sample format; it does not throw (§4.4).
- An AX write can return success and do nothing; verify by caret movement (§6.8).
- `AVAudioEngine` recycles tap buffers on return; copy them (§4.3).
- `MainActor.assumeIsolated` asserts, it does not check. One permitted site (§6.4).
- Never make the HUD key (§4.1).
- Spawning a task per audio buffer silently reorders audio (§4.2).
- Unified log redacts interpolations without `privacy: .public` (§6.1).
- `log` is shadowed in some shells; use `/usr/bin/log`.
- Mutating `@State` inside a `Canvas` or `TimelineView` draw closure floods the log; keep
  animation physics in a plain reference type the view holds.
- Never build inside an iCloud-synced folder; the Makefile's scratch path exists for this.

## 11. Later

Parakeet via CoreML as a second engine (the seam exists), command mode on selected text,
first-run onboarding, notarization and a DMG, an app icon, streaming partials for batch
engines, per-app injection preferences.
