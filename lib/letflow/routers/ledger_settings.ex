defmodule Letflow.Routers.LedgerSettings do
  @moduledoc """
  The negative balance switch routes, mounted at `/ledger-settings` by `Letflow.Plugs.ApiPipeline`
  (REQ-835, decision 0090 section 5; pattern of `Letflow.Routers.ApprovalRules`).

  | Route | Policy key -> permission | Scope class | Answers |
  |---|---|---|---|
  | `GET /` | `:LedgerSettingsManage` | `:tenant_wide` | 200 `{"items": [...]}` |
  | `PUT /:registration` (body `allow_negative` boolean, `reason` string) | `:LedgerSettingsManage` | `:tenant_wide` | 200 item; 422 `invalid_body` / `invalid_reason` / `not_switchable`; 409 `concurrent_change`; 500 |

  Each item is exactly `registration`, `allow_negative` (false when no row), `changed_by`,
  `changed_by_name`, `changed_at`, `reason`.

  The handler checks, first, that the caller signed in interactively (`credential == :oidc`) and holds
  `:LedgerSettingsManage` tenant-wide (`Letflow.Api.Scope.require_tenant_wide/2`), so a scoped
  TENANT_ADMIN grant never counts in any scope-enforcement mode. Every refusal answers the same 403
  `insufficient permissions` body as `Letflow.Plugs.Authorize` (INV-5).

  The tenant comes only from the DB-resolved `conn.assigns.scoped_opts` and `auth_context` (INV-1);
  no route takes a tenant identifier and a `tenant_id` in the query or body is never read (INV-10).
  The submitted reason is never echoed.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.LedgerSettings

  authz_get "/", :LedgerSettingsManage, scope: :tenant_wide do
    guarded(conn, fn conn ->
      Response.ok(conn, %{"items" => Enum.map(LedgerSettings.list(prefix(conn)), &item/1)})
    end)
  end

  authz_put "/:registration", :LedgerSettingsManage, scope: :tenant_wide do
    guarded(conn, fn conn ->
      actor = %{user_id: conn.assigns.auth_context.user_id, trace_id: nil}

      case LedgerSettings.put(prefix(conn), conn.params["registration"], body(conn), actor) do
        {:ok, switched} -> Response.ok(conn, item(switched))
        {:error, reason} -> reply_error(conn, reason)
      end
    end)
  end

  authz_unmatched(:ordinary)

  defp guarded(conn, fun) do
    with true <- Map.get(conn.assigns.auth_context, :credential) == :oidc,
         {:ok, conn} <- Scope.require_tenant_wide(conn, :LedgerSettingsManage) do
      fun.(conn)
    else
      _ -> Response.forbidden(conn, "insufficient permissions")
    end
  end

  defp item(i) do
    %{
      "registration" => i.registration,
      "allow_negative" => i.allow_negative,
      "changed_by" => i.changed_by,
      "changed_by_name" => i.changed_by_name,
      "changed_at" => i.changed_at,
      "reason" => i.reason
    }
  end

  # Fixed text per reason: the submitted text is never echoed.
  defp reply_error(conn, :invalid_body), do: Response.unprocessable(conn, "invalid_body")
  defp reply_error(conn, :invalid_reason), do: Response.unprocessable(conn, "invalid_reason")
  defp reply_error(conn, :not_switchable), do: Response.unprocessable(conn, "not_switchable")
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
