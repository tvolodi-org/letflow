defmodule Letflow.Routers.TenantScopeEnforcement do
  @moduledoc """
  REQ-497 PR 1b (decision 0051 D12; design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` sections 3.4, 7.2, 8) -- the
  caller's own tenant's org-scope enforcement flag.

  Mounted at `/tenant/scope-enforcement` by `Letflow.Plugs.ApiPipeline`:

    * `GET  /`                    (`:ScopeEnforcementRead`) -> the mode;
    * `PUT  /`                    (`:ScopeEnforcementManage`) -> `Letflow.ScopeEnforcement.flip/4`;
    * `GET  /integrity`           (`:ScopeGrantsIntegrityRead`) -> `Letflow.ScopeEnforcement.integrity/1`;
    * `GET  /token-preconditions` (`:ScopeEnforcementTokensRead`) -> the flip-precondition
      token listing, audited as `token.listed`.

  Every key requires the tenant-scope permission `:UsersGroupsRolesManage` (the plug's
  403), and every handler then requires that permission to be held TENANT-WIDE
  (`Letflow.Api.Scope.require_tenant_wide/2`, 0051 D11), answering the same 403 otherwise.

  The tenant comes ONLY from `auth_context.tenant_id` and `scoped_opts[:prefix]`; the path
  has no tenant segment and no tenant value is read from the query or body (INV-1). Bodies
  are built field by field (INV-2); the token listing uses `Letflow.Api.TokenView`, which
  carries no hash or plaintext (INV-4).

  PUT body: `{"mode": "off" | "shadow", "reason": string?}`. Read directly rather than
  through `Letflow.Api.Validation`, so that every bad mode (missing, non-string, `"on"`)
  answers the one stable code `invalid_enforcement_mode`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.Api.TokenView
  alias Letflow.Audit
  alias Letflow.Identity.TokenPreconditions
  alias Letflow.ScopeEnforcement

  require Logger

  authz_get "/", :ScopeEnforcementRead do
    with_tenant_wide(conn, fn conn -> handle_get(conn) end)
  end

  authz_put "/", :ScopeEnforcementManage do
    with_tenant_wide(conn, fn conn -> handle_put(conn) end)
  end

  authz_get "/integrity", :ScopeGrantsIntegrityRead do
    with_tenant_wide(conn, fn conn -> handle_integrity(conn) end)
  end

  authz_get "/token-preconditions", :ScopeEnforcementTokensRead do
    with_tenant_wide(conn, fn conn -> handle_token_preconditions(conn) end)
  end

  authz_unmatched(:ordinary)

  @spec with_tenant_wide(Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  defp with_tenant_wide(conn, fun) do
    case Scope.require_tenant_wide(conn, :UsersGroupsRolesManage) do
      {:ok, conn} -> fun.(conn)
      {:error, conn, :not_tenant_wide} -> Response.forbidden(conn, "insufficient permissions")
    end
  end

  defp prefix(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
  defp tenant_id(conn), do: conn.assigns.auth_context.tenant_id

  # ── GET / ────────────────────────────────────────────────────────────────

  defp handle_get(conn) do
    case ScopeEnforcement.get_mode(tenant_id(conn)) do
      {:ok, mode} ->
        Response.ok(conn, %{
          "mode" => Atom.to_string(mode),
          "available_modes" => Enum.map(ScopeEnforcement.modes(), &Atom.to_string/1)
        })

      {:error, :tenant_not_found} ->
        Response.internal_error(conn)
    end
  end

  # ── PUT / ────────────────────────────────────────────────────────────────

  defp handle_put(conn) do
    body = if is_map(conn.body_params), do: conn.body_params, else: %{}

    case ScopeEnforcement.parse_mode(Map.get(body, "mode")) do
      {:error, :invalid_mode} ->
        Response.unprocessable(conn, "invalid_enforcement_mode")

      {:ok, target} ->
        attrs = %{
          actor_id: conn.assigns.auth_context.user_id,
          reason: Map.get(body, "reason"),
          trace_id: conn.assigns[:trace_id]
        }

        conn |> flip(target, attrs) |> flip_response(conn)
    end
  end

  defp flip(conn, target, attrs),
    do: ScopeEnforcement.flip(tenant_id(conn), prefix(conn), target, attrs)

  defp flip_response({:ok, %{mode: mode, previous: previous, changed: changed}}, conn) do
    Response.ok(conn, %{
      "mode" => Atom.to_string(mode),
      "previous" => Atom.to_string(previous),
      "changed" => changed
    })
  end

  defp flip_response({:error, :invalid_mode}, conn),
    do: Response.unprocessable(conn, "invalid_enforcement_mode")

  defp flip_response({:error, :reason_required}, conn),
    do: Response.unprocessable(conn, "reason_required")

  defp flip_response({:error, :invalid_reason}, conn),
    do: Response.unprocessable(conn, "invalid_reason")

  # Names the failing checks and the three counts/status only: no ids, no names (INV-2).
  defp flip_response({:error, {:precondition_failed, failed, report}}, conn) do
    problem = %{
      Error.conflict("enforcement_precondition_failed")
      | extensions: %{
          "failed" => Enum.map(failed, &Atom.to_string/1),
          "report" => %{
            "bindings_without_row" => report.bindings_without_row,
            "org_consistency" => Atom.to_string(report.org_consistency),
            "tokens_exceeding_owner" => report.tokens_exceeding_owner
          }
        }
    }

    Response.send_problem(conn, problem)
  end

  # SEC C-5: the 500 path logs ONE constant line, the reason tag and the exception module
  # only (no ids, no values, no exception message).
  defp flip_response({:error, server_fault}, conn) do
    {reason, exception} = fault_tags(server_fault)
    Logger.error("scope_enforcement_flip_failed reason=#{reason} exception=#{exception}")
    Response.internal_error(conn)
  end

  defp fault_tags({:transaction_failed, %{__struct__: module}}),
    do: {"transaction_failed", inspect(module)}

  defp fault_tags({:audit_failed, _detail}), do: {"audit_failed", "none"}
  defp fault_tags(:tenant_not_found), do: {"tenant_not_found", "none"}
  defp fault_tags(:tenant_prefix_mismatch), do: {"tenant_prefix_mismatch", "none"}
  defp fault_tags(_other), do: {"unknown", "none"}

  # ── GET /integrity ───────────────────────────────────────────────────────

  defp handle_integrity(conn) do
    report = ScopeEnforcement.integrity(prefix(conn))

    Response.ok(conn, %{
      "bindings_without_row" => report.bindings_without_row,
      "items" =>
        Enum.map(report.items, fn item ->
          %{"role_id" => item.role_id, "name" => item.name, "group_id" => item.group_id}
        end),
      "orphan_group_rows" => report.orphan_group_rows,
      "truncated" => report.truncated,
      "findings" => Enum.map(report.findings, &Atom.to_string/1),
      "on_gate" => on_gate_body(report.on_gate)
    })
  end

  # What the `on` flip will check (a lock-free snapshot, REQ-519 AC 9). Counts, enums and
  # booleans only: no ids, no names, no token data (INV-2).
  defp on_gate_body(on_gate) do
    evidence = on_gate.evidence
    counts = on_gate.counts

    %{
      "blocking" => Enum.map(on_gate.blocking, &Atom.to_string/1),
      "information" => %{
        "scoped_task_workers_without_task_scope" =>
          on_gate.information.scoped_task_workers_without_task_scope
      },
      "counts" => %{
        "bindings_without_row" => counts.bindings_without_row,
        "org_consistency" => Atom.to_string(counts.org_consistency),
        "tokens_exceeding_owner" => counts.tokens_exceeding_owner,
        "explicit_tenant_wide_admins" => counts.explicit_tenant_wide_admins,
        "scoped_approvers" => counts.scoped_approvers
      },
      "evidence" => %{
        "shadow_since" => evidence.shadow_since && DateTime.to_iso8601(evidence.shadow_since),
        "window_from" => Date.to_iso8601(evidence.window_from),
        "window_to" => Date.to_iso8601(evidence.window_to),
        "requests" => evidence.requests,
        "days_without_requests" => evidence.days_without_requests,
        "would_deny" =>
          Map.new(evidence.would_deny, fn {reason, count} -> {Atom.to_string(reason), count} end),
        "criteria" =>
          Map.new(evidence.criteria, fn {name, met?} -> {Atom.to_string(name), met?} end),
        "evidence_scope" => evidence.evidence_scope
      }
    }
  end

  # ── GET /token-preconditions ─────────────────────────────────────────────

  # N2: one audit entry per listing, in its own transaction, BEFORE any token data is
  # sent. A failed audit, or a raise from the listing or the audit insert, answers the
  # detail-free 500 with no token data (fail closed) and one constant log line.
  defp handle_token_preconditions(conn) do
    case audited_listing(conn) do
      {:ok, body} ->
        Response.ok(conn, body)

      {:error, reason} ->
        Logger.error("token_preconditions_listing_refused reason=#{reason}")
        Response.internal_error(conn)
    end
  end

  defp audited_listing(conn) do
    findings = TokenPreconditions.findings(prefix(conn))

    token_ids =
      [findings.roles_exceed_owner, findings.non_expiring_platform_admin, findings.null_issuer]
      |> Enum.concat()
      |> Enum.map(& &1.token.id)
      |> Enum.concat(Enum.flat_map(findings.service_principal_owner, & &1.token_ids))
      |> Enum.uniq()
      |> Enum.sort()

    case Audit.insert_entry(Letflow.Repo, listed_entry(conn, token_ids), prefix(conn)) do
      {:ok, _entry} ->
        {:ok,
         %{
           "flip_blocked" => findings.roles_exceed_owner != [],
           "blocking" => %{"roles_exceed_owner" => items(findings.roles_exceed_owner)},
           "information" => %{
             "non_expiring_platform_admin" => items(findings.non_expiring_platform_admin),
             "null_issuer" => items(findings.null_issuer),
             "service_principal_owner" =>
               Enum.map(findings.service_principal_owner, fn owner ->
                 %{"user_id" => owner.user_id, "token_ids" => owner.token_ids}
               end)
           },
           "count" => length(token_ids)
         }}

      {:error, _reason} ->
        {:error, "audit_failed"}
    end
  rescue
    _exception -> {:error, "exception"}
  end

  defp items(list), do: Enum.map(list, &TokenView.token_map(&1.token, &1.status))

  defp listed_entry(conn, token_ids) do
    actor_id = conn.assigns.auth_context.user_id

    %{
      actor_id: actor_id,
      action: "token.listed",
      resource_type: "api_token_listing",
      resource_id: tenant_id(conn),
      before_state: nil,
      after_state: %{"actor" => actor_id, "count" => length(token_ids), "token_ids" => token_ids},
      trace_id: conn.assigns[:trace_id]
    }
  end
end
