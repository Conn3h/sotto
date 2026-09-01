# Sotto

Push-to-talk dictation for macOS. Hold a key, talk, release, and cleaned-up text lands in
whatever text field has focus. Everything runs on your Mac: Apple's on-device speech
engine, optional on-device cleanup with Apple's Foundation Model, a personal dictionary,
and local history. No accounts, no network.

Requires macOS 26 and Xcode 26.

## Quick start

```bash
make install     # builds, signs, installs to /Applications, launches
```

Then grant two permissions, neither of which can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| Accessibility | System Settings > Privacy & Security > Accessibility | Seeing the push-to-talk key and inserting text |
| Microphone | Prompted on first dictation | Audio capture |

Sotto notices the Accessibility grant on its own; no restart needed. Then hold
**Right Option** and talk.

Other targets: `make test`, `make app`, `make run`, `make clean`.

## Design and status

See `docs/SPEC.md` for the architecture, module contracts, and the milestone plan.
