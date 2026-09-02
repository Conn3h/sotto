# Codex delta review of fix batch 1, 2026-09-02

Run: `codex exec ... -c model_reasoning_effort=high review --base 61e88e6` (standard tier, fix delta). All four findings fixed in the following commit.

The patch leaves a clipboard-restoration gap that can expose dictated text, rejects dictionary values that the documented format supports, and contains UI state-management regressions. These issues require code changes despite the added tests.

Full review comments:

- [P1] Register clipboard restoration before the first suspension — /Users/conneh/code/sotto/Sources/Sotto/Core/TextInjector.swift:184-184
  During the 40 ms settle wait, `setString` has already replaced the clipboard but `pendingRestore` is still nil because it is scheduled only after Command-V. If the app terminates in this window, `flushPendingRestore()` restores nothing and dictated text remains on the clipboard; register the pending snapshot immediately after recording `changeCount`, before awaiting.

- [P2] Allow representable correction outputs — /Users/conneh/code/sotto/Sources/SottoDictionary/DictionaryRepresentability.swift:37-40
  For corrections, `write` appears after the first structural arrow, so values beginning with `#` or containing another `->` round-trip correctly; the current unconditional checks reject valid entries such as `x -> y -> z` or `tag -> #swift`, and even prevent editing such entries loaded from disk. [`CLAUDE.md:3-4`](/Users/conneh/code/sotto/CLAUDE.md#L3-L4) makes the specification contractual, and [`docs/SPEC.md:679-683`](/Users/conneh/code/sotto/docs/SPEC.md#L679-L683) explicitly defines this first-arrow behavior.

- [P2] Preserve drafts when dictionary mutations are refused — /Users/conneh/code/sotto/Sources/Sotto/UI/DictionaryPanel.swift:130-130
  When `DictionaryStore.loadFailed` is true, a representable draft still enables Add; the store refuses the mutation, but the action then clears both fields. Save similarly closes editing after a refused update, losing the user's draft without visible feedback. Include `loadFailed` in both disabled conditions or make the mutators report success and only reset the UI after success.

- [P3] Keep canceled timers from clearing replacement handles — /Users/conneh/code/sotto/Sources/Sotto/UI/HistoryPanel.swift:184-186
  On a second Copy click, the old task is canceled and a new task is assigned, but the old task's cancellation handler subsequently sets `copyFeedbackTask` to nil, discarding the new handle. A third click can therefore no longer cancel that timer, allowing it to clear feedback belonging to the newer click; use a generation token or otherwise ensure only the currently stored task clears the handle.