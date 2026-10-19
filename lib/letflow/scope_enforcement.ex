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

  ## The `on` gate (REQ-519 2f-a, dormant until 2f-b)

  The report also carries `on_gate` (design `req519-enforced-writers-and-flag-on.md` section
  4.4): `blocking` (the failing codes of `Letflow.ScopeEnforcement.OnGate`), `information`
  (`scoped_task_workers_without_task_scope`), `counts` and the shadow `evidence`, computed
  WITHOUT locks and WITHOUT audit (a labelled snapshot of what the `on` flip will check). It
  is a different list from `findings`: `findings` is the stage-1 informational list (its
  `zero_tenant_wide_admins` uses the OLD count so the off -> shadow gate is unchanged);
  `on_gate.blocking` computes `zero_tenant_wide_admins` from the INTERACTIVE EXPLICIT count
  (`Letflow.Identity.count_interactive_explicit_tenant_wide_admins/1`, SEC C-4).

  `flip/4` already contains the `shadow -> on` path (best-effort evidence flush before the
  transaction, `OnGate.evaluate/3` after the S lock inside the one `try`, the refusal audit
  of `Letflow.ScopeEnforcement.RefusedAudit` after the rollback, the `attrs[:now]` clock seam
  that only internal callers set), but `on` stays UNSETTABLE: `parse_mode/1` and
  `check_target/1` accept `off` and `shadow` only until REQ-519 2f-b widens them.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TokenPreconditions
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.ScopeEnforcement.RefusedAudit
  alias Letflow.ScopeEnforcement.ShadowWindow
  alias Letflow.ScopeNodePaths.Consistency
  alias Letflow.TenantProvisioning

  @modes [:off, :shadow]
  @stored_modes [:off, :shadow, :on]
  # Single owner of the flip audit vocabulary: `flip_entry/6`, `RefusedAudit` and
  # `ShadowWindow` (T0 = the latest flip entry) all read these.
  @enabled_action "scope.enforcement_enabled"
  @disabled_action "scope.enforcement_disabled"
  @resource_type "tenant"
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
          | :shadow_required
          | {:on_precondition_failed, [OnGate.on_precondition(), ...], OnGate.report()}
          | {:audit_failed, term()}
          | {:transaction_failed, Exception.t()}
  @type integrity_finding :: :zero_tenant_wide_admins
  @type on_gate_snapshot :: %{
          blocking: [OnGate.on_precondition()],
          information: %{scoped_task_workers_without_task_scope: non_neg_integer()},
          counts: %{
            bindings_without_row: non_neg_integer(),
            org_consistency: :ok | :inconsistent | :unavailable,
            tokens_exceeding_owner: non_neg_integer(),
            explicit_tenant_wide_admins: non_neg_integer(),
            scoped_approvers: non_neg_integer()
          },
          evidence: ShadowWindow.report()
        }
  @type integrity_report :: %{
          bindings_without_row: non_neg_integer(),
          items: [RoleScopeGrants.binding_without_row()],
          orphan_group_rows: non_neg_integer(),
          truncated: boolean(),
          findings: [integrity_finding()],
          on_gate: on_gate_snapshot()
        }

  @doc "The audit `resource_type` of every flag-flip entry (`\"tenant\"`)."
  @spec flip_resource_type() :: String.t()
  def flip_resource_type, do: @resource_type

  @doc "The audit actions of a successful flip: `[enabled, disabled]`."
  @spec flip_actions() :: [String.t()]
  def flip_actions, do: [@enabled_action, @disabled_action]

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

  defmodule ModeUnavailableError do
    @moduledoc """
    Raised by `Letflow.ScopeEnforcement.mode_under_lock!/1` when a tenant's mode cannot be
    resolved (the read failed, the prefix is not a tenant schema name, or the tenant has no
    `tenants` row). No fields and a constant message: nothing about the tenant leaks (INV-4).
    """
    defexception message: "scope enforcement mode unavailable"
  end

  @doc """
  The tenant's mode as seen by a WRITER (REQ-519 2e-a, design section 3.2). Must run inside a
  transaction that already holds the tenant admin lock (lock A,
  `Letflow.Identity.lock_tenant_admins!/1`): `flip/4` takes A first and commits the new mode
  while holding it, so after a writer acquires A the committed value is final for the writer's
  transaction. One plain primary-key read of the public `tenants` row, no row lock (no new
  lock rank). Ownership of lock A is documented, not probed (an advisory-lock probe would
  itself change lock state).

  Raises `ArgumentError` outside a transaction. RAISES `ModeUnavailableError` when the read
  fails, the prefix is not a `tenant_<32 hex>` schema name, or the tenant has no `tenants` row;
  it never answers `:off` for those (INV-8: no fail-open default on a flag read; the only
  exception is the test-only application key `:scope_mode_lenient_for_tests`, set in
  `config/test.exs` ONLY, which answers `:off` for the last two cases). The raise
  propagates out of the writer's transaction, which rolls back the whole call; sweeps report
  that tenant's error.
  """
  @spec mode_under_lock!(prefix :: String.t()) :: stored_mode()
  def mode_under_lock!(prefix) when is_binary(prefix) do
    if not Repo.in_transaction?() do
      raise ArgumentError, "mode_under_lock!/1 must run inside a transaction"
    end

    case read_stored_mode(prefix) do
      {:ok, mode} -> mode
      :unregistered -> unregistered_mode!()
      :unavailable -> raise ModeUnavailableError
    end
  end

  # `:unregistered` = a malformed prefix or a well-formed one with no `tenants` row;
  # `:unavailable` = the read itself failed (a missing `tenants` table included).
  defp read_stored_mode(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} ->
        case Repo.one(from(t in Tenant, where: t.id == ^tenant_id, select: t.scope_enforcement)) do
          mode when mode in @stored_modes -> {:ok, mode}
          nil -> :unregistered
          _other -> :unavailable
        end

      {:error, _reason} ->
        :unregistered
    end
  rescue
    _exception -> :unavailable
  end

  # TEST-ONLY leniency (design 3.2, SEC C-1): the application key is set in config/test.exs
  # and nowhere else; production never reaches the `:off` branch.
  defp unregistered_mode! do
    if Application.get_env(:letflow, :scope_mode_lenient_for_tests, false) == true do
      Logger.warning("scope_mode_read_lenient")
      :off
    else
      raise ModeUnavailableError
    end
  end

  @doc "The tenant's current mode (one read of the public `tenants` row)."
  @spec get_mode(tenant_id :: Ecto.UUID.t()) ::
          {:ok, stored_mode()} | {:error, :tenant_not_found}
  def get_mode(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(tenant_id),
         mode when mode in @stored_modes <-
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
          target :: stored_mode(),
          attrs :: %{
            :actor_id => Ecto.UUID.t() | nil,
            :reason => term(),
            :trace_id => String.t() | nil,
            optional(:now) => DateTime.t()
          }
        ) ::
          {:ok, %{mode: stored_mode(), previous: stored_mode(), changed: boolean()}}
          | {:error, flip_error()}
  def flip(tenant_id, prefix, target, attrs) when is_binary(prefix) and is_map(attrs) do
    with :ok <- check_target(target),
         :ok <- check_prefix(tenant_id, prefix),
         {:ok, reason} <- check_reason(target, Map.get(attrs, :reason)) do
      now = clock(attrs)

      # SEC S-4: flush the in-memory counters BEFORE the transaction (never extends lock hold
      # time); best-effort, a failed flush can only make the gate stricter.
      if flush_before?(target), do: ShadowWindow.flush_evidence()

      # The `rescue` encloses the WHOLE transaction, including OnGate.evaluate/3: a raise from
      # any gate fact is a rolled-back server fault, never a refusal (INV-8).
      result =
        try do
          Repo.transaction(fn -> do_flip(tenant_id, prefix, target, reason, attrs, now) end)
        rescue
          exception -> {:error, {:transaction_failed, exception}}
        end

      record_refusal(result, tenant_id, prefix, attrs)
      result
    end
  end

  # The one clock seam (SEC S-5): only an internal caller sets `attrs[:now]` (the router builds
  # a literal three-key map); anything but a `DateTime` is ignored.
  defp clock(attrs) do
    case Map.get(attrs, :now) do
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end

  # D-9 (AC 14): a refused flip to `on` is audited AFTER the rollback, in its own transaction.
  # A server fault ({:transaction_failed, _}, {:audit_failed, _}) is never recorded as one.
  defp record_refusal({:error, {:on_precondition_failed, failed, report}}, id, prefix, attrs),
    do: RefusedAudit.record(id, prefix, :shadow, failed, report, attrs)

  defp record_refusal({:error, :shadow_required}, id, prefix, attrs),
    do: RefusedAudit.record(id, prefix, :off, [:shadow_required], nil, attrs)

  defp record_refusal(_result, _id, _prefix, _attrs), do: :ok

  # The compiler infers `target` from check_target/1 (off or shadow) and flags a plain `:on`
  # comparison or clause as unreachable; the guard form keeps the dormant `on` path compiling
  # until 2f-b widens check_target/1.
  defp flush_before?(target), do: target in [:on]

  # `on` is deliberately NOT settable here (REQ-519 2f-b widens `@modes`).
  defp check_target(target) when target in @modes, do: :ok
  defp check_target(_target), do: {:error, :invalid_mode}

  defp check_prefix(tenant_id, prefix) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, ^prefix} -> :ok
      _other -> {:error, :tenant_prefix_mismatch}
    end
  end

  defp check_reason(:off, nil), do: {:error, :reason_required}
  defp check_reason(target, nil) when target in [:shadow, :on], do: {:ok, nil}

  defp check_reason(_target, reason) do
    case Letflow.Audit.Reason.validate(reason) do
      {:ok, trimmed} -> {:ok, trimmed}
      :error -> {:error, :invalid_reason}
    end
  end

  defp do_flip(tenant_id, prefix, target, reason, attrs, now) do
    # Rank A, then T (lock order of design section 10).
    Identity.lock_tenant_admins!(prefix)

    tenant =
      Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:tenant_not_found)

    previous = tenant.scope_enforcement

    cond do
      previous == target ->
        %{mode: target, previous: previous, changed: false}

      # `on` is reached only from `shadow` (D-6); nothing else is evaluated.
      target == :on and previous != :shadow ->
        Repo.rollback(:shadow_required)

      true ->
        report =
          case target do
            :on -> on_checks!(tenant_id, prefix, now)
            :shadow -> enable_checks!(prefix)
            _off -> nil
          end

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

  # shadow -> on: rank S (after A and T), then ALL six facts (4.4); every failing one is named.
  # A raise propagates out of the transaction (no flag change; not a refusal, INV-8).
  defp on_checks!(tenant_id, prefix, now) do
    :ok = ScopeNodePaths.lock!(prefix)
    {report, failed} = OnGate.evaluate(tenant_id, prefix, now)

    if failed != [], do: Repo.rollback({:on_precondition_failed, failed, report})

    report
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

    # The target decides the report's shape: `:on` carries the six-fact OnGate report,
    # `:shadow` the three stage-1 facts, `:off` none.
    after_state =
      case target do
        :on ->
          Map.merge(after_state, OnGate.audit_state(report))

        :shadow ->
          Map.put(after_state, "preconditions", %{
            "bindings_without_row" => report.bindings_without_row,
            "org_consistency" => Atom.to_string(report.org_consistency),
            "tokens_exceeding_owner" => report.tokens_exceeding_owner
          })

        :off ->
          after_state
      end

    %{
      actor_id: Map.get(attrs, :actor_id),
      action: if(target in [:shadow, :on], do: @enabled_action, else: @disabled_action),
      resource_type: @resource_type,
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
      findings: findings,
      on_gate: on_gate_snapshot(prefix)
    }
  end

  # AC 9 last sentence: what the `on` flip will check, WITHOUT locks and WITHOUT audit (counts
  # only). A prefix that is not a tenant schema name raises (INV-8), like every gate read.
  defp tenant_id!(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> raise ArgumentError, "invalid tenant schema prefix"
    end
  end

  defp on_gate_snapshot(prefix) do
    tenant_id = tenant_id!(prefix)
    {report, failed} = OnGate.evaluate(tenant_id, prefix, DateTime.utc_now())

    %{
      blocking: failed,
      information: %{
        scoped_task_workers_without_task_scope: report.scoped_task_workers_without_task_scope
      },
      counts: %{
        bindings_without_row: report.bindings_without_row,
        org_consistency: report.org_consistency,
        tokens_exceeding_owner: report.tokens_exceeding_owner,
        explicit_tenant_wide_admins: report.explicit_tenant_wide_admins,
        scoped_approvers: report.scoped_approvers
      },
      evidence: report.evidence
    }
  end
end
