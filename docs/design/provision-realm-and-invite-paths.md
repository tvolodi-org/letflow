# The paths of the realm, invite and notify steps of `platform.register_tenant` v2

T-2727 (pilot gap G17c), Opus design pass of 2026-11-25, written for the two `review_confirm` findings V8 and V9 of
`docs/platform-register-tenant-v2.md` section 10. This file is the table the fix of those findings is built to. It
names no new feature.

## Scope

- `provision_realm_and_invite` (the provisioner call that makes the realm and the first administrator) is NOT on this
  branch: it is T-2728's step (the design addendum of PM 25 Nov 00:35 goes into T-2728's PR text). Its rows below are
  marked "T-2728" and are the contract that task builds to; this task changes nothing for them. On this branch the
  realm and the first administrator are the two steps that exist: `bind_realm` (binds a realm id the caller already
  has) and `grant_first_admins` (stores the PENDING grant of `admin_email`).
- The `notify` node is rebuilt here (finding V8), and the stored audit row is masked here (finding V9).

## The decision for V8: the notification runs as a platform step

The engine has no runtime for a SERVICE_TASK that carries a `notify` attribute: entering it answers
`{:config_parse_failed, "notify", :missing_url_and_service_id}` and the instance ends in ERROR. v1 has the same node
and the same gap. The v2 definition's every other SERVICE_TASK is a `platform_call` node, run by the platform step
worker (`Letflow.Engine.PlatformStepRunner`: lease, claim token, crash takeover, attempt cap, step log, DLQ entry of
type `platform_step`, retry through `Letflow.Instances.StepRetry`).

So v2's `notify` node becomes a `platform_call` node of a new catalogue entry `tenant.notify_admin`, whose body sends
the SAME declaration v1's node carries (template `tenant_registered`, recipient `admin_email`, values `tenant_name` /
`tenant_slug` / `registered_by`) through the SAME notification dispatcher
(`Letflow.NotificationSteps.Dispatcher.retry/3`: the G14 allow-list at dispatch, the tenant's send cap, one delivery
row with no address, no body). Why not a second runtime in the engine for `notify` nodes: it would be a new worker, a
new poller and a new resume path next to the platform step's, i.e. a new feature; the platform step already has every
property the row needs (retry, crash, step log). The `notify` node of v1 is untouched (v1 is history; its gap stays
reported).

The allow-list reads the node: `Letflow.OutboundDestinations.node_target/1` answers `{"email", nil}` for a
`platform_call` of `tenant.notify_admin` as it does for a `notify` node, so the activation fence and the seed's
channel opening (`Seed.open_channels/3` through `channels_of/1`) see the mail channel exactly as before. A recipient
DOMAIN is still a human entry of the platform tenant's list (decision record G2 (c)); without it the step is refused at
dispatch with `platform_call_notify_refused` and the instance is in ERROR, retryable.

## The decision for V9: the stored row carries no registration value

`Letflow.Engine.record_instance_create_audit/4` stores the instance row (with its `variables`) as the
`instance.create` audit `after_state`. In the PLATFORM tenant's schema the three registration values `admin_email`,
`realm_id` and `hostname` are replaced in the STORED state by the redaction placeholder
(`Letflow.PlatformProcesses.RegistrationMask.scrub_stored/2`, the same placeholder the reads use), for the system start
and the operator start alike. A tenant's own variables of the same name, in a company schema, are untouched.

`hostname` joins the registration labels, so the instance reads (`GET /api/v1/instances/:id`, `/history`,
`/reconstruct`) and the audit read mask it for a caller without `:TenantsManage`, like the e-mail and the realm. The
authorised operator (`:TenantsManage`) keeps the progress view of the instance (decision of T-2704, SF-08: the
instance detail and history show the start variables to the person who manages tenants); the audit row shows the
placeholder to every reader, that operator included.

## The table

Columns: path | trigger | effects | replay behaviour | what is logged / stored (masked?) | test that proves it.

| # | path | trigger | effects | replay behaviour | logged / stored (masked?) | test |
|---|---|---|---|---|---|---|
| N1 | notify gate, no mail | `admin_email` absent, so the builder sets `notify_admin: false`; `notify_gate` takes the default edge | no delivery row, no send; the instance COMPLETES | the gateway is evaluated again, same edge | nothing of the e-mail (there is none); hostname and realm masked in the stored audit row | `register_routes_test.exs` "without admin_email: notify_admin false, the instance COMPLETES" (V8 branch B) |
| N2 | notify, with mail, success | `admin_email` given, `notify_admin: true`; the gate takes e10 to `notify` (`tenant.notify_admin`) | the platform step runs the body: allow-list check (mail channel + recipient domain), send-cap reservation, ONE mail through the Notifier adapter, ONE `notification_deliveries` row (`template_key`, `status "sent"`, `trigger_ref` = instance id; no address, no body); the instance COMPLETES | the step's call key is `tenant.notify_admin` + digest of `tenant_id`: a second arming of the same tenant is the same call (`ON CONFLICT DO NOTHING`), and an advanced row is not run again (`already_final`) | the dispatch row's `inputs` holds `admin_email` (the platform tenant's own step log, as `grant_first_admins` already does, G6); no log line carries the address (`log: false` on the domain lookup, T-2704); the delivery row has no address; the stored audit row shows the placeholder | `register_routes_test.exs` "with admin_email and hostname: the mail is delivered and the instance COMPLETES" (V8 branch A); `tenant_notify_admin_test.exs` NA1 |
| N3 | notify, crash after the send, before the result commit | the worker dies between `deliver_to_address` (its delivery row is already committed) and the dispatcher's outcome write | the row stays `running`; its lease expires | the next claim takes the row over and runs the body again: the body asks the delivery log first (`Notifications.already_delivered?` for `tenant_registered` + instance id, status `sent`) and sends NOTHING; it answers success and the instance continues | as N2; no second delivery row | `tenant_notify_admin_test.exs` NA2 (a second run after a sent row sends nothing, one row) |
| N4 | notify, recipient domain or channel not on the platform allow-list | the G14 check at dispatch refuses | nothing is sent, no delivery row; the body answers `platform_call_notify_refused`; the step gives up, the instance is in ERROR with an EXECUTION_ERROR event and a DLQ entry of type `platform_step` | the operator adds the domain and retries through the DLQ (`StepRetry`): the body runs again and sends once | `last_failure_kind = platform_call_notify_refused` (a code, no address) | `tenant_notify_admin_test.exs` NA3 |
| N5 | notify, send failed or rate limited | the adapter fails (`failed`/`adapter_error`) or the cap answers `skipped`/`rate_limited` | the delivery row records the outcome (no address); the body answers `platform_call_notify_failed`; ERROR + DLQ `platform_step` | the DLQ retry runs the body again: no `sent` row exists, so it sends again (once) | `last_failure_kind = platform_call_notify_failed` | `tenant_notify_admin_test.exs` NA4 |
| N6 | notify, no mail adapter configured | the Notifier is the Noop adapter | the delivery row says `skipped`/`adapter_noop`; nothing leaves the platform; the body answers success (nothing a retry can change) and the instance COMPLETES | as N2 | as N2 | `tenant_notify_admin_test.exs` NA5 |
| N7 | notify, recipient missing or invalid | `admin_email` absent at the step (only reachable by a hand-made start; both builders set `notify_admin: false` then) | the dispatcher refuses the missing required input before the body (`platform_call_arg_missing`) or the body refuses an invalid address (`platform_call_invalid_email`); nothing is sent | as N4 | code only | `tenant_notify_admin_test.exs` NA6 |
| R1 | `bind_realm`, no realm | `realm_id` absent | no-op | no-op again | nothing | `tenant_bind_realm_test.exs` (existing) |
| R2 | `bind_realm`, realm given | `realm_id` set | the tenant row's `idp_realm_id` is bound | the same realm again: done, nothing written; another realm on a bound tenant: `platform_call_realm_already_bound` (ERROR, DLQ) | the realm is masked in the stored audit row and in the reads of a caller without `:TenantsManage` | `tenant_bind_realm_test.exs` (existing); `system_start_canary_test.exs` |
| G1 | `grant_first_admins`, no e-mail | `admin_email` absent | no-op | no-op again | nothing | `tenant_grant_first_admins_test.exs` (existing) |
| G2 | `grant_first_admins`, e-mail given | `admin_email` set | ONE pending grant in the new tenant's schema (bound to TENANT_ADMIN at the first sign-in); the lifecycle marker `owner_grant_stored` | `:duplicate` counts as done; the marker stops a second grant after a setting flip | the e-mail is in the tenant's pending-grant row (its purpose) and the platform dispatch row's inputs; in no audit row (masked) and no log line | `tenant_grant_first_admins_test.exs` (existing); `system_start_canary_test.exs` |
| P1 | `provision_realm_and_invite`, success (T-2728) | routes 3/4 with the provisioner configured | the provisioner (allow-listed `127.0.0.1:3218`) makes the realm and the first administrator, then `bind_realm` binds it; no password in any variable or log | T-2728: the provisioner's own idempotency key (the tenant id) answers the existing realm | T-2728 | T-2728 |
| P2 | `provision_realm_and_invite`, realm create fails (T-2728) | provisioner error or timeout | nothing bound; instance ERROR, retryable | T-2728: the retry asks the provisioner again with the same key | code only | T-2728 |
| P3 | `provision_realm_and_invite`, invite fails (T-2728) | realm made, first-admin call fails | realm exists, no admin; instance ERROR, retryable | T-2728: the retry skips the realm (exists) and repeats the invite | code only | T-2728 |
| A1 | the stored `instance.create` audit row (system and operator start) | any start of a definition in the platform tenant | `after_state.variables.admin_email`, `.realm_id`, `.hostname` are the placeholder in the STORED row | a replay starts nothing and writes no row | masked in the stored row, for every reader | `system_start_canary_test.exs` (raw rows of the platform schema), `register_routes_test.exs` SF-08 |
| A2 | the instance reads | `GET /api/v1/instances/:id`, `/history`, `POST /reconstruct`, `GET /api/v1/audit` | e-mail, realm and hostname are the placeholder for a caller without `:TenantsManage` | n.a. | masked on read (labels) | `system_start_canary_test.exs` (all three values, all surfaces), `register_routes_test.exs` SF-08 |
| A3 | log lines and event metadata | the whole run at `:debug` | none of the three values in any log line or event metadata | n.a. | not logged | `system_start_canary_test.exs` |
