# Stock voice service: settings and provider clients (REQ-740)

The voice service turns a spoken or typed phrase into a stock draft. This runbook covers the
settings and the two outbound clients (`Letflow.Voice.Settings`, `Letflow.Voice.SpeechClient`,
`Letflow.Voice.ModelClient`, with the shared `Letflow.Voice.Http`). Nothing calls them yet; the
routes are REQ-741.

## Settings

Nine optional environment variables, read by `config/runtime.exs` into `config :letflow, :voice`.
All are unset by default. **An unset (or blank) value turns its step off**: the speech step needs
the four `STT` values, the model step the four `LLM` values (mode optional). With a step off,
typed and scanned entry keep working with no provider.

| Variable | Meaning | Default |
|---|---|---|
| `LETFLOW_VOICE_STT_PROVIDER` | speech provider kind; only `openai_transcriptions` is known | unset = off |
| `LETFLOW_VOICE_STT_MODEL` | transcription model name | unset = off |
| `LETFLOW_VOICE_STT_BASE_URL` | https base URL; the client posts to `<base>/audio/transcriptions` | unset = off |
| `LETFLOW_VOICE_STT_API_KEY` | bearer key for the speech provider | unset = off |
| `LETFLOW_VOICE_LLM_PROVIDER` | model provider kind; only `openai_chat` is known | unset = off |
| `LETFLOW_VOICE_LLM_MODEL` | chat model name | unset = off |
| `LETFLOW_VOICE_LLM_BASE_URL` | https base URL; the client posts to `<base>/chat/completions` | unset = off |
| `LETFLOW_VOICE_LLM_API_KEY` | bearer key for the model provider | unset = off |
| `LETFLOW_VOICE_LLM_JSON_MODE` | `schema`, `object` or `prompt` | unset = `prompt`; any other value = off |

The time limit per provider call is 60 s: app env `:timeout_ms` of the same block, not an env
var, so a test can lower it.

**Why env vars.** QA needs a provider endpoint and key, and an unset value must switch the step
off. The keys are platform settings like `LETFLOW_SMTP_PASSWORD`, not `Letflow.Secrets`
references: `Secrets.resolve/2` binds a reference to the caller's own tenant, so one platform key
cannot be resolved for a request of tenant A. Per-tenant keys stay an open question.

## Rules

- A key is never logged, answered, put in an error or shown by `inspect/1` (INV-4). Errors are bare
  atoms; the provider's answer body is never returned or logged.
- The base URL is checked with `Letflow.Webhooks.UrlValidator.validate/1` inside every call (INV-9):
  https only, private ranges refused; redirects are not followed. Residual: DNS may change between
  the check and the connect (same as webhooks); the base URL is operator-set, not tenant-set.
- One call is one request: no retry.
- Providers, accounts and who pays are the owner's (D-022, D-086); QA only, production keys are not approved.

## Failures (source is the client; the REQ-741 route attaches it)

| Client (source) | Error | Cause |
|---|---|---|
| `SpeechClient` (speech) | `:provider_error` | URL refused, non-2xx, not JSON, no `text`, transport error, redirect |
| `SpeechClient` (speech) | `:provider_timeout` | no answer within `:timeout_ms` |
| `ModelClient` (llm) | `:provider_error` | URL refused, non-2xx, unreadable body, no content, transport error |
| `ModelClient` (llm) | `:provider_timeout` | no answer within `:timeout_ms` |
| `ModelClient` (llm) | `:truncated` | `finish_reason` is `length` |
| `ModelClient` (llm) | `:refused` | the answer carries a refusal |
