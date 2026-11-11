# Part 4: follow-up review of the routes added since B3#10

Static review, 2026-11-11, against main at `1870b0429` (T-1693). Method, result vocabulary and the OWASP-to-invariant table:
`README.md`. Same limits: not a penetration test, not for publication, not a production sign-off.
Five families, one checklist row each per relevant OWASP category (categories that do not apply are one `n/a` row).

Route sources read: `routers/identity.ex` (`handle_reset_password`), `routers/identity/users_import.ex`,
`identity/user_import.ex`, `plugs/xlsx_body_parser.ex`, `entities/xlsx_import.ex` (zip guards),
`routers/platform_module_rollouts.ex`, `module_upgrade/fleet.ex`, `identity/tenant.ex` (window validation),
`routers/signup.ex`, `signup.ex`, `signup/provisioning.ex`, `routers/instances.ex` (timeline).

## F-RP: `POST /identity/users/:id/reset-password` (REQ-788)

| ID | OWASP | Checked how | Result |
|---|---|---|---|
| RP-A01 | A01 | Policy key `:UsersManage`; `with_cast_id` then `Identity.get_user` with the caller's tenant `:prefix`, so another tenant's id is the same 404 as a random id; `with_platform_admin_member_guard` refuses platform-admin group members for a customer-tenant admin. Tests `identity_reset_password_test.exs` R3, R4 (cross-tenant and non-UUID 404), R5. | ok |
| RP-A02 | A02 | The mail holds no link, password or secret (R9a); Letflow handles no password (decisions 0072 D1, 0085 D6). | ok |
| RP-A04 | A04 | Existence and guard checks run before the body check (R6), refusal order fixed (R7). No per-target or per-caller throttle: an administrator can send any number of "Forgot password" mails to one user. | finding F4-4 |
| RP-A09 | A09 | Audit entry `user.password_reset_requested` is written before the delivery starts; a failed audit write answers 500 and starts no delivery (R10); delivery failures never change the 202 (R9b, R9c). | ok |
| RP-other | A03, A05, A06, A07, A08, A10 | no SQL, template input or outbound URL from the caller (the template placeholders are `Notifications.text/1` of stored names); auth is the shared pipeline. | n/a no new surface |

## F-UI: `GET /identity/users/import-template`, `POST /identity/users/import[?dry_run=true]` (REQ-791)

| ID | OWASP | Checked how | Result |
|---|---|---|---|
| UI-A01 | A01 | `:UsersManage`; tenant `:prefix` and `:tenant_id` come from `user_write_opts/1`, never from the file; T-11 (a username that exists only in tenant B is created in A), T-2 (403 without the permission). | ok |
| UI-A03 | A03 | Rows go through `Identity.create_user/2` (Ecto); `UserImport` has columns username, display_name, email only, no password, role or group column (T-12), so the file cannot grant privilege. | ok |
| UI-A04 | A04 | Row cap 200, atomic write in one transaction with the rules re-checked inside it (T-7, T-14); an existing user is never modified (T-10). | ok |
| UI-A05 | A05 | Body is read bounded by the pipeline's 2 MiB limit (`XlsxBodyParser`, 413 in T-5); only the one POST path claims the xlsx media type. | ok |
| UI-A08 | A08 | One parse: `XlsxImport.convert_detailed` applies the zip guards (`@max_inflated` 26 MiB total, `:zip.list_dir` as the single directory source) and hands rows to the consumer. No second parser. | ok |
| UI-A09 | A09 | The answer holds no cell text of a refused row (T-4); each created user is audited with the administrator as actor (T-8). | ok |
| UI-other | A02, A06, A07, A10 | no secret, outbound call or new authentication path. | n/a |

## F-RO: `/platform-module-rollouts` (list, status, start, resume) and the tenant rollout window

| ID | OWASP | Checked how | Result |
|---|---|---|---|
| RO-A01 | A01 | Every route `:ModuleRolloutsManage`, a platform-scope permission; a tenant admin, a PLATFORM_ADMIN of another tenant and a bare token get 403 on all four routes and on an unmatched sub-path; the platform token with another tenant's slug is refused (`platform_module_rollouts_test.exs`, "A2 / N1"). No route takes a tenant identifier (INV-10 negative test is the A2/N1 block). | ok |
| RO-A03 | A03 | `Fleet.status/resume` cast the id with `Ecto.UUID.cast` before `Repo.get` (R3: malformed and unknown id are 404); `module_id` is a bounded string validated by `@start_schema`. | ok |
| RO-A04 | A04 | A tenant administrator may set `module_upgrade.window` (any HH:MM pair, start different from end, validated in `Tenant`) through the tenant settings route. A one-minute window means that tenant is `outside_window` on nearly every rollout, so a tenant can hold back a platform security update of its own modules indefinitely. The effect is limited to that tenant, but the platform operator has no override. | finding F4-2 |
| RO-A04b | A04 | `GET /platform-module-rollouts` returns every rollout without a page size; platform operators only, low volume. | finding F4-5 |
| RO-A09 | A09 | `start` and `resume` pass `auth_context.user_id` as the actor; the response holds ids, statuses and codes only, no tenant name or schema (R1). | ok |
| RO-other | A02, A05, A06, A07, A08, A10 | no secrets or outbound URLs; authentication is the shared pipeline. | n/a |

## F-SU: public sign-up (`/api/signup`, flag `LETFLOW_SIGNUP_ENABLED`, off by default) and operator resume

| ID | OWASP | Checked how | Result |
|---|---|---|---|
| SU-A01 | A01 | The mount is before `/api/v1`, never enters `AuthPipeline`; `enabled_gate` answers the standard 404 for every method and path unless the flag is exactly `true` (`signup_flag_test.exs`). `tenant_id` is server-generated; a forged id in the body is ignored (`signup_test.exs` line 68). | ok |
| SU-A02 | A02 | Token is 32 random bytes, only its SHA-256 is stored, `email` and `token_hash` are nulled when a row expires; the lookup is an equality on the hash of a 256-bit value. | ok |
| SU-A03 | A03 | Ecto queries with pinned values; email, company and language are validated (length, control characters, language from a fixed list) before use; refusal text is chosen from a fixed table by language, never echoed. | ok |
| SU-A04 | A04 | `/verify` is a POST so a link prefetch cannot consume the token; per-IP (hashed, IPv6 /64), per-domain and pending caps counted in the database under an advisory lock; every well-formed request answers 202 whatever the address state. The 429 for the per-domain cap still tells a caller that other requests from that domain exist (low). | finding F4-3 |
| SU-A05 | A05 | `Cache-Control: private, no-store`, `Referrer-Policy`, `X-Robots-Tag` on every answer; client address from `ClientIp` (trusted proxy and one `X-Real-IP` only, never `X-Forwarded-For`). | ok |
| SU-A07 | A07 | `/verify` answers one generic 400 for unknown, expired, closed and malformed tokens (INV-5); there is no throttle on `/verify` itself, which is acceptable for a 256-bit token. | ok |
| SU-A09 | A09 | One telemetry event per request with `outcome` only; the one `Logger.warning` in `signup/provisioning.ex` prints a fixed failure code. No e-mail, address, token or company name is logged. | ok |
| SU-A10 | A10 | The provisioner calls a configured adapter URL, not a caller URL; the captcha adapter takes the caller's token and address only. | n/a no caller-controlled URL |

Resume (`mix letflow.signup.resume`, `Provisioning.resume`) is an operator mix task, not an HTTP route; it moves rows to
`provisioning` with a fresh attempt budget and is not reachable by a caller. Decision 0084 D5 / 0085 D7 say there is no scheduler
for it; this review did not look at a timer because none exists.

## F-RT: `GET /instances/:id/timeline` (instance replay screen)

| ID | OWASP | Checked how | Result |
|---|---|---|---|
| RT-A01 | A01 | Policy `:InstancesRead`; prefix-scoped read; cross-tenant and nonexistent id both 404 (`instances_test.exs` "timeline: cross-tenant id and nonexistent id both 404"). **But** `/history` and `GET /:id` run `with_participation/4` (GH #2932: a task-worker-only caller reads an instance only when it started it or holds a task of it) and the timeline did not, so an uninvolved task worker could read event types, node and task ids, actor names, attached file names and error types of any instance in the tenant. | finding F4-1 (fixed here) |
| RT-A03 | A03 | `cast_instance_id` and `Pagination` validate id and page size; cursor decoded by `decode_seq_cursor`; Ecto composition only. | ok |
| RT-A04 | A04 | The timeline item exposes `node_id`, `task_id` from the payload only, never the payload (`timeline_item_map`); restricted values do not reach it (`instances_restricted_field_events_test.exs` (b2)); synthetic entity-type instances are 404 (`instances_synthetic_hidden_test.exs`). | ok |
| RT-A04b | A04 | `GET /instances/:id/pins` has the same missing participation check; it returns definition pin versions only, no instance data. | finding F4-6 |
| RT-other | A02, A05..A10 | no secrets, no outbound call. | n/a |

## Findings

| Finding | Severity | File and symbol | INV | Scenario | Status |
|---|---|---|---|---|---|
| F4-1 | medium | `lib/letflow/routers/instances.ex` `handle_timeline` | INV-2, INV-5 | A user with only TASK_WORKER (holds `InstancesRead`) calls `GET /instances/:id/timeline` for an instance it did not start and holds no task of: 200 with the instance's events (GH #2932 closed this for `/history` and `GET /:id` only). | **Fixed in T-1693**: `handle_timeline` runs inside `with_participation`; test `instances_participant_read_test.exs` G6 (red before: left 200, right 404). The probe in `instances_synthetic_hidden_test.exs` T5 now uses the auditor for the timeline, since the worker it used is not a participant. |
| F4-2 | medium | `lib/letflow/identity/tenant.ex` `validate_module_upgrade_window`, `module_upgrade/fleet.ex` `in_window?` | INV-10 (nearest) | A tenant administrator sets a window of one minute; the platform operator's rollouts leave that tenant `outside_window` until someone times a start inside it. | Queued: needs a product decision (minimum window length, or an operator "force" for security updates). Not fixed. |
| F4-3 | low | `lib/letflow/signup.ex` per-domain cap | INV-5 | The 429 `rate_limited` for the domain cap tells a caller that several requests from that e-mail domain were made recently. Free-mail providers are exempt, so the signal is only for company domains. | Listed. Fix: answer 202 neutral and send no mail when the domain cap is hit (product decision on honest feedback for a real user). |
| F4-4 | low | `routers/identity.ex` `handle_reset_password` | INV-8 (nearest) | A tenant administrator (or a script holding an admin token) posts reset-password in a loop for one user and fills that user's inbox with the platform's mail. | Listed. Fix: one pending delivery per user per few minutes, answered 202. |
| F4-5 | low | `routers/platform_module_rollouts.ex` `GET /` | INV-8 (nearest) | Unpaginated list of all rollouts and their counts; platform operators only. | Listed. Fix: page size like other lists when the rollout count grows. |
| F4-6 | low | `routers/instances.ex` `GET /:id/pins` | INV-2 | Same participation gap as F4-1 but the body holds only the pinned definition versions. | Listed. Fix: wrap in `with_participation` for consistency; not done here to keep the change small for one security review. |

## Not reviewed

- Dynamic behaviour: nothing was run against a live instance. No forged-archive attempt was made against the users import beyond
  reading the shared guards (`XlsxImport`, 26 MiB inflated cap, 200 rows).
- The sign-up mailer and the realm provisioner adapters (outbound calls with operator-configured URLs), and the captcha adapter's
  network behaviour.
- The rollout window as enforced by `Fleet` for time-zone and daylight-saving edges (a correctness matter, not security).
- Dependency advisories: unchanged since part 1 (F1-1..F1-3); not repeated.
