# UAT mail through the QA mail trap

T-1254 (D-088). QA Keycloak sends all mail to a Mailpit trap; nothing leaves the host. UAT scenarios that
need mail (invite a user, verify e-mail, reset password) read it from the trap API, never from a human
mailbox (no Gmail in the main test chain).

## Rules for a scenario that needs mail

1. Test addresses end in `@uat.letflow.internal` (a name that does not resolve; the trap accepts any recipient).
2. Before the scenario starts, purge the trap: `scripts/mail_trap.sh purge`.
3. To read a mail: `scripts/mail_trap.sh wait ADDR [SECONDS]` waits (default 60 s) and prints the link
   (the Keycloak action link is preferred over other links); `scripts/mail_trap.sh subject ADDR` prints the subject.
   Exit codes: 0 ok, 1 timeout or no link, 2 refused address (outside the domain), 3 trap unreachable.
4. Off the host, open the tunnel first: `ssh -N -L 8025:127.0.0.1:8025 ubuntu-16gb-nbg1-1`
   (`MAIL_TRAP_URL` overrides the default `http://127.0.0.1:8025`).
5. Google sign-in is a separate optional branch of a scenario, not part of the main chain.

Test: `test/scripts/mail_trap_test.exs` (fake `curl`, no network).

## Scenarios that use mail today

| Scenario | Mail | Realm |
|---|---|---|
| `platform/foundation-2-onboard-tenant-first-administrator` | invitation to the first administrator | spare realm of the new customer |
| `platform/first-login-admin-binding` | invitation + e-mail verification (confirmed vs not) | customer A / B realms |
| `swiftroute/first-login-administrator-binding` | invitation + e-mail verification | swiftroute |

Other scenarios that name test e-mail addresses (`tenant-administration/tenant-admin-1-people-groups-and-roles`,
`provisioning/*`) do not read mail; their addresses stay on the `@uat.letflow.internal` domain. No scenario
or e2e spec currently covers forgot-password; the reset link is read the same way when one is written
(`docs/migration/bilimbaga-reset-welcome-mail.md`, gap G1).

## Realm wiring (done by infra, one realm at a time)

| Realm | Status |
|---|---|
| `gate-a-demo` | wired |
| `bpm-default`, `meridian`, `vortex`, `swiftroute` | WAITING FOR INFRA (being wired): a mail scenario for these realms is reported waiting, not skipped silently and not run against a real mailbox |
| `master`, `bilimbaga` | deliberately not wired (admin realm / another project): not listed as waiting |
