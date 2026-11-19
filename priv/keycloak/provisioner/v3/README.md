# Tenant realm template, version 3

`tenant-realm.json` is the realm the tenant provisioner clones for each new tenant (decision 0072 D2,
T-2207, QA only). It is the v2 file plus one client, `letflow-mobile`. `v1` and `v2` are frozen; the
rules in `../v2/README.md` (placeholders, `smtpServer` mandatory, first administrator, what stays outside
the template) apply unchanged. The version is the realm attribute `templateVersion` (`"3"`). The drift
test `test/letflow/keycloak_tenant_realm_template_v3_test.exs` reads the file only.

## What differs from v2

The `letflow-mobile` client, copied from the `letflow-mobile` block of
`priv/keycloak/realms/bpm-default.json`: public client, standard flow only, PKCE `S256`, implicit flow and
direct access grants off, the `realm-roles` and `letflow-mobile-audience` mappers. Its addresses:

| Field | Value |
|---|---|
| `redirectUris` | `com.bizdala.letflow:/oauth2redirect` and `__PWA_URI__` |
| `webOrigins` | `__PWA_ORIGIN__` |
| `attributes."post.logout.redirect.uris"` | `com.bizdala.letflow:/oauth2redirect##__PWA_URI__` |

| Placeholder | Value |
|---|---|
| `__PWA_URI__` | the exact PWA address of the environment, `https://<pwa-host>[:port]/<base-href>/`, no wildcard, query or fragment |
| `__PWA_ORIGIN__` | its origin, `https://<pwa-host>[:port]` |

`Letflow.TenantProvisioner.RealmRequest.build/5` fills them from the `:pwa_uri` option and refuses a wildcard
or malformed value (`:invalid_pwa_uri`). Without `:pwa_uri` the client keeps the native redirect only.

## Existing realms: create if missing, never overwrite

Importing a template does not touch a realm that already exists. For such a realm the provisioner calls
`RealmRequest.ensure_mobile_client/2` with the realm's client ids: it returns the `letflow-mobile` client to
create, or `[]` when the realm has one. An existing client (its redirect URIs included) is never replaced.
