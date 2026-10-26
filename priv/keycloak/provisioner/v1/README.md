# Tenant realm template, version 1

`tenant-realm.json` is the realm the tenant provisioner clones for each new tenant
(decision 0072 D2, REQ-572, QA only). **Never use `priv/keycloak/realms/bpm-default.json`
for a tenant**: it is the dev seed (demo users, `PLATFORM_ADMIN`, wildcard redirects).

`v1` is frozen. A change is a new `v2/` directory, not an edit here. The version is the realm
attribute `templateVersion`. The drift test
`test/letflow/keycloak_tenant_realm_template_test.exs` fails when the file stops meeting the
Realm checklist of `docs/runbooks/onboarding-new-tenant-realm.md`. It reads the file only; the
real check that Keycloak accepts the import is infra's sandbox import.

## Placeholders the provisioner replaces

| Placeholder | Value |
|---|---|
| `__REALM_ID__` | the realm name, `t-` + first 20 hex characters of the tenant id |
| `__TENANT_HOST__` | the tenant's validated host name (in `redirectUris` and `webOrigins`) |

Replace every occurrence; refuse a result that still matches `__[A-Z_]+__`. Never put `*` as a
redirect URI or web origin.

## Fields the provisioner adds (not in git)

- The first administrator, as an inline user: `email` (owner e-mail, trimmed and lower-cased),
  `enabled` true, `emailVerified` true, `realmRoles: ["default-roles-<realm>"]` on the user. No
  admin or realm-management role, no group. The one-time `initial_password` is the provisioner's
  and never goes in git.
- `smtpServer` (the shared relay; credentials never in git).
- Optionally a `tenant_id` realm attribute.

## What the file leaves out on purpose

- Users, and the `PLATFORM_ADMIN` role.
- The `letflow-mobile` client and a realm-level `clientScopes` list (a list would replace the
  built-in scopes).
- `defaultClientScopes` on `letflow-web`: the client relies on the realm's built-in default
  client scopes (`basic`, `email`, `profile`, `roles`, `web-origins`, `acr`). `basic` carries
  `sub`, which Letflow's auth reads; `email` supplies the `email` and `email_verified` mappers.
- `TENANT_ADMIN` is a plain realm role, in no default role, group or composite; the first
  administrator receives it through the onboarding grant.
- Users cannot edit their own e-mail: the declarative user profile gives `email` edit rights to
  `admin` only.

`LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` must never name a realm made from this template.
