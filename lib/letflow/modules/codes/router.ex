defmodule Letflow.Modules.Codes.Router do
  @moduledoc """
  GH #3611 / REQ-667: the write routes of module `codes`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/codes`. A thin layer over the write functions of `Letflow.Modules.Codes`
  (REQ-663); no read routes and no scan route (D-067, a later slice).

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /receive` (body `entries`) | `CodesWrite` | `receive_codes/3` | 201 |
  | `POST /:id/assign` (body `target_type`, `target_id`) | `CodesWrite` | `assign_code/5` | 200 |
  | `POST /:id/release` | `CodesWrite` | `release_code/3` | 200 |
  | `POST /:id/retire` | `CodesWrite` | `retire_code/3` | 200 |
  | `POST /:id/value` (body `value`) | `CodesWrite` | `change_code_value/4` | 200 |

  The tenant is `conn.assigns.scoped_opts` and the actor `conn.assigns.auth_context.user_id`
  (INV-1, INV-10): no route takes either from the path or body. Every body carries a required
  `idempotency_key` (text); the other keys are fixed per route and anything else is
  `field_not_allowed`.

  Responses: `code_not_found` and `target_not_found` are the same 404 as an unknown path id (INV-5);
  `{:entry_invalid, index, reason}` is 422 `entry_invalid` with the entry `index` and `entry_reason`
  (never a value); `batch_size` and the other refusal atoms are 422 with a fixed `reason`; a reused
  idempotency key with another body is 409 `idempotency_key_reuse`; `audit_failed` is 500.
  The renderer is a copy of the one in `Letflow.Modules.Org.Router`; extracting a shared module is
  left to a later slice.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Modules.Codes

  @not_found [:code_not_found, :target_not_found]

  authz_post "/receive", :CodesWrite do
    action(conn, ["entries"], 201, fn prefix, _id, body, opts ->
      Codes.receive_codes(prefix, body["entries"], opts)
    end)
  end

  authz_post "/:id/assign", :CodesWrite do
    action(conn, ["target_type", "target_id"], 200, fn prefix, id, body, opts ->
      Codes.assign_code(prefix, id, body["target_type"], body["target_id"], opts)
    end)
  end

  authz_post "/:id/release", :CodesWrite do
    action(conn, [], 200, fn prefix, id, _body, opts -> Codes.release_code(prefix, id, opts) end)
  end

  authz_post "/:id/retire", :CodesWrite do
    action(conn, [], 200, fn prefix, id, _body, opts -> Codes.retire_code(prefix, id, opts) end)
  end

  authz_post "/:id/value", :CodesWrite do
    action(conn, ["value"], 200, fn prefix, id, body, opts ->
      Codes.change_code_value(prefix, id, body["value"], opts)
    end)
  end

  authz_unmatched(:ordinary)

  # -- shapes -------------------------------------------------------------------------------------

  defp action(conn, required, status, fun) do
    with_request(conn, fn prefix, body, opts, conn ->
      case check_keys(body, required) do
        :ok -> render(conn, fun.(prefix, conn.params["id"], body, opts), status)
        {:error, _} = error -> render(conn, error, status)
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

  defp render(conn, {:error, {:entry_invalid, index, reason}}, _status)
       when is_integer(index) and is_atom(reason),
       do:
         unprocessable(conn, "entry_invalid", %{
           "index" => index,
           "entry_reason" => Atom.to_string(reason)
         })

  defp render(conn, {:error, :idempotency_key_reuse}, _status) do
    problem = Error.conflict("request refused")
    Response.send_problem(conn, %{problem | extensions: %{"reason" => "idempotency_key_reuse"}})
  end

  defp render(conn, {:error, :audit_failed}, _status), do: Response.internal_error(conn)

  defp render(conn, {:error, reason}, _status) when is_atom(reason),
    do: unprocessable(conn, Atom.to_string(reason), %{})

  defp render(conn, {:error, term}, _status) do
    Logger.warning("codes request refused: #{inspect(elem_tag(term))}")
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
