# Sotto

Push-to-talk dictation for macOS, on-device, native Swift 6. Read `docs/SPEC.md` before
changing anything; it is the source of truth for v1 and every interface in it is a contract.

## Rules

- **Clean room.** Sotto is written from the spec. Do not read, search, or copy code from
  any other dictation project, on this machine or elsewhere. Author prompts, test vectors
  and copy fresh.
- **Build with `make`**, never bare `swift build`. Products live in `~/Library/Caches/SottoBuild`.
  `make test` runs the library tests; `make install` signs and installs to /Applications.
- **Swift 6 language mode, strict concurrency.** `MainActor.assumeIsolated` is allowed in
  exactly one place: the C event-tap callback in `HotkeyMonitor`, with a comment.
- **Tests first for the library targets** (`SottoText`, `SottoDictionary`). Confirm a new
  test fails before making it pass.
- **Every failure is logged.** No `try?` without a log line. Non-user values are logged
  with `privacy: .public`. Transcript text is never logged; log its length.
- **No literal values in views.** Colours, sizes, radii, fonts and durations come from
  `DS` in `UI/DesignSystem.swift`. Add a token rather than inlining a number.
- **Red means recording** and nothing else. Meter colours appear only in meters. No
  gradients, no glow.
- **The HUD never becomes key.** Do not change `canBecomeKey` / `canBecomeMain`.
- **No GitHub Actions** for now. Tests run locally.
- Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`). No AI attribution
  in commit messages.
- No emojis in code, comments, or logs.

## Diagnostics

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.conn3h.sotto"' --style compact
```

Spell out `/usr/bin/log`; `log` is often shadowed. If the Accessibility grant wedges after
a signing change, reset only this app's row and then quit System Settings fully:

```bash
tccutil reset Accessibility com.conn3h.sotto
```
