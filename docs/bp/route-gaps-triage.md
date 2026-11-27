# Route gaps triage (D-170, T-2510)

The 27 routes `check_routes.py` listed without a declaration, each checked in the code. The declarations (with the plug
file:line, reason and owner) are in `docs/bp/public-routes.json`; this page is the summary.

| class | routes | protection (code) |
|---|---|---|
| (b) public by design | `GET /health`, `GET /ready` | `lib/letflow/router.ex:134,144`; no plug beyond Cors/metrics/error capture. /health answers status, build sha and the global admission counters (an aggregate figure of the node, no tenant identifier), /ready fixed part names. |
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
2. `GET /health` returns the git commit sha of the build (`router.ex:137`): low-grade information disclosure, accepted
   in the ISS-1043 comment. T-3034 added the global admission counters to the same answer: the budget that is
   applied, the units in use, the fair-share divisor and the refusals since the node started -- all aggregate
   figures of the node, with no tenant identifier and no route of any tenant's traffic (the per-tenant rows are
   platform-scope, on `GET /api/v1/platform-status/admission`).

## The 461 "not referenced" routes

Cause: a stale snapshot. The first `route-gaps.md` (T-2494) was generated before the area catalogs merged:
stock.json and assets.json (db32d4e12, 07:17), platform.json (2c9dfe611, 07:24), designer.json (feceb4c92, 07:33),
master.json (ccbd9ead6, 07:39). Measured with `python3 -B scripts/uat/check_routes.py --root <tree>`:
- current tree, main's unmodified script: 477 routes, 477 covered, 0 not;
- tree of 3bb4e3862 (the commit that added the tool), main's script: 181 not covered.

The verb-line versus handler-range matching is therefore not the cause. No script was changed in this task (a BP-map
task may change only docs/bp/ and test/uat/); the documented reference form is in the README. The two tools agree on the
current tree: `check_routes.py` 477 covered.

Finding for the operator (developer task): `check_catalog.py` reports `docs/bp/public-routes.json` as "not an area
catalog" (scripts/uat/check_catalog.py:295-300), also when the file is `[]` as on main. It should skip that file name
(the one-line fix: `and f.name != "public-routes.json"`).
