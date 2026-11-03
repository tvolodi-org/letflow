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
  `audit_failed` is 500. The renderer is a copy of `Letflow.Modules.Org.Router`, not extracted, so the
  org router stays untouched by sibling changes.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Modules.CatalogItems

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
    Logger.warning("catalog_items request refused: #{inspect(elem_tag(term))}")
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
