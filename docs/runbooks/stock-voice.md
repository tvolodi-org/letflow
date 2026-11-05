# Stock voice service: settings and provider clients (REQ-740)

The voice service turns a spoken or typed phrase into a stock draft. This runbook covers the
settings and the two outbound clients (`Letflow.Voice.Settings`, `Letflow.Voice.SpeechClient`,
`Letflow.Voice.ModelClient`, with the shared `Letflow.Voice.Http`). The two routes
that call them are described under "Routes" (REQ-741).

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

## Routes (REQ-741 / GH #3879; stock 0.12.0)

Both routes are in module `stock` (`/api/v1/modules/stock`), permission `StockPost` (no new atom), same guard
as the document routes: a tenant-wide interactive user only; an API token or a scoped grant gets the same 404
as a tenant without the module; a role without `StockPost` gets 403. The tenant comes from the token only.

| Route | Body | 200 |
|---|---|---|
| `POST /voice/draft` | multipart: `audio` (file, m4a or WebM) and `lang` (`ru` or `kk`, both required) | `kind, items, location, to_location, quantity, transcript, dropped` |
| `POST /voice/draft-text` | JSON `text` (required), `lang` (`ru` or `kk`, optional) | the same seven keys |

Nothing is stored (no record, event, audit entry, audio or transcript) and nothing of the request is logged.
The audio limit is 10 MB (10,485,760 bytes), checked by the route on the uploaded file; the multipart parser
above it allows 25 MB, so a file between the two reaches the route and gets 413. The format is read from the
first bytes (m4a `ftyp` at offset 4, WebM `1A45DFA3` at offset 0), not from the declared content type. The
item and location lists sent to the model are the tenant's own active records, not capped (a size cap is an
open owner question), and the answer is checked on the server by `VoiceDraft.check/3`.

| Case | Status | `reason` | `source` | `field` |
|---|---|---|---|---|
| text missing, blank or not a string; audio part missing | 422 | `field_invalid` | | `text` / `audio` |
| any other key in the body | 422 | `field_not_allowed` | | that key |
| `lang` not exactly `ru` or `kk` (audio: also missing) | 422 | `bad_language` | | |
| audio over 10 MB | 413 | `audio_too_large` | `speech` | |
| audio neither m4a nor WebM | 415 | `audio_format` | `speech` | |
| speech step not configured (audio route only) | 503 | `speech_off` | `speech` | |
| speech provider failed / timed out | 502 / 504 | `provider_error` / `provider_timeout` | `speech` | |
| model provider failed / timed out / refused / truncated | 502 / 504 / 502 / 502 | `provider_error` / `provider_timeout` / `refused` / `truncated` | `llm` | |
| model answer is not the expected JSON | 502 | `bad_answer` | `llm` | |
| model step not configured | 200 | body with `notice: "llm_off"`, empty draft, the transcript | | |

A request holds a tenant admission slot for up to two provider calls of 60 s each; a per-user rate limit is an
open owner question.
