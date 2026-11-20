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
  | `POST /orders` (body `request_id` or `asset_card_id`, `description`, `urgency`; `assignee_user_id`, `idempotency_key`) (REQ-896) | `MaintenanceOrderManage` | `Orders.create/3` | 201 order view |
  | `POST /orders/:id/assign` (body `user_id`) (REQ-896) | `MaintenanceOrderManage` | `Orders.assign/4` | 200 order view |
  | `GET /orders` (`status`, `asset_card_id`, `limit`, `cursor`) (REQ-896) | `MaintenanceRead` | `Orders.list/2` | 200 `rows, next_cursor` |
  | `GET /orders/:id` (REQ-896) | `MaintenanceRead` | `Orders.get/2` | 200 order view |

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
  409 `definition_not_active` and `order_not_assignable` (REQ-896); 422 also `order_source_invalid`, `assignee_not_found`; `audit_failed` is 500. The photo routes' own refusals are in `Letflow.Modules.Maintenance.Photos`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Modules.Maintenance
  alias Letflow.Modules.Maintenance.Access
  alias Letflow.Modules.Maintenance.Orders
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

  # REQ-896: work orders. Same guard order as the request routes; Orders owns the rules.
  authz_post "/orders", :MaintenanceOrderManage do
    guarded(conn, :manage, fn conn, access ->
      case RouterKit.pop_key(conn.body_params) do
        {:ok, key, attrs} ->
          render(conn, Orders.create(access.prefix, attrs, order_opts(conn, access, key)), 201)

        {:error, _} = error ->
          render(conn, error, 201)
      end
    end)
  end

  authz_get "/orders", :MaintenanceRead do
    if Maintenance.enabled?() do
      case Access.check(conn, :read) do
        {:ok, access} ->
          params = Plug.Conn.fetch_query_params(conn).query_params
          render(conn, Orders.list(access.prefix, params), 200)

        :error ->
          Response.send_json(conn, 200, %{rows: [], next_cursor: nil})
      end
    else
      Response.not_found(conn)
    end
  end

  authz_get "/orders/:id", :MaintenanceRead do
    guarded(conn, :read, fn conn, access ->
      render(conn, Orders.get(access.prefix, conn.params["id"]), 200)
    end)
  end

  authz_post "/orders/:id/assign", :MaintenanceOrderManage do
    guarded(conn, :manage, fn conn, access ->
      case assign_user(conn.body_params) do
        {:ok, user_id} ->
          render(
            conn,
            Orders.assign(
              access.prefix,
              conn.params["id"],
              user_id,
              order_opts(conn, access, nil)
            ),
            200
          )

        {:error, _} = error ->
          render(conn, error, 200)
      end
    end)
  end

  authz_unmatched(:ordinary)

  defp order_opts(conn, access, key) do
    %{
      actor_id: access.actor_id,
      idempotency_key: key,
      activator: Letflow.Api.Context.activator(conn),
      actor_roles: Map.get(conn.assigns.auth_context, :roles) || []
    }
  end

  defp assign_user(%{"user_id" => user_id} = body) when map_size(body) == 1, do: {:ok, user_id}

  defp assign_user(%{} = body) do
    case Enum.find(Map.keys(body), &(&1 != "user_id")) do
      nil -> {:error, :assignee_not_found}
      key -> {:error, {:field_not_allowed, key}}
    end
  end

  defp assign_user(_other), do: {:error, :assignee_not_found}

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

  defp render(conn, {:error, reason}, _status)
       when reason in [:definition_not_active, :order_not_assignable] do
    problem = Error.conflict("request refused")
    Response.send_problem(conn, %{problem | extensions: %{"reason" => Atom.to_string(reason)}})
  end

  defp render(conn, result, status),
    do: RouterKit.render(conn, result, status, "maintenance", @not_found)
end
