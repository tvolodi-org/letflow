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

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.Response
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
