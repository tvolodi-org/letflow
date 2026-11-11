defmodule Letflow.Routers.PlatformModuleRollouts do
  @moduledoc """
  RU-S6 (T-1594, decision 0055 fact 10): the platform fleet driver's HTTP surface, mounted at
  `/platform-module-rollouts` by `Letflow.Plugs.ApiPipeline`.

  | Method/path                                   | Domain fn            | Response                                   |
  |-----------------------------------------------|----------------------|--------------------------------------------|
  | `POST /platform-module-rollouts`              | `Fleet.start/2`      | 200 result; 404 unknown module; 422 field  |
  | `GET /platform-module-rollouts`               | `Fleet.list/1`       | 200 `%{rollouts, next_cursor}`             |
  | `GET /platform-module-rollouts/:id`           | `Fleet.status/1`     | 200 result; 404                            |
  | `POST /platform-module-rollouts/:id/resume`   | `Fleet.resume/2`     | 200 result; 404; 409 version superseded    |

  The list is keyset-paged like `GET /promotions/platform-events`: `page_size` (default 50, 1..200)
  and an opaque `cursor` (prefix `RO:`, valid for `Pagination.cursor_expiry_us/0`); the body keeps
  the key `rollouts` and adds `next_cursor` (null on the last page). A cursor carries a timestamp and
  a rollout id only.

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

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.ModuleUpgrade.Fleet

  authz_post "/", :ModuleRolloutsManage do
    handle_start(conn)
  end

  authz_get "/", :ModuleRolloutsManage do
    handle_list(conn)
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

  @cursor_prefix "RO:"

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, size} <- Pagination.validate_page_size(raw_size),
         {:ok, after_key} <- parse_cursor(Map.get(query, "cursor")) do
      %{items: items, next: next} = Fleet.list(%{page_size: size, after: after_key})

      Response.ok(conn, %{
        "rollouts" =>
          Enum.map(items, fn %{rollout: rollout, counts: counts} ->
            %{"rollout" => rollout_map(rollout), "counts" => counts}
          end),
        "next_cursor" => encode_next(next)
      })
    else
      {:error, :invalid_page_size} -> Response.bad_request(conn, "invalid page_size")
      {:error, :page_size_too_large} -> Response.bad_request(conn, "page_size out of range")
      {:error, :invalid_cursor} -> Response.bad_request(conn, "invalid cursor")
    end
  end

  defp encode_next(nil), do: nil

  # Raw payload "RO:<mint_us>:<started_at_us>:<id>".
  defp encode_next({started_at, id}) do
    started_us = started_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

    Pagination.encode_cursor(
      "#{@cursor_prefix}#{System.os_time(:microsecond)}:#{started_us}:#{id}"
    )
  end

  defp parse_cursor(nil), do: {:ok, nil}
  defp parse_cursor(""), do: {:ok, nil}

  defp parse_cursor(raw) when is_binary(raw) do
    with {:ok, %Pagination.Cursor{inner: inner}} <-
           Pagination.decode_cursor(raw, @cursor_prefix, byte_size(@cursor_prefix)),
         {:ok, [started_at, id]} <-
           Pagination.decode_seek_parts(inner, @cursor_prefix, [:skip, :datetime_us, :uuid]) do
      {:ok, {DateTime.to_naive(started_at), id}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor(_other), do: {:error, :invalid_cursor}

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
