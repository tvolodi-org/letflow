# Sign-up request state machine (T-2748)

Table `signup_requests` (global schema). Code: `Letflow.Signup` (submit, verify, status),
`Letflow.Signup.Provisioning` (run, retry_failed, resume), mount `Letflow.Routers.Signup`.
Stored states: `pending_verification` (= *requested*), `verified`, `provisioning`, `failed`, `completed`, `expired`.
Answers are `HTTP status + body error`; 200 bodies carry `status`/`state`.

## States x events

| State | verify (`POST /verify`) | retry (`/verify` + `retry:true`) | slug taken meanwhile | rate limit | replay (same request twice) | provider error | expiry |
|---|---|---|---|---|---|---|---|
| requested | -> verified (async start), 200 `verified` | same as verify (nothing failed) 200 | submit of a second request for the slug: 422 `slug_taken`; this row keeps its slug | submit: 429 + `retry-after`; verify without retry is not limited | submit again with the same e-mail: neutral 202; verify twice: 200 both | impossible: no outbound call yet | token expired: -> expired (row swept), verify 400 `invalid_or_expired_link` |
| verified | idempotent: 200 `verified`, no second start | as verify, 200 | impossible: the row still holds the slug (open index) | retry:true is limited: 429 + `retry-after`, no state change | 200, same answer, no second provisioning | -> provisioning step runs; failure -> failed | 400 `invalid_or_expired_link` |
| provisioning | idempotent 200 `verified` | 200, no change (not failed) | impossible: row holds the slug | retry:true 429 | 200, same answer | retryable error -> stays provisioning until attempts used, then failed; permanent -> failed | 400 |
| failed | 200 `verified`, row stays failed (the link shows the named failure via `/status`) | retryable and budget left: -> provisioning, 200; permanent or `attempts_exhausted` or budget used: stays failed, 200; slug now held by another live request: stays failed, **409 `slug_taken`** | a failed row RELEASES its slug (partial unique index `signup_requests_slug_open_index`); another visitor may take it; this row's retry then answers 409 `slug_taken`, the newer holder is unchanged | retry:true 429; verify without retry is not limited | retry replay: same answer as the first (200, or 409 while the slug stays taken); never resets `step_attempts` | n/a: already failed | 400 |
| completed | idempotent 200 `verified` | 200, no change | impossible: row holds the slug | retry:true 429 | 200, same answer | impossible: provisioning is finished | 400 |
| expired | 400 `invalid_or_expired_link` | 400 | slug released (index excludes expired) | 429 applies to retry:true before the lookup | 400 same answer | impossible: no row work | already expired |

Unknown, malformed and expired tokens are one 400 `invalid_or_expired_link` (INV-5).

## Invariants

1. A slug is reserved only while a request is live (state not `failed`/`expired`); enforced by `signup_requests_slug_open_index`.
2. Retry never resets `step_attempts`; only the operator task `mix letflow.signup.resume` does.
3. `attempts_exhausted` is permanent for the visitor.
4. The per-address rate limit keys on the resolved visitor (`conn.assigns.client_ip`), never on a header the visitor sets without a trusted proxy.
5. A replay returns the same answer.
6. Reacquiring a released slug is atomic: the unique index is the check, a violation becomes 409 `slug_taken`, never an exception.

## Tests (`test/letflow/signup_provisioning_test.exs`)

P21 failed/verify/retry; P22 permanent failure; P23 budget and exhausted; P25/P26 rate limit and privacy headers;
P27 retry after the slug was taken (409, newer holder unchanged).
