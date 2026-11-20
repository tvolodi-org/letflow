defmodule Letflow.Modules.Maintenance.Router do
  @moduledoc """
  REQ-894 / GH #4806 (CMMS slice 1 part 2): the work request routes of module `maintenance`, mounted
  by `Letflow.Routers.Modules` at `/api/v1/modules/maintenance`. A thin layer over
  `Letflow.Modules.Maintenance.Requests`.

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /requests` (body `asset_card_id`, `description`, `urgency`, `idempotency_key`) | `MaintenanceRequestCreate` | `Requests.create/3` | 201 request view |
  | `GET /requests` (`status`, `limit`, `cursor`) | `MaintenanceRead` | `Requests.list/2` | 200 `rows, next_cursor` |
  | `GET /requests/:id` | `MaintenanceRead` | `Requests.get/2` | 200 request view |
  | `POST /requests/:id/reject` (body `reason`) | `MaintenanceOrderManage` | `Requests.reject/4` | 200 request view |
  | `POST /requests/:id/photos` (multipart, REQ-895) | `MaintenanceRequestCreate` | `Photos.upload/1` | 201 photo |
  | `GET /requests/:id/photos` (REQ-895) | `MaintenanceRead` | `Photos.list/1` | 200 `photos` |
  | `GET /requests/:id/photos/:photo_id/original`, `.../thumbnail` (REQ-895) | `MaintenanceRead` | `Photos.content/2` | 200 stored bytes |

  Guards, in this order: the release flag (`Letflow.Modules.Maintenance.enabled?/0`; off answers the
  404 of an unknown path on every route, also for a tenant that installed the module while the flag
  was on), the `authz_*` permission check (403 for a role that does not hold the atom), then
  `Letflow.Modules.Maintenance.Access.check/2`: only an interactive, tenant-wide holder passes. Any
  other caller (an API token, an org-scoped grant) gets the 404 of an unknown request on a read by
  id or a write and an empty list on `GET /requests` (fail closed; org-scoped access is a later
  slice). The tenant is `conn.assigns.scoped_opts` through the guard and the actor the token's user
  (INV-1, INV-10): no route takes either from the path or body.

  Refusals: not found (malformed, unknown and other tenant's ids, one body) 404; 409
  `request_not_new` and `idempotency_key_reuse`; 422 with a fixed `reason` (`asset_card_not_found`,
  `asset_card_inactive`, `asset_card_no_org_unit`, `description_required`, `description_too_long`,
  `invalid_urgency`, `reason_required`, `invalid_filter`, `field_not_allowed`, `field_invalid`);
  `audit_failed` is 500. The photo routes' own refusals are in `Letflow.Modules.Maintenance.Photos`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Modules.Maintenance
  alias Letflow.Modules.Maintenance.Access
  alias Letflow.Modules.Maintenance.Photos
  alias Letflow.Modules.Maintenance.Requests
  alias Letflow.Modules.RouterKit

  @not_found [:not_found]

  authz_post "/requests", :MaintenanceRequestCreate do
    guarded(conn, :create, fn conn, access ->
      case RouterKit.pop_key(conn.body_params) do
        {:ok, key, attrs} ->
          render(
            conn,
            Requests.create(access.prefix, attrs, %{
              actor_id: access.actor_id,
              idempotency_key: key
            }),
            201
          )

        {:error, _} = error ->
          render(conn, error, 201)
      end
    end)
  end

  authz_get "/requests", :MaintenanceRead do
    if Maintenance.enabled?() do
      case Access.check(conn, :read) do
        {:ok, access} ->
          params = Plug.Conn.fetch_query_params(conn).query_params
          render(conn, Requests.list(access.prefix, params), 200)

        :error ->
          Response.send_json(conn, 200, %{rows: [], next_cursor: nil})
      end
    else
      Response.not_found(conn)
    end
  end

  authz_get "/requests/:id", :MaintenanceRead do
    guarded(conn, :read, fn conn, access ->
      render(conn, Requests.get(access.prefix, conn.params["id"]), 200)
    end)
  end

  authz_post "/requests/:id/reject", :MaintenanceOrderManage do
    guarded(conn, :manage, fn conn, access ->
      case reject_reason(conn.body_params) do
        {:ok, reason} ->
          render(
            conn,
            Requests.reject(access.prefix, conn.params["id"], reason, %{actor_id: access.actor_id}),
            200
          )

        {:error, _} = error ->
          render(conn, error, 200)
      end
    end)
  end

  # REQ-895: photos of a request; Photos owns the guard order (flag, tenant-wide guard, lookup) and
  # the refusal map (409 request_not_new on an upload after the request left `new`).
  authz_post "/requests/:id/photos", :MaintenanceRequestCreate do
    Photos.upload(conn)
  end

  authz_get "/requests/:id/photos", :MaintenanceRead do
    Photos.list(conn)
  end

  authz_get "/requests/:id/photos/:photo_id/original", :MaintenanceRead do
    Photos.content(conn, :original)
  end

  authz_get "/requests/:id/photos/:photo_id/thumbnail", :MaintenanceRead do
    Photos.content(conn, :thumbnail)
  end

  authz_unmatched(:ordinary)

  # The flag first, then the tenant-wide guard; both refusals are the 404 of an unknown path.
  defp guarded(conn, purpose, fun) do
    with true <- Maintenance.enabled?(),
         {:ok, access} <- Access.check(conn, purpose) do
      fun.(conn, access)
    else
      _ -> Response.not_found(conn)
    end
  end

  defp reject_reason(%{"reason" => reason} = body) when map_size(body) == 1, do: {:ok, reason}

  defp reject_reason(%{} = body) do
    case Enum.find(Map.keys(body), &(&1 != "reason")) do
      nil -> {:error, :reason_required}
      key -> {:error, {:field_not_allowed, key}}
    end
  end

  defp reject_reason(_other), do: {:error, :reason_required}

  defp render(conn, {:error, :request_not_new}, _status) do
    problem = Error.conflict("request refused")
    Response.send_problem(conn, %{problem | extensions: %{"reason" => "request_not_new"}})
  end

  defp render(conn, result, status),
    do: RouterKit.render(conn, result, status, "maintenance", @not_found)
end
