defmodule Letflow.Routers.PlatformStatus do
  @moduledoc """
  Platform-operator status sub-router (T-1607), mounted at `/platform-status` by
  `Letflow.Plugs.ApiPipeline` (full path `/api/v1/platform-status/backup`).

  | Handler | Method/path                      | Domain fn                       | Auth             | Response |
  |---------|-----------------------------------|----------------------------------|------------------|----------|
  | backup  | `GET /platform-status/backup`     | `Letflow.BackupStatus.read/0`    | `:TenantsManage` | 200 `{"configured":bool,"jobs":[{job,state,ts,age_seconds}]}` |

  ## Scope rule: PLATFORM scope

  `:TenantsManage` is a platform-scope permission, reused exactly as
  `Letflow.Routers.PlatformMigrations` reuses it (see its moduledoc for the reasoning): honoured
  only for a `PLATFORM_ADMIN` of the configured platform tenant; everyone else, a tenant admin
  and a `PLATFORM_ADMIN` of another tenant included, gets the same fixed 403. No new permission
  atom. The route takes no tenant identifier and no path; the handler reads fixed file names
  from the configured directory, so there is no `:prefix` preamble. The catch-all is
  `authz_unmatched(:platform_prefix)`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response

  authz_get "/backup", :TenantsManage do
    Response.ok(conn, Letflow.BackupStatus.read())
  end

  authz_unmatched(:platform_prefix)
end
