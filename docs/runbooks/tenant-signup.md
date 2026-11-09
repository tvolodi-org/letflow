# Runbook: public tenant sign-up, part 1 (QA/demo only)

Decision record: `docs/migration/decisions/0084-public-signup-part-1.md`. Code: `Letflow.Signup`,
`Letflow.Routers.Signup`, table `signup_requests`.

## What exists

`POST /api/signup` (company name, e-mail, language, terms) records a request and mails a single-use link.
`POST /api/signup/verify` (token) marks it `verified` and moves its step to `ready_for_provisioning`.
`GET /api/signup/config` reports the languages and the terms version. **No tenant, Keycloak realm or user is created**
(that is slice SL2b), so a verified row only waits. The SPA sign-up screens are not built yet.

## Switching it on (QA/demo)

Off by default. To enable, set `LETFLOW_SIGNUP_ENABLED=true`, `LETFLOW_SIGNUP_BASE_URL=https://<spa origin>`
(origin of the mailed link) and `LETFLOW_TRUSTED_PROXIES`; mail goes through the configured notifier adapter
(`LETFLOW_MAIL_ADAPTER`; mailpit on QA). Do not enable in production: the terms text (Q6), mail sender (Q7) and
captcha (Q3) are not decided.

| Variable | Default | Meaning |
|---|---|---|
| `LETFLOW_SIGNUP_PENDING_CAP` | 50 | open unverified requests allowed at once (503 beyond) |
| `LETFLOW_SIGNUP_IP_HOURLY_CAP` | 5 | new requests per client address (IPv6 /64) per hour (429 beyond) |
| `LETFLOW_SIGNUP_RESEND_INTERVAL_SECONDS` | 60 | minimum gap between mails to one address |
| `LETFLOW_SIGNUP_TOKEN_TTL_HOURS` | 24 | link lifetime |
| `LETFLOW_SIGNUP_ABANDON_DAYS` | 7 | an unverified request is closed after this |

## Reading the table

`state` is `pending_verification`, `verified` or `expired`; `step` is `await_verification`, `verified` or
`ready_for_provisioning`. `last_error = mail_failed` means the adapter failed (the visitor still saw the neutral 202;
a resubmit after the interval re-sends). An expired row has no e-mail and no token hash.
