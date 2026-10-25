# QA tenant subdomains: how Letflow picks the tenant, and what `<slug>.letflow.qa.bizdala.com` needs

Study for GH #3252 (REQ-572, portfolio D-019, QA only). Read-only: no behaviour was changed.
Findings were taken from the code on `main` at the time of writing; symbols are cited, not line numbers.

## Short answer

Letflow does **not** resolve the tenant from the `Host` header. A new tenant whose hostname is
`<slug>.letflow.qa.bizdala.com` will be reached by the network (infra's wildcard already serves the same
upstream), but the SPA will show the **default realm's** login, not the new tenant's, unless the
realm slug is supplied some other way (`?realm=<slug>`, or the email-first login). Proposed fixes are at the end.

## How the tenant is resolved today

1. **API requests (authenticated).** The tenant comes from the bearer token, never from the host:
   `Letflow.Plugs.AuthPipeline` verifies the token, parses the realm from the `iss` claim (`/realms/<realm>`),
   then `Letflow.Identity.resolve_tenant_by_realm/1` maps realm to tenant
   (`tenants.idp_realm_id`), and `verify_realm_ownership/2` runs before any JIT provisioning.
   A request to any hostname with a token from realm X is served as tenant X. Consequence: the host
   name is irrelevant to data access, so there is no host-spoofing path (INV-1 is not affected).
2. **`GET /api/tenant-config` (login bootstrap, unauthenticated).** `Letflow.Routers.TenantConfig`:
   `?realm=<slug>` resolves slug to tenant and returns its `oidc_authority`, `client_id`, branding;
   `?host=<hostname>` is **accepted but ignored**: `resolve_realm(nil, _host)` always returns the default
   realm (`bpm-default`) and that tenant's branding. The moduledoc states it: "Letflow has no host->tenant
   binding of any kind", and assigns the owner of such a binding to REQ-076.
3. **`hostname` on the tenant.** `POST /api/v1/onboarding` takes `hostname` (unique). It is stored only in
   `onboarding_registry` (`Letflow.Identity.OnboardingRecord`, unique index) and read back only by
   `GET /api/v1/onboarding?hostname=` (`Identity.get_onboarding_by_hostname/1`, PLATFORM_ADMIN). Nothing
   in the request path reads it. There is no `tenant_hostnames` table, no host plug.
4. **Web SPA.** `web/src/auth/tenantConfig.ts` `fetchTenantConfig(hostname)` sends `{realm: slug}` when
   `?realm=` or `sessionStorage['bpm_realm_slug']` exists, else `{host: hostname}` (which the backend
   ignores, see 2). `buildRedirectArgs` (`oidcRedirectArgs.ts`) builds
   `redirect_uri = window.location.origin + '/auth/callback?realm=<slug>'`.
5. **Login directory (email-first, REQ-434).** Keyed by the e-mail address/domain, not the host; the SPA
   stores the discovered slug and continues as in 4. It is the only path today that reaches a non-default
   tenant without `?realm=` (flag and pepper in `docs/runbooks/login-directory-enablement.md`).

## Does `<slug>.letflow.qa.bizdala.com` work unchanged?

| Concern | State | Verdict |
|---|---|---|
| DNS / TLS / upstream | Done by infra (same upstream as `qa.bizdala.com`, 127.0.0.1:3201). The Letflow container does not look at `Host`. | OK |
| Tenant from `Host` | Not implemented (see 2, 3). `https://<slug>.letflow.qa.bizdala.com/` loads the SPA, calls `/api/tenant-config?host=...`, receives the default realm. | **Missing** |
| Authenticated API | Tenant from token issuer; host irrelevant. | OK once the user has a token from the tenant's realm |
| Cookies | None used. The SPA keeps the token in memory and sends `Authorization: Bearer`; `sessionStorage` is per origin, so each subdomain has its own. `Letflow.Plugs.Cors` documents "no credentials, ever". Nothing to configure. | OK |
| CORS | `Letflow.Plugs.Cors` allows only origins in `:cors_allowed_origins`, set in prod by `CORS_ALLOWED_ORIGINS` (`config/runtime.exs`), exact-match list, fail-closed `[]`, no wildcard. The SPA and API are same-origin when served from the same subdomain, so browsers do not need CORS for that. But if the SPA is served from `<slug>.letflow.qa.bizdala.com` and calls `qa.bizdala.com` (or the reverse), the origin must be in the list. Wildcard subdomains cannot be expressed; each tenant origin would have to be added and the QA env restarted. | Same-origin: OK. Cross-origin: **missing** |
| Keycloak redirect URIs | `priv/keycloak/realms/bpm-default.json` has `redirectUris: ["*"]`, `webOrigins: ["*"]`, but a tenant realm is created by infra's provisioner (D-016/D-018) from the template that does not exist yet. `docs/runbooks/onboarding-new-tenant-realm.md` step R1 says redirect URIs are set by hand per hostname. Needed: `https://<slug>.letflow.qa.bizdala.com/auth/callback*` (the SPA appends `?realm=<slug>`), post-logout URI, web origin `https://<slug>.letflow.qa.bizdala.com`. | **Missing** until the realm template (item 3 of the goal) carries them |
| "Allowed domain suffix" setting | **Does not exist.** `grep -rniE "domain_suffix|allowed_domain|hostname_suffix"` over `lib/ config/ web/src docs/runbooks` finds nothing relevant. Onboarding validates `hostname` only as a non-empty string up to 255 code points (`@codepoint_max`) and unique. The suffix guard in the portfolio contract has no Letflow counterpart yet. | **Missing** (new setting) |
| Outbound links (login-directory mail) | `LETFLOW_PUBLIC_BASE_URL` is a single base URL (`config/runtime.exs`), so a mail would link to `qa.bizdala.com`, not the tenant's subdomain. Only relevant if mail goes out for provisioned tenants. | Note |
| Trusted proxy / client IP | `Letflow.Plugs.ClientIp` is unrelated to `Host`. | OK |

## What is missing (exactly)

1. A host-to-tenant lookup so that `GET /api/tenant-config?host=<slug>.letflow.qa.bizdala.com` returns that
   tenant's realm, `client_id`, branding (today: always the default realm).
2. A storage place for it that the request path can read (the hostname lives only in `onboarding_registry`).
   Reusing `onboarding_registry.hostname` as the lookup source needs no migration; a separate table would
   (see the rejected-alternative note in `TenantConfig`'s moduledoc, REQ-078).
3. An allowed-suffix check for tenant hostnames (setting, default off or empty on non-QA), so the provisioner
   cannot bind a host outside `.letflow.qa.bizdala.com`.
4. Keycloak side (infra/realm template): redirect URIs, post-logout URI, web origin for the subdomain.
5. CORS origin entries only if the SPA is ever served from a different origin than the API.

INV-5 note for item 1: the lookup must keep answering the default config for an unknown host (no oracle on
which hostnames are bound), as `?realm=` does for an unknown slug.

## Proposed tasks (not done here)

1. `feat`: `?host=` resolution in `Letflow.Routers.TenantConfig` through `Identity.get_onboarding_by_hostname/1`
   (case-insensitive, trimmed, lower-cased), falling back to the default realm on miss or non-active tenant;
   cross-tenant and unknown-host negative tests; update the `TenantConfig` moduledoc (it says no binding exists).
2. `feat`: allowed hostname suffix setting (env, e.g. `LETFLOW_TENANT_HOSTNAME_SUFFIX`, empty = no check) enforced in
   `Routers.Onboarding` create; reason: QA-only provisioner (D-019), bound hostnames must stay inside the wildcard.
3. `docs`/template: the tenant realm template (goal item 3) carries the redirect URIs and web origin pattern above;
   update `onboarding-new-tenant-realm.md` step R1.
4. `ops` (infra, not Letflow code): add tenant origins to `CORS_ALLOWED_ORIGINS` only if cross-origin use appears.
5. Optional UAT: after 1 and 2 land, `uat_design` for a scenario that opens `https://<slug>.letflow.qa.bizdala.com/`
   and expects that tenant's login without `?realm=`.
