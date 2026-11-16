defmodule Letflow.Routers.ApprovalRules do
  @moduledoc """
  The four-eyes switch routes, mounted at `/approval-rules` by `Letflow.Plugs.ApiPipeline`
  (T-1986, docs/design/four-eyes-switch.md, owner decision D-144).

  | Route | Policy key -> permission | Scope class | Answers |
  |---|---|---|---|
  | `GET /` | `:ApprovalRulesManage` | `:tenant_wide` | 200 `{"items": [...]}` |
  | `PUT /:definition_name/:node_id` (body `four_eyes` boolean, `reason` string) | `:ApprovalRulesManage` | `:tenant_wide` | 200 item; 422 `invalid_body` / `invalid_reason` / `not_a_four_eyes_step`; 409 `concurrent_change`; 500 |

  Each item is exactly `definition_name`, `node_id`, `node_label`, `four_eyes`,
  `in_active_definition`, `changed_by`, `changed_by_name`, `changed_at`, `reason`.

  The handler checks, first, that the caller signed in interactively (`credential == :oidc`) and holds
  `:ApprovalRulesManage` tenant-wide (`Letflow.Api.Scope.require_tenant_wide/2`): the route-level class
  is enforced only while the tenant's scope enforcement is `on`, so the handler check makes "a scoped
  TENANT_ADMIN grant does not count" true in every mode. Every refusal answers the same 403
  `insufficient permissions` body as `Letflow.Plugs.Authorize` (INV-5).

  The tenant comes only from the DB-resolved `conn.assigns.scoped_opts` and `auth_context` (INV-1);
  no route takes a tenant identifier and a `tenant_id` in the query or body is never read (INV-10).
  The submitted reason is never echoed. A definition name containing `/` must be sent encoded
  (`%2F`).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.ApprovalRules

  authz_get "/", :ApprovalRulesManage, scope: :tenant_wide do
    guarded(conn, fn conn ->
      Response.ok(conn, %{"items" => Enum.map(ApprovalRules.list(prefix(conn)), &item/1)})
    end)
  end

  authz_put "/:definition_name/:node_id", :ApprovalRulesManage, scope: :tenant_wide do
    guarded(conn, fn conn ->
      actor = %{user_id: conn.assigns.auth_context.user_id, trace_id: nil}

      case ApprovalRules.put(
             prefix(conn),
             conn.params["definition_name"],
             conn.params["node_id"],
             body(conn),
             actor
           ) do
        {:ok, switched} -> Response.ok(conn, item(switched))
        {:error, reason} -> reply_error(conn, reason)
      end
    end)
  end

  authz_unmatched(:ordinary)

  defp guarded(conn, fun) do
    with true <- Map.get(conn.assigns.auth_context, :credential) == :oidc,
         {:ok, conn} <- Scope.require_tenant_wide(conn, :ApprovalRulesManage) do
      fun.(conn)
    else
      _ -> Response.forbidden(conn, "insufficient permissions")
    end
  end

  defp item(i) do
    %{
      "definition_name" => i.definition_name,
      "node_id" => i.node_id,
      "node_label" => i.node_label,
      "four_eyes" => i.four_eyes,
      "in_active_definition" => i.in_active_definition,
      "changed_by" => i.changed_by,
      "changed_by_name" => i.changed_by_name,
      "changed_at" => i.changed_at,
      "reason" => i.reason
    }
  end

  # Fixed text per reason: the submitted text is never echoed.
  defp reply_error(conn, :invalid_body), do: Response.unprocessable(conn, "invalid_body")
  defp reply_error(conn, :invalid_reason), do: Response.unprocessable(conn, "invalid_reason")

  defp reply_error(conn, :not_a_four_eyes_step),
    do: Response.unprocessable(conn, "not_a_four_eyes_step")

  defp reply_error(conn, :conflict), do: Response.conflict(conn, "concurrent_change")
  # Anything else (audit failure): the detail-free 500 (INV-8).
  defp reply_error(conn, _other), do: Response.internal_error(conn)

  defp body(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_json")
      _ -> %{}
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
end
