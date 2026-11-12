defmodule Letflow.Modules.Locations.Router do
  @moduledoc """
  GH #3612 / REQ-666: the write routes of module `locations`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/locations`. A thin layer over the write functions of `Letflow.Modules.Locations`
  (REQ-644, REQ-646, REQ-662); no read routes (screens read through `POST /entities/query`).

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /nodes` | `LocationsWrite` | `create_node/3` | 201 |
  | `PATCH /nodes/:id` | `LocationsWrite` | `update_node/4` | 200 |
  | `POST /nodes/:id/move` (key `parent_id`, null = root) | `LocationsWrite` | `move_node/4` | 200 |
  | `POST /nodes/:id/retire` | `LocationsWrite` | `retire_node/3` | 200 |
  | `POST /links` (keys `org_unit_id`, `location_id`) | `LocationsWrite` | `link_unit_location/4` | 201 |
  | `POST /links/retire` (same keys) | `LocationsWrite` | `unlink_unit_location/4` | 200 |

  `POST /links` answers 201 also when it reactivates an inactive link (the function returns the link
  either way). The tenant is `conn.assigns.scoped_opts` and the actor `conn.assigns.auth_context.user_id`
  (INV-1, INV-10): no route takes either from the path or body. Every body carries a required
  `idempotency_key` (text); the remaining keys are the record fields, whose allow-list the write
  function owns. `POST /nodes` also accepts `address_pattern`: absent or null means a free address,
  the text `"segments"` composes the address from the ancestors' segments, any other value is 422
  `field_invalid`; the value is never turned into an atom. On every other route the key is
  `field_not_allowed`.

  Responses: every `*_not_found` refusal is the same 404 as an unknown path id (INV-5, a record of
  another tenant included); `field_not_allowed` / `field_invalid` / `record_payload_invalid` and the
  other refusal atoms (`cycle`, `has_active_descendants`, `unit_inactive`, `location_inactive`,
  `parent_inactive`) are 422 with a fixed `reason` (field names only, never a stored value);
  a reused idempotency key with another body is 409 `idempotency_key_reuse`; `audit_failed` is 500.
  The request plumbing (prefix, actor, idempotency key, body-key check) is
  `Letflow.Modules.RouterKit`; the reason table and `render/3` stay here.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Modules.Locations
  alias Letflow.Modules.RouterKit

  @not_found [
    :node_not_found,
    :parent_not_found,
    :location_not_found,
    :unit_not_found,
    :link_not_found,
    :not_found
  ]

  authz_post "/nodes", :LocationsWrite do
    create_node(conn)
  end

  authz_patch "/nodes/:id", :LocationsWrite do
    update(conn, &Locations.update_node/4)
  end

  authz_post "/nodes/:id/move", :LocationsWrite do
    action(conn, ["parent_id"], fn prefix, id, %{"parent_id" => parent}, opts ->
      Locations.move_node(prefix, id, parent, opts)
    end)
  end

  authz_post "/nodes/:id/retire", :LocationsWrite do
    action(conn, [], fn prefix, id, _body, opts -> Locations.retire_node(prefix, id, opts) end)
  end

  authz_post "/links", :LocationsWrite do
    action(
      conn,
      ["org_unit_id", "location_id"],
      fn prefix, _id, body, opts ->
        Locations.link_unit_location(prefix, body["org_unit_id"], body["location_id"], opts)
      end,
      201
    )
  end

  authz_post "/links/retire", :LocationsWrite do
    action(conn, ["org_unit_id", "location_id"], fn prefix, _id, body, opts ->
      Locations.unlink_unit_location(prefix, body["org_unit_id"], body["location_id"], opts)
    end)
  end

  authz_unmatched(:ordinary)

  # -- shapes -------------------------------------------------------------------------------------

  # `address_pattern` is a create-only option, popped before the attrs allow-list sees it.
  defp create_node(conn) do
    RouterKit.with_request(conn, &render/3, fn prefix, attrs, opts, conn ->
      case Map.pop(attrs, "address_pattern") do
        {nil, rest} ->
          render(conn, Locations.create_node(prefix, rest, opts), 201)

        {"segments", rest} ->
          render(
            conn,
            Locations.create_node(prefix, rest, Map.put(opts, :address_pattern, :segments)),
            201
          )

        {_other, _rest} ->
          render(conn, {:error, {:field_invalid, "address_pattern"}}, 201)
      end
    end)
  end

  defp update(conn, fun) do
    RouterKit.with_request(conn, &render/3, fn prefix, attrs, opts, conn ->
      render(conn, fun.(prefix, conn.params["id"], attrs, opts), 200)
    end)
  end

  # Positional-argument functions: the router checks the fixed body keys itself.
  defp action(conn, required, fun, ok_status \\ 200) do
    RouterKit.with_request(conn, &render/3, fn prefix, body, opts, conn ->
      case RouterKit.check_keys(body, required) do
        :ok -> render(conn, fun.(prefix, conn.params["id"], body, opts), ok_status)
        {:error, _} = error -> render(conn, error, 200)
      end
    end)
  end

  # -- rendering ----------------------------------------------------------------------------------

  defp render(conn, result, status),
    do: RouterKit.render(conn, result, status, "locations", @not_found)
end
