defmodule Letflow.ScopeEnforcement do
  @moduledoc """
  The per-tenant org-scope enforcement flag (REQ-497 PR 1b / GH #2533, decision 0051 D12 and
  Rollout; design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 3).

  Two modes are SETTABLE: `off` and `shadow` (the scope decision is computed and counted,
  nothing is denied). A third value, `on`, is STORED since REQ-517 2b (#2535): the DB CHECK
  and the `Tenant` enum accept it and `Letflow.Plugs.Authorize` enforces it, but it is not
  parseable here and `flip/4` rejects it as `:invalid_mode`, so no route can set it until
  REQ-519 adds the guarded flip. A tenant stored as `on` can still be flipped back to
  `off` (with a reason). The flag is a column of
  the PUBLIC `tenants` row, read per request by both auth paths with no extra query, and
  written ONLY by `flip/4`.

  ## Flip (server-side preconditions)

  `flip/4` runs in one transaction: the tenant admin lock (A), the `tenants` row
  `FOR UPDATE` (T); a same-mode request returns unchanged with no audit; off -> shadow then
  takes the tenant's scope-tree table lock (S) and evaluates ALL three Rollout-4 facts
  (bindings without a grant row (T9), the scope-tree consistency, tokens whose roles exceed
  their owner's tenant-wide roles) and refuses with every failing one; shadow -> off needs a
  reason (`Letflow.Audit.Reason`). The update and its `scope.enforcement_enabled` /
  `scope.enforcement_disabled` audit entry commit together. A refused flip writes nothing.

  ## Integrity (`integrity/1`)

  The read-only grant-table integrity report behind
  `GET /api/v1/tenant/scope-enforcement/integrity` (REQ-497 open question 3, AC16): bindings
  without a row (T9, items capped at 1000), orphan group rows, and informational FINDINGS
  with stable codes. Finding `zero_tenant_wide_admins` (supervisor ruling 2026-10-15): the
  tenant has zero counted tenant-wide admins (`Letflow.Identity.count_tenant_wide_admins/1`).
  It is INFORMATIONAL in stage 1 and does NOT block the off -> shadow flip; it becomes a
  precondition of the stage-2 `on` flip (#2535).
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TokenPreconditions
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeNodePaths.Consistency
  alias Letflow.TenantProvisioning

  @modes [:off, :shadow]
  @stored_modes [:off, :shadow, :on]
  @integrity_items_cap 1000

  @type mode :: :off | :shadow
  @type stored_mode :: :off | :shadow | :on
  @type precondition :: :bindings_without_row | :org_inconsistent | :tokens_exceed_owner
  @type precondition_report :: %{
          bindings_without_row: non_neg_integer(),
          org_consistency: :ok | :inconsistent | :unavailable,
          tokens_exceeding_owner: non_neg_integer()
        }
  @type flip_error ::
          :invalid_mode
          | :reason_required
          | :invalid_reason
          | :tenant_not_found
          | :tenant_prefix_mismatch
          | {:precondition_failed, [precondition()], precondition_report()}
          | {:audit_failed, term()}
          | {:transaction_failed, Exception.t()}
  @type integrity_finding :: :zero_tenant_wide_admins
  @type integrity_report :: %{
          bindings_without_row: non_neg_integer(),
          items: [RoleScopeGrants.binding_without_row()],
          orphan_group_rows: non_neg_integer(),
          truncated: boolean(),
          findings: [integrity_finding()]
        }

  @doc "The settable modes, `[:off, :shadow]`."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "Every mode the column can store, `[:off, :shadow, :on]` (reads only; `on` is not settable)."
  @spec stored_modes() :: [stored_mode()]
  def stored_modes, do: @stored_modes

  @doc """
  Exactly the strings `"off"` and `"shadow"`. Every other value (`"on"`, `"ON"`, `nil`,
  non-strings) is `{:error, :invalid_mode}`. No atom is minted from input.
  """
  @spec parse_mode(term()) :: {:ok, mode()} | {:error, :invalid_mode}
  def parse_mode("off"), do: {:ok, :off}
  def parse_mode("shadow"), do: {:ok, :shadow}
  def parse_mode(_other), do: {:error, :invalid_mode}

  @doc "The tenant's current mode (one read of the public `tenants` row)."
  @spec get_mode(tenant_id :: Ecto.UUID.t()) ::
          {:ok, stored_mode()} | {:error, :tenant_not_found}
  def get_mode(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(tenant_id),
         # MUTANT N15: two-value guard
         mode when mode in @modes <-
           Repo.one(from(t in Tenant, where: t.id == ^id, select: t.scope_enforcement)) do
      {:ok, mode}
    else
      _missing -> {:error, :tenant_not_found}
    end
  end

  @doc """
  The three Rollout-4 facts for the tenant schema `prefix`. Read-only, no audit. Inside the
  flip it sees the flip transaction's locks.
  """
  @spec preconditions(prefix :: String.t()) :: precondition_report()
  def preconditions(prefix) when is_binary(prefix) do
    org_consistency =
      case Consistency.check(prefix) do
        {:ok, %{status: status}} -> status
        {:error, _reason} -> :unavailable
      end

    %{
      bindings_without_row: RoleScopeGrants.bindings_without_row_count(prefix),
      org_consistency: org_consistency,
      tokens_exceeding_owner: TokenPreconditions.exceeding_owner_count(prefix)
    }
  end

  @doc """
  Flips the tenant's mode to `target` (see the moduledoc). `prefix` must be the tenant's
  own schema. `attrs.reason` is mandatory for `:off` and validated when present for
  `:shadow`. A same-mode request returns `changed: false` with no write, audit or
  precondition check.
  """
  @spec flip(
          tenant_id :: Ecto.UUID.t(),
          prefix :: String.t(),
          target :: mode(),
          attrs :: %{actor_id: Ecto.UUID.t() | nil, reason: term(), trace_id: String.t() | nil}
        ) ::
          {:ok, %{mode: mode(), previous: stored_mode(), changed: boolean()}}
          | {:error, flip_error()}
  def flip(tenant_id, prefix, target, attrs) when is_binary(prefix) and is_map(attrs) do
    with :ok <- check_target(target),
         :ok <- check_prefix(tenant_id, prefix),
         {:ok, reason} <- check_reason(target, Map.get(attrs, :reason)) do
      try do
        Repo.transaction(fn -> do_flip(tenant_id, prefix, target, reason, attrs) end)
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  defp check_target(target) when target in @modes, do: :ok
  defp check_target(_target), do: {:error, :invalid_mode}

  defp check_prefix(tenant_id, prefix) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, ^prefix} -> :ok
      _other -> {:error, :tenant_prefix_mismatch}
    end
  end

  defp check_reason(:off, nil), do: {:error, :reason_required}
  defp check_reason(:shadow, nil), do: {:ok, nil}

  defp check_reason(_target, reason) do
    case Letflow.Audit.Reason.validate(reason) do
      {:ok, trimmed} -> {:ok, trimmed}
      :error -> {:error, :invalid_reason}
    end
  end

  defp do_flip(tenant_id, prefix, target, reason, attrs) do
    # Rank A, then T (lock order of design section 10).
    Identity.lock_tenant_admins!(prefix)

    tenant =
      Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:tenant_not_found)

    previous = tenant.scope_enforcement

    if previous == target do
      %{mode: target, previous: previous, changed: false}
    else
      report = if target == :shadow, do: enable_checks!(prefix)
      Repo.update!(Tenant.scope_enforcement_changeset(tenant, %{scope_enforcement: target}))

      case Audit.insert_entry(
             Repo,
             flip_entry(tenant_id, previous, target, reason, report, attrs),
             prefix
           ) do
        {:ok, _entry} -> %{mode: target, previous: previous, changed: true}
        {:error, audit_error} -> Repo.rollback({:audit_failed, audit_error})
      end
    end
  end

  # off -> shadow: rank S (no tree write can commit between the check and the flip), then
  # ALL three facts, so the refusal names every failure.
  defp enable_checks!(prefix) do
    :ok = ScopeNodePaths.lock!(prefix)
    report = preconditions(prefix)

    failed =
      [
        {:bindings_without_row, report.bindings_without_row > 0},
        {:org_inconsistent, report.org_consistency != :ok},
        {:tokens_exceed_owner, report.tokens_exceeding_owner > 0}
      ]
      |> Enum.filter(fn {_name, failed?} -> failed? end)
      |> Enum.map(fn {name, _failed?} -> name end)

    if failed != [], do: Repo.rollback({:precondition_failed, failed, report})

    report
  end

  defp flip_entry(tenant_id, previous, target, reason, report, attrs) do
    after_state = %{"mode" => Atom.to_string(target), "reason" => reason}

    after_state =
      if report,
        do:
          Map.put(after_state, "preconditions", %{
            "bindings_without_row" => report.bindings_without_row,
            "org_consistency" => Atom.to_string(report.org_consistency),
            "tokens_exceeding_owner" => report.tokens_exceeding_owner
          }),
        else: after_state

    %{
      actor_id: Map.get(attrs, :actor_id),
      action:
        if(target == :shadow, do: "scope.enforcement_enabled", else: "scope.enforcement_disabled"),
      resource_type: "tenant",
      resource_id: tenant_id,
      before_state: %{"mode" => Atom.to_string(previous)},
      after_state: after_state,
      trace_id: Map.get(attrs, :trace_id)
    }
  end

  @doc """
  The grant-table integrity report for the tenant schema `prefix` (see the moduledoc).
  Read-only, no audit, no lock.
  """
  @spec integrity(prefix :: String.t()) :: integrity_report()
  def integrity(prefix) when is_binary(prefix) do
    gaps = RoleScopeGrants.bindings_without_row(prefix)

    findings =
      if Identity.count_tenant_wide_admins(prefix) == 0, do: [:zero_tenant_wide_admins], else: []

    %{
      bindings_without_row: length(gaps),
      items: Enum.take(gaps, @integrity_items_cap),
      orphan_group_rows: length(RoleScopeGrants.orphan_group_rows(prefix)),
      truncated: length(gaps) > @integrity_items_cap,
      findings: findings
    }
  end
end
