defmodule Letflow.Modules.CatalogItems.Router do
  @moduledoc """
  GH #3610 / REQ-668: the lot write routes of module `catalog_items`, mounted by
  `Letflow.Routers.Modules` at `/api/v1/modules/catalog_items`. A thin layer over the lot writers of
  `Letflow.Modules.CatalogItems` (REQ-664); no read routes (screens read through `POST /entities/query`).

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /lots`, `PATCH /lots/:id`, `POST /lots/:id/retire` | `CatalogLotsWrite` | `create_lot/3`, `update_lot/4`, `retire_lot/3` | 201 / 200 / 200 |

  `CatalogLotsWrite` has no `role_grants`: only TENANT_ADMIN and PLATFORM_ADMIN hold it. The tenant is
  `conn.assigns.scoped_opts` and the actor `conn.assigns.auth_context.user_id` (INV-1, INV-10): no
  route takes either from the path or body. Every body carries a required `idempotency_key` (text);
  the remaining keys are the lot fields, whose allow-list the writer owns. `retire` takes no other key.

  Responses: `lot_not_found` and `item_not_found` are the same 404 as an unknown path id (INV-5, a
  record of another tenant included); `field_not_allowed` / `field_invalid` / `record_payload_invalid`
  and other refusal atoms (`item_inactive`) are 422 with a fixed `reason` (field names only, never a
  stored value); a reused idempotency key with another body is 409 `idempotency_key_reuse`;
  `audit_failed` is 500. The request plumbing (prefix, actor, idempotency key, body-key check) is
  `Letflow.Modules.RouterKit`; the reason table and `render/3` stay here.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.RouterKit

  @not_found [:lot_not_found, :item_not_found]

  authz_post "/lots", :CatalogLotsWrite do
    create(conn, &CatalogItems.create_lot/3)
  end

  authz_patch "/lots/:id", :CatalogLotsWrite do
    update(conn, &CatalogItems.update_lot/4)
  end

  authz_post "/lots/:id/retire", :CatalogLotsWrite do
    retire(conn, &CatalogItems.retire_lot/3)
  end

  authz_unmatched(:ordinary)

  # -- shapes -------------------------------------------------------------------------------------

  defp create(conn, fun) do
    RouterKit.with_request(conn, &render/3, fn prefix, attrs, opts, conn ->
      render(conn, fun.(prefix, attrs, opts), 201)
    end)
  end

  defp update(conn, fun) do
    RouterKit.with_request(conn, &render/3, fn prefix, attrs, opts, conn ->
      render(conn, fun.(prefix, conn.params["id"], attrs, opts), 200)
    end)
  end

  defp retire(conn, fun),
    do: action(conn, [], fn prefix, id, _body, opts -> fun.(prefix, id, opts) end)

  # Positional-argument functions: the router checks the fixed body keys itself.
  defp action(conn, required, fun) do
    RouterKit.with_request(conn, &render/3, fn prefix, body, opts, conn ->
      case RouterKit.check_keys(body, required) do
        :ok -> render(conn, fun.(prefix, conn.params["id"], body, opts), 200)
        {:error, _} = error -> render(conn, error, 200)
      end
    end)
  end

  # -- rendering ----------------------------------------------------------------------------------

  defp render(conn, result, status),
    do: RouterKit.render(conn, result, status, "catalog_items", @not_found)
end
