# UAT mail through the QA mail trap

T-1254 (D-088). QA Keycloak sends all mail to a Mailpit trap; nothing leaves the host. UAT scenarios that
need mail (invite a user, verify e-mail, reset password) read it from the trap API, never from a human
mailbox (no Gmail in the main test chain).

Two mail paths reach the trap and they are configured apart: Keycloak's mail (the invite, the
verification, the reset) and Letflow's OWN mail (the "task assigned" copy, the exam notifications,
and the notification step of the tenant-registration pilot). Keycloak's mail is wired to the trap
(the realm table below); Letflow's own mail was not, and is the subject of
["Letflow's own mail on QA"](#letflows-own-mail-on-qa-the-notifier-adapter) below.

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

## Letflow's own mail on QA (the notifier adapter)

Checked 2026-11-21 (T-2593, gap G8 of the tenant-registration pilot).

**Finding: Letflow's own mail is not configured on QA.** No mail variable is set at all, so the
adapter is the `Noop` default of `config/config.exs`: **Letflow sends no mail of its own on QA.** A
delivery attempt is logged as `skipped` / `adapter_noop` (`lib/letflow/notifications.ex`); only
Keycloak's mail reaches the trap.

| Variable | State on QA |
|---|---|
| `LETFLOW_MAIL_ADAPTER` | not set |
| `LETFLOW_SMTP_HOST` | not set |
| `LETFLOW_SMTP_PORT` | not set |
| `LETFLOW_SMTP_TLS` | not set |
| `LETFLOW_SMTP_USERNAME` | not set |
| `LETFLOW_SMTP_PASSWORD` | not set |
| `LETFLOW_MAIL_FROM` | not set |
| `LETFLOW_PUBLIC_BASE_URL` | not set |
| `LETFLOW_MAIL_TIMEOUT_MS` | not set |

Read from the running application container and from the `.env` file the deployment is started
from; only the names and their state, never a value. The demo stack is the same: no mail variable
is set there either.

**The trap can be read, so the runner can read it.** Its HTTP API answers and `scripts/mail_trap.sh`
reads it through the tunnel of the section above (verified 2026-11-21 from a team host: the reader
reaches the API and reports "no mail to <address>" instead of "trap unreachable"). What the trap
does not offer is what the adapter needs on the SMTP side: its SMTP port advertises `SIZE`,
`ENHANCEDSTATUSCODES`, `8BITMIME` and `SMTPUTF8`, and **neither `STARTTLS` nor `AUTH`**. The
adapter is strict about both (`lib/letflow/login_discovery/notifier/smtp/transport.ex`: `tls:
:always`, peer verification against the CA store of the image, `auth: :always`), and
`LETFLOW_SMTP_TLS=none` is refused in a prod build - QA runs `MIX_ENV=prod`. The trap has to
change as well.

### Check it yourself

`scripts/mail_adapter_check.sh` reports the same thing on any host. It is read-only and prints a
variable NAME and its state, never a value (the two closed-set modes, the adapter mode and the TLS
mode, are printed because they name no secret).

```
scripts/mail_adapter_check.sh --container letflow-qa-app-1        # on the QA host
scripts/mail_adapter_check.sh --env-file /opt/apps/letflow-qa/.env # the file the deployment reads
```

Exit 0 = Letflow's own mail can reach the trap and the trap can be read; 1 = a blocker stands (the
script names it); 3 = the trap is unreachable. The test is `test/scripts/mail_adapter_check_test.exs`
(fake `curl`, `nc` and `docker`; no network).

### The request to infra

The operator sends the block below to infra as it stands; it is self-contained.

> **Subject: QA mail: Letflow's own mail adapter to the existing mail trap**
>
> Please change two things on QA. The pilot needs Letflow's own mail (the notification step of the
> tenant-registration process) to land in the existing trap. Nothing may leave the host: the trap
> stays local.
>
> **1. The trap must offer STARTTLS and AUTH on its SMTP port.** The trap is the `mailpit`
> container of `/opt/apps/qa-mailtrap/compose.yaml`, shared with Keycloak. Today its SMTP port
> advertises only `SIZE`, `ENHANCEDSTATUSCODES`, `8BITMIME` and `SMTPUTF8`. The application upgrades
> the connection with STARTTLS and verifies the certificate against the CA store of its own image,
> and it always sends the credentials, so a plaintext or unauthenticated trap is refused. Please
> give the trap `--smtp-tls-cert` / `--smtp-tls-key` (a certificate that chains to a CA the
> application image trusts and whose name matches the host name the application uses) and
> `--smtp-auth-accept-any` (or `--smtp-auth-file`), so that the port advertises `STARTTLS` and
> `AUTH`; `--smtp-require-starttls` is welcome as well. The trap stays local: nothing may leave
> the host.
>
> **2. Add these variables to `/opt/apps/letflow-qa/.env`** (the file the `letflow-qa` compose
> project reads through `env_file`) and restart the `app` service:
>
> | Variable | Value |
> |---|---|
> | `LETFLOW_MAIL_ADAPTER` | `smtp` |
> | `LETFLOW_SMTP_HOST` | the trap's host name as the application container sees it (the `mailpit` container is on the `letflow-qa_default` network, the same network as the application) |
> | `LETFLOW_SMTP_PORT` | `1025` |
> | `LETFLOW_SMTP_TLS` | `starttls` (the adapter's default; `none` is refused in a prod build and QA runs `MIX_ENV=prod`) |
> | `LETFLOW_SMTP_USERNAME` | any non-empty value (the trap accepts any credentials) |
> | `LETFLOW_SMTP_PASSWORD` | any non-empty value |
> | `LETFLOW_MAIL_FROM` | a mailbox on the QA sending domain |
> | `LETFLOW_PUBLIC_BASE_URL` | `https://qa.bizdala.com` |
>
> The application refuses to start when one of them is missing or invalid; the boot message names
> the variable and never the value (`config/runtime.exs`,
> `Letflow.LoginDiscovery.Notifier.Smtp.Config`).
>
> **3. Verify.** `scripts/mail_adapter_check.sh --container letflow-qa-app-1` on the QA host must
> end with `ready:`. Then a mail to an `@uat.letflow.internal` address must be readable with
> `scripts/mail_trap.sh subject <address>`.
>
> Please do not set the variables before the trap offers STARTTLS and AUTH: the application starts
> then, but every send fails and the failure is only visible as a `failed` / `adapter_error`
> delivery row.
