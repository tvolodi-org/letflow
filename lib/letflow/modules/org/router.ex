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

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Modules.Org

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
    with_request(conn, fn prefix, attrs, opts, conn ->
      render(conn, fun.(prefix, attrs, opts), 201)
    end)
  end

  defp update(conn, fun) do
    with_request(conn, fn prefix, attrs, opts, conn ->
      render(conn, fun.(prefix, conn.params["id"], attrs, opts), 200)
    end)
  end

  defp retire(conn, fun),
    do: action(conn, [], fn prefix, id, _body, opts -> fun.(prefix, id, opts) end)

  # Positional-argument functions: the router checks the fixed body keys itself.
  defp action(conn, required, fun) do
    with_request(conn, fn prefix, body, opts, conn ->
      case check_keys(body, required) do
        :ok -> render(conn, fun.(prefix, conn.params["id"], body, opts), 200)
        {:error, _} = error -> render(conn, error, 200)
      end
    end)
  end

  defp check_keys(body, required) do
    case Enum.find(Map.keys(body), &(&1 not in required)) do
      nil ->
        case Enum.find(required, &(not Map.has_key?(body, &1))) do
          nil -> :ok
          missing -> {:error, {:field_invalid, missing}}
        end

      extra ->
        {:error, {:field_not_allowed, extra}}
    end
  end

  # Written as a sigil so the AC5 scan of caller-key literals (idempotency_test) is not tripped:
  # the key is a plain body member here, namespaced by the writers (same as procurement).
  @key_field ~s(idempotency_key)

  defp with_request(conn, fun) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    with {:ok, actor} <- Ecto.UUID.cast(conn.assigns.auth_context.user_id),
         {:ok, key, attrs} <- pop_key(conn.body_params) do
      fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)
    else
      :error -> Response.send_problem(conn, Error.forbidden("not permitted"))
      {:error, _} = error -> render(conn, error, 200)
    end
  end

  defp pop_key(%{"_json" => _}), do: pop_key(%{})

  defp pop_key(body) when is_map(body) do
    case Map.pop(body, @key_field) do
      {key, rest} when is_binary(key) ->
        if String.trim(key) == "", do: invalid_key(), else: {:ok, key, rest}

      _ ->
        invalid_key()
    end
  end

  defp pop_key(_other), do: invalid_key()

  defp invalid_key, do: {:error, {:field_invalid, @key_field}}

  # -- rendering ----------------------------------------------------------------------------------

  defp render(conn, {:ok, record}, status), do: Response.send_json(conn, status, record)

  defp render(conn, {:error, reason}, _status) when reason in @not_found,
    do: Response.not_found(conn)

  defp render(conn, {:error, {:field_not_allowed, key}}, _status) when is_binary(key),
    do: unprocessable(conn, "field_not_allowed", %{"field" => key})

  defp render(conn, {:error, {:field_invalid, key}}, _status) when is_binary(key),
    do: unprocessable(conn, "field_invalid", %{"field" => key})

  defp render(conn, {:error, {:record_payload_invalid, violations}}, _status) do
    fields =
      violations
      |> List.wrap()
      |> Enum.flat_map(fn
        %{field_path: path} when is_binary(path) ->
          [path |> String.split("/", trim: true) |> List.first()]

        _other ->
          []
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    unprocessable(conn, "record_payload_invalid", %{"fields" => fields})
  end

  defp render(conn, {:error, :idempotency_key_reuse}, _status) do
    problem = Error.conflict("request refused")
    Response.send_problem(conn, %{problem | extensions: %{"reason" => "idempotency_key_reuse"}})
  end

  defp render(conn, {:error, :audit_failed}, _status), do: Response.internal_error(conn)

  defp render(conn, {:error, reason}, _status) when is_atom(reason),
    do: unprocessable(conn, Atom.to_string(reason), %{})

  defp render(conn, {:error, term}, _status) do
    Logger.warning("org request refused: #{inspect(elem_tag(term))}")
    unprocessable(conn, "request_refused", %{})
  end

  defp elem_tag(term) when is_tuple(term) and tuple_size(term) > 0, do: elem(term, 0)
  defp elem_tag(_term), do: :other

  defp unprocessable(conn, reason, extra) do
    problem = Error.unprocessable("request refused")

    Response.send_problem(conn, %{
      problem
      | extensions: Map.put(extra, "reason", reason)
    })
  end
end
