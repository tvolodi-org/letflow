defmodule Letflow.Release.ScopeBreakGlass do
  @moduledoc """
  GH #2883 -- the operator break-glass for a tenant whose scope enforcement is stored `on`
  (design `lib/letflow/design/gh2883-scope-enforcement-break-glass.md`, section 3; decision
  0051 A11). It changes `tenants.scope_enforcement` from `on` to `shadow` or `off` and writes
  one `scope.enforcement_disabled` audit entry with a NULL actor, the operator label and the
  node name, through `Letflow.ScopeEnforcement.flip_out_of_band/3`. It reads no user, group,
  token or binding row, so it works when no interactive admin can log in.

  There is NO HTTP route and no role: the authority is host access to the running node. The
  operator label is an ATTESTATION, not an authenticated identity.

  Call it through the running node, feeding the expression on stdin (see
  `docs/runbooks/scope-enforcement-on.md`):

      Letflow.Release.ScopeBreakGlass.run("<slug>", "shadow", "<reason>", "<operator>", dry_run: true)
      Letflow.Release.ScopeBreakGlass.run("<slug>", "shadow", "<reason>", "<operator>", confirm: "<slug>")

  `bin/letflow eval` is NOT supported: it does not start `Letflow.Repo`. The Mix task
  `mix letflow.scope_enforcement.break_glass` is a wrapper for dev and CI hosts only.

  `run/5` prints exactly one result line (`OK`, `DRYRUN` or `ERROR`, preceded by a `TARGET` line
  once the tenant is resolved) with `IO.puts` (rpc forwards stdout) and ALSO returns it. It
  NEVER calls `System.halt`: a halt inside `rpc` would stop the live node. Only the Mix task
  halts, from `exit_code/1`.

  The name sits under `Letflow.Release.` without defining `Letflow.Release`, so it cannot
  collide with the wrapper module of GH #2567.

  ## Output and logs (INV-4)

  Output holds the slug as typed (through `inspect/1`), the modes, the audit action name and a
  boolean. NEVER a tenant id, schema name, user or token id, the reason, the operator label, the
  node name or an exception message. Logs are constant lines; the operator label appears in them
  ONLY when it passes `Letflow.ScopeEnforcement.valid_operator_label?/1`.
  """

  require Logger

  alias Letflow.Identity
  alias Letflow.ScopeEnforcement
  alias Letflow.TenantProvisioning

  @max_slug_bytes 128

  @type release_error ::
          :unknown_tenant
          | :invalid_target
          | :confirm_required
          | :confirm_mismatch
          | ScopeEnforcement.out_of_band_error()

  @type result ::
          {:ok, %{outcome: :applied | :dry_run, previous: :on, mode: :shadow | :off}}
          | {:error, release_error()}

  @doc """
  Turns enforcement off (`"off"`) or to shadow (`"shadow"`) for the tenant with slug `slug`.

  `opts`: `dry_run: true` reads and validates and writes nothing; `confirm: slug` is required
  for a real run and must equal `slug` exactly. Unknown keys are ignored. Order of checks:
  target, reason, operator, slug, (real run only) confirm, then the writer. The first failing
  check answers; none of them writes.
  """
  @spec run(
          slug :: String.t(),
          target :: String.t(),
          reason :: term(),
          operator :: term(),
          opts :: keyword()
        ) :: result()
  def run(slug, target, reason, operator, opts \\ []) do
    result = do_run(slug, target, reason, operator, opts)
    report(result, slug, operator)
    result
  end

  @doc "Maps a `run/5` result to a process exit status (used by the Mix task only)."
  @spec exit_code(result()) :: 0 | 1
  def exit_code({:ok, _result}), do: 0
  def exit_code({:error, _reason}), do: 1

  # -------------------------------------------------------------------------

  defp do_run(slug, target, reason, operator, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    confirm = Keyword.get(opts, :confirm)

    with {:ok, target_mode} <- parse_target(target),
         {:ok, trimmed_reason} <-
           ScopeEnforcement.check_out_of_band_inputs(target_mode, reason, operator),
         {:ok, tenant_id, mode} <- resolve(slug) do
      IO.puts("TARGET slug=#{inspect(slug)} current_mode=#{mode} target=#{target_mode}")

      if dry_run? do
        dry_run(mode, target_mode)
      else
        with :ok <- check_confirm(slug, confirm) do
          apply_flip(tenant_id, target_mode, trimmed_reason, operator)
        end
      end
    end
  end

  defp parse_target(target), do: ScopeEnforcement.parse_out_of_band_target(target)

  defp dry_run(:on, target_mode) do
    IO.puts("DRYRUN would_change=true")
    {:ok, %{outcome: :dry_run, previous: :on, mode: target_mode}}
  end

  defp dry_run(mode, _target_mode), do: {:error, {:not_enforced, mode}}

  defp check_confirm(_slug, nil), do: {:error, :confirm_required}
  defp check_confirm(slug, slug), do: :ok
  defp check_confirm(_slug, _other), do: {:error, :confirm_mismatch}

  defp apply_flip(tenant_id, target_mode, reason, operator) do
    case ScopeEnforcement.flip_out_of_band(tenant_id, target_mode, %{
           operator: operator,
           reason: reason
         }) do
      {:ok, %{mode: mode}} -> {:ok, %{outcome: :applied, previous: :on, mode: mode}}
      {:error, :tenant_not_found} -> {:error, :unknown_tenant}
      {:error, _reason} = error -> error
    end
  end

  # The slug selects the tenant by exact match against the public `tenants` table; nothing the
  # operator types is ever used as a schema name. Every failure is the same `:unknown_tenant`.
  defp resolve(slug) when is_binary(slug) and byte_size(slug) in 1..@max_slug_bytes do
    with true <- String.valid?(slug) and not String.contains?(slug, <<0>>),
         {:ok, tenant} <- Identity.get_tenant_by_slug(slug),
         {:ok, _schema} <- TenantProvisioning.registered_schema(tenant.id),
         {:ok, mode} <- ScopeEnforcement.get_mode(tenant.id) do
      {:ok, tenant.id, mode}
    else
      _unknown -> {:error, :unknown_tenant}
    end
  end

  defp resolve(_slug), do: {:error, :unknown_tenant}

  # -- printing and logging --------------------------------------------------------------------

  defp report({:ok, %{outcome: :applied, mode: mode}}, slug, operator) do
    IO.puts(
      "OK slug=#{inspect(slug)} previous=on mode=#{mode} action=scope.enforcement_disabled " <>
        "shadow_window_restarted=#{mode == :shadow}"
    )

    Logger.info("scope_break_glass_applied previous=on mode=#{mode} operator=#{operator}")
  end

  defp report({:ok, %{outcome: :dry_run}}, _slug, _operator), do: :ok

  defp report({:error, {:audit_failed, _error}}, _slug, operator) do
    IO.puts("ERROR server_fault")

    Logger.error(
      "scope_break_glass_failed reason=audit_failed exception=none" <> operator_suffix(operator)
    )
  end

  defp report({:error, {:transaction_failed, exception}}, _slug, operator) do
    IO.puts("ERROR server_fault")

    Logger.error(
      "scope_break_glass_failed reason=transaction_failed exception=#{inspect(exception.__struct__)}" <>
        operator_suffix(operator)
    )
  end

  defp report({:error, {:not_enforced, mode}}, _slug, operator) do
    IO.puts("ERROR not_enforced current_mode=#{mode}")
    refused("not_enforced", operator)
  end

  defp report({:error, tag}, _slug, operator) when is_atom(tag) do
    IO.puts("ERROR #{tag}")
    refused(Atom.to_string(tag), operator)
  end

  defp refused(tag, operator) do
    Logger.warning("scope_break_glass_refused reason=#{tag}" <> operator_suffix(operator))
  end

  defp operator_suffix(operator) do
    if ScopeEnforcement.valid_operator_label?(operator),
      do: " operator=" <> operator,
      else: ""
  end
end
