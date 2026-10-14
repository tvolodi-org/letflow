defmodule Letflow.Api.Scope.Shadow do
  @moduledoc """
  The shadow-mode observer (REQ-497 PR 1b, 0051 Rollout 3; design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 4.2).

  `Letflow.Plugs.Authorize` calls `observe/3` in its allow branch, after it assigned
  `scoped_opts`, only when the caller's tenant is in `shadow`. It computes
  `Letflow.Api.Scope.allowed?/3` for the route's permission against `:tenant_wide` (routes
  declare no resource scope in stage 1) and, on a would-deny, emits one telemetry event
  `[:letflow, :scope, :shadow, :would_deny]` (`%{count: 1}`, metadata `reason`, `policy`)
  and one sampled `Letflow.Api.Scope.ShadowLog` line. It DENIES NOTHING: it never halts,
  never changes status, body or assigns other than the grants memo, and never raises (any
  failure logs one constant line, once per boot per class and exception module, and the
  original conn is returned). No principal counts as `:grants_unavailable`.
  """

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.ShadowLog

  @skipped_keys [:Unknown, :UnmatchedRoute, :UnmatchedPlatformPath, :MetricsRead]
  @event [:letflow, :scope, :shadow, :would_deny]

  @doc """
  Observes one authorized request under `shadow`. Returns the conn, possibly carrying the
  grants memo. See the moduledoc.
  """
  @spec observe(Plug.Conn.t(), Authorization.AccessContext.t(), policy_key :: atom()) ::
          Plug.Conn.t()
  def observe(conn, _ctx, policy_key) when policy_key in @skipped_keys, do: conn

  def observe(conn, _ctx, policy_key) do
    do_observe(conn, policy_key)
  rescue
    e -> note_failure(conn, :error, e.__struct__)
  catch
    kind, _reason -> note_failure(conn, kind, nil)
  end

  defp do_observe(conn, policy_key) do
    permission = Authorization.required_permission(policy_key)

    case Scope.principal_from_conn(conn) do
      {:ok, conn, principal} ->
        case Scope.allowed?(principal, permission, :tenant_wide) do
          {:allow, _basis} -> conn
          {:deny, reason} -> would_deny(conn, policy_key, permission, reason)
        end

      {:error, :no_principal} ->
        would_deny(conn, policy_key, permission, :grants_unavailable)
    end
  end

  defp would_deny(conn, policy_key, permission, reason) do
    :telemetry.execute(@event, %{count: 1}, %{reason: reason, policy: policy_key})
    :ok = ShadowLog.log_would_deny(conn, policy_key, permission, reason)
    conn
  end

  # Constants plus class and exception module name only, once per boot per pair.
  defp note_failure(conn, class, mod) do
    flag = {__MODULE__, :failure_noted, class, mod}

    if :persistent_term.get(flag, nil) == nil do
      :persistent_term.put(flag, true)

      Logger.warning(
        "scope_shadow_failed class=#{class} exception=#{if mod, do: inspect(mod), else: "none"}"
      )
    end

    conn
  rescue
    _ -> conn
  catch
    _kind, _reason -> conn
  end
end
