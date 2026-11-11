# 0084 — Public tenant sign-up, part 1: record a request and verify the e-mail (behind a flag, off)

Status: accepted for implementation (T-1579, TA-SL2a; QA/demo only, no production path).
**REVIEWER sign-off: PENDING** (the PR carries the verdict).

Sources: BA decision `docs/uat/ba-decisions/T-1567.md` section 5 (slice SL2), decision 0072 (D1, D3, D6, P14, s10).

## Conflict reported, not resolved silently

The BA note recommends the sign-up page live in the portfolio *front door*, and 0072 s10 leaves per-visitor limits
with the front door. The owner's task text (T-1579) puts the sign-up page and API in Letflow behind a platform flag.
This slice follows the task. It does not change 0072: the Letflow endpoint is public but can only **record a request**.

## Decisions

- **D1 Flag.** `LETFLOW_SIGNUP_ENABLED`, default `false`, strict `true`/`false`. While off, every route under
  `/api/signup` answers the standard 404 before anything runs. Enabled outside dev/test it refuses to boot without
  `LETFLOW_TRUSTED_PROXIES` (the per-IP cap would key on the proxy hop) or without an `https://` `LETFLOW_SIGNUP_BASE_URL`.
- **D2 No credential, no tenant.** The sign-up code holds no Keycloak credential and writes nothing to `tenants`,
  `tenant_lifecycles` or any tenant schema. It writes only the global table `signup_requests`. The provisioner call
  (`POST /admin/v1/tenants`) is slice SL2b and starts from a row in step `ready_for_provisioning`. 0072 D1/D3/D6/P14 are unchanged.
- **D3 Magic link only.** No password is collected or stored (BA note step 1). The mailed single-use link is the proof
  of the address. The token is 256-bit random, stored only as SHA-256, valid 24 h (setting), and consumed by a `POST`
  (the SPA page posts it) so a mail scanner's prefetch cannot use it.
- **D4 Saga table.** `signup_requests`, keyed by a server-generated `tenant_id` (a request body can never set it).
  One open request per e-mail (partial unique index). Steps are idempotent: `await_verification` -> `verified` ->
  `ready_for_provisioning`.
- **D5 Anti-abuse minimum, DB-counted.** Per-IP hourly cap (IPv6 as /64, raw address never stored), per-address resend
  interval and mail cap, a pending cap, expiry of stale rows on submit. No new process, so supervisor child-count pins
  do not move. Every well-formed request is answered with the same 202 (no probing of registered addresses).
- **D6 Left open for the owner.** Captcha (Q3), invitation code / disposable-domain list (Q1), terms text (Q6, a
  neutral placeholder `placeholder-0` ships), mail sender (Q7, the existing notifier adapter; `Noop` unless configured).
  Residual risks: many IPs can fill the pending cap (503 for real users); an attacker can keep a victim's address
  "open" for up to 7 days.

**Addendum T-1620 (TA-SL3, no decision contradicted).** D5 gains a per-e-mail-domain hourly cap (hashed `domain_key`,
big free providers exempt), a configurable disposable-domain list (seed in `priv/signup/disposable_domains.txt`),
a captcha verification hook with no vendor (`LETFLOW_SIGNUP_CAPTCHA` accepts only `off`, fails closed) and
ru/kk/en refusal messages. D6 still leaves the vendor (Q3), the invitation code (Q1) and the list maintainer open.

**Addendum T-1701 (of 0085, no 0084 decision contradicted).** Adds a timed expiry of stale rows on the existing provisioner sweep tick next to the expiry on submit, with no new process; see 0085.

## Not decided here

Welcome mail, default modules, first credential, plan hook, host-to-tenant mapping (SL2b and later); the sign-up SPA
screens (a follow-up task; the API is complete without them).
