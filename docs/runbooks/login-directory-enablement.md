# Runbook: enabling email-first login (login directory)

REQ-444, decision 0043 D-D, decision 0042 OQ-3. This is the checklist to complete before
`LETFLOW_LOGIN_DISCOVERY_ENABLED=true` is set in any environment other than dev/test
(QA runs `MIX_ENV=prod`, so QA is gated too). Shipped defaults keep the feature off for `:prod`
(`config/config.exs`: `enabled: config_env() != :prod`) and the SPA flag `VITE_EMAIL_FIRST_LOGIN`
defaults to `false`.

Fill the Owner, Evidence and Date columns when an item is done. Evidence is a reference (ticket,
PR, document, inventory entry), never a secret value.

"Checked at boot" means `config/runtime.exs` refuses to start when the item is wrong. "Only
documented" means nothing in code verifies it; the owner is the only control.

## A. Checked at boot

| # | Item | Owner | Evidence | Date | Enforcement |
|---|------|-------|----------|------|-------------|
| A1 | Legal-confirmation marker `LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION` set (non-blank, at least 8 characters; the value is the confirming person's reference and a date). ADVISORY: the check cannot prove a confirmation happened, it only makes enabling without one a deliberate, auditable act. | | | | CHECKED AT BOOT (`Letflow.LoginDiscovery.BootCheck`) |
| A2 | A delivering mail adapter is selected: `LETFLOW_MAIL_ADAPTER=smtp` (`Letflow.LoginDiscovery.Notifier.Smtp`). Unset, `noop` and the test double are refused. The explicit list lives in `BootCheck.delivering_adapters/0`. | | | | CHECKED AT BOOT |
| A3 | `LETFLOW_TRUSTED_PROXIES` is non-empty when the mount is enabled in `:prod` (REQ-439). | | | | CHECKED AT BOOT (`Letflow.Plugs.ClientIp.boot_check/3`) |
| A4 | Pepper and key id configured (`LETFLOW_LOGIN_DIRECTORY_PEPPER` and `_ID`, REQ-435). | | | | CHECKED AT BOOT (REQ-435 checks) |

## B. Only documented (not verified by code)

| # | Item | Owner | Evidence | Date | Enforcement |
|---|------|-------|----------|------|-------------|
| B1 | OQ-3 legal confirmation by a named person (lawful basis and controller; BA position in decision 0043 D-D is PROPOSED only). | | | | ONLY DOCUMENTED |
| B2 | QA nginx `real_ip` action (infra T-0155) and `LETFLOW_TRUSTED_PROXIES` set to the Docker bridge gateway. | | | | ONLY DOCUMENTED |
| B3 | Cloudflare header and ranges, and the container-side peer address (design U3/U4), verified on the real host. | | | | ONLY DOCUMENTED |
| B4 | ISS-0991 (real-host client-IP UAT) closed. Open, blocked on this gate. | | | | ONLY DOCUMENTED |
| B5 | ISS-0992 (real-flow end-to-end) closed. Open, blocked on this gate. | | | | ONLY DOCUMENTED |
| B6 | Realm "Login with email" setting (OQ-8) reviewed, and the multi-tenant dead end (OQ-9) accepted or resolved. | | | | ONLY DOCUMENTED |
| B7 | Pepper provisioned in the environment and the entries recorded in the ai-dala-infra secrets inventory (infra T-0151 is done: record it as EVIDENCE). Rotation: `docs/runbooks/login-directory-pepper-rotation.md`. | | | | ONLY DOCUMENTED |
| B8 | SMTP relay, credentials, and SPF/DKIM/DMARC alignment for the sending domain. | | | | ONLY DOCUMENTED |
| B9 | `VITE_EMAIL_FIRST_LOGIN=true` is set only in the enabling change, never earlier. | | | | ONLY DOCUMENTED |
| B10 | Directory backfill run (dry run first, then real). Release-container form: section 0 of `docs/runbooks/login-directory-pepper-rotation.md`. | | | | ONLY DOCUMENTED |

## Order of operations

1. Complete B1 to B8 and record the evidence.
2. Set the marker (A1), the mail adapter and its settings (A2), and the trusted proxies (A3).
3. Run the backfill (B10).
4. Set `LETFLOW_LOGIN_DISCOVERY_ENABLED=true` and deploy. A boot refusal names the failing
   variable and never echoes a value.
5. Enable the SPA flag (B9) in the same change, then close B4 and B5.

## E-mail copy of the notification bell (T-1571)

The "task assigned" mail is sent only when the tenant setting `notifications.email_copy` is `true` (default off; set it
through the tenant-settings PATCH). A user opts out with the preference `notifications.email` = `"off"`
(`PUT /api/v1/me/preferences`). At most 20 such mails per user per hour; an adapter failure is retried twice inside the
delivery task. Sending to real people in production needs the SMTP credentials (`LETFLOW_SMTP_*`, infra); on QA/demo
mailpit catches the mail. The log carries no address or subject.
