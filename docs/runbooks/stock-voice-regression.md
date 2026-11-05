# Stock voice regression tests (T-1348 / D2d)

A fixed list of 20 phrases (10 Russian, 10 Kazakh) with the draft each must give, kept in
`test/fixtures/voice/phrases.yaml`. It guards the prompt, the server check and the routes of the voice
draft (REQ-740, REQ-741; design: `docs/assets/voice-port-design.md` section 8).

## Layers

| Layer | Test file | Runs | Needs |
|---|---|---|---|
| Typed, stored model answers | `test/letflow/modules/stock/voice_regression_test.exs` (R-1..R-9) | every `mix test` | nothing |
| Typed, real model (`:voice_live`) | same file, test L-1 | `mix test --include voice_live <file>` | the four `LETFLOW_VOICE_LLM_*` values |
| Audio through speech to text (`:voice_audio`) | `voice_audio_regression_test.exs` (A-1) | `mix test --include voice_audio <file>` | audio files, manifest, provider keys |

The typed layer sends each phrase text through the real `VoiceService.draft_text/2`: the real prompt
builder reads a fixture tenant's catalog, the real parser and `VoiceDraft.check/3` check the answer. Only
the model client is a double, and it returns the phrase's stored `model_answer`. The expected draft is
compared with what the service returns, so a change to the prompt path or the check shows. Four phrases
(`ru-01`, `ru-04`, `kk-01`, `kk-04`) also go through the full router to cover response shaping.

## The phrase file

Each entry has `id`, `lang`, `split` (`tune` 6 and `heldout` 4 per language, fixed), `cases` (labels),
`text`, `model_answer` and `expected`. Each of the hard cases letter article, zone word, shared name,
transfer and missing quantity appears at least twice per language (test R-5). Change the split only with
a written reason in the file header.

## What is not done yet (owner inputs)

- **Audio layer is disabled.** The recorded phrases, the one-time generation script (ElevenLabs), the
  audio files with `manifest.yaml` (sha256 per file) and the nightly run with provider keys need the owner's
  account and keys. Until then A-1 is excluded by default and fails with "no audio manifest" if included.
- **Kazakh texts are drafts.** Every `kk-*` entry has `checked_by: pending_native`; a native check may
  change texts but not the split.
- **L-1 reports and gates nothing.** It prints per-language and tune/heldout counts; whether it gates is
  the owner's decision (section 8.3).
- Only `ru` and `kk`: the route accepts no other language.
