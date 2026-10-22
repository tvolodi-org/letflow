defmodule Letflow.ScopeEnforcementTransitionsTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 13, AC 14 (wiring), AC 15 (enabled / disabled with mode `on`)
  and AC 18 (flip half): the `flip/4` transition table with `on` settable (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.1 and 4.3 and 8.4, tests
  T-X1..T-X14, T-G9 / T-E16 / T-G10 (flip halves), mutants MU-21..MU-24, MU-38, MU-39, MU-42 and
  V7 of step-18; spec `test/specs/REQ-519-2f-b.md`; SEC step-21 merge conditions).

  The gate itself is covered by the 2f-a files; this file drives it THROUGH `flip/4`:

    * T-X1 `parse_mode/1` accepts exactly `"off" | "shadow" | "on"` and mints no atom;
    * T-X2 `shadow -> on` succeeds with a satisfied gate: `enabled` entry with the six counts and the
      evidence summary, the chain verifies;
    * T-X3 / T-X4 / T-X9 / T-X10 / T-X11 the de-escalations (`on -> shadow`, `on -> off`,
      `shadow -> off`) need a reason, run NO precondition (they succeed with a failing fact seeded)
      and audit as `disabled`;
    * T-X5 `off -> on` is `:shadow_required`, nothing else is evaluated, one refusal entry (also
      for an `off` tenant whose evidence would satisfy the gate: kills MU-23);
    * T-X6 same mode is a no-op (no write, no audit, no precondition, no reason);
    * T-X7 the audit action follows the rank off < shadow < on (kills MU-24);
    * T-X12 a forced audit failure rolls the flip back;
    * T-X13 a same-mode `off` request without a reason is still `:reason_required`;
    * AC 14: each failing fact alone refuses with exactly its code and ONE `scope.enforcement_refused`
      entry written AFTER the rollback (kills MU-38); a RAISE inside the gate is a rolled-back
      `{:transaction_failed, _}`, never a refusal (kills MU-39);
    * MU-42 the in-memory counters are flushed before the gate reads (a request counted just before
      the flip is visible), MU-22 the scope-tree lock S is taken before the six facts are read
      (a gap committed by the S holder is seen), V7 `attrs[:now]` is honoured only as a `DateTime`.

  `async: false`: real tenant schemas with committed writes, committed DDL, real connections for the
  lock test, VM-global shadow-evidence process.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Scope.ShadowEvidence
  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.ShadowWindow
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture

  @enabled "scope.enforcement_enabled"
  @disabled "scope.enforcement_disabled"
  @refused "scope.enforcement_refused"

  @precondition_keys [
    "bindings_without_row",
    "explicit_tenant_wide_admins",
    "org_consistency",
    "scoped_approvers",
    "scoped_task_workers_without_task_scope",
    "tokens_exceeding_owner"
  ]
  @evidence_keys ["criteria", "days_without_requests", "evidence_scope", "requests", "would_deny"]

  # --- helpers ---------------------------------------------------------------------------------

  # A shadow tenant that satisfies all six facts at `fx.now` (t0 + 7 days).
  defp green!(slug_prefix) do
    fx = F.shadow_tenant!(slug_prefix)
    :ok = F.satisfy!(fx, fx.now)
    fx
  end

  # shadow -> on at the injected clock `fx.now`.
  defp go_on(fx, reason) do
    ScopeEnforcement.flip(
      fx.tenant_id,
      fx.schema_name,
      :on,
      fx |> F.attrs(reason) |> Map.put(:now, fx.now)
    )
  end

  defp flip(fx, target, reason),
    do: ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, target, F.attrs(fx, reason))

  # A tenant stored `on` through the REAL guarded flip.
  defp on_tenant!(slug_prefix) do
    fx = green!(slug_prefix)
    assert {:ok, %{mode: :on, previous: :shadow, changed: true}} = go_on(fx, "req519 2f-b setup")
    fx
  end

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp flip_entries(fx), do: F.entries(fx, @enabled) ++ F.entries(fx, @disabled)

  defp all_entries(fx) do
    Repo.all(from(e in Entry, order_by: [e.timestamp, e.id]), prefix: fx.schema_name)
  end

  # An `off` tenant whose evidence WOULD satisfy the gate at `now`: a RAW backdated "entered
  # shadow" entry (the latest flip entry, so it is the shadow start) and persisted counters.
  defp off_tenant_with_satisfied_evidence! do
    fx = F.admin_tenant!("req519-x5b")
    t0 = DateTime.utc_now() |> DateTime.add(-8 * F.day_seconds(), :second)

    _id =
      F.raw_entry!(fx, %{
        action: @enabled,
        resource_type: "tenant",
        resource_id: fx.tenant_id,
        timestamp: t0,
        after_state: %{"mode" => "shadow"}
      })

    now = F.after_days(t0, 7)
    :ok = F.satisfy!(fx, now)
    Map.put(fx, :now, now)
  end

  defp with_audit_fault(fx, condition, fun) do
    name = "req519_2fb_fault_#{System.unique_integer([:positive])}"
    SyncScopeFixture.create_audit_fault!(fx.schema_name, name, condition)

    try do
      fun.()
    after
      SyncScopeFixture.drop_audit_fault!(fx.schema_name, name)
    end
  end

  # --- T-X1 ------------------------------------------------------------------------------------

  describe "T-X1 parse_mode/1 and the mode lists" do
    test "exactly off, shadow and on are accepted; no other value, and no atom is minted" do
      assert ScopeEnforcement.parse_mode("off") == {:ok, :off}
      assert ScopeEnforcement.parse_mode("shadow") == {:ok, :shadow}
      assert ScopeEnforcement.parse_mode("on") == {:ok, :on}

      junk = "req519-never-an-atom-#{System.unique_integer([:positive])}"

      for value <- ["ON", "On", "oN", " on", "on ", "", junk, nil, :on, :off, 1, %{}, ["on"]] do
        assert ScopeEnforcement.parse_mode(value) == {:error, :invalid_mode}, inspect(value)
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(junk) end

      assert ScopeEnforcement.modes() == [:off, :shadow, :on]
      assert ScopeEnforcement.stored_modes() == ScopeEnforcement.modes()
    end

    test "flip/4 rejects a target that is not a mode atom (the string \"on\" included)" do
      fx = F.admin_tenant!("req519-x1b")

      for target <- ["on", "shadow", nil, :enforced, :ON] do
        assert ScopeEnforcement.flip(
                 fx.tenant_id,
                 fx.schema_name,
                 F.opaque(target),
                 F.attrs(fx, "r")
               ) == {:error, :invalid_mode}
      end

      assert mode!(fx) == :off
      assert all_entries(fx) |> Enum.filter(&(&1.action in [@enabled, @disabled, @refused])) == []
    end
  end

  # --- T-X2 ------------------------------------------------------------------------------------

  describe "T-X2 shadow -> on with a satisfied gate" do
    test "the flag is on, one enabled entry carries the six counts and the evidence summary, the chain verifies" do
      fx = green!("req519-x2")
      before_ids = Enum.map(F.entries(fx, @enabled), & &1.id)

      assert {:ok, %{mode: :on, previous: :shadow, changed: true}} =
               go_on(fx, "req519 pilot tenant")

      assert mode!(fx) == :on

      entries = F.entries(fx, @enabled)
      assert [entry] = Enum.reject(entries, &(&1.id in before_ids))
      assert entry.action == @enabled
      assert entry.resource_type == "tenant"
      assert entry.resource_id == fx.tenant_id
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == F.trace()
      assert entry.before_state == %{"mode" => "shadow"}

      assert Enum.sort(Map.keys(entry.after_state)) ==
               ["evidence", "mode", "preconditions", "reason"]

      assert entry.after_state["mode"] == "on"
      assert entry.after_state["reason"] == "req519 pilot tenant"

      pre = entry.after_state["preconditions"]
      assert Enum.sort(Map.keys(pre)) == @precondition_keys

      assert pre == %{
               "bindings_without_row" => 0,
               "org_consistency" => "ok",
               "tokens_exceeding_owner" => 0,
               "explicit_tenant_wide_admins" => 1,
               "scoped_approvers" => 0,
               "scoped_task_workers_without_task_scope" => 0
             }

      evidence = entry.after_state["evidence"]
      assert Enum.sort(Map.keys(evidence)) == @evidence_keys
      assert evidence["requests"] == 160
      assert evidence["days_without_requests"] == 0
      assert evidence["evidence_scope"] == ShadowWindow.evidence_scope()

      assert evidence["criteria"] == %{
               "duration" => true,
               "requests" => true,
               "every_day_has_requests" => true,
               "no_blocking_would_deny" => true,
               "configuration" => true
             }

      assert Enum.sort(Map.keys(evidence["would_deny"])) ==
               Enum.sort(Enum.map(ShadowEvidence.reasons(), &Atom.to_string/1))

      assert Enum.all?(Map.values(evidence["would_deny"]), &(&1 == 0))

      # no id, name or token data anywhere in the stored state (INV-2)
      refute F.uuid_in?(Jason.encode!(entry.after_state))

      assert Audit.verify_chain(fx.schema_name) == {:ok, :valid}
      assert F.entries(fx, @refused) == []
    end

    test "the reason is optional on the way up: nil is recorded as nil" do
      fx = green!("req519-x2b")

      assert {:ok, %{mode: :on}} = go_on(fx, nil)

      entry = F.latest_flip_entry!(fx)
      assert entry.action == @enabled
      assert entry.after_state["reason"] == nil
    end

    test "a reason that is not one plain line is :invalid_reason and nothing changes" do
      fx = green!("req519-x2c")

      for reason <- ["", "   ", "line one\nline two", String.duplicate("x", 501), 5, %{}] do
        assert go_on(fx, reason) == {:error, :invalid_reason}, inspect(reason)
      end

      assert mode!(fx) == :shadow
      assert F.entries(fx, @refused) == []
    end
  end

  # --- T-X3 / T-X9 / T-X10 / T-X4 / T-X11 -------------------------------------------------------

  describe "T-X3 / T-X9 on -> shadow" do
    test "succeeds with a reason, audits as disabled with mode and reason only, and runs no precondition" do
      fx = on_tenant!("req519-x3")

      assert {:ok, %{mode: :shadow, previous: :on, changed: true}} =
               flip(fx, :shadow, "req519 pilot paused")

      assert mode!(fx) == :shadow

      entry = F.latest_flip_entry!(fx)
      assert entry.action == @disabled
      assert entry.before_state == %{"mode" => "on"}
      assert entry.after_state == %{"mode" => "shadow", "reason" => "req519 pilot paused"}
    end

    test "T-X9 without a reason it is :reason_required (nothing written); a blank or multi-line one is :invalid_reason" do
      fx = on_tenant!("req519-x9")
      before = flip_entries(fx)

      assert flip(fx, :shadow, nil) == {:error, :reason_required}
      assert flip(fx, :shadow, "") == {:error, :invalid_reason}
      assert flip(fx, :shadow, "  ") == {:error, :invalid_reason}
      assert flip(fx, :shadow, "a\nb") == {:error, :invalid_reason}

      assert mode!(fx) == :on
      assert flip_entries(fx) == before
      assert F.entries(fx, @refused) == []
    end

    test "T-X10 it SUCCEEDS with every failing fact seeded, while off -> shadow with the same seed is refused (MU-21)" do
      fx = on_tenant!("req519-x10")
      F.break_all_facts!(fx)

      # the gate would refuse every fact now
      assert {_report, failed} =
               Letflow.ScopeEnforcement.OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      assert length(failed) >= 4

      assert {:ok, %{mode: :shadow, previous: :on, changed: true}} =
               flip(fx, :shadow, "req519 de-escalate with failing facts")

      assert mode!(fx) == :shadow
      entry = F.latest_flip_entry!(fx)
      assert entry.action == @disabled
      # no preconditions were evaluated, so none are recorded
      assert entry.after_state == %{
               "mode" => "shadow",
               "reason" => "req519 de-escalate with failing facts"
             }

      # the same seed refuses the stage-1 gate: the facts are real
      assert {:ok, %{mode: :off}} = flip(fx, :off, "req519 reset")

      assert {:error, {:precondition_failed, failed1, _report}} = flip(fx, :shadow, nil)
      assert :bindings_without_row in failed1
    end
  end

  describe "T-X4 / T-X11 on -> off and shadow -> off" do
    test "on -> off needs a reason, is never gated, and audits as disabled" do
      fx = on_tenant!("req519-x4")
      F.break_all_facts!(fx)

      assert flip(fx, :off, nil) == {:error, :reason_required}
      assert mode!(fx) == :on

      assert {:ok, %{mode: :off, previous: :on, changed: true}} =
               flip(fx, :off, "req519 turned off")

      entry = F.latest_flip_entry!(fx)
      assert entry.action == @disabled
      assert entry.before_state == %{"mode" => "on"}
      assert entry.after_state == %{"mode" => "off", "reason" => "req519 turned off"}
    end

    test "on -> off with a blank, multi-line or non-string reason is :invalid_reason (AC 13); nothing is written" do
      fx = on_tenant!("req519-x4b")
      before = flip_entries(fx)

      for reason <- ["", "  ", "a
b", String.duplicate("x", 501), 5] do
        assert flip(fx, :off, reason) == {:error, :invalid_reason}, inspect(reason)
      end

      assert mode!(fx) == :on
      assert flip_entries(fx) == before
    end

    test "off -> shadow with a blank, multi-line or non-string reason is :invalid_reason (AC 13); nothing is written" do
      fx = F.admin_tenant!("req519-x4c")
      before = all_entries(fx)

      for reason <- ["", "  ", "a
b", String.duplicate("x", 501), 5] do
        assert flip(fx, :shadow, reason) == {:error, :invalid_reason}, inspect(reason)
      end

      assert mode!(fx) == :off
      assert all_entries(fx) == before
    end

    test "shadow -> off keeps its stage-1 behaviour (reason, disabled, no gate) with a failing fact seeded" do
      fx = F.admin_tenant!("req519-x11")
      F.flip!(fx, :shadow, nil)
      _gap = F.gap!(fx)

      assert flip(fx, :off, nil) == {:error, :reason_required}
      assert {:ok, %{mode: :off, previous: :shadow}} = flip(fx, :off, "req519 stage 1")
      assert F.latest_flip_entry!(fx).action == @disabled
    end
  end

  # --- T-X5 ------------------------------------------------------------------------------------

  describe "T-X5 off -> on" do
    test "is :shadow_required, changes nothing, writes ONE refusal entry and no flip entry" do
      fx = F.admin_tenant!("req519-x5")

      assert flip(fx, :on, "req519 try on") == {:error, :shadow_required}

      assert mode!(fx) == :off
      assert flip_entries(fx) == []

      assert [refusal] = F.entries(fx, @refused)
      assert refusal.resource_type == "tenant"
      assert refusal.resource_id == fx.tenant_id
      assert refusal.actor_id == fx.admin.id
      assert refusal.trace_id == F.trace()
      assert refusal.before_state == %{"mode" => "off"}
      assert refusal.after_state["target"] == "on"
      assert refusal.after_state["failed"] == ["shadow_required"]
      refute Map.has_key?(refusal.after_state, "evidence")
    end

    test "even an off tenant whose evidence would satisfy the gate is refused: on is reached only from shadow (MU-23)" do
      fx = off_tenant_with_satisfied_evidence!()

      # the gate would pass for this tenant at fx.now (proof the fixture is not vacuous)
      assert {_report, []} =
               Letflow.ScopeEnforcement.OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      result =
        ScopeEnforcement.flip(
          fx.tenant_id,
          fx.schema_name,
          :on,
          fx |> F.attrs("req519 skip shadow") |> Map.put(:now, fx.now)
        )

      assert result == {:error, :shadow_required}
      assert mode!(fx) == :off
    end

    test "nothing else is evaluated: with a table every fact would read renamed, the answer is still :shadow_required" do
      fx = F.admin_tenant!("req519-x5c")

      F.with_renamed_table!(fx, "role_scope_grants", fn ->
        assert flip(fx, :on, nil) == {:error, :shadow_required}
      end)

      assert mode!(fx) == :off
    end
  end

  # --- T-X6 / T-X13 ----------------------------------------------------------------------------

  describe "T-X6 / T-X13 same mode" do
    test "on -> on and shadow -> shadow are no-ops: changed false, no write, no audit, no precondition, no reason" do
      fx = on_tenant!("req519-x6")
      F.break_all_facts!(fx)
      before = all_entries(fx)

      assert {:ok, %{mode: :on, previous: :on, changed: false}} = flip(fx, :on, nil)
      assert {:ok, %{mode: :on, previous: :on, changed: false}} = flip(fx, :on, "ignored")
      assert all_entries(fx) == before

      assert {:ok, _} = flip(fx, :shadow, "req519 down")
      before = all_entries(fx)
      assert {:ok, %{mode: :shadow, previous: :shadow, changed: false}} = flip(fx, :shadow, nil)
      assert all_entries(fx) == before
    end

    test "T-X13 a same-mode off request WITHOUT a reason is still :reason_required; with one it is a no-op" do
      fx = F.admin_tenant!("req519-x13")

      assert flip(fx, :off, nil) == {:error, :reason_required}
      assert {:ok, %{mode: :off, previous: :off, changed: false}} = flip(fx, :off, "req519 noop")
      assert flip_entries(fx) == []
    end
  end

  # --- T-X7 ------------------------------------------------------------------------------------

  describe "T-X7 the audit action follows the rank off < shadow < on" do
    test "enabled when the target outranks the previous mode, disabled otherwise" do
      fx = green!("req519-x7")
      # off -> shadow happened in the fixture
      assert F.entries(fx, @enabled) |> length() == 1

      assert {:ok, _} = go_on(fx, nil)
      assert F.latest_flip_entry!(fx).action == @enabled

      assert {:ok, _} = flip(fx, :shadow, "req519 rank")
      assert F.latest_flip_entry!(fx).action == @disabled

      # shadow -> off is disabled, then walk up and down again to pin on -> off
      assert {:ok, _} = flip(fx, :off, "req519 rank 2")
      assert F.latest_flip_entry!(fx).action == @disabled

      assert {:ok, _} = flip(fx, :shadow, nil)
      assert F.latest_flip_entry!(fx).action == @enabled
    end

    test "on -> off is disabled" do
      fx = on_tenant!("req519-x7b")
      assert {:ok, %{previous: :on, mode: :off}} = flip(fx, :off, "req519 rank 3")

      entry = F.latest_flip_entry!(fx)
      assert entry.action == @disabled
      assert entry.before_state == %{"mode" => "on"}
    end
  end

  # --- T-X12 -----------------------------------------------------------------------------------

  describe "T-X12 a forced audit failure rolls the flip back" do
    test "shadow -> on: the flag stays shadow and no flip entry exists" do
      fx = green!("req519-x12")
      before = flip_entries(fx)

      result =
        with_audit_fault(fx, "NEW.action = '#{@enabled}'", fn -> go_on(fx, "req519 fault") end)

      assert {:error, {tag, _detail}} = result
      assert tag in [:audit_failed, :transaction_failed]
      assert mode!(fx) == :shadow
      assert flip_entries(fx) == before
      assert F.entries(fx, @refused) == []
    end

    test "on -> off: the flag stays on" do
      fx = on_tenant!("req519-x12b")
      before = flip_entries(fx)

      result =
        with_audit_fault(fx, "NEW.action = '#{@disabled}'", fn ->
          flip(fx, :off, "req519 fault")
        end)

      assert {:error, {tag, _detail}} = result
      assert tag in [:audit_failed, :transaction_failed]
      assert mode!(fx) == :on
      assert flip_entries(fx) == before
    end
  end

  # --- AC 15 ---------------------------------------------------------------------------------------

  describe "T-A6 the actions with mode on are listed without error (AC 15)" do
    test "enabled (shadow -> on), refused and disabled (on -> off) come back through Audit.list_entries/1; the chain verifies" do
      fx = F.shadow_tenant!("req519-a6")

      # a refusal first (no evidence yet), then the gate is satisfied and the flip goes through
      assert {:error, {:on_precondition_failed, _, _}} = go_on(fx, nil)
      :ok = F.satisfy!(fx, fx.now)
      assert {:ok, %{mode: :on}} = go_on(fx, "req519 listed")
      assert {:ok, %{mode: :off}} = flip(fx, :off, "req519 listed off")

      assert {:ok, %{items: items, has_more: false}} =
               Audit.list_entries(%{
                 prefix: fx.schema_name,
                 page_size: 50,
                 resource_type: "tenant",
                 resource_id: fx.tenant_id
               })

      by_action =
        items
        |> Enum.filter(&(&1.action in [@enabled, @disabled, @refused]))
        |> Enum.group_by(& &1.action)

      assert length(by_action[@refused]) == 1
      assert length(by_action[@enabled]) == 2
      assert length(by_action[@disabled]) == 1

      # the entries carry mode `on` where the flip reached or left it
      assert Enum.any?(by_action[@enabled], &(&1.after_state["mode"] == "on"))

      assert [%{before_state: %{"mode" => "on"}, after_state: %{"mode" => "off"}}] =
               by_action[@disabled]

      assert Audit.verify_chain(fx.schema_name) == {:ok, :valid}
    end
  end

  # --- AC 14: each failing fact refuses, ONE refusal entry after the rollback -------------------

  describe "AC 14 a gate refusal through flip/4" do
    @facts [
      {:bindings_without_row, "g1"},
      {:org_inconsistent, "g2"},
      {:tokens_exceed_owner, "g3"},
      {:zero_tenant_wide_admins, "g4"},
      {:scoped_approvers_without_task_scope, "g5"}
    ]

    for {code, slug} <- @facts do
      @tag code: code, slug: slug
      test "#{code} alone refuses with exactly [#{code}], leaves the flag shadow and writes ONE refusal entry",
           %{code: code, slug: slug} do
        fx = green!("req519-r-#{slug}")
        F.break_fact!(fx, code)

        assert {:error, {:on_precondition_failed, [^code], report}} = go_on(fx, "req519 try")

        assert mode!(fx) == :shadow
        # nothing was written by the flip itself: the only enabled entry is the shadow flip's
        assert F.entries(fx, @enabled) |> length() == 1

        # the refusal is committed AFTER the rollback (it would not exist if written inside it)
        assert [refusal] = F.entries(fx, @refused)
        assert refusal.action == @refused
        assert refusal.resource_type == "tenant"
        assert refusal.resource_id == fx.tenant_id
        assert refusal.actor_id == fx.admin.id
        assert refusal.trace_id == F.trace()
        assert refusal.before_state == %{"mode" => "shadow"}

        assert Enum.sort(Map.keys(refusal.after_state)) ==
                 ["evidence", "failed", "preconditions", "target"]

        assert refusal.after_state["target"] == "on"
        assert refusal.after_state["failed"] == [Atom.to_string(code)]
        assert refusal.after_state["preconditions"] == counts_of(report)
        refute F.uuid_in?(Jason.encode!(refusal.after_state))
      end
    end

    test "the evidence fact alone (fresh shadow tenant, no requests) refuses with exactly [:shadow_evidence_insufficient]" do
      fx = F.shadow_tenant!("req519-r-g6")

      assert {:error, {:on_precondition_failed, [:shadow_evidence_insufficient], report}} =
               go_on(fx, nil)

      assert report.evidence.criteria.duration == true
      assert report.evidence.criteria.requests == false
      assert mode!(fx) == :shadow
      assert [refusal] = F.entries(fx, @refused)
      assert refusal.after_state["failed"] == ["shadow_evidence_insufficient"]
    end

    test "every failing fact is named at once, in read order, in ONE refusal entry" do
      fx = F.shadow_tenant!("req519-r-all")
      F.break_all_facts!(fx)

      assert {:error, {:on_precondition_failed, failed, _report}} = go_on(fx, nil)

      assert failed == [
               :bindings_without_row,
               :org_inconsistent,
               :tokens_exceed_owner,
               :zero_tenant_wide_admins,
               :scoped_approvers_without_task_scope,
               :shadow_evidence_insufficient
             ]

      assert [refusal] = F.entries(fx, @refused)
      assert refusal.after_state["failed"] == Enum.map(failed, &Atom.to_string/1)
    end

    test "each attempt writes its own refusal entry; the flag stays shadow" do
      fx = F.shadow_tenant!("req519-r-twice")

      assert {:error, {:on_precondition_failed, _, _}} = go_on(fx, nil)
      assert {:error, {:on_precondition_failed, _, _}} = go_on(fx, nil)

      assert F.entries(fx, @refused) |> length() == 2
      assert mode!(fx) == :shadow
    end

    test "a refused off -> shadow stays unaudited (only refusals of on are recorded)" do
      fx = F.admin_tenant!("req519-r-stage1")
      _gap = F.gap!(fx)

      assert {:error, {:precondition_failed, [:bindings_without_row], _}} =
               flip(fx, :shadow, nil)

      assert F.entries(fx, @refused) == []
    end
  end

  # --- MU-39: a raise is a server fault, not a refusal ------------------------------------------

  describe "T-G9 / T-H9 (flip half) a raise inside the gate" do
    test "is {:transaction_failed, _}: the flag stays shadow and NO refusal entry is written (MU-39)" do
      fx = green!("req519-g9")

      result =
        F.with_renamed_table!(fx, "role_scope_grants", fn ->
          send(self(), {:result, go_on(fx, "req519 raise")})
        end)

      assert result == :ok
      assert_received {:result, {:error, {:transaction_failed, exception}}}
      assert is_exception(exception)

      assert mode!(fx) == :shadow
      assert F.entries(fx, @refused) == []
      assert F.entries(fx, @enabled) |> length() == 1
    end

    test "a raise from the EVIDENCE read (the last fact) is also a rolled-back fault, never a refusal" do
      fx = green!("req519-g9b")

      F.with_renamed_table!(fx, "scope_shadow_counters", fn ->
        send(self(), {:result, go_on(fx, nil)})
      end)

      assert_received {:result, {:error, {:transaction_failed, _exception}}}
      assert mode!(fx) == :shadow
      assert F.entries(fx, @refused) == []
    end
  end

  # --- MU-42: flush before the transaction ------------------------------------------------------

  describe "T-E16 (flip half) the in-memory counters are flushed before the gate reads" do
    test "a request counted in memory for a window date with no persisted counter is visible to the flip" do
      fx = F.shadow_tenant!("req519-e16")
      schema = fx.schema_name
      missing = DateTime.to_date(fx.now)

      # every window date but the last has persisted requests; the last exists only in memory
      for day <- F.window_dates(fx.now, 7), day != missing do
        :ok = F.put_count!(fx, day, :requests, 20)
      end

      for _n <- 1..20, do: :ok = ShadowEvidence.record(schema, :requests, missing)
      assert ShadowEvidence.counts_by_day(schema, missing, missing) == %{}

      # without the flush the evidence rule fails on `missing`; with it the gate passes
      assert {:ok, %{mode: :on}} = go_on(fx, nil)
      assert ShadowEvidence.counts_by_day(schema, missing, missing)[missing].requests == 20
    end
  end

  # --- MU-22: the scope-tree lock S is taken before the facts -----------------------------------

  describe "T-G10 (flip half) lock order on the shadow -> on path" do
    test "the six facts are read AFTER the scope-tree lock S: a gap committed by the S holder is seen (MU-22)" do
      fx = green!("req519-g10")
      schema = fx.schema_name
      group = RSG.fresh_group!(schema)
      test_pid = self()

      Locks.attach_error_handler(:req519_2fb)

      # The holder takes ONLY the tree lock S (lock A is free), so the flip gets A and T and then
      # parks on S; a fact read before S would run on a snapshot that predates the gap.
      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            :ok = ScopeNodePaths.lock!(schema)
            send(test_pid, :s_held)

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end

            # committed together with the release of S
            _gap = RSG.raw_binding!(schema, "PROCESS_OPERATOR", :platform_role, group.id)
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive :s_held, 10_000

      {worker, pid} = Locks.start_worker(fn -> go_on(fx, nil) end)
      Locks.wait_for_blocked([pid], 1)

      send(holder.pid, :release)
      assert {:ok, _gap} = Task.await(holder, Locks.await_ms())

      {result, _finished_at} = Task.await(worker, Locks.await_ms())

      assert {:error, {:on_precondition_failed, [:bindings_without_row], report}} = result
      assert report.bindings_without_row == 1
      assert mode!(fx) == :shadow
      refute_receive {:deadlock_detected, _}, 0
    end

    test "locks are taken in the order A, T, S: a flip queued on lock A never deadlocks with an S holder" do
      fx = green!("req519-g10b")
      schema = fx.schema_name
      test_pid = self()

      Locks.attach_error_handler(:req519_2fb_a)

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            :ok = Identity.lock_tenant_admins!(schema)
            send(test_pid, :a_held)

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive :a_held, 10_000

      {worker, pid} = Locks.start_worker(fn -> go_on(fx, nil) end)
      Locks.wait_for_blocked([pid], 1)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, Locks.await_ms())

      {result, _finished_at} = Task.await(worker, Locks.await_ms())
      assert {:ok, %{mode: :on}} = result
      refute_receive {:deadlock_detected, _}, 0
    end
  end

  # --- V7: attrs[:now] ---------------------------------------------------------------------------

  describe "V7 the clock seam" do
    test "a DateTime in attrs[:now] is honoured: the same tenant passes at fx.now" do
      fx = green!("req519-v7a")

      # at the REAL clock the tenant has only seconds of shadow, so it can only pass through the seam
      assert {:error, {:on_precondition_failed, failed, _}} =
               ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :on, F.attrs(fx, nil))

      assert :shadow_evidence_insufficient in failed

      assert {:ok, %{mode: :on}} = go_on(fx, nil)
    end

    test "anything but a DateTime is ignored (the real clock is used): never read, never a crash" do
      fx = green!("req519-v7b")

      for junk <- [
            "2030-01-01T00:00:00Z",
            1_900_000_000,
            nil,
            %{},
            :now,
            [~U[2030-01-01 00:00:00Z]]
          ] do
        attrs = fx |> F.attrs(nil) |> Map.put(:now, junk)

        assert {:error, {:on_precondition_failed, failed, _report}} =
                 ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, :on, attrs),
               inspect(junk)

        assert failed == [:shadow_evidence_insufficient]
      end

      assert mode!(fx) == :shadow
    end
  end

  defp counts_of(report) do
    Letflow.ScopeEnforcement.OnGate.counts_with_task_workers(report)
  end
end
