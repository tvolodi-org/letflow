# 0085 — Public tenant sign-up, SL2b part a: the realm step through infra's provisioner (behind the flag, off)

Status: accepted for implementation (T-1593, TA-SL2b part a; QA/demo only, no production path).
**REVIEWER and SECURITY-REVIEWER sign-off: PENDING** (the PR carries the verdicts).

Sources: BA decision `docs/uat/ba-decisions/T-1567.md` sections 2 and 5; decisions 0072 (D1, D3), 0084 (D2, D4).
Part b (in-process `TenantProvisioner.create/1`, default modules, welcome mail) is a separate task and is not decided here.

## Premises of the task text that this record corrects

- Letflow gets **no Keycloak credential and no admin client** (0072 D1, 0084 D2). The create-realm-only credential
  lives in infra's `tenant-provisioner`. Letflow adds one outbound HTTP client with a caller bearer token.
- The first admin is **not a Letflow step**: the provisioner creates it inside `POST /v1/realms` (verified e-mail,
  default roles, temporary password, required action `UPDATE_PASSWORD`).

## Decisions

- **D1 Client.** `Letflow.Signup.RealmProvisioner` over `:httpc` (no new dependency). `POST /v1/realms` with
  `tenant_id`, `name`, `language`, `tier: "demo"` (hard-coded), `owner_email`, `hostname`; on 409 a `GET
  /v1/realms/{tenant_id}` resolves a replay. The response is validated, not trusted: the realm must equal
  `t-` + the first 20 hex digits of the tenant id (the 0072 D3 namespace guard), `client_id` must be `letflow-web`,
  `tenant_id` and `tier`, when present, must match; body capped at 64 KiB.
- **D2 Settings (new, all unset by default = the step does not run).** `LETFLOW_SIGNUP_PROVISIONER_URL`,
  `LETFLOW_SIGNUP_PROVISIONER_TOKEN`, `LETFLOW_SIGNUP_HOSTNAME_DOMAIN` (the provisioner requires a hostname; the label is
  derived from the tenant id). They are set together or boot refuses; setting them without `LETFLOW_SIGNUP_ENABLED=true`
  also refuses. Retry and timeout values are `Letflow.Signup.config/0` defaults, not env.
- **D3 INV-9.** The URL is `http://` with a loopback or RFC 1918 IP literal or `localhost`, explicit port, no
  userinfo, path, query or fragment; checked at boot and on every call. No DNS name is resolved. RFC 1918 is allowed
  because a containerised Letflow reaches the host's provisioner over a private bridge address (owner may narrow it).
- **D4 INV-4.** The token is read with `System.get_env/1` at call time and is not stored in `Application` env.
  Failures are reduced to a closed set of atoms; no request, header, body or exception is logged or stored. The
  temporary password lives in one local variable from the 201 to the mail send and is written nowhere else.
- **D5 Saga.** After the verify commit a supervised task (the login-discovery task supervisor) runs
  `Signup.Provisioning.run/1`: a compare-and-set claim (`claimed_at`, stale after 2 minutes) so the one-time password
  is requested once; steps `ready_for_provisioning` -> `realm_created` -> `credential_sent`; up to 3 attempts per run
  with 1 s and 5 s backoff, 5 in total per request; permanent errors (`demo_cap_reached`, `unauthorized`,
  `invalid_request`, `bad_response`, `bad_url`) fail at once. Failure = `state failed`, `step provisioning_failed`, a
  fixed `last_error` code and one fixed-text warning. The verify answer never changes.
- **D6 Credential mail.** Sent synchronously by the task through the existing mail adapter. When the password is not
  available (a replay, a crash after the 201, a failed first mail) a "Forgot password" hint is sent instead. This needs
  `resetPasswordAllowed: true` in the realm template.
- **D7 Cleanup.** `mix letflow.signup.resume [--tenant-id ID] [--force]`. Nothing here deletes: an orphan realm is
  removed by infra's reaper. No scheduler (0084).
- **D8 Data.** Migration `20261110200001`: five nullable columns on the global `signup_requests` (realm, issuer,
  template version, claim time, credential-sent time). No tenant table, route or permission is added.
- **D9 Tenant create (T-1679, part 1a).** After the credential mail the saga calls `Letflow.TenantProvisioner.create/1` in-process
  (tier `demo`, the row's `tenant_id`, hostname `<label>.<hostname_domain>`, `source_key` = hex of the row's `ip_key`). It carries no
  provisioner credential and no `auth_context`; INV-10 holds because the only callers are the server-side saga on a row the server
  created with a server-generated `tenant_id`, and the admin routes. Demo cap, budgets and default-modules install apply unchanged
  (0072 D3: one call to Letflow's own create path). The step is `tenant_created`; the state stays `provisioning` until the welcome
  mail (D10). Failure codes: `tenant_internal` (retryable), `tenant_conflict`, `invalid_tenant`, `demo_cap_reached`, `source_budget`,
  `email_domain_budget`. Resume restarts at `credential_sent` when `credential_sent_at` is set, so the mail is never repeated.
- **D10 Welcome mail (T-1685, part 1b).** After the tenant create (or from a row stopped at `tenant_created`) the saga sends one
  welcome mail through `Mailer.deliver_now/1`, in the person's language (ru/kk/en, unknown -> en), with the link
  `https://<label>.<hostname_domain>/?realm=<t-32hex slug>` (same host helper as the create; a UAT assumption, T-1567 Q4 option a, to be
  confirmed by the process owner). On success the row becomes `completed`/`completed`; a completed row is never claimed, so no second
  welcome. A mail failure is the retryable code `welcome_mail_failed`: the tenant stays, and `mix letflow.signup.resume` restarts at
  `credential_sent`, replays the create (a no-op) and sends the welcome; the credential mail is not repeated. No demo-end date or contact
  address (no source yet); the completed row keeps the e-mail (retention is the sweep's job). Still behind the flag (default off).

**Addendum T-1701 (sign-up sweep, for REQ-803; build in T-1686).** This addendum replaces only the sentence "No scheduler (0084)."
of D7 and Residual 5 "Resume is operator-driven". Those lines stay as written; D1 to D6, D8 and D9 are unchanged, and
`mix letflow.signup.resume` stays the operator path. It also adds a timed expiry next to the expiry on submit of 0084 D5.
- **Host.** The tick of `Letflow.TenantProvisioner.Sweep` (`lib/letflow/tenant_provisioner/sweep.ex`), on the interval of
  `Letflow.TenantProvisioner.Config.sweep_interval_minutes/0` (default 60), started by `Letflow.Supervisor.Pollers`. There is no new
  process, no new supervisor child, no new env var or setting. It is not a step of `Letflow.Scheduler.Poller`, because that tick
  iterates tenant schemas while `signup_requests` is global.
- **Gate.** The sign-up steps do nothing unless `Letflow.Signup.enabled?/0` is true (0084 D1, default false); the resume step also needs
  `Letflow.Signup.Provisioning.configured?/0`. With the flag off the tick behaves as before.
- **Expiry step.** Calls `Letflow.Signup.expire_stale/1` with the tick's clock; the rule and its values are unchanged and the call on the
  submit path stays. It does not take the advisory lock of the submit path: `expire_stale/1` is one atomic UPDATE statement, a
  concurrent submit sees the row either before or after it, and a row closed earlier only lowers the pending count. Not taking the
  lock keeps the tick from queueing behind the form.
- **Resume step.** Selects requests in state `verified` or `provisioning` whose step is one of the saga's steps
  (`ready_for_provisioning`, `realm_created`, `credential_sent`) and whose claim is empty or older than the 2 minutes of D5, and starts each
  with `Letflow.Signup.Provisioning.start_async/1`, so retries and timeouts run in the supervised task, not in the tick. It never
  touches state `failed`: that stays with the operator (`mix letflow.signup.resume`, with or without `--force`). It never resets
  `step_attempts`, so the 5 attempts in total of D5 bound each request. Runs that overlap (the sweep and the mix task, two nodes) are
  separated by the compare-and-set `claim/1`. The select needs a new public function in `Letflow.Signup.Provisioning` (the second half
  of `resume/1`'s query without the `run/1`); that is part of T-1686.
- **Never.** The sweep deletes no row and no realm (an orphan realm is infra's reaper, D7). It calls no tenant create itself; a request
  resumed at `credential_sent` runs the D9 create inside the saga, unchanged. It writes nothing to `tenants`, `tenant_lifecycles` or
  tenant schemas by itself (0084 D2). It logs counts and fixed result codes only, never an e-mail, token or password (D4). A failure in
  a sign-up step is rescued so that the existing Expire and Purge steps still run (INV-8); the sign-up steps run after Purge so that a
  bug there cannot delay lifecycle work.
- **Not decided here.** Retention of a `failed` request's e-mail (`fail/2` keeps it; no retention source exists, owner question); the
  welcome mail (slice 1b); the build of the sweep (T-1686).

## Residuals

1. The temporary password is lost if the process dies between the 201 and the mail, and infra has no re-issue endpoint:
   the fallback is the hint mail. **Verify `resetPasswordAllowed: true` in infra's template before enabling on QA.**
2. The credential mail precedes the Letflow tenant. Part b (create) is done in T-1679 (D9); the welcome mail is done in T-1685 (D10).
   Between the two mails a failed create leaves a realm login that leads nowhere until `mix letflow.signup.resume`. Accepted for QA.
3. The mail is clear text through the QA relay; the forced password change is the mitigation.
4. A response shape for `GET /v1/realms/{tenant_id}` is assumed equal to the create response (infra README read only).
5. Resume is operator-driven.
