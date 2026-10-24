defmodule Letflow.Routers.Documents do
  @moduledoc """
  The document retention and legal-hold routes, mounted at `/documents` by
  `Letflow.Plugs.ApiPipeline` (REQ-536, GH #3106, decision 0063 S4, S5, S7).

  | Route | Policy key -> permission | Scope class |
  |---|---|---|
  | `PUT /types/:key/retention` | `:DocumentsRetentionManage` | `:tenant_wide` |
  | `POST /:document_id/hold` | `:DocumentHold` | resolver `Letflow.Documents.ScopeResolver.document_scope/1` |
  | `POST /:document_id/hold/release` | `:DocumentHold` | same resolver |

  Order of checks (0063 S7): the permission at `Letflow.Plugs.Authorize` first (the same 403 for
  an existing and an absent id, since the plug does not look at the id), then body validation
  (422), then one scoped query on id and tenant prefix applying the caller's 0051 scope, then
  the state check (409) and the action with its audit event. The scope is applied inside
  `Letflow.Documents.Hold`'s locked query through `Letflow.Api.ScopeGate.scope_set/2`; the policy
  route is `:tenant_wide`, so `Letflow.Api.Scope.Enforce` refuses a partly-scoped grant with the
  unchanged 403 before the handler runs.

  The tenant comes only from `conn.assigns.scoped_opts` (INV-1) and the actor only from the
  DB-resolved `auth_context` (INV-2); no route takes a tenant identifier (INV-10). Every not-found
  case (absent, malformed, out-of-scope or other-tenant id, unknown key) goes through the one
  `Response.not_found/1`, so the bodies are byte-identical (INV-5). Responses are allowlists and
  never echo the note. Refusals (403, 404, 409, 422) write no audit event.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Documents.Hold
  alias Letflow.Documents.Retention
  alias Letflow.Documents.ScopeResolver

  authz_put "/types/:key/retention", :DocumentsRetentionManage, scope: :tenant_wide do
    handle_policy(conn, conn.params["key"])
  end

  authz_post "/:document_id/hold", :DocumentHold,
    scope: {:resolver, {ScopeResolver, :document_scope}} do
    handle_hold(conn, :set, conn.params["document_id"])
  end

  authz_post "/:document_id/hold/release", :DocumentHold,
    scope: {:resolver, {ScopeResolver, :document_scope}} do
    handle_hold(conn, :release, conn.params["document_id"])
  end

  authz_unmatched(:ordinary)

  # ── PUT /types/:key/retention ───────────────────────────────────────────────

  defp handle_policy(conn, key) do
    body = body(conn)

    policy = %{
      retention_period_days: Map.get(body, "retention_period_days", :missing),
      retention_from: Map.get(body, "retention_from"),
      retention_action: Map.get(body, "retention_action")
    }

    result =
      Retention.change_policy(
        prefix(conn),
        key,
        policy,
        actor_id(conn),
        Map.get(body, "reason_code")
      )

    case result do
      {:ok, %{type_key: type_key, after: after_policy, changed: changed}} ->
        Response.ok(conn, %{
          "type_key" => type_key,
          "retention_period_days" => after_policy.retention_period_days,
          "retention_from" => after_policy.retention_from,
          "retention_action" => after_policy.retention_action,
          "changed" => changed
        })

      other ->
        reply_error(conn, other)
    end
  end

  # ── POST /:document_id/hold[/release] ───────────────────────────────────────

  defp handle_hold(conn, kind, document_id) do
    body = body(conn)

    attrs = %{
      reason_code: Map.get(body, "reason_code"),
      reason_note: Map.get(body, "reason_note")
    }

    {conn, scope} = ScopeGate.scope_set(conn, :DocumentHold)

    result =
      case kind do
        :set -> Hold.set(prefix(conn), document_id, scope, attrs, actor_id(conn))
        :release -> Hold.release(prefix(conn), document_id, scope, attrs, actor_id(conn))
      end

    case result do
      {:ok, %{document_id: id, on_hold: on_hold, reason_code: reason_code}} ->
        Response.ok(conn, %{
          "document_id" => id,
          "on_hold" => on_hold,
          "reason_code" => reason_code
        })

      other ->
        reply_error(conn, other)
    end
  end

  # ── replies ─────────────────────────────────────────────────────────────────

  defp reply_error(conn, {:error, {:unprocessable, reason}}),
    do: Response.unprocessable(conn, unprocessable_detail(reason))

  defp reply_error(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp reply_error(conn, {:error, :conflict}),
    do: Response.conflict(conn, "document hold state conflict")

  # Anything else (audit failure, bad schema name): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  # Fixed text per reason: no input is echoed.
  defp unprocessable_detail(:invalid_reason_code), do: "invalid reason_code"
  defp unprocessable_detail(:invalid_reason_note), do: "invalid reason_note"
  defp unprocessable_detail(:invalid_period), do: "invalid retention_period_days"
  defp unprocessable_detail(:invalid_retention_from), do: "invalid retention_from"
  defp unprocessable_detail(:invalid_retention_action), do: "invalid retention_action"

  defp unprocessable_detail(:period_action_mismatch),
    do: "retention_period_days and retention_action do not match"

  defp unprocessable_detail(_other), do: "invalid request"

  # ── context ─────────────────────────────────────────────────────────────────

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp actor_id(conn), do: conn.assigns.auth_context.user_id
end
