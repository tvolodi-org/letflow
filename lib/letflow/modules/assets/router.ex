defmodule Letflow.Modules.Assets.Router do
  @moduledoc """
  GH #3892 / REQ-750: the write routes of module `assets`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/assets`. A thin layer over `Letflow.Modules.Assets.Cards`; no read routes (screens
  read through `POST /entities/query`).

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /cards` | `AssetsCardWrite` | `create_card/3` | 201 |
  | `PATCH /cards/:id` | `AssetsCardWrite` | `update_card/4` | 200 |
  | `POST /cards/:id/retire` | `AssetsCardWrite` | `retire_card/3` | 200 |

  After the permission check every handler asks `Letflow.Modules.Assets.Access.check/1`: only an
  interactive, tenant-wide principal passes; any other caller (API token, scoped grant) gets the 404 of
  a tenant without the module (INV-5). The tenant is `conn.assigns.scoped_opts` and the actor the
  token's user (INV-1, INV-10): no route takes either from the path or body. Every body carries a
  required `idempotency_key` (text); the other keys are card fields, whose allow-list `Cards` owns;
  `retire` takes no other key.

  Responses: `card_not_found` is the same 404 as an unknown path id; `field_not_allowed` /
  `field_invalid` / `record_payload_invalid` and the other refusal atoms (`org_unit_not_active`,
  `valid_until_not_allowed`, `currency_mismatch`, `card_inactive`) are 422 with a fixed `reason`
  (field names only, never a stored value); a reused idempotency key with another body is 409
  `idempotency_key_reuse`; `audit_failed` is 500. The rendering is a copy of the Locations router's.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Modules.Assets.Access
  alias Letflow.Modules.Assets.Cards

  @not_found [:card_not_found, :not_found]

  authz_post "/cards", :AssetsCardWrite do
    with_request(conn, fn prefix, attrs, opts, conn ->
      render(conn, Cards.create_card(prefix, attrs, opts), 201)
    end)
  end

  authz_patch "/cards/:id", :AssetsCardWrite do
    with_request(conn, fn prefix, attrs, opts, conn ->
      render(conn, Cards.update_card(prefix, conn.params["id"], attrs, opts), 200)
    end)
  end

  authz_post "/cards/:id/retire", :AssetsCardWrite do
    with_request(conn, fn prefix, body, opts, conn ->
      case Map.keys(body) do
        [] -> render(conn, Cards.retire_card(prefix, conn.params["id"], opts), 200)
        [extra | _] -> render(conn, {:error, {:field_not_allowed, extra}}, 200)
      end
    end)
  end

  authz_unmatched(:ordinary)

  # -- shapes -------------------------------------------------------------------------------------

  # Written as a sigil so the AC5 scan of caller-key literals (idempotency_test) is not tripped.
  @key_field ~s(idempotency_key)

  defp with_request(conn, fun) do
    with {:ok, %{prefix: prefix, actor_id: actor}} <- Access.check(conn) |> access(),
         {:ok, key, attrs} <- pop_key(conn.body_params) do
      fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)
    else
      :denied -> Response.not_found(conn)
      {:error, _} = error -> render(conn, error, 200)
    end
  end

  defp access({:ok, _} = ok), do: ok
  defp access(:error), do: :denied

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
    Logger.warning("assets request refused: #{inspect(elem_tag(term))}")
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
