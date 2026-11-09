# Runbook: public tenant sign-up, part 1 (QA/demo only)

Decision record: `docs/migration/decisions/0084-public-signup-part-1.md`. Code: `Letflow.Signup`,
`Letflow.Routers.Signup`, table `signup_requests`.

## What exists

`POST /api/signup` (company name, e-mail, language, terms) records a request and mails a single-use link.
`POST /api/signup/verify` (token) marks it `verified` and moves its step to `ready_for_provisioning`.
`GET /api/signup/config` reports the languages and the terms version. **No Letflow tenant is created** (slice SL2b part b).
With the provisioner settings below, a verified row continues: infra's tenant-provisioner creates the realm and the
first admin, and the one-time credential is mailed (decision 0085). Without them a verified row only waits. The SPA sign-up screens are not built yet.

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

## Realm step (T-1593, decision 0085; QA/demo only, never production)

Needs `LETFLOW_SIGNUP_ENABLED=true` and all three of: `LETFLOW_SIGNUP_PROVISIONER_URL` (`http://` + loopback or
private IP + port, e.g. `http://127.0.0.1:3218`), `LETFLOW_SIGNUP_PROVISIONER_TOKEN` (caller bearer token, a secret: never
in a file in git, a log or a ticket) and `LETFLOW_SIGNUP_HOSTNAME_DOMAIN` (e.g. `qa.example.com`). Unset = the step does
not run. Tier is always `demo`. Before the first enable check that infra's realm template sets `resetPasswordAllowed: true`
(the fallback mail points to "Forgot password").

After verification the row goes `provisioning`: step `realm_created` (realm, issuer, template version stored), then
`credential_sent` (mail with the temporary password, or the "Forgot password" hint when the password is no longer
available). On a permanent error or after the retry budget the row is `failed`, step `provisioning_failed`, and
`last_error` is one of `unavailable`, `rate_limited`, `demo_cap_reached`, `unauthorized`, `invalid_request`,
`bad_response`, `bad_url`, `credential_mail_failed`, `no_recipient`, `attempts_exhausted`, `internal`.
Resume (also for rows stuck in `provisioning` after a restart): `mix letflow.signup.resume [--tenant-id ID]`
(`--force` retries a permanent failure too). A failed row keeps the e-mail (personal data). An orphan realm is removed by
infra's reaper; nothing here deletes.

## Reading the table

`state` is `pending_verification`, `verified`, `provisioning`, `failed` or `expired`; `step` is `await_verification`,
`verified`, `ready_for_provisioning`, `realm_created`, `credential_sent` or `provisioning_failed`. `last_error = mail_failed` means the adapter failed (the visitor still saw the neutral 202;
a resubmit after the interval re-sends). An expired row has no e-mail and no token hash.
