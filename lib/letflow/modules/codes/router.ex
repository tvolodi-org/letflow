defmodule Letflow.Modules.Codes.Router do
  @moduledoc """
  GH #3611 / REQ-667: the write routes of module `codes`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/codes`. A thin layer over the write functions of `Letflow.Modules.Codes`
  (REQ-663), plus the scan lookup `POST /resolve` (GH #3797 / REQ-730).

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /receive` (body `entries`) | `CodesWrite` | `receive_codes/3` | 201 |
  | `POST /:id/assign` (body `target_type`, `target_id`) | `CodesWrite` | `assign_code/5` | 200 |
  | `POST /:id/release` | `CodesWrite` | `release_code/3` | 200 |
  | `POST /:id/retire` | `CodesWrite` | `retire_code/3` | 200 |
  | `POST /:id/value` (body `value`) | `CodesWrite` | `change_code_value/4` | 200 |
  | `POST /resolve` (body `value`, no `idempotency_key`) | `CodesRead` | `resolve/2` | 200 |
  | `POST /labels` (body `code_ids`, no `idempotency_key`) | `CodesRead` | `Labels.render/1` | 200 PDF |

  `POST /labels` (GH #4017 / REQ-779) writes nothing: 1..1000 distinct `code_tag` ids, one label
  each, in list order. An id that is not a live `code_tag` of the tenant is the same 404 as an
  unknown id (INV-5); a code that cannot be printed is 422 `entry_invalid` with `index` and
  `entry_reason` (never the value); a repeated id is `duplicate_in_batch`.

  `POST /resolve` writes nothing. A `not_assigned` code, or an assigned code whose target type is
  `:tenant_wide` (`Letflow.Entities.ScopeDeclaration.for_type/2`), is 200 with the resolve map. A
  retired or conflicting code is 200 with the sent value and five null keys. An unknown code, and an
  assigned code whose target type is scoped or undeclared (fail closed, decision 0076 R7 ruling 2),
  get the same 404 as an unknown code id (INV-5).

  The tenant is `conn.assigns.scoped_opts` and the actor `conn.assigns.auth_context.user_id`
  (INV-1, INV-10): no route takes either from the path or body. Every body carries a required
  `idempotency_key` (text); the other keys are fixed per route and anything else is
  `field_not_allowed`.

  Responses: `code_not_found` and `target_not_found` are the same 404 as an unknown path id (INV-5);
  `{:entry_invalid, index, reason}` is 422 `entry_invalid` with the entry `index` and `entry_reason`
  (never a value); `batch_size` and the other refusal atoms are 422 with a fixed `reason`; a reused
  idempotency key with another body is 409 `idempotency_key_reuse`; `audit_failed` is 500.
  The request plumbing (prefix, actor, idempotency key, body-key check) is
  `Letflow.Modules.RouterKit`; the reason table and `render/3` stay here.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Modules.Codes
  alias Letflow.Modules.Codes.Labels
  alias Letflow.Modules.RouterKit

  @not_found [:code_not_found, :target_not_found]

  authz_post "/resolve", :CodesRead do
    resolve_action(conn)
  end

  authz_post "/labels", :CodesRead do
    labels_action(conn)
  end

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

  defp resolve_action(conn) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    body =
      case conn.body_params do
        %{"_json" => _} -> %{}
        map when is_map(map) -> map
        _ -> %{}
      end

    with :ok <- RouterKit.check_keys(body, ["value"]),
         value when is_binary(value) <- body["value"] do
      render_resolve(conn, Codes.resolve(prefix, value), prefix, value)
    else
      {:error, _} = error -> render(conn, error, 200)
      _ -> render(conn, {:error, {:field_invalid, "value"}}, 200)
    end
  end

  @max_label_ids 1000

  defp labels_action(conn) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    body =
      case conn.body_params do
        %{"_json" => _} -> %{}
        map when is_map(map) -> map
        _ -> %{}
      end

    with :ok <- RouterKit.check_keys(body, ["code_ids"]),
         {:ok, ids} <- label_ids(body["code_ids"]),
         :ok <- no_duplicates(ids),
         {:ok, codes} <- load_tags(prefix, ids) do
      case Labels.render(codes) do
        {:ok, pdf} -> send_pdf(conn, pdf)
        {:error, :no_codes} -> render(conn, {:error, {:field_invalid, "code_ids"}}, 200)
        {:error, _} = error -> render(conn, error, 200)
      end
    else
      :not_found -> Response.not_found(conn)
      {:error, _} = error -> render(conn, error, 200)
    end
  end

  defp label_ids(ids) when is_list(ids) and ids != [] and length(ids) <= @max_label_ids do
    if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: {:error, {:field_invalid, "code_ids"}}
  end

  defp label_ids(_other), do: {:error, {:field_invalid, "code_ids"}}

  defp no_duplicates(ids) do
    keys = Enum.map(ids, &id_key/1)

    keys
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {key, i}, seen ->
      if MapSet.member?(seen, key),
        do: {:halt, {:error, {:entry_invalid, i, :duplicate_in_batch}}},
        else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  defp id_key(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp load_tags(prefix, ids) do
    ids
    |> Enum.reduce_while([], fn id, acc ->
      case Codes.lookup(prefix, id) do
        {:ok, %{"entity_type" => "code_tag"} = tag} -> {:cont, [tag | acc]}
        _ -> {:halt, :not_found}
      end
    end)
    |> case do
      :not_found -> :not_found
      tags -> {:ok, Enum.reverse(tags)}
    end
  end

  defp send_pdf(conn, pdf) do
    conn
    |> Plug.Conn.put_resp_content_type("application/pdf", nil)
    |> Plug.Conn.put_resp_header(
      "content-disposition",
      ~s(attachment; filename="code-labels.pdf")
    )
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(200, pdf)
  end

  defp render_resolve(
         conn,
         {:ok, %{"status" => "assigned", "target_type" => type} = map},
         prefix,
         _v
       ) do
    case type do
      t when is_binary(t) ->
        case ScopeDeclaration.for_type(t, prefix) do
          :tenant_wide -> Response.send_json(conn, 200, map)
          _ -> Response.not_found(conn)
        end

      _ ->
        Response.not_found(conn)
    end
  end

  defp render_resolve(conn, {:ok, map}, _prefix, _value), do: Response.send_json(conn, 200, map)

  defp render_resolve(conn, {:error, :code_retired}, _prefix, value),
    do: Response.send_json(conn, 200, unresolved(value, "retired"))

  defp render_resolve(conn, {:error, :assignment_conflict}, _prefix, value),
    do: Response.send_json(conn, 200, unresolved(value, "assignment_conflict"))

  defp render_resolve(conn, _other, _prefix, _value), do: Response.not_found(conn)

  defp unresolved(value, status) do
    %{
      "code_id" => nil,
      "value" => value,
      "kind" => nil,
      "status" => status,
      "target_type" => nil,
      "target_id" => nil,
      "assignment_id" => nil
    }
  end

  defp action(conn, required, status, fun) do
    RouterKit.with_request(conn, &render/3, fn prefix, body, opts, conn ->
      case RouterKit.check_keys(body, required) do
        :ok -> render(conn, fun.(prefix, conn.params["id"], body, opts), status)
        {:error, _} = error -> render(conn, error, status)
      end
    end)
  end

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
    Logger.warning("codes request refused: #{inspect(RouterKit.elem_tag(term))}")
    unprocessable(conn, "request_refused", %{})
  end

  defp unprocessable(conn, reason, extra) do
    problem = Error.unprocessable("request refused")

    Response.send_problem(conn, %{
      problem
      | extensions: Map.put(extra, "reason", reason)
    })
  end
end
