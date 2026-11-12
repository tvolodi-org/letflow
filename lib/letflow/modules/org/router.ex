defmodule Letflow.Modules.Org.Router do
  @moduledoc """
  GH #3613 / REQ-665: the write routes of module `org`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/org`. A thin layer over the write functions of `Letflow.Modules.Org`
  (REQ-660, REQ-495, REQ-661); no read routes (screens read through `POST /entities/query`).

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /legal-entities`, `PATCH /legal-entities/:id`, `POST /legal-entities/:id/retire` | `OrgStructureWrite` | `create_legal_entity/3`, `update_legal_entity/4`, `retire_legal_entity/3` | 201 / 200 / 200 |
  | `POST /sites`, `PATCH /sites/:id`, `POST /sites/:id/retire` | `OrgStructureWrite` | `create_site/3`, `update_site/4`, `retire_site/3` | 201 / 200 / 200 |
  | `POST /units`, `PATCH /units/:id`, `POST /units/:id/move`, `POST /units/:id/retire` | `OrgStructureWrite` | `create_unit/3`, `update_unit/4`, `move_unit/4`, `retire_unit/3` | 201 / 200 / 200 / 200 |
  | `POST /positions`, `PATCH /positions/:id`, `POST /positions/:id/retire` | `OrgEmployeesWrite` | `create_position/3`, `update_position/4`, `retire_position/3` | 201 / 200 / 200 |
  | `POST /employees`, `PATCH /employees/:id`, `POST /employees/:id/transfer`, `POST /employees/:id/retire` | `OrgEmployeesWrite` | `create_employee/3`, `update_employee/4`, `transfer_employee/5`, `retire_employee/3` | 201 / 200 / 200 / 200 |

  The tenant is `conn.assigns.scoped_opts` and the actor `conn.assigns.auth_context.user_id`
  (INV-1, INV-10): no route takes either from the path or body. Every body carries a required
  `idempotency_key` (text); the remaining keys are the record fields, whose allow-list the write
  function owns. The action routes (`retire`, `move`, `transfer`) take their own fixed keys.

  Responses: every `*_not_found` refusal is the same 404 as an unknown path id (INV-5, a record of
  another tenant included); `field_not_allowed` / `field_invalid` / `record_payload_invalid` and the
  other refusal atoms are 422 with a fixed `reason` (field names only, never a stored value);
  a reused idempotency key with another body is 409 `idempotency_key_reuse`; `audit_failed` is 500.
  REQ-666..668 copy this renderer; extracting a shared module is their decision.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Modules.Org
  alias Letflow.Modules.RouterKit

  @not_found [
    :legal_entity_not_found,
    :site_not_found,
    :unit_not_found,
    :parent_not_found,
    :position_not_found,
    :employee_not_found,
    :user_not_found
  ]

  # -- legal entities / sites / units / positions / employees -------------------------------------

  authz_post "/legal-entities", :OrgStructureWrite do
    create(conn, &Org.create_legal_entity/3)
  end

  authz_patch "/legal-entities/:id", :OrgStructureWrite do
    update(conn, &Org.update_legal_entity/4)
  end

  authz_post "/legal-entities/:id/retire", :OrgStructureWrite do
    retire(conn, &Org.retire_legal_entity/3)
  end

  authz_post "/sites", :OrgStructureWrite do
    create(conn, &Org.create_site/3)
  end

  authz_patch "/sites/:id", :OrgStructureWrite do
    update(conn, &Org.update_site/4)
  end

  authz_post "/sites/:id/retire", :OrgStructureWrite do
    retire(conn, &Org.retire_site/3)
  end

  authz_post "/units", :OrgStructureWrite do
    create(conn, &Org.create_unit/3)
  end

  authz_patch "/units/:id", :OrgStructureWrite do
    update(conn, &Org.update_unit/4)
  end

  authz_post "/units/:id/move", :OrgStructureWrite do
    action(conn, ["parent_id"], fn prefix, id, %{"parent_id" => parent}, opts ->
      Org.move_unit(prefix, id, parent, opts)
    end)
  end

  authz_post "/units/:id/retire", :OrgStructureWrite do
    retire(conn, &Org.retire_unit/3)
  end

  authz_post "/positions", :OrgEmployeesWrite do
    create(conn, &Org.create_position/3)
  end

  authz_patch "/positions/:id", :OrgEmployeesWrite do
    update(conn, &Org.update_position/4)
  end

  authz_post "/positions/:id/retire", :OrgEmployeesWrite do
    retire(conn, &Org.retire_position/3)
  end

  authz_post "/employees", :OrgEmployeesWrite do
    create(conn, &Org.create_employee/3)
  end

  authz_patch "/employees/:id", :OrgEmployeesWrite do
    update(conn, &Org.update_employee/4)
  end

  authz_post "/employees/:id/transfer", :OrgEmployeesWrite do
    action(conn, ["org_unit_id", "position_id"], fn prefix, id, body, opts ->
      Org.transfer_employee(prefix, id, body["org_unit_id"], body["position_id"], opts)
    end)
  end

  authz_post "/employees/:id/retire", :OrgEmployeesWrite do
    retire(conn, &Org.retire_employee/3)
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

  defp render(conn, result, status), do: RouterKit.render(conn, result, status, "org", @not_found)
end
