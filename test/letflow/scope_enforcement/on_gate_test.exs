defmodule Letflow.ScopeEnforcement.OnGateTest do
  @moduledoc """
  REQ-519 slice 2f-a (GH #2535), AC 9 and AC 18 (gate half): `Letflow.ScopeEnforcement.OnGate`
  (design `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.4 and 8.3,
  tests T-G1..T-G10, SEC code-gate merge conditions of step-16 and REVIEWER notes of step-17;
  spec `test/specs/REQ-519-2f-a.md`).

  Every test here calls `OnGate.evaluate/3` (and the lock-free `ScopeEnforcement.integrity/1`
  snapshot) directly, with an injected `now`; the same gate inside `flip/4` (the `shadow -> on`
  transition) is exercised by the 2f-b tests.

    * T-G1..T-G6: each of the six facts alone refuses with exactly its stable code, on top of a
      tenant that satisfies every fact (so nothing else can fail), including the SEC conditions
      for fact 3 (a flagged service-principal owner STILL counts) and fact 4 (C-4: interactive,
      explicit, active, no token owner, no flagged principal);
    * T-G8: ALL six failing at once are ALL named, in the fixed read order, with stable codes and
      no id anywhere in the report (INV-2);
    * T-G9: a raise in any fact (a table renamed inside a rolled-back transaction, a prefix that
      is not a tenant schema name) PROPAGATES, never becomes "no failure" (INV-8);
    * T-G10: the evaluation takes no lock of its own (it completes while another connection
      holds lock A and the scope-tree lock S), and the flip that the gate will run inside still
      reads its facts AFTER those locks (shadow path, a gap committed by the lock holder is
      seen);
    * the `ScopeEnforcement.integrity/1` `on_gate` block at function level.

  `async: false`: real tenant schemas, committed DDL and writes, real connections for the lock
  tests.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.ScopeEnforcement.ShadowWindow
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @codes [
    :bindings_without_row,
    :org_inconsistent,
    :tokens_exceed_owner,
    :zero_tenant_wide_admins,
    :scoped_approvers_without_task_scope,
    :shadow_evidence_insufficient
  ]

  # --- helpers ---------------------------------------------------------------------------------

  # A tenant that satisfies all six facts at `fx.now`.
  defp green!(slug_prefix) do
    fx = F.shadow_tenant!(slug_prefix)
    :ok = F.satisfy!(fx, fx.now)
    fx
  end

  defp evaluate(fx), do: OnGate.evaluate(fx.tenant_id, fx.schema_name, fx.now)

  defp gap!(fx) do
    g = RSG.fresh_group!(fx.schema_name)
    RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)
  end

  # A holder of lock A and the scope-tree lock S on its own connection until `:release`.
  defp hold_locks!(schema) do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          :ok = Identity.lock_tenant_admins!(schema)
          :ok = ScopeNodePaths.lock!(schema)
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(test_pid, {:locks_held, backend})

          receive do
            :release -> :ok
          after
            15_000 -> :timeout
          end
        end)
      end)

    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive {:locks_held, backend}, 10_000
    {holder, backend}
  end

  # --- baseline --------------------------------------------------------------------------------

  describe "a tenant that satisfies every fact" do
    test "T-G0 the gate passes and the report carries the six counts and the evidence" do
      fx = green!("req519-g0")

      {report, failed} = evaluate(fx)

      assert failed == []
      assert report.bindings_without_row == 0
      assert report.org_consistency == :ok
      assert report.tokens_exceeding_owner == 0
      assert report.explicit_tenant_wide_admins == 1
      assert report.scoped_approvers == 0
      assert report.scoped_task_workers_without_task_scope == 0
      assert report.evidence.shadow_since == fx.t0
      assert report.evidence.requests == 160
      assert report.evidence.days_without_requests == 0

      assert report.evidence.criteria == %{
               duration: true,
               requests: true,
               every_day_has_requests: true,
               no_blocking_would_deny: true,
               configuration: true
             }

      assert Enum.sort(Map.keys(report)) ==
               Enum.sort([
                 :bindings_without_row,
                 :org_consistency,
                 :tokens_exceeding_owner,
                 :explicit_tenant_wide_admins,
                 :scoped_approvers,
                 :scoped_task_workers_without_task_scope,
                 :evidence
               ])
    end

    test "the evaluation is read-only: no audit entry, no mode change, no counter change" do
      fx = green!("req519-g0b")
      audit_before = Repo.aggregate(Letflow.Audit.Entry, :count, prefix: fx.schema_name)

      _ = evaluate(fx)
      _ = evaluate(fx)

      assert Repo.aggregate(Letflow.Audit.Entry, :count, prefix: fx.schema_name) == audit_before
      assert {:ok, :shadow} = ScopeEnforcement.get_mode(fx.tenant_id)
    end

    test "the gate does not read the stored mode: an `off` tenant is evaluated the same way" do
      fx = green!("req519-g0c")
      _ = F.flip!(fx, :off, "req519 gate is mode independent")

      # T0 is now nil (the latest transition left shadow), everything else still holds.
      {report, failed} = evaluate(fx)
      assert failed == [:shadow_evidence_insufficient]
      assert report.evidence.shadow_since == nil
    end
  end

  # --- one fact at a time ----------------------------------------------------------------------

  describe "T-G1 fact 1: bindings without a grant row" do
    test "a binding with no row refuses with exactly [:bindings_without_row]" do
      fx = green!("req519-g1")
      _gap = gap!(fx)

      {report, failed} = evaluate(fx)

      assert failed == [:bindings_without_row]
      assert report.bindings_without_row == 1
    end
  end

  describe "T-G2 fact 2: organisation consistency" do
    test "an inconsistent scope tree refuses with exactly [:org_inconsistent]" do
      fx = green!("req519-g2")
      :ok = F.seed_orphan_node!(fx.schema_name)

      {report, failed} = evaluate(fx)

      assert failed == [:org_inconsistent]
      assert report.org_consistency == :inconsistent
    end
  end

  describe "T-G3 fact 3: tokens that exceed their owner" do
    test "a token whose roles exceed its owner's refuses with exactly [:tokens_exceed_owner]" do
      fx = green!("req519-g3")
      lone = RSG.user!(fx.schema_name)
      _token = F.raw_token!(fx.schema_name, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)

      {report, failed} = evaluate(fx)

      assert failed == [:tokens_exceed_owner]
      assert report.tokens_exceeding_owner == 1
    end

    test "T-G2 (design id) a flagged service-principal owner with an exceeding token STILL refuses" do
      fx = green!("req519-g3b")
      lone = RSG.user!(fx.schema_name)
      _token = F.raw_token!(fx.schema_name, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)
      :ok = F.flag_service_principal!(fx.schema_name, lone.id)

      # the flag exempts only the mint subset check, never the flip gate
      {report, failed} = evaluate(fx)

      assert failed == [:tokens_exceed_owner]
      assert report.tokens_exceeding_owner == 1
    end
  end

  describe "T-G4 fact 4: explicit INTERACTIVE tenant-wide administrators (SEC C-4)" do
    test "a tenant with no administrator is refused; after an admin is bound the same call passes" do
      fx = green!("req519-g4a")
      :ok = F.remove_memberships!(fx.schema_name, fx.admin.id)

      {report, failed} = evaluate(fx)
      assert failed == [:zero_tenant_wide_admins]
      assert report.explicit_tenant_wide_admins == 0

      other = RSG.user!(fx.schema_name)
      _ = TokenMintFixture.grant_roles!(fx.schema_name, other.id, ["TENANT_ADMIN"])

      {report, failed} = evaluate(fx)
      assert failed == []
      assert report.explicit_tenant_wide_admins == 1
    end

    test "the only TENANT_ADMIN member sits in a zero-row binding: refused (the stage-1 count still counts it)" do
      fx = green!("req519-g4b")
      group_id = RSG.group_of!(fx.schema_name, "TENANT_ADMIN")
      assert RSG.raw_delete_rows!(fx.schema_name, group_id, "TENANT_ADMIN") == 1

      # MU-25: the gate must not use the stage-1 count, which still counts this member
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 1
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      {report, failed} = evaluate(fx)

      assert failed == [:bindings_without_row, :zero_tenant_wide_admins]
      assert report.explicit_tenant_wide_admins == 0
    end

    test "(i) a tenant whose only explicit admin is a flagged service principal is refused" do
      fx = green!("req519-g4c")
      :ok = F.flag_service_principal!(fx.schema_name, fx.admin.id)

      # the 517 explicit count still counts it (unchanged); the interactive variant does not
      assert Identity.count_explicit_tenant_wide_admins(fx.schema_name) == 1
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      {report, failed} = evaluate(fx)

      assert failed == [:zero_tenant_wide_admins]
      assert report.explicit_tenant_wide_admins == 0
    end

    test "(ii) a tenant whose only TENANT_ADMIN is a live token owner is refused" do
      fx = green!("req519-g4d")
      :ok = F.remove_memberships!(fx.schema_name, fx.admin.id)
      owner = RSG.user!(fx.schema_name)
      _token = F.raw_token!(fx.schema_name, owner.id, ["TENANT_ADMIN"], fx.admin.id)

      assert Identity.count_tenant_wide_admins(fx.schema_name) == 1
      assert Identity.count_explicit_tenant_wide_admins(fx.schema_name) == 1
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      {report, failed} = evaluate(fx)

      # the token also exceeds its owner (fact 3); both are named, in read order
      assert failed == [:tokens_exceed_owner, :zero_tenant_wide_admins]
      assert report.explicit_tenant_wide_admins == 0
    end

    test "(iii) one human explicit admin plus a flagged service principal passes" do
      fx = green!("req519-g4e")
      principal = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])
      :ok = F.flag_service_principal!(fx.schema_name, principal.id)

      {report, failed} = evaluate(fx)

      assert failed == []
      assert report.explicit_tenant_wide_admins == 1
    end

    test "(iv) an inactive human admin does not count" do
      fx = green!("req519-g4f")
      :ok = F.set_status!(fx.schema_name, fx.admin.id, :inactive)

      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      {report, failed} = evaluate(fx)

      assert failed == [:zero_tenant_wide_admins]
      assert report.explicit_tenant_wide_admins == 0
    end

    test "a member of a scoped-only TENANT_ADMIN group counts only through a tenant-wide USER row" do
      fx = green!("req519-g4g")
      schema = fx.schema_name
      group_id = RSG.group_of!(schema, "TENANT_ADMIN")
      node = RSG.node!(schema)
      assert RSG.raw_delete_rows!(schema, group_id, "TENANT_ADMIN") == 1
      :ok = RSG.raw_scoped_row!(schema, group_id, "TENANT_ADMIN", node)

      assert Identity.count_interactive_explicit_tenant_wide_admins(schema) == 0
      assert {_report, [:zero_tenant_wide_admins]} = evaluate(fx)

      :ok = RSG.raw_user_row!(schema, fx.admin.id, "TENANT_ADMIN", nil)

      assert Identity.count_interactive_explicit_tenant_wide_admins(schema) == 1
      assert {_report, []} = evaluate(fx)
    end

    test "the interactive count is distinct per user: two admins count two, one admin in the group once" do
      fx = green!("req519-g4h")
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 1

      _second = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 2
    end
  end

  describe "T-G5 fact 5: scoped approvers without a task scope" do
    test "a scoped approver refuses with exactly [:scoped_approvers_without_task_scope]" do
      fx = green!("req519-g5a")
      _worker = F.scoped_task_worker!(fx.schema_name, true)

      {report, failed} = evaluate(fx)

      assert failed == [:scoped_approvers_without_task_scope]
      assert report.scoped_approvers == 1
      assert report.scoped_task_workers_without_task_scope == 0
    end

    test "a scoped task worker who is NOT an approver is informational only and never blocks" do
      fx = green!("req519-g5b")
      _worker = F.scoped_task_worker!(fx.schema_name, false)

      {report, failed} = evaluate(fx)

      assert failed == []
      assert report.scoped_approvers == 0
      assert report.scoped_task_workers_without_task_scope == 1
    end
  end

  describe "T-G6 fact 6: shadow evidence" do
    test "no persisted evidence refuses with exactly [:shadow_evidence_insufficient]" do
      fx = F.shadow_tenant!("req519-g6")

      {report, failed} = evaluate(fx)

      assert failed == [:shadow_evidence_insufficient]
      assert report.evidence.requests == 0
      assert report.evidence.criteria.duration == true
      assert report.evidence.criteria.requests == false
    end
  end

  # --- all failures, order, stable codes, no ids -----------------------------------------------

  describe "T-G8 every failing fact is named" do
    setup do
      fx = F.shadow_tenant!("req519-g8")
      schema = fx.schema_name

      # fact 5 first: the scope-node writer needs a consistent tree
      _worker = F.scoped_task_worker!(schema, true)
      # fact 1
      _gap = gap!(fx)
      # fact 3
      lone = RSG.user!(schema)
      _token = F.raw_token!(schema, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)
      # fact 4
      :ok = F.remove_memberships!(schema, fx.admin.id)
      # fact 2 (raw, after every writer-built node)
      :ok = F.seed_orphan_node!(schema)
      # fact 6: no counters seeded

      %{fx: fx}
    end

    test "all six codes, in the fixed read order, none dropped", %{fx: fx} do
      {_report, failed} = evaluate(fx)

      assert failed == @codes
    end

    test "the report holds counts, enums and booleans only: no id anywhere (INV-2)", %{fx: fx} do
      {report, failed} = evaluate(fx)

      assert Enum.all?(failed, &(&1 in @codes))
      refute F.uuid_in?(inspect(report))
      refute inspect(report) =~ fx.tenant_id
      refute inspect(report) =~ fx.schema_name

      assert report.bindings_without_row == 1
      assert report.org_consistency == :inconsistent
      assert report.tokens_exceeding_owner == 1
      assert report.explicit_tenant_wide_admins == 0
      assert report.scoped_approvers == 1
    end

    test "MU-27: the audit payload of the same report carries all six counts and no id", %{fx: fx} do
      {report, _failed} = evaluate(fx)

      state = OnGate.audit_state(report)

      assert state["preconditions"] == %{
               "bindings_without_row" => 1,
               "org_consistency" => "inconsistent",
               "tokens_exceeding_owner" => 1,
               "explicit_tenant_wide_admins" => 0,
               "scoped_approvers" => 1,
               "scoped_task_workers_without_task_scope" => 0
             }

      refute F.uuid_in?(Jason.encode!(state))
    end
  end

  describe "OnGate.audit_state/1 (pure)" do
    test "string keys, atoms turned into strings, the closed key sets" do
      report = %{
        bindings_without_row: 2,
        org_consistency: :unavailable,
        tokens_exceeding_owner: 3,
        explicit_tenant_wide_admins: 4,
        scoped_approvers: 5,
        scoped_task_workers_without_task_scope: 6,
        evidence: %{
          shadow_since: nil,
          window_from: ~D[2026-01-01],
          window_to: ~D[2026-01-08],
          requests: 7,
          days_without_requests: 1,
          would_deny: %{
            role_not_held: 1,
            no_grant_rows: 2,
            not_tenant_wide: 3,
            out_of_scope: 4,
            unresolvable: 5,
            grants_unavailable: 6
          },
          criteria: %{
            duration: false,
            requests: true,
            every_day_has_requests: false,
            no_blocking_would_deny: false,
            configuration: true
          },
          evidence_scope: "tenant_wide_and_admin_plane_routes_only"
        }
      }

      state = OnGate.audit_state(report)

      assert Map.keys(state) |> Enum.sort() == ["evidence", "preconditions"]

      assert state["preconditions"] == %{
               "bindings_without_row" => 2,
               "org_consistency" => "unavailable",
               "tokens_exceeding_owner" => 3,
               "explicit_tenant_wide_admins" => 4,
               "scoped_approvers" => 5,
               "scoped_task_workers_without_task_scope" => 6
             }

      assert state["evidence"] == %{
               "would_deny" => %{
                 "role_not_held" => 1,
                 "no_grant_rows" => 2,
                 "not_tenant_wide" => 3,
                 "out_of_scope" => 4,
                 "unresolvable" => 5,
                 "grants_unavailable" => 6
               },
               "requests" => 7,
               "days_without_requests" => 1,
               "criteria" => %{
                 "duration" => false,
                 "requests" => true,
                 "every_day_has_requests" => false,
                 "no_blocking_would_deny" => false,
                 "configuration" => true
               },
               "evidence_scope" => "tenant_wide_and_admin_plane_routes_only"
             }

      # JSON-encodable as it stands (it is stored in a jsonb column)
      assert is_binary(Jason.encode!(state))
    end
  end

  # --- T-G9: a raise is never "no failure" -----------------------------------------------------

  describe "T-G9 a raised read propagates (INV-8)" do
    test "each table a fact reads, renamed with committed DDL, makes evaluate/3 RAISE" do
      fx = green!("req519-g9")

      for table <- [
            "tenant_role",
            "role_scope_grants",
            "scope_node_paths",
            "api_tokens",
            "group_members",
            "audit_entries",
            "scope_shadow_counters"
          ] do
        :ok =
          F.with_renamed_table!(fx, table, fn ->
            assert_raise Postgrex.Error, fn -> evaluate(fx) end
          end)
      end

      # nothing was left renamed: the same call passes again
      assert {_report, []} = evaluate(fx)
    end

    test "a schema whose name is not tenant_<32 hex> raises ArgumentError at the evidence read" do
      fx = green!("req519-g9b")

      F.with_plain_schema(fx, fn plain ->
        error =
          assert_raise ArgumentError, fn -> OnGate.evaluate(fx.tenant_id, plain, fx.now) end

        assert error.message == "invalid tenant schema prefix"
      end)
    end

    test "evaluate/3 accepts only a DateTime clock (no thresholds, no options)" do
      fx = green!("req519-g9c")

      # opaque values, so the compiler's type checker does not (rightly) flag the bad calls
      no_clock = F.opaque(nil)
      text_clock = F.opaque("2026-01-01T00:00:00Z")

      assert_raise FunctionClauseError, fn ->
        OnGate.evaluate(fx.tenant_id, fx.schema_name, no_clock)
      end

      assert_raise FunctionClauseError, fn ->
        OnGate.evaluate(fx.tenant_id, fx.schema_name, text_clock)
      end

      Code.ensure_loaded!(OnGate)
      refute function_exported?(OnGate, :evaluate, 4)
    end
  end

  # --- T-G10: locks ----------------------------------------------------------------------------

  describe "T-G10 lock order" do
    setup do
      Locks.attach_error_handler(:req519_2fa)
      :ok
    end

    test "evaluate/3 takes no lock of its own: it completes while lock A and the tree lock S are held elsewhere" do
      fx = green!("req519-g10a")
      {holder, _backend} = hold_locks!(fx.schema_name)

      task = Task.async(fn -> evaluate(fx) end)
      assert {:ok, {_report, []}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, Locks.await_ms())
      refute_receive {:deadlock_detected, _}, 0
    end

    test "the integrity snapshot is lock-free too, and its on_gate block agrees with the gate" do
      fx = green!("req519-g10b")
      {holder, _backend} = hold_locks!(fx.schema_name)

      task = Task.async(fn -> ScopeEnforcement.integrity(fx.schema_name) end)
      assert {:ok, report} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      assert is_list(report.on_gate.blocking)

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, Locks.await_ms())
    end

    test "the shadow flip reads its facts AFTER locks A and S: a gap committed by the lock holder is seen" do
      fx = F.admin_tenant!("req519-g10c")
      schema = fx.schema_name
      group = RSG.fresh_group!(schema)
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            :ok = Identity.lock_tenant_admins!(schema)
            :ok = ScopeNodePaths.lock!(schema)
            send(test_pid, :locks_held)

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end

            # committed together with the release: the flip, queued on lock A, must see it
            _gap = RSG.raw_binding!(schema, "PROCESS_OPERATOR", :platform_role, group.id)
          end)
        end)

      on_exit(fn -> send(holder.pid, :release) end)
      assert_receive :locks_held, 10_000

      {worker, pid} =
        Locks.start_worker(fn ->
          ScopeEnforcement.flip(fx.tenant_id, schema, :shadow, F.attrs(fx, nil))
        end)

      Locks.wait_for_blocked([pid], 1)
      send(holder.pid, :release)
      assert {:ok, _gap} = Task.await(holder, Locks.await_ms())

      {result, _finished_at} = Task.await(worker, Locks.await_ms())

      assert {:error, {:precondition_failed, [:bindings_without_row], report}} = result
      assert report.bindings_without_row == 1
      assert {:ok, :off} = ScopeEnforcement.get_mode(fx.tenant_id)
      refute_receive {:deadlock_detected, _}, 0
    end
  end

  # --- the integrity on_gate block (function level) --------------------------------------------

  describe "ScopeEnforcement.integrity/1 on_gate (AC 9, last sentence)" do
    test "the block holds blocking, information, counts and evidence, and agrees with OnGate" do
      fx = green!("req519-gi1")

      %{on_gate: gate} = ScopeEnforcement.integrity(fx.schema_name)

      assert Enum.sort(Map.keys(gate)) == [:blocking, :counts, :evidence, :information]

      assert Enum.sort(Map.keys(gate.counts)) ==
               Enum.sort([
                 :bindings_without_row,
                 :org_consistency,
                 :tokens_exceeding_owner,
                 :explicit_tenant_wide_admins,
                 :scoped_approvers
               ])

      # the snapshot uses the real clock: T0 is seconds old, no counter exists for today
      assert gate.blocking == [:shadow_evidence_insufficient]
      assert gate.information == %{scoped_task_workers_without_task_scope: 0}

      assert gate.counts == %{
               bindings_without_row: 0,
               org_consistency: :ok,
               tokens_exceeding_owner: 0,
               explicit_tenant_wide_admins: 1,
               scoped_approvers: 0
             }

      assert gate.evidence.shadow_since == fx.t0
      assert gate.evidence.criteria.duration == false
      assert gate.evidence.evidence_scope == ShadowWindow.evidence_scope()
    end

    test "the stage-1 findings keep the OLD admin count while on_gate.blocking uses the explicit one" do
      fx = green!("req519-gi2")
      :ok = F.flag_service_principal!(fx.schema_name, fx.admin.id)

      report = ScopeEnforcement.integrity(fx.schema_name)

      # the old count still counts the flagged principal, so the stage-1 finding is absent
      assert report.findings == []
      assert :zero_tenant_wide_admins in report.on_gate.blocking
      assert report.on_gate.counts.explicit_tenant_wide_admins == 0
    end

    test "every fact seeded: blocking names them in read order, information carries the worker count" do
      fx = F.shadow_tenant!("req519-gi3")
      schema = fx.schema_name
      _approver = F.scoped_task_worker!(schema, true)
      _worker = F.scoped_task_worker!(schema, false)
      _gap = gap!(fx)

      %{on_gate: gate} = ScopeEnforcement.integrity(schema)

      assert gate.blocking == [
               :bindings_without_row,
               :scoped_approvers_without_task_scope,
               :shadow_evidence_insufficient
             ]

      assert gate.counts.bindings_without_row == 1
      assert gate.counts.scoped_approvers == 1
      assert gate.information == %{scoped_task_workers_without_task_scope: 1}
    end

    test "the snapshot writes no audit entry" do
      fx = green!("req519-gi4")
      before = Repo.aggregate(Letflow.Audit.Entry, :count, prefix: fx.schema_name)

      _ = ScopeEnforcement.integrity(fx.schema_name)

      assert Repo.aggregate(Letflow.Audit.Entry, :count, prefix: fx.schema_name) == before
    end

    test "SEC F-1 / REVIEWER C-1: a prefix that is not a tenant schema name raises ArgumentError 'invalid tenant schema prefix'" do
      fx = green!("req519-gi5")

      F.with_plain_schema(fx, fn plain ->
        error = assert_raise ArgumentError, fn -> ScopeEnforcement.integrity(plain) end
        assert error.message == "invalid tenant schema prefix"
      end)
    end

    test "a failing fact read raises out of integrity/1 (no partial report)" do
      fx = green!("req519-gi6")

      :ok =
        F.with_renamed_table!(fx, "scope_shadow_counters", fn ->
          assert_raise Postgrex.Error, fn -> ScopeEnforcement.integrity(fx.schema_name) end
        end)

      assert %{on_gate: _gate} = ScopeEnforcement.integrity(fx.schema_name)
    end
  end

  # --- the audit vocabulary --------------------------------------------------------------------

  test "the stored audit vocabulary the gate relies on is owned by ScopeEnforcement" do
    assert ScopeEnforcement.flip_actions() ==
             ["scope.enforcement_enabled", "scope.enforcement_disabled"]

    assert ScopeEnforcement.flip_resource_type() == "tenant"
  end
end
