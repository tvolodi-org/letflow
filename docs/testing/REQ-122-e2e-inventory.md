# REQ-122 — Playwright E2E Spec Inventory

**Produced:** 2026-08-24  
**Branch:** main  
**Letflow routes at time of inventory:** `GET /health`, `GET /api/tenant-config`,
`GET /api/mobile/tenant-config`, `POST|GET|PATCH|DELETE /api/v1/{tenants,instances,
definitions,tasks,identity,onboarding,promotion,solution-packs,audit,metrics}`  
**Sources read:** all 37 `*.e2e.spec.ts` files, `helpers.ts`, `pipeline.ts`,
`lib/letflow/router.ex`, `lib/letflow/plugs/api_pipeline.ex`,
`lib/letflow/routers/*.ex`, `playwright.config.ts`, `vite.config.ts`

---

## Classification summary

| Category | Count |
|---|---|
| RUNNABLE-NOW | 1 |
| BLOCKED-ON-INFRA | 36 |
| BLOCKED-ON-S4 | 0 |
| **Total** | **37** |

The BLOCKED-ON-S4 column is zero because every spec that exercises an unimplemented
route also requires Keycloak authentication — the Keycloak gap is the binding blocker
for all of them. Unimplemented-route gaps are noted per-entry as secondary blockers.

---

## RUNNABLE-NOW set (1 spec)

### `sh05-06.shell.e2e.spec.ts`

**Tests (3):** TC-SH06-01, TC-SH06-02, TC-SH06-03 (SH-06 API Connectivity Banner)

**Backend routes exercised:** `GET /health/ready` — but all three tests stub this
endpoint with `page.route('**/health/ready', ...)`, so the real backend is never
reached.

**Auth:** Uses `makeFakeJwt()` (defined inline) — a base64-encoded JWT with
`alg: none` and a fabricated payload injected into `sessionStorage.__e2e_session`
via `loginWithToken`. Does NOT call `getKeycloakToken()`. No Keycloak token request
is ever issued.

**Why runnable:** All three tests control their own `/health/ready` response
entirely through Playwright's `page.route()` intercept. The SPA starts from the
Vite dev server (auto-launched by `playwright.config.ts`'s `webServer` directive)
and loads even when Letflow is not running — backend calls fail with ECONNREFUSED
from the Vite proxy but the connectivity-banner tests only assert on the
`[data-testid="connectivity-banner"]` element whose visibility is solely determined
by the stubbed `/health/ready` response.

**Infrastructure required to reproduce:**
- Node.js ≥ 18, `web/node_modules` installed (`npm ci`)
- Playwright Chromium (`npx playwright install chromium` + system deps via
  `npx playwright install-deps chromium`)
- No Letflow backend, no Keycloak, no database

**Actual run command:**
```
cd /home/tvolodi/workspace/letflow-1/web
npx playwright test tests/e2e/sh05-06.shell.e2e.spec.ts --reporter=list
```

**Actual output (verbatim):**
```
Running 3 tests using 1 worker

[WebServer] 2:43:03 AM [vite] http proxy error: /api/tenant-config?host=127.0.0.1
[WebServer] Error: connect ECONNREFUSED ::1:4000
[WebServer]     at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1549:16)
[WebServer] 2:43:03 AM [vite] http proxy error: /api/v1/definitions?page_size=5
[WebServer] Error: connect ECONNREFUSED ::1:4000
[WebServer]     at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1549:16)
[WebServer] 2:43:03 AM [vite] http proxy error: /api/v1/instances?status=ACTIVE&page_size=1
[WebServer] Error: connect ECONNREFUSED ::1:4000
[WebServer]     at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1549:16)
[WebServer] 2:43:03 AM [vite] http proxy error: /api/v1/tasks?status=PENDING&page_size=1
[WebServer] Error: connect ECONNREFUSED ::1:4000
[WebServer]     at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1549:16)
[WebServer] 2:43:03 AM [vite] http proxy error: /api/v1/dlq?status=pending&page_size=101
[WebServer] Error: connect ECONNREFUSED ::1:4000
[WebServer]     at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1549:16)
  ✓  1 [chromium] › tests/e2e/sh05-06.shell.e2e.spec.ts:60:3 › SH-06 — API Connectivity Banner › TC-SH06-01: /health/ready returns 200 → connectivity-banner NOT visible (2.0s)
[WebServer] 2:43:04 AM [vite] http proxy error: /api/tenant-config?host=127.0.0.1
[WebServer] Error: connect ECONNREFUSED ::1:4000
...
  ✓  2 [chromium] › tests/e2e/sh05-06.shell.e2e.spec.ts:85:3 › SH-06 — API Connectivity Banner › TC-SH06-02: /health/ready returns 503 → connectivity-banner visible (818ms)
...
  ✓  3 [chromium] › tests/e2e/sh05-06.shell.e2e.spec.ts:125:3 › SH-06 — API Connectivity Banner › TC-SH06-03: banner disappears when health recovers (re-mount after 200) (1.6s)

  3 passed (7.9s)
```

**Verdict: 3/3 PASSED.**  
The Vite proxy ECONNREFUSED lines are expected noise — Letflow is not running;
the tests do not depend on it and all pass regardless.

---

## BLOCKED-ON-INFRA specs (36 specs)

### Root cause shared by 35 of the 36

Every spec except `oidcf2-subdomain.e2e.spec.ts` calls either:

- `getKeycloakToken(request, username, password)` — defined in `helpers.ts`; issues
  a real HTTP `POST` to
  `BPM_IDP_BASE_URL/realms/bpm-default/protocol/openid-connect/token`
  (password-grant), and throws if the response is not 2xx, or
- inline equivalents in `f4-task-inbox.e2e.spec.ts`, `f5-admin-groups-tokens.e2e.spec.ts`,
  `f5-admin-observability.e2e.spec.ts`, `f5-admin-users.e2e.spec.ts`,
  `f6-webhooks.e2e.spec.ts`, `tenants.e2e.spec.ts`, and the pipeline specs — all of
  which POST to the same Keycloak token endpoint.

Without a running Keycloak instance at `BPM_IDP_BASE_URL` (default
`http://localhost:8082`) with the `bpm-default` realm, the token request fails
immediately and every test in those 35 files is aborted before the first
`page.goto()`.

**Note on `obs04.timeline.e2e.spec.ts`** (included in the 35 despite using
`makeFakeJwt()`): obs04 does not call `getKeycloakToken()` and mocks all
`/api/v1/**` routes with `page.route()`. However, when run against the live SPA,
`loginWithToken(page, fakeJwt)` injects the fake token into
`sessionStorage.__e2e_session` but the SPA's OIDC client (`oidc-client-ts`) also
checks its own `oidc.user:...` storage key — which is empty. `ProtectedRoute`
redirects to Keycloak; obs04 does NOT mock the Keycloak auth redirect, only the
API calls. Measured result: `loginWithToken` silently times out (`.catch(() => {})`
suppresses the selector error), then the test fails because the `Instances` heading
is never rendered. Actual Playwright output:

```
Running 1 test using 1 worker

[WebServer] Error: connect ECONNREFUSED ::1:4000   (api/tenant-config, health/ready)

  ✘  1 [chromium] › tests/e2e/obs04.timeline.e2e.spec.ts:118:3 › OBS-04 timeline browser flow › opens an instance and renders the timeline tab state (6.7s)

    Error: expect(locator).toBeVisible() failed
    Locator: getByRole('heading', { name: 'Instances' })
    Expected: visible
    Timeout: 5000ms
    Error: element(s) not found

  1 failed
```

obs04 is therefore BLOCKED-ON-INFRA: requires Keycloak (OIDC redirect not mocked)
plus a running Letflow instance (so `/api/tenant-config` responds and the SPA can
complete its auth handshake).

---

### Per-spec entries

**Legend:**
- *Auth evidence* — the line(s) in the spec file that prove Keycloak is required
- *Routes exercised* — `/api/v1/...` paths referenced (✓ = Letflow serves it today,
  ✗ = not yet mounted)
- *Additional blockers* — beyond Keycloak (missing routes / missing /health/ready)

---

#### 1. `a11y-gate.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm, user `worker-user`/`worker-pass`  
**Auth evidence:** `const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')`  
**Routes exercised:** Multiple SPA pages (definitions, instances, tasks, admin) —
the spec drives the SPA to each route and runs axe; the specific API calls depend on
what the SPA loads on each page.  
All pages behind `/api/v1/**` — auth pipeline blocks without token.

---

#### 2. `admin/services.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready` (not
implemented — Letflow deliberatey omits the readiness endpoint); additionally
`GET /api/v1/admin/services` (no `/admin` forward in `ApiPipeline`) and
`GET /api/v1/services` (`Letflow.Routers.Services` deferred to S6, no assigned
REQ-id yet)  
**Auth evidence:** `getKeycloakToken, loginWithToken` imports + `assertServicesReady`
calls `/health/ready`

---

#### 3. `env04.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm + Keycloak admin API (creates realm,
users); multi-realm setup (`bpm-default` + a dynamically-created test realm)  
**Auth evidence:** `getKeycloakToken(request, ...)` at top; spec comment: "Keycloak:
BPM_IDP_BASE_URL (default: http://localhost:8082)"  
**Routes exercised:** `POST /api/v1/definitions` ✓, `GET /api/v1/definitions` ✓,
`POST /api/v1/definitions/:id/activate` ✓, `DELETE /api/v1/definitions/:id` ✓,
`GET /api/v1/tenants` ✓, `GET /api/v1/tenants/current` ✓,
`POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓  
**Additional blockers:** Keycloak master realm admin API (to seed test realm and
users); the spec directly POSTs to
`BPM_IDP_BASE_URL/admin/realms/:slug/users/:id/reset-password`

---

#### 4. `f2-canvas.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `authToken = await getKeycloakToken(request)`  
**Routes exercised:** `POST /api/v1/definitions` ✓, `POST /api/v1/definitions/:id/activate` ✓,
`POST /api/v1/instances` ✓, `GET /api/v1/instances` ✓, `DELETE /api/v1/definitions/:id` ✓

---

#### 5. `f2-canvas-shoulds.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `authToken = await getKeycloakToken(request)`  
**Routes exercised:** Same as `f2-canvas.e2e.spec.ts`

---

#### 6. `f2-definition-list.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `getKeycloakToken, loginWithToken` imported from helpers  
**Routes exercised:** `GET /api/v1/definitions` ✓, `POST /api/v1/definitions` ✓,
`POST /api/v1/definitions/:id/activate` ✓, `DELETE /api/v1/definitions/:id` ✓

---

#### 7. `f3-instance-monitoring.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `getKeycloakToken, loginWithToken` imported from helpers  
**Routes exercised:** `POST /api/v1/definitions` ✓, `POST /api/v1/definitions/:id/activate` ✓,
`POST /api/v1/instances` ✓, `GET /api/v1/instances` ✓, `GET /api/v1/instances/:id` ✓

---

#### 8. `f4-task-inbox.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** inline `getKeycloakToken` posts to
`${BPM_IDP_BASE_URL}/realms/bpm-default/protocol/openid-connect/token` (same
endpoint as helpers.ts)  
**Routes exercised:** `GET /api/v1/tasks/inbox` ✓, `POST /api/v1/definitions` ✓,
`POST /api/v1/definitions/:id/activate` ✓, `POST /api/v1/instances` ✓

---

#### 9. `f5-admin-groups-tokens.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready` (not
implemented); additionally `GET/POST /api/v1/admin/groups` and
`GET/DELETE /api/v1/auth/tokens` — neither `/admin` nor `/auth` is forwarded by
`ApiPipeline` (contract gap; identity.ex serves these at `/api/v1/identity/groups`
and `/api/v1/identity/tokens`)  
**Auth evidence:** inline token endpoint POST to KEYCLOAK_TOKEN_URL;
`assertServicesReady` calls `/health/ready`

---

#### 10. `f5-admin-observability.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready`
(not implemented); additionally Keycloak discovery endpoint
(`BPM_IDP_BASE_URL/realms/bpm-default/.well-known/openid-configuration`)  
**Auth evidence:** inline token endpoint POST; `assertServicesReady` calls
`/health/ready` and Keycloak discovery URL

---

#### 11. `f5-admin-users.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally Keycloak discovery endpoint;
additionally `GET/POST /api/v1/admin/users` and `POST /api/v1/admin/users/:id/status`
(no `/admin` forward in ApiPipeline — these are served at `/api/v1/identity/users`)  
**Auth evidence:** inline token endpoint POST; Keycloak discovery URL referenced

---

#### 12. `f6-dlq.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /api/v1/dlq` —
`Letflow.Routers.Dlq` is deferred to S6 (no REQ id assigned yet per
`router.ex` deferred-routes table)  
**Auth evidence:** `getKeycloakToken, loginWithToken, BPM_IDP_BASE_URL` imported
from helpers

---

#### 13. `f6-webhooks.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /api/v1/webhooks` and
related webhook CRUD — `Letflow.Routers.Webhooks` deferred to S6 (no REQ id
assigned yet)  
**Auth evidence:** inline token endpoint POST; Keycloak discovery URL referenced

---

#### 14. `grd-ui-07.field-aria.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm, users `admin-user`/`worker-user`  
**Auth evidence:** `const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')`
and `getKeycloakToken(request, 'admin-user', 'admin-pass')`  
**Routes exercised:** `POST /api/v1/definitions` ✓, `POST /api/v1/definitions/:id/activate` ✓,
`POST /api/v1/instances` ✓, `GET /api/v1/tasks/inbox` ✓

---

#### 15. `iss-0063-oidc-redirect-loop.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready`
(not implemented)  
**Auth evidence:** `BPM_IDP_BASE_URL` used for both `/health/ready` pre-check and
Keycloak discovery URL; spec comment: "Ensure Keycloak is running"

---

#### 16. `obs04.timeline.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak OIDC (the SPA's `ProtectedRoute` redirects to Keycloak when
`oidc-client-ts` finds no OIDC session, even though `__e2e_session` is present in
sessionStorage); additionally Letflow backend for `/api/tenant-config` on SPA
startup  
**Auth evidence:** uses `makeFakeJwt()` (no real Keycloak token) BUT the SPA still
redirects because obs04 mocks `/api/v1/**` API calls but does NOT mock the Keycloak
auth redirect — `ProtectedRoute` fires before the API mocks are relevant  
**Measured failure:** `toBeVisible()` on `Instances` heading times out; confirmed by
running the spec; see output quoted in the "Root cause" section above

---

#### 17. `oidcf2-subdomain.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Letflow backend must be running at `:4000` (for TC-OIDCF2-01 and
TC-OIDCF2-02 which call `GET /api/tenant-config`); no Keycloak needed  
**Note:** TC-OIDCF2-03 and TC-OIDCF2-04 DO pass without Letflow (both stub or abort
the Keycloak redirect; neither calls a real backend route). TC-OIDCF2-01 and
TC-OIDCF2-02 call `request.get('/api/tenant-config?host=...')` directly — the Vite
proxy forwards to `:4000`; with Letflow not running the proxy returns 500 ("connect
ECONNREFUSED").  
**Measured result:** 2 failed (TC01, TC02: `Expected: 200 / Received: 500`),
2 passed (TC03, TC04).  
**Routes exercised:** `GET /api/tenant-config` ✓ (when Letflow is running)  
**Infrastructure to run fully:** Letflow backend at `:4000` with a running Postgres
database and the default tenant seeded; no Keycloak required

---

#### 18. `oidcf-login.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `assertKeycloakReady()` GETs Keycloak discovery URL; spec comment:
"Default Keycloak realm: http://localhost:8082/realms/bpm-default"

---

#### 19. `onboarding/onb-ui-01.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready` (not
implemented); additionally Keycloak admin API for realm setup  
**Auth evidence:** `getKeycloakToken` imported; `assertServicesReady` calls
`/health/ready` and `KEYCLOAK_DISCOVERY` URL; spec comment: "No mocks. Real
Keycloak tokens via getKeycloakToken()"  
**Routes exercised:** `POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓

---

#### 20. `onboarding/onb-ui-02.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Same as onb-ui-01  
**Auth evidence:** same `assertServicesReady` + `getKeycloakToken` pattern  
**Routes exercised:** `POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓

---

#### 21. `onboarding/onb-ui-03.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Same as onb-ui-01  
**Routes exercised:** `POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓

---

#### 22. `onboarding/onb-ui-04.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Same as onb-ui-01  
**Routes exercised:** `POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓

---

#### 23. `pdui07-export-import.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `getKeycloakToken, loginWithToken` imported  
**Routes exercised:** `GET /api/v1/definitions` ✓, `GET /api/v1/definitions/:id/export` ✓,
`POST /api/v1/definitions/import` ✓

---

#### 24. `pdui08-debounced-search.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `getKeycloakToken, loginWithToken` imported  
**Routes exercised:** `GET /api/v1/definitions` ✓, `GET /api/v1/definitions/search` ✓,
`POST /api/v1/definitions` ✓

---

#### 25. `pipelines/admin-user-lifecycle.pipeline.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready`
(not implemented); additionally `GET/POST /api/v1/admin/users` (no `/admin` forward)  
**Auth evidence:** `getKeycloakToken` imported; `assertServicesReady`-equivalent
calls `/health/ready`

---

#### 26. `pipelines/onboarding-wizard.pipeline.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm + Keycloak admin API; additionally
`GET /health/ready` (not implemented)  
**Auth evidence:** `getKeycloakToken` imported; `/health/ready` pre-check  
**Routes exercised:** `POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓

---

#### 27. `pipelines/sim-admin-processes.pipeline.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready`  
**Auth evidence:** `getKeycloakToken` imported; `/health/ready` pre-check  
**Routes exercised:** `POST /api/v1/definitions` ✓, `POST /api/v1/definitions/:id/activate` ✓,
`POST /api/v1/instances` ✓, `GET /api/v1/instances` ✓

---

#### 28. `pipelines/sim-company-onboarding.pipeline.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm + Keycloak admin API; additionally
`GET /health/ready`  
**Auth evidence:** `getKeycloakToken` imported; `/health/ready` pre-check  
**Routes exercised:** `POST /api/v1/onboarding` ✓, `GET /api/v1/onboarding/:id` ✓

---

#### 29. `rnd-ui-05.rate-limit-backpressure.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally
`Letflow.Plugs.RateLimit` is deferred to S4 in `api_pipeline.ex` (no REQ id
assigned), so burst-until-429 tests will never see a 429 response  
**Auth evidence:** `const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')`  
**Routes exercised:** `GET /api/v1/tasks/inbox` ✓ (route exists but no rate limiting applied)

---

#### 30. `rnd-ui-06.conflict-resolver.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm, users `worker-user`/`worker-user-2`  
**Auth evidence:** `tokenA = await getKeycloakToken(request, 'worker-user', 'worker-pass')`
and `tokenB = await getKeycloakToken(request, 'worker-user-2', 'worker-pass-2')`  
**Routes exercised:** `POST /api/v1/definitions` ✓, `PATCH /api/v1/definitions/:id` ✓

---

#### 31. `sh01-04.shell.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm  
**Auth evidence:** `const token = await getKeycloakToken(request, username, password)`  
**Routes exercised:** SPA shell navigation; OIDC login flow with Keycloak

---

#### 32. `tenant-dashboard.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally Letflow running (the spec
comment states "Tenant display_name is fetched via real GET /api/v1/tenants/:slug")  
**Auth evidence:** `getKeycloakToken` imported; spec comment: "Keycloak:
http://localhost:8082 (env BPM_IDP_BASE_URL)"  
**Routes exercised:** `GET /api/v1/tenants/:slug` ✓

---

#### 33. `tenants.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; additionally `GET /health/ready`
(not implemented); additionally `POST /api/v1/admin/tenants` — no `/admin` forward
in ApiPipeline (tenant creation is served at `POST /api/v1/tenants` by
`Letflow.Routers.Tenants`)  
**Auth evidence:** `getKeycloakToken` imported; `assertServicesReady` checks
`/health/ready` + KEYCLOAK_DISCOVERY_URL

---

#### 34. `uat-alice-login.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak multi-realm setup: `bpm-default` realm (default) AND a
`swiftroute` realm; user `alice.bauer`/`Alice-pass-001` must exist in `swiftroute`  
**Auth evidence:** `aliceToken = await getKeycloakToken(request, 'alice.bauer', 'Alice-pass-001', 'swiftroute')`
(fourth param is realm override, used in `pipeline.ts`'s `getKeycloakToken`)

---

#### 35. `uat-eo-003-004-v5.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm; spec references `BPM_IDP_BASE_URL` and
`IDP_URL` for OIDC flow  
**Auth evidence:** `import { BPM_IDP_BASE_URL } from './helpers'`; `const IDP_URL = BPM_IDP_BASE_URL`

---

#### 36. `uat-tenant-url.e2e.spec.ts`
**Status:** BLOCKED-ON-INFRA  
**Blocker:** Keycloak `bpm-default` realm AND a second tenant-specific Keycloak realm;
additionally `GET /health/ready` (not implemented) for both backend and IDP  
**Auth evidence:** `getKeycloakToken` imported; checks both
`${apiBaseUrl}/health/ready` and `${idpBaseUrl}/health/ready`

---

> **Superseded (GH #2486):** the current local run recipe is `docs/runbooks/local-e2e.md`. The steps below are historical;
> the Letflow dev backend port is `:4000` and the specs now default `BPM_TEST_URL` to it.

## What "BLOCKED-ON-INFRA" requires, concretely

To re-run the 35 Keycloak-blocked specs, you need:

1. **Letflow backend** at `:4000` — `LETFLOW_DEV_DB_CONFIRMED=1 mix run --no-halt`
   (PostgreSQL accessible at the configured URL)
2. **Keycloak** at `http://localhost:8082` — `docker compose up -d keycloak`
   (or equivalent); realm `bpm-default` must exist with:
   - Users: `admin-user`/`admin-pass`, `worker-user`/`worker-pass`,
     `worker-user-2`/`worker-pass-2`; these need appropriate roles
   - For `uat-alice-login.e2e.spec.ts`: additionally a `swiftroute` realm with
     user `alice.bauer`/`Alice-pass-001`
   - For `env04.e2e.spec.ts` and onboarding pipeline specs: Keycloak admin API
     access (master realm admin credentials) to create/delete realms dynamically
3. **Seeded Letflow tenants** — at minimum one active tenant whose slug matches
   `BPM_IDP_CLIENT_ID`'s configured realm; `env04` and onboarding specs seed their
   own via `POST /api/v1/onboarding` or `POST /api/v1/admin/tenants`
4. **SPA dev server** — Playwright's `webServer` directive starts it automatically
   via `npm run dev -- --host 127.0.0.1 --port 4173`

To re-run `oidcf2-subdomain.e2e.spec.ts` fully (all 4 tests):
- Items 1 and 4 above; no Keycloak needed

To re-run `sh05-06.shell.e2e.spec.ts` (already confirmed RUNNABLE-NOW):
- Item 4 only (Playwright starts the SPA); no Letflow, no Keycloak, no database

---

## `git diff` confirmation — no spec files modified

```
$ git diff -- web/tests/e2e/
(no output — clean)
```

This inventory file was written to `docs/testing/` (outside `web/tests/e2e/`).
No spec file under `web/tests/e2e/` was created, modified, or deleted.
