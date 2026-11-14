# Production readiness of Letflow for a customer company (REQ-785)

What a customer company needs from a production Letflow, and which Letflow pieces already serve it, on one page, so
that infra and the owner can decide from it. The settings table is kept in step with `config/runtime.exs` by
`test/letflow/production_readiness_runbook_test.exs`.

## Status

Production is not approved. The owner has approved the build on QA only (portfolio decision D-019 item 3 and
D-019 item 9, "build approved on QA only") and D-086 states "not lifted: production". This page changes no setting
and creates no environment: it builds nothing in infra and enables nothing. Every infra step it mentions is an owner
or infra item (see "Open owner questions").

## Sign-in per company

Each customer company signs in through its own tenant and realm. Each statement names its source.

1. Each customer company is its own tenant with its own Keycloak realm (portfolio decision D-016, one realm per tenant).
2. The realm is made from the versioned template `priv/keycloak/provisioner/v2/tenant-realm.json`.
3. Until a production provisioner is approved, the tenant gets its realm by the manual steps of
   `docs/runbooks/onboarding-new-tenant-realm.md` (the QA-only provisioner of `docs/runbooks/tenant-provisioner-credential.md`
   is not used for production, D-019 item 9).
4. The tenant is then set to `tenant_type` production, as the section "Tenant type (REQ-469)" of
   `docs/runbooks/onboarding-new-tenant-realm.md` says.
5. D-019 item 7 settles the Keycloak admin rights of the first administrator for demo tenants only (no Keycloak admin
   rights). Manage-users rights for the first administrator of a production tenant are decided later, so this page
   states no rule for a production tenant; see "Open owner questions".
6. Gate F pre-go-live CHECK (not an owner question): re-probe the production `bpm-default` realm for the nine realm roles
   (AGENT_RUNNER, CANDIDATE, PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR, STOREKEEPER, TASK_WORKER, TENANT_ADMIN,
   TENANT_AUDITOR). STOREKEEPER, TENANT_ADMIN and TENANT_AUDITOR were missing on 2026-10-14; a fix is infra's and only on
   the owner's production go. Nothing is touched on production by this page. Run the same check again when the roles-as-data
   stages 2 and 4 land (`docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md`,
   `docs/design/roles-stage0-slices.md`), because the IdP claim mapping changes then. The file check is
   `scripts/check_realm_roles.py`.

## What a backup must hold

Three things, restored together. A restore of one without the others does not give a working company.

1. The PostgreSQL database: the `public` schema and every tenant schema.
2. The Keycloak realm of every tenant.
3. The value of `LETFLOW_SECRETS_MASTER_KEY`, kept apart from the database backup. Stored secrets are encrypted under
   this key (`docs/migration/decisions/0016-secrets-storage-backend.md`, sections A and B), so a database backup
   without it cannot decrypt them.

`docs/runbooks/tenant-provisioner-credential.md` says: "A purge does not erase backups or replicas". Data of a purged
tenant stays in older backups until they expire.

The scripts, targets, the restore test, the backup status line of the readiness answer (`LETFLOW_BACKUP_STATUS_DIR`)
and the off-site proposal are in `docs/runbooks/backup-restore.md`; this page does not repeat them.

## Settings

Every boot setting that `config/runtime.exs` names. "When unset" is what the file does when the variable is unset.
No value is shown for a secret (INV-4). "Required in :prod" means the release stops at boot without it.
Entries marked "comment only" appear only in a comment of the file and are not read by it.

| Setting | Required in :prod | When unset | Source |
|---|---|---|---|
| `CORS_ALLOWED_ORIGINS` | no (but without it no browser origin is trusted) | the list is empty: no cross-origin caller is trusted (prod block only) | `config/runtime.exs` (REQ-118) |
| `DATABASE_URL` | yes | raises at boot (prod block) | `config/runtime.exs` |
| `LETFLOW_AUTH_FAILURES_PER_MIN` | no | nothing written; the limiter keeps its built-in defaults; a non-positive-integer value raises | `config/runtime.exs`, `Letflow.Plugs.AuthAttemptLimit` |
| `LETFLOW_BACKUP_STATUS_DIR` | no | nil: the readiness answer says backup status is "not configured here" | `config/runtime.exs`, `docs/runbooks/backup-restore.md` |
| `LETFLOW_BUILD_SHA` | no | nil: `GET /health` reports `sha` as null | `config/runtime.exs`, `deploy/Dockerfile` |
| `LETFLOW_INCLUDE_RUNTIME_DEMO` | no | not read by the code, mentioned in a comment (a build-time switch of the QA-only demo module) | `config/runtime.exs` comment |
| `LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION` | only when the login discovery mount is enabled | nil; with the mount enabled outside dev and test a missing or too short marker raises | `config/runtime.exs`, `Letflow.LoginDiscovery.BootCheck` |
| `LETFLOW_LOGIN_DIRECTORY_PEPPER` | yes (every environment) | raises at boot; must be a secret of 64 lowercase hex characters, distinct from the master key | `config/runtime.exs` (REQ-435) |
| `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID` | yes (every environment) | raises at boot | `config/runtime.exs` (REQ-435) |
| `LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS` | no (rotation only) | no previous pepper; set together with its id or not at all, otherwise raises | `config/runtime.exs` (REQ-435) |
| `LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID` | no (rotation only) | no previous pepper; set together with the pepper or not at all, otherwise raises | `config/runtime.exs` (REQ-435) |
| `LETFLOW_LOGIN_DISCOVERY_ENABLED` | no | default value: off in :prod (on in dev and test); a value other than true or false raises | `config/runtime.exs`, `Letflow.Plugs.ClientIp` |
| `LETFLOW_LOGIN_DISCOVERY_MODE` | no | nothing written; the default of `config/config.exs` (redirect_single) stands; an unknown value raises | `config/runtime.exs` (REQ-437) |
| `LETFLOW_MAIL_ADAPTER` | no (needed to enable email-first login in :prod) | nothing written; the no-op mail adapter stands, nothing is delivered | `config/runtime.exs` (REQ-441) |
| `LETFLOW_MAIL_FROM` | only with the smtp adapter | nothing written; with `LETFLOW_MAIL_ADAPTER` set to smtp a missing value raises | `config/runtime.exs` (REQ-441) |
| `LETFLOW_MAIL_TIMEOUT_MS` | no | default value of the smtp parser | `config/runtime.exs`, `Letflow.LoginDiscovery.Notifier.Smtp.Config` |
| `LETFLOW_MODULE_ROLLOUT_HALT_AFTER` | no | default value 3 (range 1 to 1000); an invalid value raises | `config/runtime.exs`, `Letflow.ModuleUpgrade.Settings` |
| `LETFLOW_MODULE_UPGRADE_ON_BOOT` | no | default value false (exactly true or false) | `config/runtime.exs` (REQ-772) |
| `LETFLOW_MODULE_UPGRADE_ONE_TX_MAX_RECORDS` | no | default value 1000; an invalid value raises | `config/runtime.exs`, `Letflow.ModuleUpgrade.Settings` (REQ-773) |
| `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` | no | default value: empty list (off); a name outside the realm alphabet raises | `config/runtime.exs` (ISS-1030) |
| `LETFLOW_PLATFORM_TENANT_ID` | no for boot; yes for any platform-scope operation | nothing written; a warning goes to standard error and platform-scope operations are denied for every caller; a malformed value raises | `config/runtime.exs`, `Letflow.PlatformTenant` |
| `LETFLOW_PROBLEM_REPORT_EXPORT_SHA256` | no; QA only for the problem-report handoff (T-1948) | nothing written; the `/maintenance/v1` export answers 404 | `config/runtime.exs`, `Letflow.Plugs.ReportExportAuth`, `docs/runbooks/problem-report-handoff.md` |
| `LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | nothing written | `config/runtime.exs`, `Letflow.TenantProvisioner.Config`, `docs/runbooks/tenant-provisioner-credential.md` |
| `LETFLOW_PROVISIONER_CREDENTIAL_SHA256` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | nothing written; the `/admin/v1` provisioner routes answer 404 | `config/runtime.exs`, `docs/runbooks/tenant-provisioner-credential.md` |
| `LETFLOW_PROVISIONER_DEFAULT_MODULES` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | default value: a built-in module list | `config/runtime.exs`, `Letflow.TenantProvisioner.Config` |
| `LETFLOW_PROVISIONER_DEMO_ALARM` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | default value 25 | `config/runtime.exs`, `Letflow.TenantProvisioner.Config` |
| `LETFLOW_PROVISIONER_DEMO_CAP` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | default value 30 | `config/runtime.exs`, `Letflow.TenantProvisioner.Config` |
| `LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | default value of the provisioner parser (a starting value, not a rule) | `config/runtime.exs`, `Letflow.TenantProvisioner.Config` |
| `LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | nothing written (no read-only credential) | `config/runtime.exs`, `docs/runbooks/tenant-provisioner-credential.md` |
| `LETFLOW_PROVISIONER_RETENTION_DAYS` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | default value 30 | `config/runtime.exs`, `Letflow.TenantProvisioner.Config` |
| `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES` | no; stays unset in production until the owner approves production provisioning (D-019 item 9) | default value 60 | `config/runtime.exs`, `Letflow.TenantProvisioner.Config` |
| `LETFLOW_PUBLIC_BASE_URL` | only with the smtp adapter | nothing written; with the smtp adapter a missing value raises | `config/runtime.exs` (REQ-441) |
| `LETFLOW_REALM_USERS_ENABLED` | no | default value: off; only true or unset is accepted, anything else raises | `config/runtime.exs` (REQ-807) |
| `LETFLOW_REALM_USERS_PROVISIONER_TOKEN` | only when realm users are enabled | nothing written; set together with the flag and the URL or not at all, otherwise raises | `config/runtime.exs` (REQ-807) |
| `LETFLOW_REALM_USERS_PROVISIONER_URL` | only when realm users are enabled | nothing written; set together with the flag and the token or not at all, otherwise raises | `config/runtime.exs` (REQ-807) |
| `LETFLOW_RUNTIME_DEMO_RELEASE` | no | default value 0.1.0 (no effect unless the build included the QA-only demo module) | `config/runtime.exs`, `Letflow.Modules.RuntimeDemo` |
| `LETFLOW_SECRETS_MASTER_KEY` | yes (every environment) | raises at boot; must be a secret of 64 lowercase hex characters, not all zeros or all ones; no default exists | `config/runtime.exs`, `docs/migration/decisions/0016-secrets-storage-backend.md` |
| `LETFLOW_SIGNUP_ABANDON_DAYS` | no | default value 7 | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_ALLOW_DOMAINS` | no | default value: empty list | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_BASE_URL` | only when sign-up is enabled | nil; with sign-up enabled outside dev and test a value that is not an https URL raises | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_CAPTCHA` | no | nothing written; only off is accepted, anything else raises | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_DISPOSABLE_DOMAINS` | no | default value: empty list | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_DOMAIN_CAP_EXEMPT` | no | default value: a built-in list of public mail domains | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_DOMAIN_HOURLY_CAP` | no | default value 20 | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_ENABLED` | no | default value: off; only true or false is accepted; enabled outside dev and test it also needs trusted proxies and an https base URL | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_HOSTNAME_DOMAIN` | no | nil; set together with the provisioner URL and token or not at all, otherwise raises | `config/runtime.exs` (decision 0085) |
| `LETFLOW_SIGNUP_IP_HOURLY_CAP` | no | default value 5 | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_PENDING_CAP` | no | default value 50 | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_PROVISIONER_TOKEN` | no | nothing written; set together with the URL and the hostname domain or not at all, otherwise raises | `config/runtime.exs` (decision 0085) |
| `LETFLOW_SIGNUP_PROVISIONER_URL` | no | nil; set together with the token and the hostname domain or not at all, otherwise raises | `config/runtime.exs` (decision 0085) |
| `LETFLOW_SIGNUP_RESEND_INTERVAL_SECONDS` | no | default value 60 | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SIGNUP_TOKEN_TTL_HOURS` | no | default value 24 | `config/runtime.exs` (decision 0084) |
| `LETFLOW_SMTP_HOST` | only with the smtp adapter | nothing written; with the smtp adapter a missing value raises | `config/runtime.exs` (REQ-441) |
| `LETFLOW_SMTP_PASSWORD` | only with the smtp adapter | counted as absent; with the smtp adapter a missing value raises; never written to app config | `config/runtime.exs` (REQ-441) |
| `LETFLOW_SMTP_PORT` | only with the smtp adapter | nothing written; with the smtp adapter a missing value raises | `config/runtime.exs` (REQ-441) |
| `LETFLOW_SMTP_TLS` | no | default value of the smtp parser; the value none is refused in :prod | `config/runtime.exs`, `Letflow.LoginDiscovery.Notifier.Smtp.Config` |
| `LETFLOW_SMTP_USERNAME` | only with the smtp adapter | counted as absent; with the smtp adapter a missing value raises; never written to app config | `config/runtime.exs` (REQ-441) |
| `LETFLOW_TRUSTED_PROXIES` | yes when login discovery or sign-up is enabled | default value: empty list; with either enabled in :prod an empty list raises | `config/runtime.exs`, `Letflow.Plugs.ClientIp` (REQ-439) |
| `LETFLOW_VOICE_LLM_API_KEY` | no | nil: that voice step is off; the value is never logged | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_LLM_BASE_URL` | no | nil: that voice step is off | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_LLM_JSON_MODE` | no | nil | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_LLM_MODEL` | no | nil: that voice step is off | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_LLM_PROVIDER` | no | nil: that voice step is off | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_STT_API_KEY` | no | nil: that voice step is off; the value is never logged | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_STT_BASE_URL` | no | nil: that voice step is off | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_STT_MODEL` | no | nil: that voice step is off | `config/runtime.exs` (REQ-740) |
| `LETFLOW_VOICE_STT_PROVIDER` | no | nil: that voice step is off | `config/runtime.exs` (REQ-740) |
| `LOG_LEVEL` | no | default value info outside test; an unrecognised value raises | `config/runtime.exs` (REQ-193) |
| `OIDC_CLIENT_ID` | no | default value: a placeholder client id (prod block); set it for a real Keycloak | `config/runtime.exs` |
| `OIDC_ISSUER` | no | legacy fallback only: used to derive the Keycloak base URL when `OIDC_KEYCLOAK_BASE_URL` is unset; never decides trust (REQ-370) | `config/runtime.exs` (REQ-370) |
| `OIDC_KEYCLOAK_BASE_URL` | yes in practice | falls back to `OIDC_ISSUER`, then to a placeholder `.invalid` URL: sign-in cannot work (prod block) | `config/runtime.exs` (REQ-370) |
| `POOL_SIZE` | no | default value 30 (prod block) | `config/runtime.exs` (ISS-0908) |
| `PORT` | no | default value 4000 (prod block) | `config/runtime.exs` (ISS-0015) |
| `RESERVED_HEADROOM` | no | default value 2 (prod block) | `config/runtime.exs` (ISS-0908) |

## Open owner questions

No number is given here; each is the owner's to answer.

1. What is the largest acceptable data loss for a customer company?
2. What is the longest acceptable restore time?
3. How long are backups kept, including the data of a purged tenant that still sits in a backup?
4. The production Keycloak (D-019 item 3): where it runs, who runs it, and who holds its admin access.
5. Production provisioning (D-019 item 9): whether and when a production provisioner is approved; until then realms are made by hand.
6. Does the first administrator of a production tenant get Keycloak manage-users rights? D-019 item 7 leaves it to be decided later.

Infra items behind these answers, listed for the PM and done by nobody here: the production host (VPS), DNS, the
off-site copy of the backups and its restore drill (`docs/runbooks/backup-restore.md`), custody of
`LETFLOW_SECRETS_MASTER_KEY`, and delivery of alerts from the backup status files.
