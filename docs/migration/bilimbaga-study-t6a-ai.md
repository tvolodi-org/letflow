# BilimBaga study T6a: what the AI does and whether it is used

Task T6a of `docs/migration/bilimbaga-retirement-status.md` (criterion 6, AI). Read-only
study of the BilimBaga repo (`c:\Users\tvolo\dev\ai-dala\BilimBaga`). Written finding only:
no product code, test or requirement file changed, and nothing in the BilimBaga repo was
modified (files were read with `git show origin/main:<path>`; the local checkout is 170
commits behind, so `origin/main` at `2dd4254`, 2026-10-13, is the source of record).

## 1. What the AI does

It is **generation and assessment, not translation.** Four features use one LLM text client
(`GenerateText(ctx, prompt, model)`); there are no other AI call sites.

| Feature | Req | Route / trigger | Who | Files |
|---|---|---|---|---|
| Question generation: up to 10 draft questions from category, difficulty, context text; drafts are returned, never inserted | FR-BB71 | `POST /api/v1/admin/ai/generate-questions` | `questions:write` (examiner and up) | `backend/internal/ai/handler.go` (`HandleGenerateQuestions`), `service.go`, `prompt.go` (`generateQuestionsPromptTemplate`), `docs/requirements/FR-BB71.Question-generation-assist.md` |
| Short-text answer grading: scores an employee's free-text answer against the model answer (JSON `score_pct` and `reasoning`); any error falls back to `pending_manual` | FR-BB73 | called inside session grading, not a route | automatic, when AI is configured | `backend/internal/sessions/grading.go` (`AIGradingEngine`, `gradeShortText`), wired in `backend/cmd/api/main.go` |
| Exam performance insight summary, cached 24 h, `?refresh=true` bypasses the cache | FR-BB74 | `GET /api/v1/admin/ai/insights/{examId}` | `reports:read` | `ai/handler.go` (`HandleGetInsights`), `ai/insight_cache.go`, migration `028_ai_insight_cache` |
| Loyalty-session narrative | FR-BB75 | `GET /api/v1/admin/ai/loyalty-summary/{sessionId}` | `reports:read`, department scope checked in the service | `ai/handler.go` (`GetLoyaltyNarrative`), `ai/prompt.go` |

Translation is **not** AI. `backend/internal/questions/translation_service.go` and
`FR-BB24.Translation-API.md` are a manual per-locale store (`PUT .../translations/:locale`);
no file in `internal/questions/` calls the AI client. Machine translation does not exist in
BilimBaga, so there is nothing to port for it.

Router wiring: `backend/internal/router/router.go` (the three `/admin/ai/...` routes);
client wiring: `backend/cmd/api/main.go` (`ai.NewProviderClient(cfg.AI.Provider, cfg.AI.BaseURL, cfg.AI.APIKey, ...)`).

## 2. Provider and key handling

- Two provider adapters behind one interface (`ai/provider.go`, `NewProviderClient`):
  `anthropic` (`ai/client.go`, `POST https://api.anthropic.com/v1/messages`, header
  `x-api-key`, default model `claude-3-5-haiku-20241022`) and `openai_compatible`
  (`ai/openai_client.go`, `POST {base}/chat/completions`, `Authorization: Bearer`).
  The x.ai default is `https://api.x.ai/v1`, model `grok-4.7` (`backend/internal/config/ai.go`).
- Key source: environment only, never the database. `ANTHROPIC_API_KEY`, `AI_API_KEY`,
  `XAI_API_KEY` (or the lower-case `xai_api_key`), read in `config/ai.go`; compose files use
  `env_file: .env` (`deploy/docker-compose.{prod,qa,test}.yml`, `docker-compose.yml`). A single
  key for the whole deployment: **not per tenant.**
- Key hygiene already present: `AIConfig.String()` masks the key (`config/ai.go`);
  `logUpstreamFailure` replaces the key with `[redacted]` and truncates the body to 500
  characters before logging (`ai/provider.go`); an x.ai-named key is never used as an
  Anthropic key and is sent only to `api.x.ai`.
- Outbound URL handling: `AI_BASE_URL` must be absolute, https (http only for localhost) and
  carry no credentials (`checkBaseURL`, `config/ai.go`). It is operator config, not tenant
  input. Timeout `AI_TIMEOUT_SECONDS` (at most 150 s); nginx waits 180 s on the AI routes
  (`deploy/nginx.conf`).
- Cost control: per-user rate limit of 20 generate calls per hour (`rateLimit` in
  `ai/service.go`, counted in `ai_usage_log`, migration `025`); insights capped at
  `AI_INSIGHTS_DAILY_LIMIT` (default 50) per user per day.
- With no key the client is `unavailableClient`: AI routes answer 503 `AI_UNAVAILABLE`
  without a request, and grading uses the non-AI engine. The app boots without AI.
- Data sent out: question text, correct and model answers, and employees' free-text answers
  (grading); aggregate exam data (insights); loyalty-session data (narrative). Free-text
  answers are personal data and go to a third party.

## 3. Is production using it?

**Unverified.** Evidence read, and what it does and does not show:

- Code is wired in all three deployments (`env_file: .env`), so the feature is *possible*, but
  the deployed `.env` of `bilimbaga-test.ai-dala.com` (the customer demo, treated as
  production-class by `docs/requirements/DEC-001`) was not read, and `ai_usage_log` /
  `ai_insight_cache` row counts on any deployed database were not read.
- `swarm/state/escalations.json` (entry for #263) records that on the local stack the app
  returned 503 `AI_UNAVAILABLE` because no key was set, and that the owner had to supply a
  key for an end-to-end check; `docs/test-reports/uat-make-dev-20261013.log` shows
  `WARN AI is off` on a dev stack. So AI has been **off** in at least the UAT stacks.
- The AI UAT scenario (`docs/uat-scenarios/ai-content-authoring-20260609.md`) has
  "graceful fallback" paths and is run against local/qa, never the demo.

To verify (owner or infra, read-only, one query each): `SELECT count(*), max(created_at) FROM
ai_usage_log;` on the demo database, and whether `ANTHROPIC_API_KEY` / `AI_API_KEY` /
`XAI_API_KEY` is set in `/opt/apps/bilimbaga-test/.env` (presence only, not the value).

## 4. Recommendation for T6b

**Queue T6b, but narrowed: AI-assisted question authoring (FR-BB71) only, as an opt-in feature
that is off by default and works with no key.** Reasons: it is the only AI feature that
changes authoring work (drafts reviewed by a human before saving); a missing key degrades to
a 503 and nothing else, so cost of carrying it is low; usage is unverified, so do not commit
to the other three. Keep out of T6b: AI grading (FR-BB73, sends employee answers to a third
party and decides scores; needs its own decision), insights (FR-BB74) and loyalty narrative
(FR-BB75; the loyalty track is outside the Letflow roadmap so far). If the two checks in
section 3 show zero rows in `ai_usage_log` and no key on the demo, the stronger option is to
drop T6b and record criterion 6 as "not used in production"; that check is cheap and should
run before T6b is designed.

## 5. INV-4 and INV-9 implications for a Letflow requirement

INV-4 (secrets by reference, `Letflow.Secrets`):
- BilimBaga holds one process-wide key in `.env`. Letflow must not copy that: the provider
  key is a secret stored and resolved through `Letflow.Secrets` by reference; the requirement
  names who sets it (platform operator or per tenant) and that the value never appears in
  logs, responses, errors, git or the prompt. A per-tenant key (tenant pays) and a platform
  key (platform pays, needs a per-tenant quota) are different requirements; pick one.
- Keep BilimBaga's good habits as criteria: mask the key in any config `inspect`/`to_string`,
  redact it from upstream error bodies before logging and truncate the body, never send it
  anywhere but the provider host.
- The 2026-10-13 retro (`docs/retrospectives/retro-011-architect-draft.md`, item 5) records a
  key being copied into a scratch variable during UAT: a Letflow requirement should say
  agents and tests use a fake provider, never a real key.
- Prompts carry tenant content (and, for grading, personal data): they must not be written to
  logs or to the usage table in full; the usage log stores counts and ids only.

INV-9 (tenant-controlled outbound URLs are validated):
- BilimBaga's `AI_BASE_URL` is operator-set, with an https-only (http for localhost),
  no-credentials check. In Letflow, if the endpoint is settable by a tenant admin (an
  `openai_compatible` choice), it is tenant-controlled and needs the full INV-9 validation
  (scheme, resolved address not private/loopback/link-local/metadata, redirects not followed
  or re-validated, response size and time limits), not just BilimBaga's scheme check.
  Simplest safe choice: a fixed allow-list of provider hosts chosen by the platform, no
  free-form tenant URL.
- INV-1 note: usage log, rate-limit counters and any cache (BilimBaga caches insights per
  exam) live in the tenant schema with `:prefix`; limits are per tenant and per user.
- INV-3 note: model output is untrusted text; generated questions are drafts only and go
  through the normal question validation and authorisation before being saved (BilimBaga does
  this: "drafts never inserted").
