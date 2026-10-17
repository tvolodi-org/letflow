defmodule Letflow.Api.Scope.Shadow do
  @moduledoc """
  The shadow-mode observer (REQ-497 PR 1b, 0051 Rollout 3; design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 4.2).

  `Letflow.Plugs.Authorize` calls `observe/3` in its allow branch, after it assigned
  `scoped_opts`, only when the caller's tenant is in `shadow`. It computes
  `Letflow.Api.Scope.allowed?/3` for the route's permission against `:tenant_wide` and, on a
  would-deny, emits one telemetry event `[:letflow, :scope, :shadow, :would_deny]`
  (`%{count: 1}`, metadata `reason`, `policy`) and one sampled `Letflow.Api.Scope.ShadowLog`
  line. It DENIES NOTHING: it never halts, never changes status, body or assigns other than
  the grants memo, and never raises (any failure logs one constant line, once per boot per
  class and exception module, and the original conn is returned). No principal counts as
  `:grants_unavailable`.

  ## Declared class and persisted evidence (REQ-517 2b, AC 22)

  Every non-skipped request first records one `requests` count in
  `Letflow.Api.Scope.ShadowEvidence` (an ETS increment, no database), keyed by the plug's own
  `scoped_opts[:prefix]`; a would-deny also records its reason there. The route is evaluated by
  its class (`Letflow.Api.RouteScope.class_of/1`): `:tenant_wide`, `:admin_plane` and
  default-sourced routes are evaluated against `:tenant_wide`; `{:resolver, _}`, `:filter`
  and `:self_service` routes are counted as requests only (shadow cannot evaluate them; data
  path denials are proven by REQ-518's tests). The in-memory metric family
  `letflow_scope_shadow_would_deny_total` is unchanged and is not used for gating.
  """

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.RouteScope
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.ShadowEvidence
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
    prefix = evidence_prefix(conn)
    if prefix, do: ShadowEvidence.record(prefix, :requests)

    case RouteScope.class_of(conn.private) do
      {{:resolver, _fun}, _source} -> conn
      {:filter, _source} -> conn
      {:self_service, _source} -> conn
      {_tenant_wide_or_admin_plane, _source} -> evaluate(conn, policy_key, prefix)
    end
  end

  defp evaluate(conn, policy_key, prefix) do
    permission = Authorization.required_permission(policy_key)

    case Scope.principal_from_conn(conn) do
      {:ok, conn, principal} ->
        case Scope.allowed?(principal, permission, :tenant_wide) do
          {:allow, _basis} -> conn
          {:deny, reason} -> would_deny(conn, policy_key, permission, reason, prefix)
        end

      {:error, :no_principal} ->
        would_deny(conn, policy_key, permission, :grants_unavailable, prefix)
    end
  end

  # The plug's own prefix (INV-1); nil when the conn carries none (nothing is recorded).
  defp evidence_prefix(conn) do
    with opts when is_list(opts) <- Map.get(conn.assigns, :scoped_opts),
         prefix when is_binary(prefix) <- Keyword.get(opts, :prefix) do
      prefix
    else
      _none -> nil
    end
  end

  defp would_deny(conn, policy_key, permission, reason, prefix) do
    if prefix, do: ShadowEvidence.record(prefix, reason)
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
