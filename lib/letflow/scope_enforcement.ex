defmodule Letflow.ScopeEnforcement do
  @moduledoc """
  The per-tenant org-scope enforcement flag (REQ-497 PR 1b / GH #2533, decision 0051 D12 and
  Rollout; REQ-519 2f-b / GH #2535, design `lib/letflow/design/req519-enforced-writers-and-flag-on.md`
  sections 4.1 to 4.10).

  Three modes are SETTABLE since REQ-519 2f-b: `off`, `shadow` (the scope decision is computed
  and counted, nothing is denied) and `on` (`Letflow.Plugs.Authorize` enforces it since REQ-517
  2b). The flag is a column of the PUBLIC `tenants` row, read per request by both auth paths
  with no extra query, and written only through ONE shared write helper, used by `flip/4`
  (called only by `Letflow.Routers.TenantScopeEnforcement`: PUT, interactive tenant-wide
  TENANT_ADMIN only) and by `flip_out_of_band/3` (called only by
  `Letflow.Release.ScopeBreakGlass`: the platform-operator break-glass, GH #2883, `on` to
  `shadow` or `off` only, no gate). No seed, migration or config sets a tenant to `on`.

  ## Flip (server-side preconditions)

  `flip/4` runs in one transaction. Lock order: the tenant admin lock (A), the `tenants` row
  `FOR UPDATE` (T), the tenant's scope-tree table lock (S), then PLAIN READS only. Transition
  table (`previous -> target`):

    * same mode: `changed: false`, no write, no audit, no precondition;
    * `off -> shadow`: the three stage-1 facts (bindings without a grant row (T9), scope-tree
      consistency, tokens whose roles exceed their owner's tenant-wide roles) after S, every
      failing one named; audited `scope.enforcement_enabled`;
    * `shadow -> on`: the SIX facts of `Letflow.ScopeEnforcement.OnGate` after S (see below),
      every failing one named; audited `scope.enforcement_enabled`;
    * `off -> on`: refused `:shadow_required` (`on` is reached ONLY from `shadow`); nothing else
      is evaluated;
    * `on -> shadow`: NO precondition (it must succeed with a failing fact seeded) but a
      mandatory reason, checked in the transaction after T (`:reason_required`); audited
      `scope.enforcement_disabled`;
    * `shadow -> off`, `on -> off`: no precondition, mandatory reason (checked before the
      transaction, so a same-mode `off` request without a reason is still `:reason_required`);
      audited `scope.enforcement_disabled`;
    * out of band (`flip_out_of_band/3`, no HTTP route, no role): ONLY `on -> shadow` and
      `on -> off`, no precondition, mandatory reason and operator label, audited
      `scope.enforcement_disabled` with a NULL actor (see "Out of band" below).

  The audit action follows the rank off < shadow < on: `enabled` when the target outranks the
  previous mode, `disabled` otherwise. The update and its audit entry commit together; a
  failed audit write rolls the flip back (`{:audit_failed, _}`). A REFUSED flip to `on`
  (`{:on_precondition_failed, ...}`, `:shadow_required`) changes nothing and is audited AFTER the
  rollback by `Letflow.ScopeEnforcement.RefusedAudit` (`scope.enforcement_refused`, best-effort,
  own transaction); a server fault (any raise, including one inside a gate read) is a rolled
  back `{:transaction_failed, exception}`, answered 500 and NEVER recorded as a refusal (INV-8).
  Before the transaction of a flip to `on`, the in-memory shadow counters are flushed best-effort
  (never extends lock hold time; a failed flush can only make the gate stricter). The only clock
  seam is the internal `attrs[:now]`, honoured ONLY when it is a `DateTime`; the router never
  sets it.

  ## Out of band (GH #2883)

  `flip_out_of_band/3` is the operator break-glass for a tenant stored `on` whose interactive
  tenant-wide TENANT_ADMINs cannot turn it off (design
  `lib/letflow/design/gh2883-scope-enforcement-break-glass.md`). Its authority is host access to
  the running node, not a role, token or permission; its only caller is
  `Letflow.Release.ScopeBreakGlass`. It takes lock A, then the `tenants` row (T), then the audit
  chain lock (C), never the scope-tree lock (S); runs no gate fact; and writes one
  `scope.enforcement_disabled` entry with `actor_id` NULL and `operator`, `source` and `node` in
  the `after_state`. The `on -> shadow` entry restarts the shadow window (T0) by construction.

  ## The `on` gate and its limits

  The five facts (`OnGate`): T9 = 0, org consistency ok, no token exceeds its owner (tokens of a
  flagged service-principal owner STILL block: the flagged-service-principal exemption covers
  ONLY the mint subset check), at least one INTERACTIVE explicit tenant-wide TENANT_ADMIN (SEC
  C-4: the flip route is interactive-only, so a tenant with none could not be turned off), and
  the shadow evidence (`Letflow.ScopeEnforcement.ShadowWindow`). A scoped TASK_WORKER no longer
  blocks the flip: since REQ-532 every task carries its instance's scope node (`tasks.scope_node_id`),
  so the scoped-approver count is informational only. Limits of the evidence, stated once: the
  shadow period proves only the denials of tenant-wide and admin-plane routes (the sentence of
  `ShadowWindow.scope_sentence/0`, also in `docs/roles.md`); request counts include every
  authorized request of any principal, the flip request itself included, so criterion (b) is an
  operator-safety control, not an adversarial one.

  BUILD-ORDER dependency (SEC C-1, not a runtime check): `on` may only be settable once every
  `/me/*` and `/help/*` read is classified. REQ-518 PR #2817 classified the three of them
  (`:self_service`, rulings `0051-A7`, `SEC-518-R2-modules`, `SEC-518-R2-help`); the route-walk
  test `route_scope_on_flip_blocker_test.exs` pins it.

  ## Integrity (`integrity/1`)

  The read-only grant-table integrity report behind
  `GET /api/v1/tenant/scope-enforcement/integrity` (REQ-497 open question 3, AC16): bindings
  without a row (T9, items capped at 1000), orphan group rows, and informational FINDINGS
  with stable codes. Finding `zero_tenant_wide_admins`: the tenant has zero counted
  tenant-wide admins (`Letflow.Identity.count_tenant_wide_admins/1`); it is informational and
  does NOT block `off -> shadow`.

  The report also carries `on_gate`: `blocking` (the failing codes of `OnGate`), `information`
  (`scoped_task_workers_without_task_scope`), `counts` and the shadow `evidence`, computed
  WITHOUT locks and WITHOUT audit (a labelled snapshot of what the `on` flip will check). It
  is a different list from `findings`: `findings` is the stage-1 list (its
  `zero_tenant_wide_admins` uses the OLD count so the `off -> shadow` gate is unchanged);
  `on_gate.blocking` computes `zero_tenant_wide_admins` from the INTERACTIVE EXPLICIT count
  (`Letflow.Identity.count_interactive_explicit_tenant_wide_admins/1`).
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

  # The settable modes are the stored modes (stage 1 kept two lists; `on` became settable in
  # REQ-519 2f-b, so there is one list and `stored_modes/0` delegates to it).
  @modes [:off, :shadow, :on]
  # Single owner of the flip audit vocabulary: `flip_entry/6`, `RefusedAudit` and
  # `ShadowWindow` (T0 = the latest flip entry) all read these.
  @enabled_action "scope.enforcement_enabled"
  @disabled_action "scope.enforcement_disabled"
  @resource_type "tenant"
  @integrity_items_cap 1000
  # GH #2883: the operator label rule (design 3.3) and the break-glass timeouts.
  @out_of_band_source "operator_break_glass"
  @default_lock_timeout_ms 10_000
  # Below the 15 s default per-query timeout, so a lock wait ends as the lock error (R5 F3).
  @max_lock_timeout_ms 14_000
  @transaction_slack_ms 10_000

  @type mode :: :off | :shadow | :on
  @type stored_mode :: mode()
  @type precondition :: :bindings_without_row | :org_inconsistent | :tokens_exceed_owner
  @type precondition_report :: %{
          bindings_without_row: non_neg_integer(),
          org_consistency: :ok | :inconsistent | :unavailable,
          tokens_exceeding_owner: non_neg_integer()
        }
  # GH #2890: the closed set of refusal kinds `flip/4` can return. `refuse/2` is the only way a
  # refusal leaves `do_flip/6` (its guard rejects a kind not listed here). The router's
  # `flip_response/2` has a clause per kind; its catch-all is only the INV-8 fallback, and the
  # closed-kind test fails any kind that falls through to it.
  @refusal_kinds [
    :invalid_mode,
    :reason_required,
    :invalid_reason,
    :tenant_not_found,
    :tenant_prefix_mismatch,
    :precondition_failed,
    :shadow_required,
    :on_precondition_failed,
    :audit_failed,
    :transaction_failed
  ]
  # Pinned to `@refusal_kinds` by `TenantScopeEnforcementRefusalKindsTest` (no drift).
  @type refusal_kind ::
          :invalid_mode
          | :reason_required
          | :invalid_reason
          | :tenant_not_found
          | :tenant_prefix_mismatch
          | :precondition_failed
          | :shadow_required
          | :on_precondition_failed
          | :audit_failed
          | :transaction_failed
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
  @type out_of_band_target :: :shadow | :off
  @type out_of_band_error ::
          :invalid_target
          | :operator_required
          | :invalid_operator
          | :reason_required
          | :invalid_reason
          | :tenant_not_found
          | {:not_enforced, :off | :shadow}
          | :lock_conflict
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

  @doc "Every kind a `flip/4` error can carry (the closed set behind `t:refusal_kind/0`)."
  @spec refusal_kinds() :: [refusal_kind()]
  def refusal_kinds, do: @refusal_kinds

  @doc "The settable modes, `[:off, :shadow, :on]`."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "Every mode the column can store, `[:off, :shadow, :on]` (the same list as `modes/0`)."
  @spec stored_modes() :: [stored_mode()]
  def stored_modes, do: modes()

  @doc """
  Exactly the strings `"off"`, `"shadow"` and `"on"`. Every other value (`"ON"`, `nil`,
  non-strings) is `{:error, :invalid_mode}`. No atom is minted from input.
  """
  @spec parse_mode(term()) :: {:ok, mode()} | {:error, :invalid_mode}
  def parse_mode("off"), do: {:ok, :off}
  def parse_mode("shadow"), do: {:ok, :shadow}
  def parse_mode("on"), do: {:ok, :on}
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
          mode when mode in @modes -> {:ok, mode}
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
  Flips the tenant's mode to `target` (see the moduledoc for the transition table). `prefix`
  must be the tenant's own schema. `attrs.reason` is mandatory for `:off` and for `on ->
  shadow`, and validated when present otherwise. A same-mode request returns `changed: false`
  with no write, audit or precondition check.
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
          {:ok, %{mode: mode(), previous: mode(), changed: boolean()}}
          | {:error, flip_error()}
  def flip(tenant_id, prefix, target, attrs) when is_binary(prefix) and is_map(attrs) do
    with :ok <- check_target(target),
         :ok <- check_prefix(tenant_id, prefix),
         {:ok, reason} <- check_reason(target, Map.get(attrs, :reason)) do
      now = clock(attrs)

      # SEC S-4: flush the in-memory counters BEFORE the transaction (never extends lock hold
      # time); best-effort, a failed flush can only make the gate stricter.
      if target == :on, do: ShadowWindow.flush_evidence()

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

  defp check_target(target) when target in @modes, do: :ok
  defp check_target(_target), do: {:error, :invalid_mode}

  defp check_prefix(tenant_id, prefix) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, ^prefix} -> :ok
      _other -> {:error, :tenant_prefix_mismatch}
    end
  end

  defp check_reason(:off, nil), do: {:error, :reason_required}
  defp check_reason(_target, nil), do: {:ok, nil}

  defp check_reason(_target, reason) do
    case Letflow.Audit.Reason.validate(reason) do
      {:ok, trimmed} -> {:ok, trimmed}
      :error -> {:error, :invalid_reason}
    end
  end

  defp do_flip(tenant_id, prefix, target, reason, attrs, now) do
    # Rank A, then T (lock order of design section 10).
    tenant = lock_tenant_row!(tenant_id, prefix)

    previous = tenant.scope_enforcement

    cond do
      previous == target ->
        %{mode: target, previous: previous, changed: false}

      # `on` is reached only from `shadow` (D-6); nothing else is evaluated.
      target == :on and previous != :shadow ->
        refuse(:shadow_required)

      # The de-escalation `on -> shadow` runs NO precondition, but its reason is mandatory
      # (AC 13; the pre-transaction check cannot know the previous mode).
      previous == :on and target == :shadow and is_nil(reason) ->
        refuse(:reason_required)

      true ->
        report = transition_report!(previous, target, tenant_id, prefix, now)

        write_flag_and_audit!(
          tenant,
          prefix,
          previous,
          target,
          flip_entry(tenant_id, previous, target, reason, report, attrs)
        )
    end
  end

  # Shared by `flip/4` and `flip_out_of_band/3` (GH #2883). Inside a transaction: the tenant
  # admin lock (A) FIRST, then the `tenants` row `FOR UPDATE` (T). Rolls back
  # `:tenant_not_found` when the row is absent.
  @spec lock_tenant_row!(tenant_id :: Ecto.UUID.t(), prefix :: String.t()) :: Tenant.t()
  defp lock_tenant_row!(tenant_id, prefix) do
    Identity.lock_tenant_admins!(prefix)

    Repo.one(from(t in Tenant, where: t.id == ^tenant_id, lock: "FOR UPDATE")) ||
      refuse(:tenant_not_found)
  end

  # Shared by both writers: the ONE call of `Tenant.scope_enforcement_changeset/2`, then the
  # audit entry (rank C) in the same transaction; a failed audit insert rolls the flag back.
  @spec write_flag_and_audit!(
          tenant :: Tenant.t(),
          prefix :: String.t(),
          previous :: mode(),
          target :: mode(),
          entry :: map()
        ) :: %{mode: mode(), previous: mode(), changed: true}
  defp write_flag_and_audit!(tenant, prefix, previous, target, entry) do
    Repo.update!(Tenant.scope_enforcement_changeset(tenant, %{scope_enforcement: target}))

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> %{mode: target, previous: previous, changed: true}
      {:error, audit_error} -> refuse(:audit_failed, [audit_error])
    end
  end

  # The facts a transition must satisfy, tagged by kind so the audit entry dispatches on the
  # tag and not on the shape of the map. Only escalations are gated; every de-escalation
  # (`on -> shadow`, `* -> off`) runs no precondition.
  defp transition_report!(:shadow, :on, tenant_id, prefix, now),
    do: {:on_gate, on_checks!(tenant_id, prefix, now)}

  defp transition_report!(:off, :shadow, _tenant_id, prefix, _now),
    do: {:three_facts, enable_checks!(prefix)}

  defp transition_report!(_previous, _target, _tenant_id, _prefix, _now), do: nil

  # shadow -> on: rank S (after A and T), then ALL five facts (4.4); every failing one is named.
  # A raise propagates out of the transaction (no flag change; not a refusal, INV-8).
  defp on_checks!(tenant_id, prefix, now) do
    :ok = ScopeNodePaths.lock!(prefix)
    {report, failed} = OnGate.evaluate(tenant_id, prefix, now)

    if failed != [], do: refuse(:on_precondition_failed, [failed, report])

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

    if failed != [], do: refuse(:precondition_failed, [failed, report])

    report
  end

  # Every refusal of `do_flip/6` and its gates rolls back through here. The guard keeps the kind
  # inside `@refusal_kinds`; a kind outside the closed set is a FunctionClauseError inside the
  # transaction, which `flip/4` answers as a server fault (INV-8), never as an `unknown` refusal.
  @spec refuse(refusal_kind(), [term()]) :: no_return()
  defp refuse(kind, payload \\ []) when kind in @refusal_kinds do
    Repo.rollback(if payload == [], do: kind, else: List.to_tuple([kind | payload]))
  end

  defp flip_entry(tenant_id, previous, target, reason, report, attrs) do
    after_state = %{"mode" => Atom.to_string(target), "reason" => reason}

    # The tag decides the report's shape: `:on_gate` carries the five-fact OnGate report,
    # `:three_facts` the stage-1 facts, `nil` none (every de-escalation).
    after_state =
      case report do
        {:on_gate, on_report} ->
          Map.merge(after_state, OnGate.audit_state(on_report))

        {:three_facts, facts} ->
          Map.put(after_state, "preconditions", %{
            "bindings_without_row" => facts.bindings_without_row,
            "org_consistency" => Atom.to_string(facts.org_consistency),
            "tokens_exceeding_owner" => facts.tokens_exceeding_owner
          })

        nil ->
          after_state
      end

    %{
      actor_id: Map.get(attrs, :actor_id),
      action: if(rank(target) > rank(previous), do: @enabled_action, else: @disabled_action),
      resource_type: @resource_type,
      resource_id: tenant_id,
      before_state: %{"mode" => Atom.to_string(previous)},
      after_state: after_state,
      trace_id: Map.get(attrs, :trace_id)
    }
  end

  # Audit action rank (AC 13): enabled when the target outranks the previous mode.
  defp rank(:off), do: 0
  defp rank(:shadow), do: 1
  defp rank(:on), do: 2

  @doc """
  Exactly the strings `"shadow"` and `"off"` (the only out-of-band targets). Every other value
  (`"on"`, `"ON"`, `nil`, non-strings) is `{:error, :invalid_target}`. No atom is minted.
  """
  @spec parse_out_of_band_target(term()) ::
          {:ok, out_of_band_target()} | {:error, :invalid_target}
  def parse_out_of_band_target("shadow"), do: {:ok, :shadow}
  def parse_out_of_band_target("off"), do: {:ok, :off}
  def parse_out_of_band_target(_other), do: {:error, :invalid_target}

  @doc """
  The operator label rule (pure, never raises): a binary of 1 to 64 bytes, an ASCII letter or
  digit followed by letters, digits and `. _ @ + -`, anchored at both ends (a trailing newline
  is rejected). Excludes whitespace, control, format and bidi characters and quotes, so a label
  cannot spoof an audit reader or inject into a log line.
  """
  @spec valid_operator_label?(term()) :: boolean()
  def valid_operator_label?(label) when is_binary(label),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}\z/, label)

  def valid_operator_label?(_label), do: false

  @doc """
  The pre-transaction input checks of the break-glass, in the order target, reason, operator
  (no database access, no write). The reason is mandatory for both targets: `nil`, a non-binary
  or a blank binary is `:reason_required`, a binary failing `Letflow.Audit.Reason` is
  `:invalid_reason`; the operator likewise (`:operator_required` / `:invalid_operator`).
  `{:ok, trimmed_reason}` on success.
  """
  @spec check_out_of_band_inputs(target :: term(), reason :: term(), operator :: term()) ::
          {:ok, String.t()}
          | {:error,
             :invalid_target
             | :reason_required
             | :invalid_reason
             | :operator_required
             | :invalid_operator}
  def check_out_of_band_inputs(target, reason, operator) do
    with :ok <- check_out_of_band_target(target),
         {:ok, trimmed} <- check_out_of_band_reason(reason),
         :ok <- check_out_of_band_operator(operator) do
      {:ok, trimmed}
    end
  end

  defp check_out_of_band_target(target) when target in [:shadow, :off], do: :ok
  defp check_out_of_band_target(_target), do: {:error, :invalid_target}

  defp check_out_of_band_reason(reason) do
    if blank?(reason) do
      {:error, :reason_required}
    else
      case Letflow.Audit.Reason.validate(reason) do
        {:ok, trimmed} -> {:ok, trimmed}
        :error -> {:error, :invalid_reason}
      end
    end
  end

  defp check_out_of_band_operator(operator) do
    cond do
      blank?(operator) -> {:error, :operator_required}
      valid_operator_label?(operator) -> :ok
      true -> {:error, :invalid_operator}
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  @doc """
  The platform-operator break-glass writer (GH #2883): `on -> shadow` or `on -> off` for the
  tenant `tenant_id`, with no HTTP route and no role. OPERATOR ONLY: its single caller is
  `Letflow.Release.ScopeBreakGlass` (a scan pins it), whose authority is host access.

  Reads exactly two keys of `attrs`, `:operator` (a label, see `valid_operator_label?/1`) and
  `:reason` (mandatory, see `check_out_of_band_inputs/3`); any other key is ignored. The audit
  entry is `scope.enforcement_disabled` with `actor_id` NULL and `operator`, `source` and `node`
  in its `after_state`. Runs NO gate fact and takes no scope-tree lock. A tenant not stored `on`
  is `{:not_enforced, mode}`, decided from the LOCKED row. Lock order A, T, C; each wait is
  bounded by the lock timeout (`:scope_break_glass_lock_timeout_ms`, default 10 s, test-only
  override) and the transaction timeout is `transaction_timeout_ms/1` (SEC F-1), so a lock
  expiry is `:lock_conflict` and never a connection timeout.
  """
  @spec flip_out_of_band(
          tenant_id :: Ecto.UUID.t(),
          target :: out_of_band_target(),
          attrs :: %{required(:operator) => term(), required(:reason) => term()}
        ) ::
          {:ok, %{mode: out_of_band_target(), previous: :on, changed: true}}
          | {:error, out_of_band_error()}
  def flip_out_of_band(tenant_id, target, attrs) when is_map(attrs) do
    operator = Map.get(attrs, :operator)

    with {:ok, reason} <- check_out_of_band_inputs(target, Map.get(attrs, :reason), operator),
         {:ok, id, prefix} <- out_of_band_registration(tenant_id) do
      lock_ms = lock_timeout_ms()

      # The `rescue` encloses the WHOLE transaction: a raise anywhere is a rolled-back fault,
      # never a refusal (INV-8).
      try do
        Repo.transaction(
          fn -> do_flip_out_of_band(id, prefix, target, reason, operator, lock_ms) end,
          timeout: transaction_timeout_ms(lock_ms)
        )
      rescue
        exception in Postgrex.Error ->
          case exception.postgres do
            %{code: code} when code in [:lock_not_available, :deadlock_detected] ->
              {:error, :lock_conflict}

            _other ->
              {:error, {:transaction_failed, exception}}
          end

        exception ->
          {:error, {:transaction_failed, exception}}
      end
    end
  end

  # An invalid id or an id without a provisioned schema is `:tenant_not_found` (no raise).
  defp out_of_band_registration(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(tenant_id),
         {:ok, prefix} <- TenantProvisioning.registered_schema(id) do
      {:ok, id, prefix}
    else
      _unknown -> {:error, :tenant_not_found}
    end
  end

  defp do_flip_out_of_band(tenant_id, prefix, target, reason, operator, lock_ms) do
    # Transaction-local, bound parameter (INV-7): bounds each of the three lock waits.
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", [Integer.to_string(lock_ms)],
      timeout: transaction_timeout_ms(lock_ms)
    )

    # Rank A, then T. NO scope-tree lock (S): a de-escalation runs no gate fact.
    tenant = lock_tenant_row!(tenant_id, prefix)

    # `previous` is read FROM THE LOCKED ROW, never from an earlier read.
    case tenant.scope_enforcement do
      :on ->
        entry = %{
          actor_id: nil,
          action: @disabled_action,
          resource_type: @resource_type,
          resource_id: tenant_id,
          before_state: %{"mode" => "on"},
          after_state: %{
            "mode" => Atom.to_string(target),
            "reason" => reason,
            "operator" => operator,
            "source" => @out_of_band_source,
            "node" => Atom.to_string(node())
          },
          trace_id: "break-glass-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        }

        write_flag_and_audit!(tenant, prefix, :on, target, entry)

      not_on ->
        Repo.rollback({:not_enforced, not_on})
    end
  end

  defp lock_timeout_ms do
    case Application.get_env(
           :letflow,
           :scope_break_glass_lock_timeout_ms,
           @default_lock_timeout_ms
         ) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_lock_timeout_ms)
      _other -> @default_lock_timeout_ms
    end
  end

  @doc false
  # SEC F-1: up to three lock waits (A, the `tenants` row, the audit chain lock) can each last
  # `lock_ms`, so the transaction timeout is strictly above their sum: 3 x L + 10 s.
  @spec transaction_timeout_ms(lock_ms :: pos_integer()) :: pos_integer()
  def transaction_timeout_ms(lock_ms) when is_integer(lock_ms) and lock_ms > 0,
    do: 3 * lock_ms + @transaction_slack_ms

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
