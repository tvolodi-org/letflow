defmodule Letflow.Routers.PlatformStatus do
  @moduledoc """
  Platform-operator status sub-router (T-1607), mounted at `/platform-status` by
  `Letflow.Plugs.ApiPipeline` (full path `/api/v1/platform-status/backup`).

  | Handler | Method/path                      | Domain fn                       | Auth             | Response |
  |---------|-----------------------------------|----------------------------------|------------------|----------|
  | backup  | `GET /platform-status/backup`     | `Letflow.BackupStatus.read/0`    | `:TenantsManage` | 200 `{"configured":bool,"jobs":[{job,state,ts,age_seconds}]}` |
  | admission | `GET /platform-status/admission` | `Letflow.Admission.Observability.counters_with_tenants/0` | `:TenantsManage` | 200 the admission counters (see below) |

  ## Scope rule: PLATFORM scope

  `:TenantsManage` is a platform-scope permission, reused exactly as
  `Letflow.Routers.PlatformMigrations` reuses it (see its moduledoc for the reasoning): honoured
  only for a `PLATFORM_ADMIN` of the configured platform tenant; everyone else, a tenant admin
  and a `PLATFORM_ADMIN` of another tenant included, gets the same fixed 403. No new permission
  atom. The route takes no tenant identifier and no path; the handler reads fixed file names
  from the configured directory, so there is no `:prefix` preamble. The catch-all is
  `authz_unmatched(:platform_prefix)`.

  ## The admission counters (T-3034)

  The QA evidence this route answers to is a set of 503s whose refusals could
  not be attributed: 25 of 26 recorded bodies were the GLOBAL admission gate
  refusing on a stable build while one smoke ran, so either the global slots
  were held or the cap was not what the deployment believed.

  The answer is the same counters the public `GET /health` carries (the budget
  that is actually applied, the units in use, the fair-share divisor, the
  refusals since the process started) PLUS the per-tenant in-flight rows: the
  top five tenants by in-flight admissions, each with its route CLASS (the
  route pattern, never the request path) and the age of its oldest admission.
  The tenant schema names are hashed (`Letflow.Admission.Observability`), so
  the rows are comparable with each other and with the refusal lines without
  naming a tenant.

  This route shows tenant data, which is exactly why it is platform-scope and
  why the tenant rows are NOT on the public `GET /health`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response

  authz_get "/backup", :TenantsManage do
    Response.ok(conn, Letflow.BackupStatus.read())
  end

  authz_get "/admission", :TenantsManage do
    Response.ok(conn, Letflow.Admission.Observability.counters_with_tenants())
  end

  authz_unmatched(:platform_prefix)
end
