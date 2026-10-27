# Tenant realm template, version 2

`tenant-realm.json` is the realm the tenant provisioner clones for each new tenant
(decision 0072 D2, REQ-593, QA only). **Never use `priv/keycloak/realms/bpm-default.json`
for a tenant**: it is the dev seed (demo users, `PLATFORM_ADMIN`, wildcard redirects).

`v1` is frozen: it is not edited, and `v2` is a new directory beside it. The version is the realm
attribute `templateVersion` (`"2"` here). The drift test
`test/letflow/keycloak_tenant_realm_template_v2_test.exs` reads the file only (no Keycloak, no
database); the real check that Keycloak accepts the import is infra's sandbox import.

## What differs from v1

`tenant-realm.json` is the v1 file with exactly these changes, and the drift test pins it:

| Field | Value | Why |
|---|---|---|
| `attributes.templateVersion` | `"2"` | the version marker |
| `resetPasswordAllowed` | `true` | Keycloak shows the "Forgot password" link only when this is on |
| `actionTokenGeneratedByUserLifespan` | `3600` | the reset link lives 60 minutes (seconds) |
| `internationalizationEnabled` | `true` | switches realm locales on |
| `supportedLocales` | `["en", "ru", "kk"]` | English, Russian, Kazakh |
| `defaultLocale` | `"en"` | Keycloak's own fallback; a UAT assumption to be confirmed by the process owner |

## Placeholders the provisioner replaces

| Placeholder | Value |
|---|---|
| `__REALM_ID__` | the realm name, `t-` + first 20 hex characters of the tenant id |
| `__TENANT_HOST__` | the tenant's validated host name (in `redirectUris` and `webOrigins`) |

Replace every occurrence; refuse a result that still matches `__[A-Z_]+__`. Never put `*` as a
redirect URI or web origin.

## `smtpServer` is mandatory for a v2 realm

A v2 realm is only useful with an `smtpServer`: without it Keycloak cannot send the reset mail
that `resetPasswordAllowed` promises. The template does not carry it (decision 0072 D2, INV-4: the
relay and its credentials are never in git), so the provisioner adds `smtpServer` from its own
configuration, and **the provisioner must refuse to create a v2 realm without it**. That check
lives in the provisioner (infra's `services/tenant-provisioner`), not in this repository.

## Fields the provisioner adds (not in git)

- `smtpServer` (the shared relay; mandatory, see above; credentials never in git).
- The first administrator, as an inline user, exactly as for v1 (see `../v1/README.md`). The
  one-time `initial_password` is the provisioner's and never goes in git.
- Optionally a `tenant_id` realm attribute.

## Outside the template on purpose

- `emailTheme`, `loginTheme` and every mail or page text (`localizationTexts`): infra ships the
  theme, and the texts are reviewed by the business analyst. The template only switches the
  locales on.
- Users, and the `PLATFORM_ADMIN` role.
- Everything else v1 leaves out (see `../v1/README.md`).

`LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` must never name a realm made from this template.
