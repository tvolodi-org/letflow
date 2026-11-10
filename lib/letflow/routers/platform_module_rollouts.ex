defmodule Letflow.Routers.PlatformModuleRollouts do
  @moduledoc """
  RU-S6 (T-1594, decision 0055 fact 10): the platform fleet driver's HTTP surface, mounted at
  `/platform-module-rollouts` by `Letflow.Plugs.ApiPipeline`.

  | Method/path                                   | Domain fn            | Response                                   |
  |-----------------------------------------------|----------------------|--------------------------------------------|
  | `POST /platform-module-rollouts`              | `Fleet.start/2`      | 200 result; 404 unknown module; 422 field  |
  | `GET /platform-module-rollouts`               | `Fleet.list/0`       | 200 `%{rollouts: [...]}`                   |
  | `GET /platform-module-rollouts/:id`           | `Fleet.status/1`     | 200 result; 404                            |
  | `POST /platform-module-rollouts/:id/resume`   | `Fleet.resume/2`     | 200 result; 404; 409 version superseded    |

  Every route needs `:ModuleRolloutsManage`, a PLATFORM-scope permission
  (`Letflow.Api.Authorization.permission_scope/1`): honoured only for a `PLATFORM_ADMIN` of the
  platform tenant; anyone else gets the fixed platform 403, also on an unmatched sub-path
  (`authz_unmatched(:platform_prefix)`). No handler names a tenant: the driver walks the tenant
  registry itself and reaches tenant data only through `Apply` with `prefix:`. `start` answers 200,
  not 201 (a repeat returns the same rollout, like `/platform-migrations`). The upgrade is never
  acknowledged on behalf of a tenant (no `ack_destructive`).

  The response carries ids, statuses and codes only: `rollout` (id, module_id, to_version, status,
  halt_after, consecutive_failures, started_at, completed_at, halted_at) and `outcomes` (tenant_id,
  status, error_code, plan_hash, attempted_at, completed_at). No tenant name, schema name or record
  data.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.ModuleUpgrade.Fleet

  authz_post "/", :ModuleRolloutsManage do
    handle_start(conn)
  end

  authz_get "/", :ModuleRolloutsManage do
    rollouts =
      Enum.map(Fleet.list(), fn %{rollout: rollout, counts: counts} ->
        %{"rollout" => rollout_map(rollout), "counts" => counts}
      end)

    Response.ok(conn, %{"rollouts" => rollouts})
  end

  authz_get "/:id", :ModuleRolloutsManage do
    case Fleet.status(conn.params["id"]) do
      {:ok, result} -> Response.ok(conn, result_map(result))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  authz_post "/:id/resume", :ModuleRolloutsManage do
    actor_id = conn.assigns.auth_context.user_id

    case Fleet.resume(conn.params["id"], actor_id) do
      {:ok, result} -> Response.ok(conn, result_map(result))
      {:error, :not_found} -> Response.not_found(conn)
      {:error, :version_superseded} -> Response.conflict(conn, "version_superseded")
    end
  end

  authz_unmatched(:platform_prefix)

  @start_schema [
    %FieldConstraint{
      name: "module_id",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    }
  ]

  defp handle_start(conn) do
    case Validation.validate(@start_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"module_id" => module_id}} ->
        case Fleet.start(module_id, conn.assigns.auth_context.user_id) do
          {:ok, result} -> Response.ok(conn, result_map(result))
          {:error, :unknown_module} -> Response.not_found(conn)
        end
    end
  end

  defp result_map(%{rollout: rollout, outcomes: outcomes}) do
    %{"rollout" => rollout_map(rollout), "outcomes" => Enum.map(outcomes, &outcome_map/1)}
  end

  defp rollout_map(r) do
    %{
      "id" => r.id,
      "module_id" => r.module_id,
      "to_version" => r.to_version,
      "status" => r.status,
      "halt_after" => r.halt_after,
      "consecutive_failures" => r.consecutive_failures,
      "started_at" => iso8601(r.started_at),
      "completed_at" => iso8601(r.completed_at),
      "halted_at" => iso8601(r.halted_at)
    }
  end

  defp outcome_map(o) do
    %{
      "tenant_id" => o.tenant_id,
      "status" => o.status,
      "error_code" => o.error_code,
      "plan_hash" => o.plan_hash,
      "attempted_at" => iso8601(o.attempted_at),
      "completed_at" => iso8601(o.completed_at)
    }
  end

  defp iso8601(nil), do: nil

  defp iso8601(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
