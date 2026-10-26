# BilimBaga study T5c: reset and welcome mail, and the tenant realm template

Written finding, read-only study (task T5c of `docs/migration/bilimbaga-retirement-status.md`, criterion 5).
No product code, test or requirement file is changed by it. Date: 2026-10-26.

Sources read in the BilimBaga repo (`c:\Users\tvolo\dev\ai-dala\BilimBaga`, HEAD `445216d`) and in this repo
(`priv/keycloak/provisioner/v1/tenant-realm.json` and `README.md`, `docs/migration/decisions/0072-tenant-provisioner-realm-per-tenant-on-qa.md`
D2 and section 10, `lib/letflow/login_discovery/notifier/smtp*`, `lib/letflow/tenant_provisioner/config.ex`).

## 1. Answer

- **BilimBaga sends all of its mail itself**, from its Go backend over SMTP. Its login is its own (bcrypt
  passwords in its own `users` table), so there is no identity provider to send anything.
- **Letflow today sends neither a reset mail nor a welcome mail, and Keycloak is not configured to.** The only
  mail Letflow's code sends is the login-discovery message ("Your Letflow sign-in options", REQ-441).
- **The REQ-572 realm template (`v1`) does not cover reset or welcome mail.** It leaves `smtpServer` out on
  purpose (an argument of the provisioner call, never in git) and does not set `resetPasswordAllowed`, so the
  Keycloak "Forgot password" link is off in a realm made from the template. Welcome mail is decided "not
  Keycloak" by 0072.

## 2. How BilimBaga sends mail today

| Mail | Trigger | Code | Content |
|---|---|---|---|
| Reset link (self-service "forgot password") | `POST` forgot-password for an active user | `backend/internal/auth/recovery_service.go` `ForgotPassword` issues a 256-bit token (`resetTokenBytes = 32`), stores only its hash, TTL 60 min (`resetTokenTTL`), at most 3 per hour (`resetMaxPerHour`); `backend/internal/email/service.go` `TriggerPasswordResetLink` sends it in a goroutine | template `password_reset_link`, link `{PUBLIC_APP_URL}/reset-password?token=...`; the response is identical for known and unknown addresses (FR-BB115) |
| Admin password reset | admin resets a user: `backend/internal/users/service.go` `ResetPassword` (line 283, mail at line 313) | `TriggerPasswordReset` | template `password_reset` carrying the **temporary password in clear text** |
| Welcome | none | `CreateUser` (`users/service.go` line 166) generates a temporary password and returns it **in the API response** to the admin; it does not call the mail service (the only `emailSvc` call in that file besides the reminder is the reset at line 313) | the admin hands the password over by hand; `force_password_change` forces a change at first login |

Delivery mechanics (`backend/internal/email/service.go`): `net/smtp`, plain or STARTTLS by `SMTP_TLS`;
settings `SMTP_HOST/PORT/USER/PASS/TLS/FROM` from the environment (`backend/internal/config/config.go`); one
sender for the whole deployment; templates rendered from `internal/email/locales/{en,ru,kk}.json`, locale from the
user, falling back to the tenant locale; every attempt recorded in `email_log` (recipient, template, time,
error; migration 022). Sending is fire-and-forget: no retry, no queue.

## 3. What Letflow and the realm template provide

| Item | State | Evidence |
|---|---|---|
| Realm `verifyEmail` | `true` | `tenant-realm.json` line 7 (0072 D2) |
| Realm `resetPasswordAllowed` | **not set**: Keycloak's default for an imported realm is off, so the login page has no "Forgot password" link | `grep resetPasswordAllowed tenant-realm.json` finds nothing |
| Realm `smtpServer` | **not in the template**; the provisioner adds the shared QA relay per call, credentials never in git | `README.md` "Fields the provisioner adds"; 0072 D2 |
| E-mail templates, theme, locale (`ru`, `kk`) | none: the realm gets Keycloak's default English texts | no `loginTheme`, `emailTheme`, `internationalizationEnabled` in the file |
| `requiredActions` (UPDATE_PASSWORD) on the first administrator | none; the first sign-in credential is the provisioner's one-time `initial_password` | 0072 D2 "First administrator" row |
| Welcome mail | **decided not Keycloak** (its welcome mail needs `manage-users`); "the front door or Letflow" left open | 0072 section 10 |
| Delivery of `initial_password` to the person | open | 0072 section 10 |
| Letflow outbound mail | only the login-discovery notifier: fixed template, `:gen_smtp`, settings `LETFLOW_SMTP_*`, no delivery log, no tenant templates | `lib/letflow/login_discovery/notifier/smtp.ex`, `Smtp.Message` |
| Admin-created users in a tenant (TENANT_ADMIN users surface) | Letflow has no admin client to Keycloak (0072 section 10), so a Keycloak account for a new user is created elsewhere; no mail path in Letflow | 0072 section 10 |

So for reset: the mechanism that fits the target is Keycloak's own forgot-password flow, which needs two things
the template lacks (the realm switch and an SMTP server), and the SMTP server is by design supplied per call.
For welcome: nothing exists on the Letflow side, and BilimBaga itself does not send one either (the admin hands
over the temporary password).

## 4. Gaps and candidate requirements

| # | Gap | Candidate requirement | Owner of the decision |
|---|---|---|---|
| G1 | Forgot-password link is off in tenant realms: `resetPasswordAllowed` missing from `v1` | Template `v2`: add `"resetPasswordAllowed": true` (a new `v2/` directory; `v1` is frozen) and a drift-test row; with it, `actionTokenGeneratedByUserLifespan` set to match BilimBaga's 60 minutes | REQ-572 amendment, small |
| G2 | Provisioner must pass `smtpServer` (host, port, from, TLS, credentials by reference) and a failed relay must not leave a realm where reset silently does nothing | Provisioner requirement: validate and set `smtpServer` on realm creation; refuse or report when absent | infra and Letflow; the relay itself is the owner's |
| G3 | Reset and welcome texts in `ru` and `kk` (BilimBaga has en, ru, kk) | Template `v2`: `internationalizationEnabled`, `supportedLocales`, `emailTheme` carrying the translated texts, theme shipped by infra | infra; texts reviewed by BA-BILIMBAGA |
| G4 | Nobody sends a welcome mail, and delivery of `initial_password` is open (0072 section 10) | Decide the sender (front door or Letflow). If Letflow: it belongs to the outbound notification requirement T5a (template store, SMTP adapter, delivery log), as a `welcome` template that carries a sign-in link and never the password | owner decision; flagged, not assumed |
| G5 | Users added later by a TENANT_ADMIN have no mail path: no Keycloak account creation from Letflow and no invitation mail | Candidate requirement: invitation of a tenant user (create the Keycloak account through the provisioner or a narrow admin client, send the "set your password" action mail). Needs a security design: a new credential and tenant-bound realm access | owner decision (0072 says admin client is decided later) |
| G6 | BilimBaga's admin reset mails a clear-text temporary password; this must not be carried over | Not a requirement: retire it. Replace with Keycloak's reset (G1) or an execute-actions mail (G5); no password in mail | none |
| G7 | Delivery audit (`email_log`) has no counterpart for Keycloak mail | Covered by T5a's delivery log only for mail Letflow sends; Keycloak's own mail is visible only in Keycloak events. Accept or add the event listener | owner decision |

The smallest set that retires BilimBaga's reset behaviour is G1 + G2. G3 is a quality gap for the Kazakh and
Russian users; G4 and G5 are owner decisions that this study does not make.

## 5. Not checked

No production BilimBaga database or SMTP relay was read; `SMTP_FROM` and `PUBLIC_APP_URL` values are from
`.env.example` only. Keycloak behaviour for an imported realm (default `resetPasswordAllowed` false) is stated
from Keycloak's documented default, not from a sandbox import; infra's sandbox import is the check.
