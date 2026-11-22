# QA tenant subdomains: how Letflow picks the tenant, and what `<slug>.qa.ai-letflow.com` needs (old `<slug>.letflow.qa.bizdala.com` stays valid)

Current-state note (D-158, T-2148): login-directory mail and exact redirects now follow the shared
guarded suffix policy; company CORS is decided PER HOST (T-2621: a host grants only its own origin and
the app's own fixed origins, and the guarded suffix list grants no CORS allowance); see
`tenant-provisioner-credential.md` and `onboarding-new-tenant-realm.md`. The dated study below retains
its historical gap analysis.

## Register or change the host of an existing tenant (T-2184)

Use the API instead of inserting into `public.onboarding_registry` by hand:

| Request | Body | Result |
|---|---|---|
| `PUT /api/v1/tenants/:slug/hostname` | `{"hostname":"company.qa.ai-letflow.com"}` | 200: `tenant_id`, `slug`, normalized `hostname`, `onboarding_id`, `changed` |
| `DELETE /api/v1/tenants/:slug/hostname` | None | 200: same keys, null hostname and onboarding id |

Both require a PLATFORM_ADMIN token of the configured **platform tenant**. A tenant's
TENANT_ADMIN or PLATFORM_ADMIN cannot call them, even for its own slug (403).
`Letflow.TenantHosts` writes the registry and both audit chains in one transaction;
the platform entry identifies the operator, and the tenant entry identifies only
the actor class `platform_operator`.

The hostname must be one label under a suffix configured in
`LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES`. The shared policy supports
`qa.ai-letflow.com`, `ai-letflow.com` and the existing bizdala suffixes; only
configured suffixes are enabled. An empty setting refuses every host. Wildcards,
extra labels, malformed names and reserved labels are refused (422 with a hostname
field error). Reserved labels: `auth`, `app`, `www`, `pwa`, `api`, `qa`, `staging`,
`mail`, `send`, `rsend`, `demo`, `admin`, `status`.

An unknown slug returns 404. An occupied hostname, a purged tenant, an
unprovisioned tenant or multiple legacy host rows return 409 (remove the legacy
rows with DELETE before setting one host). Audit failure returns a fixed 500 and
rolls back the write. After a 500 or a lost response, repeat PUT: it is idempotent,
and `changed: false` means the host was already stored. A repeated DELETE also
returns `changed: false`.

There is **one host per tenant**. PUT replaces it and keeps its onboarding id;
the previous hostname stops resolving. DELETE removes the onboarding id too, so
`/api/v1/onboarding/:id/...` returns 404 until a new registration creates a new id.
A purged tenant's host stays reserved and cannot be removed. Existing hand-written
rows remain valid; this release performs no backfill or rewrite.

For QA creation, use this order: `realm` → `users` → `POST /api/v1/tenants`
(including `idp_realm_id`) → `host <slug> <hostname>`. The `/admin/v1/tenants`
provisioner already stores its validated host on creation and now also refuses
legacy case/padding variants held by another tenant. A replay of a provisioner
create completes missing steps, including re-registering its host after DELETE. The full procedure, QA and production, is `docs/runbooks/production-tenant-onboarding.md`.

The infra helper is maintained outside this product. T-2184 supplies
`infra/qa-tenant-create.host-mode.patch` in its task artifacts, with a patched copy
and tests. Infra must apply that patch to `ai-dala-infra/scripts/qa-tenant-create.py`
before using these commands; it adds `host` and `unhost` modes, preserving the
helper's slug allowlist:

```bash
ssh ubuntu-16gb-nbg1-1 "sudo -n python3 - host qoimeks-qa qoimeks-qa.qa.ai-letflow.com" < scripts/qa-tenant-create.py
ssh ubuntu-16gb-nbg1-1 "sudo -n python3 - unhost qoimeks-qa" < scripts/qa-tenant-create.py
```

The helper obtains the platform `admin-user` token at the **public** issuer
`https://auth.qa.bizdala.com` using the host-only seeded-users file. Minting it at
`127.0.0.1:3204` yields the wrong issuer. Tokens and passwords are never printed.

Post-merge operator check (after auto-CD deploys this API to QA): apply the infra
patch, then register `qoimeks-qa`, `qoimeks-client1-qa` and `rehearsal-1` with their
actual DNS names. Register `gate-b6` with the same API directly; the helper's
existing allowlist deliberately excludes `gate-*`. Use the old
`<slug>.letflow.qa.bizdala.com` names while the new QA DNS is unavailable. For each:

```bash
curl --fail --silent 'https://qoimeks-qa.letflow.qa.bizdala.com/api/tenant-config?host=qoimeks-qa.letflow.qa.bizdala.com'
```

Verify `oidc_authority` ends in `/realms/<tenant realm>` rather than the default
realm. Also configure the exact Keycloak redirects for the chosen host per
`onboarding-new-tenant-realm.md`; no wildcard registration is added here.


Study for GH #3252 (REQ-572, portfolio D-019, QA only). The findings below were taken from the code on
`main` at the time of writing; symbols are cited, not line numbers.

> **Implemented after this study (T-1359, 2026-11-18):** `GET /api/tenant-config?host=` now resolves
> the hostname stored in `onboarding_registry` to its active tenant and returns that tenant's realm and
> allowlisted branding. Unknown, malformed, ambiguous or unservable hosts retain the default response.
> Production company URLs use `https://<company>.ai-letflow.com`, replacing the proposed
> `<slug>.letflow.bizdala.com` scheme. QA company URLs use `https://<slug>.qa.ai-letflow.com`; the old
> `<slug>.letflow.qa.bizdala.com` names stay valid as an alias. QA Keycloak remains
> `auth.qa.bizdala.com`. DNS and certificates for the new QA names are not yet configured (owner token
> O-016, infra). The rest of this document is the dated QA study, kept as history;
> its statements that host binding is missing are not current behavior. DNS, certificates and Keycloak
> redirect configuration remain infra/PM work.

## Short answer (historical study)

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
| CORS | `Letflow.Plugs.Cors` takes the allow decision PER HOST (T-2621): an origin is allowed when it is one of the app's own origins in `:cors_allowed_origins` (set in prod by `CORS_ALLOWED_ORIGINS`, `config/runtime.exs`; exact-match list, fail-closed `[]`, no wildcard) or when it IS the host the request is addressed to. So the SPA and API on the same subdomain need no list entry at all, and one company's origin is never allowed on another company's host or on the platform host. But if the SPA is served from `<slug>.letflow.qa.bizdala.com` and calls `qa.bizdala.com` (or the reverse), that origin is cross-origin and must be in the list — and a LISTED origin is allowed on EVERY host, so listing a company origin there is a deliberate cross-host exposure (it would then be allowed on the platform host and on every other company's host). List the app's own origins only; a company origin needs no entry, the per-host rule already allows it on its own host. Wildcard subdomains cannot be expressed; each such tenant origin would have to be added and the QA env restarted. | Same-origin: OK. Cross-origin: **missing** |
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
5. CORS origin entries only if the SPA is ever served from a different origin than the API — and then
   the app's own origins only: a LISTED origin is allowed on EVERY host, so listing a company origin
   is a deliberate cross-host exposure (it would be allowed on the platform host and on every other
   company's host). A company origin needs no entry at all: the per-host rule allows it on its own host.

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
4. `ops` (infra, not Letflow code): add origins to `CORS_ALLOWED_ORIGINS` only if cross-origin use
   appears — the app's own origins only. A LISTED origin is allowed on EVERY host, so adding a
   company origin is a deliberate cross-host exposure (it would then be allowed on the platform host
   and on every other company's host). A company origin needs no entry: the per-host rule allows it
   on its own host.
5. Optional UAT: after 1 and 2 land, `uat_design` for a scenario that opens `https://<slug>.letflow.qa.bizdala.com/`
   and expects that tenant's login without `?realm=`.
