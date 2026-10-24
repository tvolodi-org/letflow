# Frontend/API contract-gap inventory (REQ-116)

**Taken against Letflow commit `00bbdc6e3acda6e0abe6dfcb68ac7f675e984af9`** (branch
`feature/WF02-REQ116-20260822`, working tree otherwise clean — `git diff` touches
nothing under `lib/` or `web/src/`, see "Environment notes" below for the two
non-`lib/`/non-`web/src/` fixes that were needed to get an authenticated sweep at
all). This inventory goes stale as S4 (`REQ-071`..`REQ-085`) lands; re-run the sweep
before trusting it for a later commit.

**Authenticated as:** `operator-user` (`PROCESS_OPERATOR`) for the primary pass and
`admin-user` (`PLATFORM_ADMIN`) for admin-only surfaces, both seeded by
`priv/keycloak/realms/bpm-default.json`, realm `bpm-default`, via the Keycloak
resource-owner-password-credentials grant. Evidence the bearer token was actually
accepted (not a stale/cached assumption) — a request that used to 401 now returns a
real (non-auth) status once the token carries a valid `aud` claim and a tenant row
exists for the token's realm:

```
$ curl -sS -4 -i "http://localhost:4000/api/v1/definitions" -H "Authorization: Bearer $TOKEN"
HTTP/1.1 404 Not Found
content-type: application/problem+json; charset=utf-8
{"status":404,"type":"https://bpm.example.com/problems/not-found","title":"Not Found",...}
```

A 404 (route not matched) rather than 401 (`{"error":"unauthorized","detail":"invalid
or expired bearer token"}`) is exactly the signal that the AuthPipeline accepted the
token, resolved the tenant, and passed the request through to route matching — a
malformed/rejected/expired token would have short-circuited at `AuthPipeline` and
never reached the 404 branch at all. Decoded token payload (roles claim visible):

```json
{
  "iss": "http://localhost:8092/realms/bpm-default",
  "aud": "letflow-web",
  "sub": "faeefcc5-9f8d-45a8-91a5-33365ceb7f9a",
  "azp": "letflow-web",
  "realm_access": { "roles": ["PROCESS_OPERATOR"] },
  "roles": ["PROCESS_OPERATOR"],
  "preferred_username": "operator-user",
  "email": "operator@letflow.local"
}
```

## Environment notes — two blockers found and fixed live (not in `lib/`/`web/src/`, not committed to any tracked file)

REQ-116 is explicitly read-only against `lib/` and `web/src/`, and neither of these
touches either directory or any git-tracked file, so they leave no `git diff`. Recorded
here because they are themselves candidate findings for whoever owns Keycloak/dev-seed
setup (REQ-128 and friends), and because a future sweep needs to reproduce them:

1. **Seeded realm client has no audience mapper.** `priv/keycloak/realms/bpm-default.json`'s
   `letflow-web` client has no `oidc-audience-mapper`, so a token it issues carries no
   `aud` claim at all. `Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2` calls
   `Oidcc.Token.validate_jwt/3`, which rejects any token missing `aud` outright —
   `{:error, {:missing_claim, "aud", ...}}` — before `Letflow.Plugs.AuthPipeline` ever
   reaches tenant resolution. Every request 401s identically regardless of route,
   which is exactly the "authentication sweep collapses to one flat 401" failure mode
   REQ-116's own text warns about. Fixed **live, against the running container only**
   (not the tracked realm JSON) via the Keycloak Admin REST API — added an
   `oidc-audience-mapper` (`included.client.audience: letflow-web`) to the
   `letflow-web` client in the `bpm-default` realm. Confirmed by decoding a
   freshly-issued token before/after (missing `aud` → present `aud: "letflow-web"`).
   **This is a real gap worth its own requirement** (the seeded realm cannot
   authenticate against Letflow's own resource-server validation as shipped) — filed
   as a finding, not fixed at the source, since fixing `priv/keycloak/realms/bpm-default.json`
   is outside this requirement's read-only scope and REQ-128 already owns that file.

2. **No default tenant row exists in a fresh dev DB.** With `aud` fixed, every request
   still 401'd — `Letflow.Identity.resolve_tenant_by_realm("bpm-default")` returned
   `{:error, :not_found}` because no `tenants` row has `idp_realm_id = "bpm-default"`.
   There is no `priv/repo/seeds.exs` and no dev-bootstrap path that creates one; only
   test fixtures (`test/support/tenant_fixture.ex`) do this, and only for the test DB.
   Unblocked by calling the real, already-shipped `lib/` functions directly from a
   throwaway script (`scratch/bootstrap_tenant.exs`, not committed — `scratch/` is
   gitignored) — `Letflow.Identity.create_tenant/1` →
   `Letflow.TenantProvisioning.provision_tenant_schema/1` →
   `Letflow.TenantProvisioning.replay_migrations/1`, the same three calls
   `Letflow.Routers.Tenants`'s own `POST /tenants` handler makes. This is data, not a
   code or config change, and reproduces exactly what an operator would need to run
   once against any fresh dev database. **Also worth its own requirement** (a
   `mix letflow.seed` or documented bootstrap step for the default tenant) — filed as
   a finding, not built here, since `priv/repo/` migrations/seeds are `lib/`-adjacent
   and this requirement is read-only.

Neither fix is committed; both are reproducible from the steps above and evaporate the
moment the `letflow-keycloak-1`/`letflow-postgres-1` containers or the dev DB are
recreated.

## Route inventory

`grep -c "path:" web/src/router.tsx` = **26**: 24 content-route `path:` lines
(children array), plus the top-level `/auth/callback` route, plus the top-level `/`
layout route's own `path: '/'` — matching this file's own reconciliation note. All 26
have a row below. (The `index: true` dashboard route at `/` carries no `path:` key and
so is not one of the 26 — it renders the identical `TenantDashboardPage` component as
the `dashboard` row below and was exercised identically; noted, not double-counted.)

PROVENANCE (historical, not current decision authority):
| # | Route (`web/src/router.tsx`) | API call(s) issued | Expected shape (cite) | Actual response | Classification | Owning REQ |
|---|---|---|---|---|---|---|
| 1 | `/auth/callback` | none | — | — | **EXCLUDED** — `OidcCallbackPage` only completes the OIDC redirect (`oidc-client-ts` code exchange against Keycloak directly); it issues no Letflow API request. | — |
| 2 | `/` (layout route) | none | — | — | **EXCLUDED** — `AppShell`/`ProtectedRoute`/`AuthProvider` wrapper; issues no API request of its own (its `index` child renders `TenantDashboardPage`, covered by row 3). | — |
| 3 | `dashboard` (and index `/`) | `GET /api/v1/definitions?page_size=5`<br>`GET /api/v1/instances?status=ACTIVE&page_size=1`<br>`GET /api/v1/tasks?status=PENDING&page_size=1` | `CursorPage<ProcessDefinition>` / `CursorPage<ProcessInstance>` / `CursorPage<Task>` — `web/src/types/api.ts:14,71,103,135`; called from `web/src/pages/dashboard/TenantDashboardPage.tsx:26-38` | definitions: `404 {"status":404,"type":".../problems/not-found",...}`<br>instances: same 404 shape<br>tasks: `200 {"count":0,"items":[],"next_cursor":null}` | **Mixed** — tasks call: WORKS. definitions/instances calls: **NOT-YET-IMPLEMENTED** | tasks: n/a (works); definitions: `REQ-081`; instances: `REQ-080` |
| 4 | `definitions` | `GET /api/v1/definitions` | `CursorPage<ProcessDefinition>` — `web/src/api/definitions.ts:16-17`, `web/src/types/api.ts:14,71` | `404 {"status":404,"type":"https://bpm.example.com/problems/not-found","title":"Not Found","detail":"the requested resource was not found",...}` | **NOT-YET-IMPLEMENTED** — `lib/letflow/routers/definitions.ex` currently defines only `POST /:id/validate` (REQ-078); `handleList` is unbuilt. | `REQ-081` |
| 5 | `definitions/new` | none on load (local draft state only; would `POST /api/v1/definitions` on save — `web/src/api/definitions.ts:25-26`, `web/src/pages/definitions/DefinitionEditorPage.tsx:73-74` gate `isNew`) | `ProcessDefinition` — `web/src/types/api.ts:71` | not exercised (no GET on mount); the write path it would hit on save is the same unbuilt router (`handleCreate` is REQ-082 scope) | **NOT-YET-IMPLEMENTED** (write path, on save) | `REQ-082` |
| 6 | `definitions/:id` | `GET /api/v1/definitions/:id` | `ProcessDefinition` — `web/src/api/definitions.ts:19-20`, `web/src/types/api.ts:71` | `404` (same problem-document shape as row 4, id `00000000-0000-0000-0000-000000000001`) | **NOT-YET-IMPLEMENTED** — `handleGetById` unbuilt. | `REQ-081` |
| 7 | `instances` | `GET /api/v1/instances` | `CursorPage<ProcessInstance>` — `web/src/api/instances.ts:12-21`, `web/src/types/api.ts:14,103` | `404` (same problem-document shape) | **NOT-YET-IMPLEMENTED** — `lib/letflow/routers/instances.ex` currently defines only `POST /:id/rebind-pins`; list/get/start/cancel/history/timeline/reconstruct are all unbuilt. | `REQ-079` (write half) / `REQ-080` (read half, owns this route) |
| 8 | `instances/:id` | `GET /api/v1/instances/:id` | `ProcessInstance` — `web/src/api/instances.ts:23-24`, `web/src/types/api.ts:103` | `404` (same shape) | **NOT-YET-IMPLEMENTED** — `handleGetById` unbuilt. | `REQ-080` |
| 9 | `tasks` | `GET /api/v1/tasks/inbox` | `CursorPage<Task>` (post-`normalizeTask`) — `web/src/api/tasks.ts:57-60`, `web/src/types/api.ts:14,135` | `200 {"count":0,"items":[],"next_cursor":null}` | **WORKS** — `lib/letflow/routers/tasks.ex:122` (`GET /inbox`) exists and returns a page envelope the SPA can consume (`items`/`next_cursor` present; SPA does not read `count`, harmless extra field). | n/a |
| 10 | `admin/users` | `GET /api/v1/users` | `PagedResponse<User>` (`{items,total,page,page_size}`) — `web/src/api/identity.ts:14-16`, `web/src/types/api.ts:21-26,233-246` | `404` at `/api/v1/users`. The real, working route is `GET /api/v1/identity/users` (`lib/letflow/routers/identity.ex:116`, mounted at `/identity` by `lib/letflow/plugs/api_pipeline.ex:57`) → `200 {"items":[{"auth_source":"oidc","display_name":"Operator User","email":"operator@letflow.local","id":"bde3ae1a-...","inserted_at":"2026-08-22T14:19:42Z","status":"active","updated_at":"2026-08-22T14:19:42Z","username":"operator-user"},...],"next_cursor":null,"count":2}` | **SHAPE-MISMATCH** — two independent mismatches, both on the *working* route: (a) **path** — SPA calls `/api/v1/users`, the real mounted path is `/api/v1/identity/users`; `usersApi.list` in `web/src/api/identity.ts:16` never has and never will hit the real route as written. (b) **envelope + fields**, once pointed at the right path — actual body is a `CursorPage`-shaped envelope (`items`/`next_cursor`/`count`) not the `PagedResponse` (`items`/`total`/`page`/`page_size`) `web/src/types/api.ts:21-26` declares and `usersApi.list`'s return type promises; and each item is missing `roles: string[]` (required, non-optional at `web/src/types/api.ts:241`) entirely, and has `inserted_at`/`updated_at` where the `User` type (`web/src/types/api.ts:233-246`) requires `created_at`. | `REQ-073` (done — the route exists; the mismatch is the frontend pointing at the wrong prefix/shape, not missing backend work) |
| 11 | `admin/users/:id` | `GET /api/v1/users/:id` | `User` — `web/src/api/identity.ts:18-19`, `web/src/types/api.ts:233-246` | `404` at `/api/v1/users/00000000-0000-0000-0000-000000000001` (same problem-document shape); the real route is `GET /api/v1/identity/users/:id` (`lib/letflow/routers/identity.ex:122`) | **SHAPE-MISMATCH** — same path-prefix mismatch as row 10, same field mismatches apply to the single-item shape. | `REQ-073` |
| 12 | `admin/groups` | `GET /api/v1/admin/groups` | `PagedResponse<Group>` — `web/src/api/identity.ts:37-38`, `web/src/types/api.ts:21-26,248-256` | `404` at `/api/v1/admin/groups`. The real, working route is `GET /api/v1/identity/groups` (`lib/letflow/routers/identity.ex:146`) → `200 {"items":[],"total":0}` | **SHAPE-MISMATCH** — (a) **path**: SPA calls `/api/v1/admin/groups`, real path is `/api/v1/identity/groups` — neither the `/admin` prefix nor the mount point match. (b) even at the right path, the envelope (`{items,total}`) is missing `page`/`page_size` that `PagedResponse` (`web/src/types/api.ts:21-26`) requires. | `REQ-074` (done — route exists, wrong prefix expected) |
| 13 | `admin/tokens` | `GET /api/v1/auth/tokens` | `{ items: ApiToken[] }` — `web/src/api/identity.ts:92-93`, `web/src/types/api.ts:272-284` | `404 {"status":404,...}` — no router forwards `/auth` or `/tokens` at all (`lib/letflow/plugs/api_pipeline.ex:57-66` lists no such mount) | **NOT-YET-IMPLEMENTED** — `handleCreateToken`/`handleListTokens`/`handleRevokeToken` are explicitly REQ-076 scope (`docs/requirements.yaml` REQ-076, status `pending`), unbuilt in any router. | `REQ-076` |
| 14 | `admin/audit` | `GET /api/v1/audit` | `CursorPage<AuditEntry>` (via `RawAuditPage` mapper) — `web/src/api/audit.ts:37-73`, `web/src/types/api.ts:14` | `200 {"count":0,"items":[],"next_cursor":null}` | **WORKS** — `lib/letflow/routers/audit.ex:113` (`GET /`), mounted at `/audit`, matches the SPA's call path and the envelope `auditApi.list` expects (`items`/`next_cursor`). | n/a |
| 15 | `admin/health` | `GET /health/ready` (superseded — see ISS-0532 note below) | `AdminHealthSnapshot` (mapped from `ReadinessOkBody`/`ReadinessErrorBody`) — was `web/src/api/health.ts:19-92`, now removed | `404 {"status":404,...}` | **NOT-YET-IMPLEMENTED** — `lib/letflow/router.ex`'s own moduledoc states explicitly: "Readiness endpoint ... is deliberately not ported — it requires S6 observability subsystem probes that do not yet exist. Only the liveness endpoint (GET /health) is preserved." No REQ exists yet (S6 unexpanded in `docs/requirements.yaml`). **ISS-0532 (2026-09-08)**: this same 404 was, until then, also silently swallowed by `web/src/hooks/useApiConnectivity.ts`'s `healthReady()` into a permanent false "Platform is currently unavailable" site-wide banner (every authenticated page, all roles), since a 404 was indistinguishable from a real outage. Fixed by pointing `healthReady()` at the real `GET /health` liveness endpoint instead — the site-wide banner false-positive is resolved. `admin/health` (`HealthDashboardPage.tsx`, PLATFORM_ADMIN-only) no longer calls the non-existent readiness endpoint either; it now degrades to an honest liveness-only view (real `GET /health` status plus a plain "per-subsystem readiness not available yet" statement) rather than fabricating `database`/`scheduler` status from the 404, as it used to. True per-subsystem readiness display is still gated on S6 exactly as before — only the false-positive/fabricated-data symptoms are fixed, not the underlying gap. | S6 (unassigned REQ id — stage not yet expanded) |
| 16 | `admin/metrics` | `GET /metrics` (via `client.getText`, expects Prometheus text exposition format) | Prometheus text, parsed by `parsePrometheusText` — `web/src/api/metrics.ts:38-128` | `404` at plain `/metrics` (not mounted at top level at all — `lib/letflow/router.ex` only declares `/health`, `/api/tenant-config`, `/api/mobile/tenant-config`, and the `/api/v1` forward). The real, working route is `GET /api/v1/metrics` (`lib/letflow/routers/metrics.ex:113`) → `200 application/json` `{"definitions":{"active":0,"archived":0,"deprecated":0,"draft":0,"total":0},"generated_at":"2026-08-22T14:22:55.904000Z","instances":{...},"scope":"tenant","tasks":{...}}` | **SHAPE-MISMATCH** — two independent mismatches: (a) **path** — SPA calls `/metrics`, real path is `/api/v1/metrics`. (b) **format**, even at the right path — the backend returns a JSON tenant-scoped summary object (REQ-078, done, deliberate design per its own description), not the Prometheus text exposition format `metricsApi.prometheusText`/`parsePrometheusText` (`web/src/api/metrics.ts`) is built to parse; feeding the actual JSON body into `parsePrometheusText` would throw `PROM_PARSE_ERROR` (`web/src/api/metrics.ts:120`). This is not a partial gap — the two shapes are unrelated formats. | `REQ-078` (done — route exists by design, in a shape the frontend was never built to consume) |
| 17 | `admin/onboarding` | none on load (form only); would `POST /api/v1/onboarding` on submit — `web/src/api/onboarding.ts:92-130`, called from `web/src/pages/admin/onboarding/RegisterTenantPage.tsx:291` | `OnboardingCreateResponse` (`{onboarding_id}`) — `web/src/api/onboarding.ts:48-50` | not exercised on load; the submit path was probed directly: `POST /api/v1/onboarding` → `404 {"status":404,...}` | **NOT-YET-IMPLEMENTED** (write path, on submit) — `lib/letflow/routers/onboarding.ex` is a literal stub (`match _ do ... not_found` only, no other clause), moduledoc: "Routes added by REQ-076." | `REQ-076` |
| 18 | `admin/onboarding/new` | same as row 17 (identical component, same form) | same as row 17 | same as row 17 | **NOT-YET-IMPLEMENTED** | `REQ-076` |
| 19 | `admin/onboarding/:onboardingId/progress` | `GET /api/v1/onboarding/:onboardingId` | `OnboardingSagaResult` — `web/src/api/onboarding.ts:137-139` | `404 {"status":404,...}` at `/api/v1/onboarding/00000000-0000-0000-0000-000000000001` | **NOT-YET-IMPLEMENTED** — `handleGetOnboarding` is REQ-076 scope, unbuilt (stub router). | `REQ-076` |
| 20 | `admin/onboarding/:onboardingId/result` | `GET /api/v1/onboarding?hostname=<hostname>` (only when arriving without `location.state.sagaResult` — `web/src/pages/admin/onboarding/OnboardingResultPage.tsx:114`) | `OnboardingStatusCompleted` — `web/src/api/onboarding.ts:58-70,147-149` | `404 {"status":404,...}` at `/api/v1/onboarding?hostname=nonexistent.example.com` | **NOT-YET-IMPLEMENTED** — `handleGetOnboardingByHostname` is REQ-076 scope, unbuilt (stub router). | `REQ-076` |
| 21 | `admin/tenants` | `GET /api/v1/tenants` | `TenantListResponse` (`{items,total,limit,offset}`) — `web/src/api/tenants.ts:17-26` | `200 {"items":[{"display_name":"Default Tenant","id":"5e83cd3c-...","inserted_at":"2026-08-22T14:19:24Z","slug":"bpm-default","status":"active","updated_at":"2026-08-22T14:19:24Z"}],"next_cursor":null,"count":1}` | **SHAPE-MISMATCH** (route works, envelope/field drift) — the SPA's `Tenant` type (`web/src/api/tenants.ts:3-15`) requires `tenant_type`, `production_tenant_id`, `production_tenant_display_name`, `idp_realm_id`, `status: 'ACTIVE'\|'INACTIVE'` (uppercase); the actual item has none of `tenant_type`/`production_tenant_id`/`production_tenant_display_name`/`idp_realm_id`, and `status: "active"` (lowercase, from `Ecto.Enum`, `lib/letflow/identity/tenant.ex:66`). The list envelope is also `{items,next_cursor,count}` (`CursorPage`-shaped), not `{items,total,limit,offset}` (`TenantListResponse`) the frontend type declares. | `REQ-...` — the route itself is done (`lib/letflow/routers/tenants.ex`, forward confirmed in `api_pipeline.ex:58`); no REQ found in the S4 range whose description covers `tenant_type`/production-tenant fields, so this looks like a frontend type drift against an already-shipped shape rather than missing backend work — flagged for REVIEWER rather than guessed at. |
| 22 | `admin/tenants/:slug/edit` | `GET /api/v1/tenants/:slug` | `Tenant` (same type as row 21) | `200 {"display_name":"Default Tenant","id":"5e83cd3c-...","inserted_at":"2026-08-22T14:19:24Z","slug":"bpm-default","status":"active","updated_at":"2026-08-22T14:19:24Z"}` | **SHAPE-MISMATCH** — identical field/status-case drift to row 21, on the single-item shape. | (same as row 21) |
| 23 | `admin/services` | `GET /api/v1/admin/services` (PLATFORM_ADMIN) or `GET /api/v1/services` (other roles) — `web/src/api/services.ts:39-44`, branch in `web/src/pages/admin/services/ServicesPage.tsx:32-37` | `CursorPage<ServiceRecord>` — `web/src/api/services.ts:37-44`, `web/src/types/api.ts:14` | both `404` (`/api/v1/admin/services` and `/api/v1/services`, both probed) | **NOT-YET-IMPLEMENTED** — `lib/letflow/router.ex`'s own "Deferred routes" table lists `Letflow.Routers.Services` (from `services.zig`) as not yet mounted, owning stage S6. | S6 (unassigned REQ id — stage not yet expanded) |
| 24 | `admin/modules` | `GET /api/v1/admin/modules` | `CursorPage<ProcessModuleCatalogEntry>` — `web/src/api/modules.ts:43-45` | `404 {"status":404,...}` | **NOT-YET-IMPLEMENTED** — `lib/letflow/router.ex`'s "Deferred routes" table lists `Letflow.Routers.ProcessModules` (from `process_modules.zig`) as not yet mounted, owning stage S5. | S5 (unassigned REQ id — stage not yet expanded) |
| 25 | `dlq` | `GET /api/v1/dlq` | `CursorPage<DlqEntry>` — `web/src/api/dlq.ts:66-75`, `web/src/types/api.ts:14,306` | `404 {"status":404,...}` | **NOT-YET-IMPLEMENTED** — `lib/letflow/router.ex`'s "Deferred routes" table lists `Letflow.Routers.Dlq` (from `dlq.zig`) as not yet mounted, owning stage S6. | S6 (unassigned REQ id) |
| 26 | `webhooks` | `GET /api/v1/webhooks/subscriptions` | `{ items: WebhookSubscription[] }` — `web/src/api/dlq.ts:87-89`, `web/src/types/api.ts:333` | `404 {"status":404,...}` | **NOT-YET-IMPLEMENTED** — `lib/letflow/router.ex`'s "Deferred routes" table lists `Letflow.Routers.Webhooks` (from `webhooks.zig`) as not yet mounted, owning stage S6. | S6 (unassigned REQ id) |

## Summary

- **26/26** rows present, reconciled against `grep -c "path:" web/src/router.tsx` = 26
  (2 excluded as layout/callback routes issuing no API request, 24 content routes with
  a row each).
- **WORKS:** 2 of 24 content routes (`tasks` via `/inbox`, `admin/audit`) — the calls
  used exactly match a mounted, done route and a consumable envelope.
- **NOT-YET-IMPLEMENTED:** 14 of 24 (`definitions`, `definitions/new`, `definitions/:id`,
  `instances`, `instances/:id`, `admin/tokens`, `admin/health`, `admin/onboarding`,
  `admin/onboarding/new`, `admin/onboarding/:onboardingId/progress`,
  `admin/onboarding/:onboardingId/result`, `admin/services`, `admin/modules`, `dlq`,
  `webhooks` — note `dashboard` contributes two of its three calls to this count, so the
  distinct-route tally above double-counts `dashboard` across WORKS/NOT-YET-IMPLEMENTED;
  see row 3).
- **SHAPE-MISMATCH:** 6 of 24 (`admin/users`, `admin/users/:id`, `admin/groups`,
  `admin/metrics`, `admin/tenants`, `admin/tenants/:slug/edit`) — every one of these
  routes is backed by `done` REQ work; the gap is entirely in the frontend pointing at
  the wrong path, expecting the wrong envelope shape, or expecting a field the backend
  does not (yet, or ever, by design in `admin/metrics`'s case) send.
- Two environment-setup gaps were found and fixed live (not committed) to make an
  authenticated sweep possible at all — see "Environment notes" above; both are
  candidate requirements in their own right, reported here rather than fixed at the
  source.

## Definition view: `activation_state` (GH #2692, REQ-515)

The definition view gained three optional read-only fields: `activation_state` (`"ok"` or
`"needs_reactivation"`), `needs_reactivation_reason` and `needs_reactivation_at`. `status` is
unchanged (still `ACTIVE`). The SPA does not render them today; `POST /definitions/:id/reactivate`
is the in-place fix. No web or mobile code changed.
