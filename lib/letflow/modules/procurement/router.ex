defmodule Letflow.Modules.Procurement.Router do
  @moduledoc """
  GH #3162 / REQ-544 part 2: the HTTP surface of module `procurement`, mounted by
  `Letflow.Routers.Modules` at `/api/v1/modules/procurement`. A thin layer: every route delegates to
  `Letflow.Modules.Procurement.PurchaseRequests` or `Letflow.Modules.Procurement.Decisions`. A
  process definition's service task calls these routes; no engine-to-module dispatch exists yet.

  | Route | Permission | Delegate | Responses |
  |---|---|---|---|
  | `POST /purchase-requests` | `ProcurementRequestWrite` | `PurchaseRequests.create/3` | 201 / 404 / 422 |
  | `GET /purchase-requests/:id` | `ProcurementRequestRead` | `Decisions.status/2` | 200 / 404 |
  | `POST /purchase-requests/:id/submit` | `ProcurementRequestWrite` | `PurchaseRequests.submit_for_bpm/3` | 200 / 404 / 422 / 503 |
  | `POST /purchase-requests/:id/revise` | `ProcurementRequestWrite` | `PurchaseRequests.revise/4` | 200 / 404 / 422 |
  | `POST /purchase-requests/:id/decisions` | `ProcurementRequestDecide` | `Decisions.record/3` | 201 / 200 replay / 403 / 404 / 409 / 422 / 503 |
  | `GET /purchase-requests/:id/lines/:line_no` | `ProcurementRequestRead` | `LineEvents.line_view/3` | 200 / 404 |
  | `POST /purchase-requests/:id/lines/:line_no/officer` | `ProcurementLineRecord` | `LineEvents.record_officer/3` | 201 / 200 replay / 403 / 404 / 409 / 422 / 503 |
  | `POST /purchase-requests/:id/lines/:line_no/supplier` | `ProcurementLineRecord` | `LineEvents.record_supplier/3` | same |
  | `POST /purchase-requests/:id/lines/:line_no/reference` | `ProcurementLineRecord` | `LineEvents.record_reference/3` | same |
  | `POST /purchase-requests/:id/lines/:line_no/cancel` | `ProcurementLineRecord` | `LineEvents.cancel_line/3` | same (409 `request_closed` on a Closed or Cancelled request) |
  | `POST /purchase-requests/:id/attachments` | `ProcurementRequestWrite` | `Attachments.attach/4` | 201 / 404 / 409 `not_draft` / 413 / 422 / 503 |
  | `GET /purchase-requests/:id/attachments` | `ProcurementRequestRead` | `Attachments.list/4` | 200 / 404 / 422 |
  | `GET /purchase-requests/:id/attachments/:attachment_id/content` | `ProcurementRequestRead` | `Attachments.download/5` | 200 bytes / 404 |
  | `POST /purchase-requests/:id/attachments/:attachment_id/replace` | `ProcurementRequestWrite` | `Attachments.replace/5` | same as attach (`:attachment_id` is the slot id) |

  GH #3503 / REQ-626 part A and B: on a submitted request attach and replace make a new issued version
  (see `Attachments`); the attachment routes take a JSON body of `file_name`, `content_type` and
  `content_base64` only. The effective upload cap is the JSON body limit of `Letflow.Plugs.ApiPipeline`
  (2 MiB, about 1.5 MiB of file): the 25 MiB rule is enforced in `Attachments`, a larger body gets a
  413 from the parser first. List and download are open to the requester and to a holder of
  `ProcurementRequestDecide`; attach and replace to the requester only.

  The caller is `conn.assigns.auth_context.user_id` and the tenant is `conn.assigns.scoped_opts`
  (INV-1, INV-10): no route takes a performer, requester, actor or tenant from the body or path. The
  path `:id` is a document id. A document that is absent, malformed, of another type, of another
  tenant, or (for requester operations) someone else's, gives the same `Response.not_found/1`
  (INV-5). The one exception is `:self_decision` (403): the requester already knows the request
  exists. Error bodies carry a code in the `reason` extension, never a hash, id or content.

  GH #3188 / REQ-558 part 1 adds the four line routes (a refusal `:not_approved` is a 409). `GET` is
  open to the requester and to a holder of `ProcurementRequestDecide` or, for the line read,
  `ProcurementLineRecord` (who must read a
  request to decide it); anyone else gets not-found. All routes are tenant-wide, as the Exam router:
  there is no per-org-unit scope on deciders in this slice.

  Until per-tenant role grants exist the same two roles (TENANT_ADMIN, PLATFORM_ADMIN) hold the
  write, read and decide permissions: every other role is refused by the permission gate, and a
  TENANT_ADMIN who created a request cannot decide it (`:self_decision`).
  """

  use Letflow.Api.AuthorizedRouter

  import Plug.Conn, only: [put_resp_content_type: 3, put_resp_header: 3, send_resp: 3]

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
  alias Letflow.Modules.Procurement.Attachments
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.LineEvents
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.PlatformTenant

  authz_post "/purchase-requests", :ProcurementRequestWrite do
    result = PurchaseRequests.create(prefix!(conn), actor(conn), request_body(conn))
    render(conn, result, 201, & &1)
  end

  authz_get "/purchase-requests/:id", :ProcurementRequestRead do
    prefix = prefix!(conn)
    actor = actor(conn)

    with {:ok, status} <- Decisions.status(prefix, conn.params["id"]),
         true <-
           Decisions.requester_of(prefix, status.document_id) == actor or
             holds?(conn, :ProcurementRequestDecide) do
      Response.ok(
        conn,
        Map.put(status, :fulfilment_status, LineEvents.request_status(prefix, status.document_id))
      )
    else
      _other -> Response.not_found(conn)
    end
  end

  authz_post "/purchase-requests/:id/submit", :ProcurementRequestWrite do
    params =
      Map.put(
        whitelist(conn, ~w(version_no content_hash idempotency_key)),
        "document_id",
        conn.params["id"]
      )

    render(conn, PurchaseRequests.submit_for_bpm(prefix!(conn), actor(conn), params), 200, & &1)
  end

  authz_post "/purchase-requests/:id/revise", :ProcurementRequestWrite do
    result =
      PurchaseRequests.revise(prefix!(conn), actor(conn), conn.params["id"], request_body(conn))

    render(conn, result, 200, & &1)
  end

  authz_post "/purchase-requests/:id/decisions", :ProcurementRequestDecide do
    params =
      Map.put(
        whitelist(conn, ~w(version_no content_hash decision idempotency_key)),
        "document_id",
        conn.params["id"]
      )

    case Decisions.record(prefix!(conn), actor(conn), params) do
      {:ok, %{replayed: true} = result} -> Response.ok(conn, result)
      {:ok, result} -> Response.created(conn, result)
      {:error, _reason} = error -> render(conn, error, 200, & &1)
    end
  end

  authz_get "/purchase-requests/:id/lines/:line_no", :ProcurementRequestRead do
    prefix = prefix!(conn)
    actor = actor(conn)

    with {:ok, view} <- LineEvents.line_view(prefix, conn.params["id"], conn.params["line_no"]),
         true <-
           Decisions.requester_of(prefix, view.document_id) == actor or
             holds?(conn, :ProcurementRequestDecide) or holds?(conn, :ProcurementLineRecord) do
      Response.ok(conn, view)
    else
      _other -> Response.not_found(conn)
    end
  end

  authz_post "/purchase-requests/:id/lines/:line_no/officer", :ProcurementLineRecord do
    record_line(conn, :record_officer, ~w(officer_id idempotency_key))
  end

  authz_post "/purchase-requests/:id/lines/:line_no/supplier", :ProcurementLineRecord do
    record_line(conn, :record_supplier, ~w(source_system identifier display_name idempotency_key))
  end

  authz_post "/purchase-requests/:id/lines/:line_no/reference", :ProcurementLineRecord do
    record_line(conn, :record_reference, ~w(source_system identifier kind idempotency_key))
  end

  authz_post "/purchase-requests/:id/lines/:line_no/cancel", :ProcurementLineRecord do
    record_line(conn, :cancel_line, ~w(reason idempotency_key))
  end

  authz_post "/purchase-requests/:id/attachments", :ProcurementRequestWrite do
    with {:ok, file} <- upload_params(conn) do
      result = Attachments.attach(prefix!(conn), actor(conn), conn.params["id"], file)
      render_attachment(conn, result)
    else
      {:error, _reason} = error -> render(conn, error, 201, & &1)
    end
  end

  authz_get "/purchase-requests/:id/attachments", :ProcurementRequestRead do
    opts = [decider?: holds?(conn, :ProcurementRequestDecide), version_no: version_param(conn)]

    case Attachments.list(prefix!(conn), actor(conn), conn.params["id"], opts) do
      {:ok, view} -> Response.ok(conn, view)
      {:error, _reason} = error -> render(conn, error, 200, & &1)
    end
  end

  authz_get "/purchase-requests/:id/attachments/:attachment_id/content",
            :ProcurementRequestRead do
    opts = [decider?: holds?(conn, :ProcurementRequestDecide)]

    case Attachments.download(
           prefix!(conn),
           actor(conn),
           conn.params["id"],
           conn.params["attachment_id"],
           opts
         ) do
      {:ok, file} -> send_file_bytes(conn, file)
      {:error, _reason} = error -> render(conn, error, 200, & &1)
    end
  end

  authz_post "/purchase-requests/:id/attachments/:attachment_id/replace",
             :ProcurementRequestWrite do
    with {:ok, file} <- upload_params(conn) do
      result =
        Attachments.replace(
          prefix!(conn),
          actor(conn),
          conn.params["id"],
          conn.params["attachment_id"],
          file
        )

      render_attachment(conn, result)
    else
      {:error, _reason} = error -> render(conn, error, 201, & &1)
    end
  end

  authz_unmatched(:ordinary)

  # -- rendering --------------------------------------------------------------------------------

  defp render(conn, {:ok, result}, status, shape),
    do: Response.send_json(conn, status, shape.(result))

  defp render(conn, {:error, :not_found}, _status, _shape), do: Response.not_found(conn)

  defp render(conn, {:error, {:validation, errors}}, _status, _shape) do
    problem = %{
      Letflow.Api.Error.unprocessable("request is invalid")
      | extensions: %{
          "reason" => "validation",
          "errors" => Enum.map(errors, &%{"field" => &1.field, "code" => &1.code})
        }
    }

    Response.send_problem(conn, problem)
  end

  defp render(conn, {:error, :self_decision}, _status, _shape),
    do:
      Response.send_problem(
        conn,
        with_reason(Letflow.Api.Error.forbidden("not permitted"), :self_decision)
      )

  defp render(conn, {:error, reason}, _status, _shape)
       when reason in [:idempotency_key_reused, :version_closed, :not_approved, :request_closed],
       do:
         Response.send_problem(
           conn,
           with_reason(Letflow.Api.Error.conflict("request refused"), reason)
         )

  defp render(conn, {:error, reason}, _status, _shape)
       when reason in [:not_draft, :slot_conflict],
       do:
         Response.send_problem(
           conn,
           with_reason(Letflow.Api.Error.conflict("request refused"), reason)
         )

  defp render(conn, {:error, reason}, _status, _shape)
       when reason in [:content_type_not_allowed, :infected],
       do:
         Response.send_problem(
           conn,
           with_reason(Letflow.Api.Error.unprocessable("request refused"), reason)
         )

  defp render(conn, {:error, :file_too_large}, _status, _shape),
    do:
      Response.send_problem(
        conn,
        with_reason(Letflow.Api.Error.payload_too_large("file is too large"), :file_too_large)
      )

  defp render(conn, {:error, :scan_unavailable}, _status, _shape),
    do: Response.service_unavailable(conn, "scan unavailable, retry shortly")

  defp render(conn, {:error, :binding_refused}, _status, _shape),
    do:
      Response.send_problem(
        conn,
        with_reason(Letflow.Api.Error.unprocessable("request refused"), :binding_refused)
      )

  defp render(conn, {:error, :busy}, _status, _shape),
    do: Response.service_unavailable(conn, "busy, retry shortly")

  defp render(conn, {:error, :audit_failed}, _status, _shape), do: Response.internal_error(conn)

  # Any other refusal comes from `Letflow.Documents` and is about the caller's input.
  defp render(conn, {:error, reason}, _status, _shape) do
    Logger.warning("procurement request refused: #{inspect(reason)}")
    Response.send_problem(conn, Letflow.Api.Error.unprocessable("request refused"))
  end

  defp with_reason(problem, reason),
    do: %{problem | extensions: %{"reason" => Atom.to_string(reason)}}

  # -- attachments -------------------------------------------------------------------------------

  defp render_attachment(conn, {:ok, view}), do: Response.created(conn, view)
  defp render_attachment(conn, {:error, _reason} = error), do: render(conn, error, 201, & &1)

  # Only the three file fields are read from the body; a missing or non-text field, or base64 that
  # does not decode, is a validation error naming the field.
  defp upload_params(conn) do
    body = whitelist(conn, ~w(file_name content_type content_base64))

    with {:ok, name} <- text_field(body, "file_name"),
         {:ok, type} <- text_field(body, "content_type"),
         {:ok, encoded} <- text_field(body, "content_base64"),
         {:ok, bytes} <- decode(encoded) do
      {:ok, %{file_name: name, content_type: type, bytes: bytes}}
    end
  end

  defp text_field(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:validation, [%{field: key, code: "invalid"}]}}
    end
  end

  defp decode(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:validation, [%{field: "content_base64", code: "invalid"}]}}
    end
  end

  defp version_param(conn) do
    case conn.query_params do
      %{"version_no" => value} -> value
      _other -> nil
    end
  end

  # The stored type is from the allow-list (never text/html); `nosniff` and `no-store` as the
  # instance attachment download.
  defp send_file_bytes(conn, file) do
    conn
    |> put_resp_content_type(file.content_type, nil)
    |> put_resp_header("content-disposition", content_disposition(file.file_name))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, file.content)
  end

  # Copy of the private `Letflow.Routers.Instances.content_disposition/1` (not shared: that file
  # is out of scope for this slice).
  defp content_disposition(file_name) do
    sanitized =
      file_name
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(~r/[\x00-\x1F\x7F]/, "")

    "attachment; filename=\"#{sanitized}\""
  end

  # -- plumbing ----------------------------------------------------------------------------------

  defp prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp actor(conn), do: conn.assigns.auth_context.user_id

  defp request_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> %{}
      body when is_map(body) -> Map.drop(body, ["id", "requester"])
      _other -> %{}
    end
  end

  defp whitelist(conn, keys) do
    case conn.body_params do
      body when is_map(body) -> Map.take(body, keys)
      _other -> %{}
    end
  end

  defp record_line(conn, operation, keys) do
    params =
      conn
      |> whitelist(keys)
      |> Map.put("document_id", conn.params["id"])
      |> Map.put("line_no", conn.params["line_no"])

    case apply(LineEvents, operation, [prefix!(conn), actor(conn), params]) do
      {:ok, %{replayed: true} = result} -> Response.ok(conn, result)
      {:ok, result} -> Response.created(conn, result)
      {:error, _reason} = error -> render(conn, error, 200, & &1)
    end
  end

  defp holds?(conn, permission) do
    platform? = PlatformTenant.platform_tenant?(Map.get(conn.assigns.auth_context, :tenant_id))
    roles = Authorization.effective_roles(conn.assigns.auth_context.roles, platform?)
    Authorization.has_permission?(roles, permission)
  end
end
