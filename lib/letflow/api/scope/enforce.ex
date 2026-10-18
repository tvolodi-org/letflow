defmodule Letflow.Api.Scope.Enforce do
  @moduledoc """
  The enforcing sibling of `Letflow.Api.Scope.Shadow` (REQ-517 PR 2b / GH #2535, decision 0051
  D5, D11; design `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.3).

  `Letflow.Plugs.Authorize` calls `check/3` in its allow branch, after the unchanged coarse
  `Letflow.Api.Authorization.evaluate_access/2` allow and after it assigned `scoped_opts`,
  only when the caller's tenant is stored as `on`. It returns the conn unchanged, or a
  HALTED 403 / 500 conn. Decision, in order:

    1. the policy key is `:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath` or
       `:MetricsRead`: the conn is returned (their own handling is unchanged);
    2. the route's class is `Letflow.Api.RouteScope.class_of/1` of `conn.private`;
    3. `:self_service`: the conn is returned (tenant-level or own-data reads, REQ-518 AC 21);
       `{:resolver, _}` and `:filter`: the conn is returned with a before-send check registered
       (below); the handler applies the scope through `Letflow.Api.ScopeGate` (REQ-518);
    4. `:admin_plane`, `:tenant_wide` and a default-sourced (unclassified) route:
       `Letflow.Api.Scope.allowed?(principal, permission, :tenant_wide)`. An allow returns the
       conn. A deny, or no principal, emits `[:letflow, :scope, :enforce, :denied]`
       (`%{count: 1}`, metadata `policy` and `reason`; no metrics family), writes the
       attribution line through `Letflow.Api.AuthzDenyLog` and answers the unchanged uniform
       `403 insufficient permissions` (route-level, no resource revealed: no existence
       oracle);
    5. any raise, exit or throw (INV-8, AC 20): one constant line
       `scope_enforcement_failed class=<error|exit|throw> exception=<module|none>` per
       occurrence (no ids, no values) and a halted detail-free 500. NEVER an allow.

  ## Before-send backstop (REQ-518 SEC ruling R-4, DETECTIVE only)

  For `{:resolver, _}` and `:filter` routes (in this `on` branch only) a before-send callback
  turns a 2xx response sent WITHOUT the `Letflow.Api.ScopeGate` marker into the detail-free 500
  of `fail_closed/3` and logs one constant line `scope_not_applied` (no ids). It detects a handler
  that omitted `ScopeGate`; it does NOT make a response safe, and the marker proves "gate
  called", not "result applied" (the preventive controls are the per-route tests and the ledger).
  Every non-2xx response passes unchanged. The callback rescues itself and answers the same
  detail-free 500. Caveat (design OQ-8): a write already committed before the check still
  commits; write handlers therefore apply scope BEFORE writing. A handler that drops the conn
  `ScopeGate` returned loses the marker and gets a false 500 (fail closed, accepted).

  `:admin_plane` and `:tenant_wide` decide identically here; the difference is declarative
  (the D11 inventory, the route walk, and the handlers' own `require_tenant_wide/2`).
  """

  import Plug.Conn, only: [halt: 1, register_before_send: 2]

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.AuthzDenyLog
  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.RouteScope
  alias Letflow.Api.Scope
  alias Letflow.Api.ScopeGate

  @skipped_keys [:Unknown, :UnmatchedRoute, :UnmatchedPlatformPath, :MetricsRead]
  @event [:letflow, :scope, :enforce, :denied]

  @doc """
  Enforces the route's scope class for one authorized request of an `on` tenant (see the
  moduledoc). Returns the conn, or a halted 403 / 500 conn.
  """
  @spec check(Plug.Conn.t(), Authorization.AccessContext.t(), policy_key :: atom()) ::
          Plug.Conn.t()
  def check(conn, _ctx, policy_key) when policy_key in @skipped_keys, do: conn

  def check(conn, ctx, policy_key) do
    {class, _source} = RouteScope.class_of(conn.private)

    case class do
      {:resolver, _fun} -> require_scope_applied(conn)
      :filter -> require_scope_applied(conn)
      :self_service -> conn
      _admin_or_tenant_wide -> require_tenant_wide(conn, ctx, policy_key)
    end
  rescue
    e -> fail_closed(conn, :error, e.__struct__)
  catch
    kind, _reason -> fail_closed(conn, kind, nil)
  end

  defp require_scope_applied(conn), do: register_before_send(conn, &assert_scope_applied/1)

  # Runs when the response is about to be sent: only a 2xx without the ScopeGate marker is
  # replaced (detective control, moduledoc). It must never raise: any failure is the same
  # detail-free 500.
  defp assert_scope_applied(%Plug.Conn{status: status} = conn) when status in 200..299 do
    if ScopeGate.applied?(conn) do
      conn
    else
      Logger.error("scope_not_applied")
      replace_with_internal_error(conn)
    end
  rescue
    e -> fail_closed_unsent(conn, :error, e.__struct__)
  catch
    kind, _reason -> fail_closed_unsent(conn, kind, nil)
  end

  defp assert_scope_applied(conn), do: conn

  defp fail_closed_unsent(conn, class, mod) do
    log_failure(class, mod)
    replace_with_internal_error(conn)
  end

  defp replace_with_internal_error(conn),
    do: Response.put_problem(conn, Error.internal())

  defp require_tenant_wide(conn, ctx, policy_key) do
    permission = Authorization.required_permission(policy_key)

    case Scope.principal_from_conn(conn) do
      {:ok, conn, principal} ->
        case Scope.allowed?(principal, permission, :tenant_wide) do
          {:allow, _basis} -> conn
          {:deny, reason} -> deny(conn, ctx, policy_key, reason)
        end

      {:error, :no_principal} ->
        deny(conn, ctx, policy_key, :no_principal)
    end
  end

  defp deny(conn, ctx, policy_key, reason) do
    :telemetry.execute(@event, %{count: 1}, %{policy: policy_key, reason: reason})
    AuthzDenyLog.log_denial(conn, ctx, policy_key)
    conn |> Response.forbidden("insufficient permissions") |> halt()
  end

  # One constant line per occurrence: class and exception module name only (INV-4, INV-8).
  defp fail_closed(conn, class, mod) do
    log_failure(class, mod)
    conn |> Response.internal_error() |> halt()
  end

  defp log_failure(class, mod) do
    Logger.error(
      "scope_enforcement_failed class=#{class} exception=#{if mod, do: inspect(mod), else: "none"}"
    )
  end
end
