# Route gaps triage (D-170, T-2510)

The 27 routes `check_routes.py` listed without a declaration, each checked in the code. The declarations (with the plug
file:line, reason and owner) are in `docs/bp/public-routes.json`; this page is the summary.

| class | routes | protection (code) |
|---|---|---|
| (b) public by design | `GET /health`, `GET /ready` | `lib/letflow/router.ex:123,129`; no plug beyond Cors/metrics/error capture. /health answers status and build sha, /ready fixed part names. |
| (b) public by design | `GET /metrics` | `routers/metrics_exposition.ex`, decision REQ-194: unauthenticated, no tenant label on any metric. |
| (a) plug-authenticated, `shared-secret` | 6 x `/admin/v1/tenants*` | `routers/admin_v1.ex:46-47` ProvisionerAuth + class gate (`plugs/provisioner_auth.ex`): hashed bearer, write/read class, rate limit, 404 when unconfigured. |
| (a) plug-authenticated, `shared-secret` | `GET /maintenance/v1/problem-reports`, `/error-groups` | `routers/maintenance_v1.ex:30` ReportExportAuth (`plugs/report_export_auth.ex`). |
| (a) plug-authenticated, `shared-secret` | `POST /maintenance/v1/owner-list/import` | `routers/maintenance_owner_list_v1.ex:28` ReportExportAuth with the owner-list credential. |
| (a) plug-authenticated, `shared-access` | 7 x `/qoimeks/:tenant_slug/*` | `routers/shared_stock_access.ex:79-81`: failure limiter, tenant-bound bearer proof, per-credential limit, 403 while scope enforcement is on. |
| (b) public by design | `POST /api/login-discovery` | enabled gate, ClientIp, LoginDiscoveryRateLimit (`routers/login_discovery.ex:60-62`). |
| (b) public by design | 3 x `/api/signup*` | enabled gate (off by default), caps, captcha, verification link (`routers/signup.ex:36-37`, `Letflow.Signup`). |
| (b) public by design | `GET /api/public/:kind/:handle` | PublicReadRateLimit (`routers/public_read.ex:55`); unguessable handle names the tenant. |
| (b) public by design | `GET /api/tenant-config`, `/logo`, `GET /api/mobile/tenant-config` | AuthAttemptLimit `:requests`; neutral answer for unknown host or slug. |

## (c) Real gaps

None: every route is protected as its moduledoc and decision say. Advisories for the PM (no fix here, no exploit
found):

1. `GET /metrics` is unauthenticated by decision (REQ-194). Exposure: platform-wide aggregate counters to anyone who
   can reach the host. `grep -rn metrics deploy/` finds no proxy rule restricting it. Whether to restrict it to the
   monitoring network is the platform operator's call.
2. `GET /health` returns the git commit sha of the build (`router.ex:124`): low-grade information disclosure, accepted
   in the ISS-1043 comment.

## The 461 "not referenced" routes

Cause: `check_routes.py` built route items from the verb line only (`end == line`), while `bp_inventory.py` items span
the whole handler (`end`). A process task whose `code_refs` cites a line inside the handler counted for
`check_catalog.py` but not for `check_routes.py`. Fix (this task, a small code change): `all_routes` takes `end` from
the inventory item. After it, `check_routes.py`: 477 routes, 477 covered; `check_catalog.py`: every area 100%, PASS.
(`check_catalog.py` also stopped reporting `public-routes.json` as "not an area catalog".)
