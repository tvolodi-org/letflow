defmodule Letflow.Identity.TenantAdminGuard do
  @moduledoc """
  The N1 last-tenant-wide-admin guard of decision 0051 (REQ-497 PR 1b / GH #2533; design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 6). One helper set for
  every path that can remove the last tenant-wide administrator, so no path invents its own
  refusal shape or event name (0051 D8).

  ## Shared contract (binding; pinned with GH #2564)

    * function error: `{:error, :last_tenant_wide_admin}`;
    * HTTP: 409 with code `last_tenant_wide_admin`;
    * event: `tenant_admin.guard_refused`, its `after_state` keys EXACTLY `"action"`,
      `"actor"`, `"target_id"`, `"reason_code"`, `"counted_admins"`, `"trace_id"`;
    * `reason_code`: `"last_tenant_wide_admin"` by default (every N1 path), or, for the
      GH #2869 last-interactive-admin guard, `"last_interactive_tenant_wide_admin"` (function
      error `{:error, :last_interactive_tenant_wide_admin}`, HTTP 409 with that code);
    * `action`: `unbind_tenant_admin` (POST /roles kind change), `remove_tenant_admin_member`,
      `rebind_tenant_admin`, `revoke_pending_grant`, `revoke_token`, (#2564)
      `deactivate_user`, and (#2869) `flag_service_principal`.

  ## Last interactive administrator (GH #2869 part (a))

  `ensure_interactive_admin_remains!/4` is the second guard. It counts with
  `Letflow.Identity.count_interactive_explicit_tenant_wide_admins/1` (the SAME counter gate
  fact `zero_tenant_wide_admins` uses; this module builds no query of its own) and applies the
  transition rule: refuse only when the count goes from above 0 to 0 AND the tenant is stored
  `on` (`Letflow.ScopeEnforcement.mode_under_lock!/1`, read after lock A and only in that one
  case; an unreadable mode raises and rolls the write back, fail closed). It runs after the N1
  guard, which keeps its own error when both would fire.

  ## Protocol

  Inside the guarded transaction, after `Letflow.Identity.lock_tenant_admins!/1` (lock A):
  `lock_admin_binding!/1` where the path needs the binding row (rank R), the write, then
  `ensure_admins_remain!/3`, which counts with `Letflow.Identity.count_tenant_wide_admins/1`
  and rolls the whole transaction back with `{:tenant_admin_guard, refusal}`. The binding,
  membership and rebind paths use the transition rule (`count_before!/1` before the write:
  refuse only when the count goes from above 0 to 0); `revoke_token` guards a counted token
  on the after-count. After the transaction has returned that value, the public function
  calls `refuse/4`, which writes the event in its OWN transaction (the guarded change and its
  own audit entry stay rolled back) and returns `{:error, :last_tenant_wide_admin}`.
  `refuse/3,4` is the single event writer, so it can delegate to GH #2564's shared writer.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo
  alias Letflow.ScopeEnforcement

  require Logger

  @tenant_admin_role "TENANT_ADMIN"
  @event "tenant_admin.guard_refused"
  @reason_code "last_tenant_wide_admin"
  @interactive_reason_code "last_interactive_tenant_wide_admin"

  @type action ::
          :unbind_tenant_admin
          | :remove_tenant_admin_member
          | :rebind_tenant_admin
          | :revoke_pending_grant
          | :revoke_token
          | :deactivate_user
          | :scope_tenant_admin
          | :revoke_tenant_admin_grant
          | :flag_service_principal

  # The refusal event keeps the N1 contract: the six keys incl. `target_id` (the id already in
  # the request); `counted_admins` is 0 and the 409 body carries no id and no count.
  @type refusal :: %{
          required(:action) => action(),
          required(:target_id) => String.t(),
          required(:counted_admins) => non_neg_integer(),
          optional(:reason_code) => String.t()
        }

  @type refuse_opt :: {:platform_companion, platform_prefix :: String.t()}

  @typedoc "Which admin count a guarded path uses (REQ-517 finding F1)."
  @type counter :: :counted | :explicit | :interactive_explicit

  @doc """
  Locks the `tenant_role` row named `TENANT_ADMIN` (no `kind` filter) `FOR UPDATE` in the
  tenant schema `prefix` and returns it, or `nil` when there is none. Rank R of the lock
  order: the caller already holds lock A. Raises `ArgumentError` outside a transaction.
  """
  @spec lock_admin_binding!(prefix :: String.t()) :: TenantRole.t() | nil
  def lock_admin_binding!(prefix) when is_binary(prefix) do
    ensure_in_transaction!("lock_admin_binding!/1")

    Repo.one(
      from(t in TenantRole, where: t.name == ^@tenant_admin_role, lock: "FOR UPDATE"),
      prefix: prefix
    )
  end

  @doc """
  The group the `TENANT_ADMIN` binding points to when the binding is a `:platform_role`,
  else `nil`. Pure.
  """
  @spec admin_group_id(TenantRole.t() | nil) :: Ecto.UUID.t() | nil
  def admin_group_id(%TenantRole{kind: :platform_role, group_id: group_id}), do: group_id
  def admin_group_id(_binding_or_nil), do: nil

  @doc """
  The before-count of the transition rule: `Letflow.Identity.count_tenant_wide_admins/1`,
  taken under lock A after the path's row locks and BEFORE its write. Raises
  `ArgumentError` outside a transaction.
  """
  @spec count_before!(prefix :: String.t()) :: non_neg_integer()
  def count_before!(prefix), do: count_before!(prefix, :counted)

  @doc """
  REQ-517: `count_before!/1` with a counter. `:counted` is
  `Letflow.Identity.count_tenant_wide_admins/1`; `:explicit` is
  `Letflow.Identity.count_explicit_tenant_wide_admins/1` (used by `revoke_tenant_admin_grant`,
  design finding F1).
  """
  @spec count_before!(prefix :: String.t(), counter()) :: non_neg_integer()
  def count_before!(prefix, counter) when is_binary(prefix) do
    ensure_in_transaction!("count_before!/2")
    count(prefix, counter)
  end

  defp count(prefix, :counted), do: Identity.count_tenant_wide_admins(prefix)
  defp count(prefix, :explicit), do: Identity.count_explicit_tenant_wide_admins(prefix)

  defp count(prefix, :interactive_explicit),
    do: Identity.count_interactive_explicit_tenant_wide_admins(prefix)

  @doc """
  GH #2869 (a): the second guard, after the write and after the N1 guard, in the same
  transaction under lock A. `before_count` is `count_before!(prefix, :interactive_explicit)`
  taken before the write. `0` is `:ok` (the write removed nobody). Otherwise the interactive
  count is taken after the write; above 0 is `:ok`. At 0 the stored mode is read
  (`ScopeEnforcement.mode_under_lock!/1`): `:on` rolls back with `{:tenant_admin_guard,
  refusal}` (`counted_admins` 0, `reason_code` `"last_interactive_tenant_wide_admin"`),
  `:shadow` and `:off` are `:ok`. A raise from the mode read propagates (fail closed).
  Raises `ArgumentError` outside a transaction.
  """
  @spec ensure_interactive_admin_remains!(
          prefix :: String.t(),
          action(),
          target_id :: String.t(),
          before_count :: non_neg_integer()
        ) :: :ok
  def ensure_interactive_admin_remains!(prefix, action, target_id, before_count)
      when is_binary(prefix) do
    ensure_in_transaction!("ensure_interactive_admin_remains!/4")

    case interactive_admin_check(prefix, before_count) do
      :ok -> :ok
      :refused -> Repo.rollback({:tenant_admin_guard, interactive_refusal(action, target_id)})
    end
  end

  @doc """
  The decision of `ensure_interactive_admin_remains!/4` without the rollback, for a caller
  that is an `Ecto.Multi` step (`update_locked_user`): `:ok` or `:refused`. Same transaction,
  same lock, same fail-closed mode read. Raises `ArgumentError` outside a transaction.
  """
  @spec interactive_admin_check(prefix :: String.t(), before_count :: non_neg_integer()) ::
          :ok | :refused
  def interactive_admin_check(prefix, before_count) when is_binary(prefix) do
    ensure_in_transaction!("interactive_admin_check/2")

    cond do
      before_count == 0 -> :ok
      count(prefix, :interactive_explicit) > 0 -> :ok
      ScopeEnforcement.mode_under_lock!(prefix) == :on -> :refused
      true -> :ok
    end
  end

  @doc "The refusal map of the last-interactive-admin guard (`counted_admins` is 0)."
  @spec interactive_refusal(action(), target_id :: String.t()) :: refusal()
  def interactive_refusal(action, target_id),
    do: %{
      action: action,
      target_id: target_id,
      counted_admins: 0,
      reason_code: @interactive_reason_code
    }

  @doc "`ensure_admins_remain!(prefix, action, target_id, :not_measured)` (state rule)."
  @spec ensure_admins_remain!(prefix :: String.t(), action(), target_id :: String.t()) :: :ok
  def ensure_admins_remain!(prefix, action, target_id),
    do: ensure_admins_remain!(prefix, action, target_id, :not_measured)

  @doc """
  After the guarded write, in the same transaction. The ONE place the N1 count rule lives:

    * `before_count` a non-negative integer (from `count_before!/1`): the TRANSITION rule
      (supervisor ruling 2026-10-15, used by `unbind_tenant_admin`,
      `remove_tenant_admin_member`, `rebind_tenant_admin`): refuse only when `before_count`
      was above 0 AND the count after the write is 0. A tenant already at 0 is not refused
      (the write did not remove the last admin);
    * `:not_measured`: the STATE rule (`revoke_token`, whose caller only guards a token that
      was counted at lock time): refuse when the count after the write is 0.

  A refusal is `Repo.rollback({:tenant_admin_guard, refusal})` with `counted_admins: 0`.
  Raises `ArgumentError` outside a transaction.
  """
  @spec ensure_admins_remain!(
          prefix :: String.t(),
          action(),
          target_id :: String.t(),
          before_count :: non_neg_integer() | :not_measured
        ) :: :ok
  def ensure_admins_remain!(prefix, action, target_id, before_count),
    do: ensure_admins_remain!(prefix, action, target_id, before_count, :counted)

  @doc "`ensure_admins_remain!/4` counting with `counter` (REQ-517; default `:counted`)."
  @spec ensure_admins_remain!(
          prefix :: String.t(),
          action(),
          target_id :: String.t(),
          before_count :: non_neg_integer() | :not_measured,
          counter()
        ) :: :ok
  def ensure_admins_remain!(prefix, action, target_id, before_count, counter)
      when is_binary(prefix) do
    ensure_in_transaction!("ensure_admins_remain!/5")

    if before_count == 0 do
      :ok
    else
      case count(prefix, counter) do
        0 ->
          Repo.rollback(
            {:tenant_admin_guard, %{action: action, target_id: target_id, counted_admins: 0}}
          )

        _positive ->
          :ok
      end
    end
  end

  @doc "`refuse(prefix, refusal, ctx, [])`."
  @spec refuse(prefix :: String.t(), refusal(), AuditContext.t()) ::
          {:error, :last_tenant_wide_admin | :last_interactive_tenant_wide_admin}
  def refuse(prefix, refusal, ctx), do: refuse(prefix, refusal, ctx, [])

  @doc """
  Records a refusal and returns `{:error, :last_tenant_wide_admin}` (or, when the refusal
  carries `reason_code` `"last_interactive_tenant_wide_admin"`, `{:error,
  :last_interactive_tenant_wide_admin}`). Called AFTER the
  guarded transaction returned its rollback value, i.e. outside any transaction; inside one
  it writes nothing (an inner write would roll back with the caller) and logs one constant
  line.

  ONE transaction of its own: a `tenant_admin.guard_refused` entry on the tenant chain
  (`prefix`) with the six contract keys; actor and trace come from `ctx`. With
  `platform_companion: platform_prefix` the tenant entry carries a nil actor and a nil trace
  (no platform user id ever enters a tenant chain) and a companion entry with the operator
  and the trace is written LAST on the platform chain; both commit or neither. An audit
  failure logs one constant line (no ids) and the refusal is still returned.
  """
  @spec refuse(prefix :: String.t(), refusal(), AuditContext.t(), [refuse_opt()]) ::
          {:error, :last_tenant_wide_admin | :last_interactive_tenant_wide_admin}
  def refuse(prefix, %{action: action} = refusal, ctx, opts)
      when is_binary(prefix) and is_list(opts) do
    if Repo.in_transaction?() do
      Logger.error("tenant_admin_guard_refusal_not_recorded reason=inside_transaction")
    else
      write_refusal(prefix, refusal, ctx, Keyword.get(opts, :platform_companion))
    end

    refusal_error(refusal)
  rescue
    exception ->
      Logger.error(
        "tenant_admin_guard_refusal_not_recorded exception=#{inspect(exception.__struct__)} action=#{action}"
      )

      refusal_error(refusal)
  end

  defp refusal_error(%{reason_code: @interactive_reason_code}),
    do: {:error, :last_interactive_tenant_wide_admin}

  defp refusal_error(_refusal), do: {:error, :last_tenant_wide_admin}

  # The common case: the shared writer from GH 2564 (one transaction, the six contract
  # keys, never raises); only the kind of the refused target differs per action.
  defp write_refusal(prefix, refusal, ctx, nil) do
    Identity.record_guard_refused(prefix, %{
      action: Atom.to_string(refusal.action),
      actor: Map.get(ctx, :actor_id),
      target_id: refusal.target_id,
      reason_code: Map.get(refusal, :reason_code, @reason_code),
      counted_admins: refusal.counted_admins,
      trace_id: Map.get(ctx, :trace_id),
      resource_type: resource_type(refusal.action)
    })
  end

  defp write_refusal(prefix, refusal, ctx, platform_prefix) when is_binary(platform_prefix) do
    tenant_entry = entry(refusal, nil, nil)

    platform_entry =
      refusal
      |> entry(Map.get(ctx, :actor_id), Map.get(ctx, :trace_id))
      |> Map.put(:resource_type, "pending_admin_grant")

    commit_entries([{tenant_entry, prefix}, {platform_entry, platform_prefix}], refusal.action)
  end

  # Writes the entries in order inside one transaction; the platform chain is last.
  defp commit_entries(entries, action) do
    result =
      Repo.transaction(fn ->
        Enum.each(entries, fn {attrs, chain_prefix} ->
          case Audit.insert_entry(Repo, attrs, chain_prefix) do
            {:ok, _entry} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, _reason} ->
        Logger.error(
          "tenant_admin_guard_refusal_not_recorded reason=audit_failed action=#{action}"
        )

        :ok
    end
  end

  defp entry(%{action: action, target_id: target_id, counted_admins: counted}, actor, trace) do
    %{
      actor_id: actor,
      action: @event,
      resource_type: resource_type(action),
      resource_id: target_id,
      before_state: nil,
      after_state: %{
        "action" => Atom.to_string(action),
        "actor" => actor,
        "target_id" => target_id,
        "reason_code" => @reason_code,
        "counted_admins" => counted,
        "trace_id" => trace
      },
      trace_id: trace
    }
  end

  defp resource_type(action) when action in [:unbind_tenant_admin, :rebind_tenant_admin],
    do: "tenant_role"

  defp resource_type(:remove_tenant_admin_member), do: "group_member"
  defp resource_type(:revoke_token), do: "api_token"
  defp resource_type(:revoke_pending_grant), do: "pending_admin_grant"
  defp resource_type(:deactivate_user), do: "user"
  defp resource_type(:flag_service_principal), do: "user"

  # REQ-517 (finding F3): without these clauses `refuse/4` would raise `FunctionClauseError`
  # into its blanket rescue and silently lose the audit event.
  defp resource_type(action) when action in [:scope_tenant_admin, :revoke_tenant_admin_grant],
    do: "role_scope_grant"

  defp ensure_in_transaction!(function) do
    if not Repo.in_transaction?() do
      raise ArgumentError, "#{function} must run inside a transaction"
    end
  end
end
