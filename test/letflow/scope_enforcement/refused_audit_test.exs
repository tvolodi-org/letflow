defmodule Letflow.ScopeEnforcement.RefusedAuditTest do
  @moduledoc """
  REQ-519 slice 2f-a (GH #2535), AC 14, AC 15 (refused half) and AC 18 (log half): the audit
  entry of a REFUSED flip to `on` (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.3 and 8.3, tests
  T-F1..T-F10, T-A5; SEC S-6, A-5; spec `test/specs/REQ-519-2f-a.md`):
  `Letflow.ScopeEnforcement.RefusedAudit.record/6`.

  `flip/4` cannot reach this module yet (`on` is unsettable until 2f-b), so every test calls
  `record/6` directly, with a REAL `OnGate` report of a tenant broken in exactly one way.

  The tenant fixture leaves the sandbox in `:auto` mode, so `Repo.in_transaction?/0` is false
  in the test process and `record/6` runs on committed, non-sandboxed state, the way
  `TenantAdminGuard.refuse/4` is tested (design A-5). The "inside a transaction" cases open an
  explicit `Repo.transaction`.

    * T-F1..T-F6 one entry per failing fact code, T-F7 `shadow_required`: exactly one
      `scope.enforcement_refused` entry, `resource_type "tenant"`, actor and trace from the
      attrs, `before_state` the previous mode, `after_state` the closed key set `target`,
      `failed`, `preconditions`, `evidence` (six reason counts, requests, criteria,
      `evidence_scope`), no id inside, NO flag change;
    * the entry survives the rollback of the refused flip (own transaction after it), and
      nothing is written inside an open transaction (a constant log line instead);
    * T-F9 / T-F10 a failed refusal audit still returns `:ok`, logs ONE constant line without any
      id, and leaves no entry (best effort, the 409 stays a 409);
    * T-A5 the entry is listed through `Audit.list_entries/1` and the chain verifies.

  `async: false`: committed writes, DDL (an audit fault trigger).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Audit
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.ScopeEnforcement.RefusedAudit
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture

  @action "scope.enforcement_refused"

  # code => {preconditions key that must be non-trivial, the expected value}
  @cases [
    {:bindings_without_row, "bindings_without_row", 1},
    {:org_inconsistent, "org_consistency", "inconsistent"},
    {:tokens_exceed_owner, "tokens_exceeding_owner", 1},
    {:zero_tenant_wide_admins, "explicit_tenant_wide_admins", 0},
    {:shadow_evidence_insufficient, "bindings_without_row", 0}
  ]

  # --- helpers ---------------------------------------------------------------------------------

  # A shadow tenant that satisfies every fact, then broken in exactly the way of `code`.
  defp broken!(code, slug_prefix) do
    fx = F.shadow_tenant!(slug_prefix)
    if code != :shadow_evidence_insufficient, do: :ok = F.satisfy!(fx, fx.now)
    break!(code, fx)
    fx
  end

  defp break!(:bindings_without_row, fx) do
    g = RSG.fresh_group!(fx.schema_name)
    _ = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)
    :ok
  end

  defp break!(:org_inconsistent, fx), do: F.seed_orphan_node!(fx.schema_name)

  defp break!(:tokens_exceed_owner, fx) do
    lone = RSG.user!(fx.schema_name)
    _ = F.raw_token!(fx.schema_name, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)
    :ok
  end

  defp break!(:zero_tenant_wide_admins, fx),
    do: F.remove_memberships!(fx.schema_name, fx.admin.id)

  defp break!(:shadow_evidence_insufficient, _fx), do: :ok

  defp refused(fx), do: F.entries(fx, @action)

  defp record(fx, previous, failed, report),
    do:
      RefusedAudit.record(
        fx.tenant_id,
        fx.schema_name,
        previous,
        failed,
        report,
        F.attrs(fx, nil)
      )

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  # --- T-F1..T-F6: one entry per failing code --------------------------------------------------

  describe "T-F1..T-F6 a refused gate is audited, one entry per failing code" do
    test "each code alone: the entry names it, carries the closed payload and changes no flag" do
      for {{code, key, expected}, index} <- Enum.with_index(@cases) do
        fx = broken!(code, "req519-f#{index}")
        {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)
        assert failed == [code], "#{code}: precondition of the scenario"

        assert :ok = record(fx, :shadow, failed, report)

        assert [entry] = refused(fx), "#{code}: exactly one entry"
        assert entry.actor_id == fx.admin.id
        assert entry.trace_id == F.trace()
        assert entry.resource_type == "tenant"
        assert entry.resource_id == fx.tenant_id
        assert entry.before_state == %{"mode" => "shadow"}

        assert Enum.sort(Map.keys(entry.after_state)) ==
                 ["evidence", "failed", "preconditions", "target"]

        assert entry.after_state["target"] == "on"
        assert entry.after_state["failed"] == [Atom.to_string(code)]

        assert entry.after_state ==
                 Map.merge(
                   %{"target" => "on", "failed" => [Atom.to_string(code)]},
                   OnGate.audit_state(report)
                 )

        assert entry.after_state["preconditions"][key] == expected, "#{code}: #{key}"

        # the flag did not move and nothing but the refusal was recorded for it
        assert mode!(fx) == :shadow
        assert F.entries(fx, "scope.enforcement_enabled") |> length() == 1
        assert F.entries(fx, "scope.enforcement_disabled") == []
      end
    end

    test "the payload keys are the closed sets: six preconditions, the evidence block, five reasons" do
      fx = broken!(:bindings_without_row, "req519-f-keys")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)
      assert :ok = record(fx, :shadow, failed, report)

      assert [entry] = refused(fx)
      state = entry.after_state

      assert Enum.sort(Map.keys(state["preconditions"])) ==
               Enum.sort([
                 "bindings_without_row",
                 "org_consistency",
                 "tokens_exceeding_owner",
                 "explicit_tenant_wide_admins",
                 "scoped_approvers",
                 "scoped_task_workers_without_task_scope"
               ])

      assert Enum.sort(Map.keys(state["evidence"])) ==
               ["criteria", "days_without_requests", "evidence_scope", "requests", "would_deny"]

      assert Enum.sort(Map.keys(state["evidence"]["would_deny"])) ==
               ~w(grants_unavailable no_grant_rows not_tenant_wide out_of_scope role_not_held unresolvable)

      assert Enum.sort(Map.keys(state["evidence"]["criteria"])) ==
               ~w(configuration duration every_day_has_requests no_blocking_would_deny requests)

      assert state["evidence"]["evidence_scope"] == "tenant_wide_and_admin_plane_routes_only"
    end

    test "every failing code of a multiply broken tenant is named, in the gate's order" do
      fx = F.shadow_tenant!("req519-f-multi")
      :ok = break!(:bindings_without_row, fx)
      :ok = break!(:zero_tenant_wide_admins, fx)
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      assert failed == [
               :bindings_without_row,
               :zero_tenant_wide_admins,
               :shadow_evidence_insufficient
             ]

      assert :ok = record(fx, :shadow, failed, report)

      assert [entry] = refused(fx)

      assert entry.after_state["failed"] == [
               "bindings_without_row",
               "zero_tenant_wide_admins",
               "shadow_evidence_insufficient"
             ]
    end

    test "no id, name or token data is inside the stored entry (INV-2)" do
      fx = broken!(:tokens_exceed_owner, "req519-f-ids")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)
      assert :ok = record(fx, :shadow, failed, report)

      assert [entry] = refused(fx)
      json = Jason.encode!(entry.after_state)

      refute F.uuid_in?(json)
      refute json =~ fx.schema_name
      refute json =~ "lf_tok_"
      refute json =~ "PROCESS_DESIGNER"
    end
  end

  describe "T-F7 shadow_required" do
    test "an off -> on refusal is audited with failed [shadow_required] and no counts" do
      fx = F.admin_tenant!("req519-f7")

      assert :ok = record(fx, :off, [:shadow_required], nil)

      assert [entry] = refused(fx)
      assert entry.before_state == %{"mode" => "off"}
      assert entry.after_state == %{"target" => "on", "failed" => ["shadow_required"]}
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == F.trace()
      assert mode!(fx) == :off
    end

    test "attrs without actor or trace are recorded as nil, never raise" do
      fx = F.admin_tenant!("req519-f7b")

      assert :ok =
               RefusedAudit.record(
                 fx.tenant_id,
                 fx.schema_name,
                 :off,
                 [:shadow_required],
                 nil,
                 %{}
               )

      assert [entry] = refused(fx)
      assert entry.actor_id == nil
      assert entry.trace_id == nil
    end
  end

  # --- the entry survives the rollback, and is never written inside a transaction --------------

  describe "T-F8 own transaction, after the rollback" do
    test "the refusal written after a rolled-back flip transaction persists" do
      fx = broken!(:bindings_without_row, "req519-f8")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      # what flip/4 does: the flip transaction returns the refusal (rolled back), THEN it records
      assert {:error, {:on_precondition_failed, ^failed, ^report}} =
               Repo.transaction(fn ->
                 Repo.rollback({:on_precondition_failed, failed, report})
               end)

      refute Repo.in_transaction?()
      assert :ok = record(fx, :shadow, failed, report)

      assert [_entry] = refused(fx)
    end

    test "inside an open transaction nothing is written and one constant line is logged (A-5)" do
      fx = broken!(:bindings_without_row, "req519-f8b")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      {result, log} =
        with_log(fn ->
          Repo.transaction(fn ->
            assert Repo.in_transaction?()
            outcome = record(fx, :shadow, failed, report)
            assert F.entries(fx, @action) == []
            Repo.rollback({:done, outcome})
          end)
        end)

      assert {:error, {:done, :ok}} = result
      assert refused(fx) == []

      lines = F.lines_with(log, "scope_enforcement_refusal_not_recorded")
      assert length(lines) == 1
      assert hd(lines) =~ "scope_enforcement_refusal_not_recorded reason=inside_transaction"
      refute F.uuid_in?(hd(lines))
      refute hd(lines) =~ fx.schema_name
    end

    test "each refused request writes its own entry" do
      fx = broken!(:org_inconsistent, "req519-f8c")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      assert :ok = record(fx, :shadow, failed, report)
      assert :ok = record(fx, :shadow, failed, report)

      # one entry per refused request: a second refused flip is a second entry
      assert length(refused(fx)) == 2
    end
  end

  # --- T-F9 / T-F10: best effort ---------------------------------------------------------------

  describe "T-F9 / T-F10 a failed refusal audit still returns :ok" do
    test "a raising audit write logs ONE constant line without any id and leaves no entry" do
      fx = broken!(:bindings_without_row, "req519-f10")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)
      name = "req519_2fa_refusal_fault"

      _ =
        SyncScopeFixture.create_audit_fault!(
          fx.schema_name,
          name,
          "NEW.action = '#{@action}'"
        )

      try do
        {result, log} = with_log(fn -> record(fx, :shadow, failed, report) end)

        assert result == :ok
        lines = F.lines_with(log, "scope_enforcement_refusal_not_recorded")
        assert length(lines) == 1
        assert hd(lines) =~ "scope_enforcement_refusal_not_recorded reason=exception"
        refute F.uuid_in?(hd(lines))
        refute hd(lines) =~ fx.schema_name
        refute hd(lines) =~ "injected fault"
      after
        SyncScopeFixture.drop_audit_fault!(fx.schema_name, name)
      end

      assert refused(fx) == []
      assert mode!(fx) == :shadow
    end

    test "a successful write logs nothing of its own" do
      fx = broken!(:bindings_without_row, "req519-f9")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

      {result, log} = with_log(fn -> record(fx, :shadow, failed, report) end)

      assert result == :ok
      assert F.lines_with(log, "scope_enforcement_refusal_not_recorded") == []
      assert length(refused(fx)) == 1
    end

    test "the gate evaluation itself logs no id and no token data (the captured log, own lines only)" do
      fx = broken!(:tokens_exceed_owner, "req519-f9b")

      {_result, log} = with_log(fn -> OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now) end)

      # Ecto debug QUERY lines may carry bound ids, so only lines this feature writes are judged
      assert F.lines_with(log, "scope_enforcement") == []
      refute log =~ "lf_tok_"
    end
  end

  # --- T-A5: listing and chain -----------------------------------------------------------------

  describe "T-A5 the refused entry is listed without error" do
    test "through Audit.list_entries/1 with the tenant filters, and the chain still verifies" do
      fx = broken!(:bindings_without_row, "req519-a5")
      {report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)
      assert :ok = record(fx, :shadow, failed, report)

      assert {:ok, %{items: items, has_more: false}} =
               Audit.list_entries(%{
                 prefix: fx.schema_name,
                 page_size: 50,
                 resource_type: "tenant",
                 resource_id: fx.tenant_id
               })

      actions =
        items
        |> Enum.map(& &1.action)
        |> Enum.filter(&String.starts_with?(&1, "scope.enforcement"))
        |> Enum.sort()

      assert actions == Enum.sort([@action, "scope.enforcement_enabled"])

      refused_item = Enum.find(items, &(&1.action == @action))
      assert refused_item.after_state["failed"] == ["bindings_without_row"]

      assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)
    end
  end
end
