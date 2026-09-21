# Sotto

> **sotto voce** *(adverb, Italian: "under the voice")* — in a quiet voice, as if not to be overheard.

Hold a key, say it under your breath, let go. Sotto writes it where you were typing.

Push-to-talk dictation for macOS. Hold a key, talk, release, and cleaned-up text lands in
whatever text field has focus: a terminal, an editor, a chat box, a prompt for a coding
agent. Everything runs on your Mac: Apple's on-device speech engine (or NVIDIA Parakeet as
an experimental second engine), optional on-device cleanup with Apple's Foundation Model, a
personal dictionary for the names and jargon speech models get wrong, and local history.
No accounts, no network, no subscription.

Built for talking to Claude Code, Codex and the like all day without typing, but it works in
any app that takes text.

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

## Building from source

`make app` signs the bundle with a Developer ID Application identity from your keychain and
refuses to sign ad-hoc, because an ad-hoc signature changes on every build and macOS resets
the Accessibility grant each time. If you have no Developer ID, `make app SIGN_ID=-`
produces a throwaway build; expect to re-grant Accessibility after each rebuild.

The library targets (`SottoText`, `SottoDictionary`) are tested first and `docs/SPEC.md` is
the contract every module is written against. Contributions are welcome; keep to the spec,
or change the spec in the same change. There is no CI; run `make test` locally.

## Privacy

Nothing you say or type leaves the Mac. There is no account, no server and no analytics.
macOS itself may download Apple's speech model for your language the first time it is needed.

## Design and status

Built clean-room from a written spec, with the modules implemented independently against it.
See `docs/SPEC.md` for the architecture and module contracts, and `docs/reviews/` for the
external reviews the spec and the code went through.

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) runs the
  experimental Parakeet engine on CoreML.
- [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and
  Parakeet CTC 110M (CC-BY-4.0) are downloaded on first use of that engine; they are not
  part of this repository.
- Apple's Speech and Foundation Models frameworks provide the default engine and cleanup.

## License

MIT. See [LICENSE](LICENSE).
