# Runbook: public tenant sign-up, part 1 (QA/demo only)

Decision record: `docs/migration/decisions/0084-public-signup-part-1.md`. Code: `Letflow.Signup`,
`Letflow.Routers.Signup`, table `signup_requests`.

## What exists

`POST /api/signup` (company name, e-mail, language, terms) records a request and mails a single-use link.
`POST /api/signup/verify` (token) marks it `verified` and moves its step to `ready_for_provisioning`.
`GET /api/signup/config` reports the languages and the terms version. After the credential mail the Letflow demo tenant is created in-process (T-1679, slice 1a); the welcome mail (T-1685, slice 1b) follows and the row becomes `completed`.
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
| `LETFLOW_SIGNUP_DOMAIN_HOURLY_CAP` | 20 | new requests per e-mail domain per hour (429 beyond; T-1620) |
| `LETFLOW_SIGNUP_DOMAIN_CAP_EXEMPT` | gmail.com, mail.ru, yandex.ru, outlook.com, icloud.com, bk.ru, inbox.ru, list.ru, yahoo.com | comma list; domains the domain cap skips (shared free providers: bounded by the IP and pending caps). A set value replaces the default |
| `LETFLOW_SIGNUP_DISPOSABLE_DOMAINS` | empty | comma list added to the built-in disposable list |
| `LETFLOW_SIGNUP_ALLOW_DOMAINS` | empty | comma list removed from the blocked set (allow wins) |
| `LETFLOW_SIGNUP_CAPTCHA` | unset (off) | only `off` is accepted: no captcha vendor is implemented (owner question Q3) |

## Anti-abuse (T-1620, TA-SL3)

All of it is server-side, behind the same flag, and runs before any row or mail is written:

- **Disposable e-mail domains** are refused with `422 email_not_accepted` (a domain and its subdomains). The built-in
  list is `priv/signup/disposable_domains.txt` (a starting point, compiled in); extend it per deployment with
  `LETFLOW_SIGNUP_DISPOSABLE_DOMAINS`, exempt a wrongly blocked domain with `LETFLOW_SIGNUP_ALLOW_DOMAINS`.
  The answer depends only on the request, never on whether the address is known.
- **Per-domain hourly cap** (`429`, same `retry-after` as the IP cap). The domain is stored only as a SHA-256
  (`signup_requests.domain_key`); older rows have NULL and are not counted.
- **Captcha hook** `Letflow.Signup.Captcha`: a behaviour, no adapter ships and none can be switched on by an env
  value yet. When one exists the request carries `captcha_token`; a wrong token is `422 captcha_failed`, an adapter
  that is down, raises or exits is `503 signup_unavailable` (fails closed). `GET /api/signup/config` says
  `captcha_required` (a boolean, never a vendor or key).
- Every refusal body (422/429/503) has `error` and a `message` in the request's `language` (ru/kk/en, default en).
- Not built here (portfolio front door): edge rate limiting, the captcha widget and vendor/key choice, the sign-up
  screens, the invitation code (Q1), and who keeps the disposable list up to date.

## Realm step (T-1593, decision 0085; QA/demo only, never production)

Needs `LETFLOW_SIGNUP_ENABLED=true` and all three of: `LETFLOW_SIGNUP_PROVISIONER_URL` (`http://` + loopback or
private IP + port, e.g. `http://127.0.0.1:3218`), `LETFLOW_SIGNUP_PROVISIONER_TOKEN` (caller bearer token, a secret: never
in a file in git, a log or a ticket) and `LETFLOW_SIGNUP_HOSTNAME_DOMAIN` (e.g. `qa.example.com`). Unset = the step does
not run. Tier is always `demo`. Before the first enable check that infra's realm template sets `resetPasswordAllowed: true`
(the fallback mail points to "Forgot password").

After verification the row goes `provisioning`: step `realm_created` (realm, issuer, template version stored), then
`credential_sent` (mail with the temporary password, or the "Forgot password" hint when the password is no longer
available), then `tenant_created` (the Letflow tenant exists), then the one welcome mail with the link `https://<label>.<hostname domain>/?realm=<slug>` in the person's language and `completed` (T-1685). The
tenant create calls `Letflow.TenantProvisioner.create/1` in-process with the row's `tenant_id`, so a replay changes nothing and
no provisioner bearer token is used; it needs the `Letflow.TenantProvisioner` settings (`allowed_hostname_suffixes` containing the
hostname domain, `provisioner_public_base_url`, the platform tenant pinned). A failed create keeps the row retryable and resumes at
`credential_sent`: the credential mail is not sent again. A failed welcome mail is `welcome_mail_failed` (retryable; the tenant stays; resume sends only the welcome). On a permanent error or after the retry budget the row is `failed`, step `provisioning_failed`, and
`last_error` is one of `unavailable`, `rate_limited`, `demo_cap_reached`, `unauthorized`, `invalid_request`,
`bad_response`, `bad_url`, `credential_mail_failed`, `no_recipient`, `attempts_exhausted`, `internal`, and for the tenant create
`tenant_internal` (retryable), `tenant_conflict`, `invalid_tenant`, `source_budget`, `email_domain_budget` (permanent; `--force`).
Timer (T-1686, only with the sign-up flag on): the provisioner sweep tick (`LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES`, default 60) closes stale `pending_verification` requests and restarts `verified`/`provisioning` requests at `ready_for_provisioning`, `realm_created` or `credential_sent` whose claim is older than 2 minutes (at most 50 per tick); it never reopens `failed` rows, never resets attempts, deletes nothing, and logs counts only.
Resume (also for rows stuck in `provisioning` after a restart): `mix letflow.signup.resume [--tenant-id ID]`
(`--force` retries a permanent failure too). A failed row keeps the e-mail (personal data). An orphan realm is removed by
infra's reaper; nothing here deletes.

## Reading the table

`state` is `pending_verification`, `verified`, `provisioning`, `completed`, `failed` or `expired`; `step` is `await_verification`,
`verified`, `ready_for_provisioning`, `realm_created`, `credential_sent`, `tenant_created`, `completed` or `provisioning_failed`. `last_error = mail_failed` means the adapter failed (the visitor still saw the neutral 202;
a resubmit after the interval re-sends). An expired row has no e-mail and no token hash.
