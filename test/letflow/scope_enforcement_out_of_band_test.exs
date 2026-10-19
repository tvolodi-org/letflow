defmodule Letflow.ScopeEnforcementOutOfBandTest do
  @moduledoc """
  GH #2883 (the operator break-glass of REQ-519, decision 0051 A11; design
  `lib/letflow/design/gh2883-scope-enforcement-break-glass.md` section 5, tests T-BG-1..T-BG-19;
  spec `test/specs/GH2883-break-glass.md`): `Letflow.ScopeEnforcement.flip_out_of_band/3`.

    * input checks before any database access, in the order target, reason, operator, each a
      distinct error that writes nothing (T-BG-1 to T-BG-3, T-BG-10, T-BG-11);
    * the success entries: `scope.enforcement_disabled`, `actor_id` NULL, `operator`, `source`
      and `node` in the `after_state`, one entry in the SAME transaction as the flag, never
      without the flag (T-BG-4 to T-BG-6, T-BG-12);
    * the flag is the ONLY thing that changes, and no interactive admin, user, token or passing
      gate fact is needed (T-BG-7, T-BG-8);
    * only a tenant stored `on` can be broken open, to `shadow` or `off` (T-BG-9, T-BG-28);
    * `on -> shadow` restarts the shadow window, `on -> off` needs the full way back
      (T-BG-13);
    * lock order A, T, C with a bounded wait and an explicit transaction timeout (T-BG-14a/b/c,
      T-BG-15), the platform tenant, an inactive tenant and the next request (T-BG-16 to
      T-BG-18).

  Every locking, timing and window case runs on COMMITTED state (the tenant fixture's sandbox
  `:auto` mode): `async: false`. The tests use their own throwaway tenants; no real tenant is
  touched, and `Letflow.Support.BreakGlassFixture` stores every committed `on` tenant `off`
  again in an `on_exit`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.LockOrderHelpers, as: Locks
  alias Letflow.PlatformTenant
  alias Letflow.Plugs.AuthPipeline
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.OnGate
  alias Letflow.ScopeEnforcement.ShadowWindow
  alias Letflow.Support.BreakGlassFixture, as: BG
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.SyncScopeFixture

  @op "ops.handle-2883"
  @reason "INC-2883: identity provider outage"
  @disabled "scope.enforcement_disabled"
  @lock_timeout_key :scope_break_glass_lock_timeout_ms

  setup do
    BG.purge_stale!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp attrs, do: %{operator: @op, reason: @reason}

  defp oob(fx, target, call_attrs),
    do: ScopeEnforcement.flip_out_of_band(fx.tenant_id, target, call_attrs)

  defp go(fx, target), do: oob(fx, target, attrs())

  # nothing changed: still `on`, the same number of audit entries
  defp assert_untouched(fx, entries_before, label) do
    assert BG.mode(fx) == "on", "#{label}: the flag changed"
    assert BG.entry_count(fx) == entries_before, "#{label}: an audit entry was written"
  end

  defp flip(fx, target, reason),
    do: ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, target, F.attrs(fx, reason))

  # --- T-BG-1 .. T-BG-3, T-BG-10: the checks before the transaction ----------------------------

  describe "T-BG-1 the reason is mandatory for both targets" do
    test "missing, nil, blank and non-binary reasons are :reason_required and write nothing" do
      fx = BG.on_tenant!("t1")
      before = BG.entry_count(fx)

      for target <- [:shadow, :off],
          reason <- [:missing, nil, "", "   ", "\n\t \r\n", 123, :some_atom, ["x"], %{}] do
        call_attrs =
          if reason == :missing, do: %{operator: @op}, else: %{operator: @op, reason: reason}

        assert oob(fx, target, call_attrs) == {:error, :reason_required},
               "#{target} / #{inspect(reason)}"
      end

      assert_untouched(fx, before, "blank reasons")
    end

    test "the reason is checked BEFORE the operator, and the target before both" do
      fx = BG.on_tenant!("t1b")
      before = BG.entry_count(fx)

      assert oob(fx, :shadow, %{reason: nil, operator: nil}) == {:error, :reason_required}
      assert oob(fx, :off, %{reason: "ok reason", operator: nil}) == {:error, :operator_required}

      assert oob(fx, :shadow, %{reason: "bad\u0000reason", operator: "bad label"}) ==
               {:error, :invalid_reason}

      assert oob(fx, :on, %{reason: nil, operator: nil}) == {:error, :invalid_target}
      assert_untouched(fx, before, "order of checks")
    end
  end

  describe "T-BG-2 a reason that fails the audit rule" do
    test "control, format, bidi and separator characters and 501 codepoints are :invalid_reason" do
      fx = BG.on_tenant!("t2")
      before = BG.entry_count(fx)

      bad = [
        "a\u0000b",
        "a\x7Fb",
        "a\u0085b",
        "a\u200Bb",
        "a\u202Eb",
        "a\u2066b",
        "a\u2028b",
        "a\nb",
        String.duplicate("x", 501),
        <<0xFF, 0xFE>>
      ]

      for target <- [:shadow, :off], reason <- bad do
        assert oob(fx, target, %{operator: @op, reason: reason}) == {:error, :invalid_reason},
               "#{target} / #{inspect(reason)}"
      end

      assert_untouched(fx, before, "invalid reasons")
    end

    test "exactly 500 codepoints is accepted and stored" do
      fx = BG.on_tenant!("t2b")
      reason = String.duplicate("é", 500)

      assert {:ok, %{mode: :shadow}} = oob(fx, :shadow, %{operator: @op, reason: reason})
      assert [entry] = F.entries(fx, @disabled)
      assert entry.after_state["reason"] == reason
    end
  end

  describe "T-BG-3 the operator label" do
    test "missing, nil, blank and non-binary labels are :operator_required" do
      fx = BG.on_tenant!("t3a")
      before = BG.entry_count(fx)

      for target <- [:shadow, :off], operator <- [:missing, nil, "", "   ", "\n", 42, :atom] do
        call_attrs =
          if operator == :missing,
            do: %{reason: @reason},
            else: %{reason: @reason, operator: operator}

        assert oob(fx, target, call_attrs) == {:error, :operator_required},
               "#{target} / #{inspect(operator)}"
      end

      assert_untouched(fx, before, "missing operators")
    end

    test "labels outside the rule are :invalid_operator" do
      fx = BG.on_tenant!("t3b")
      before = BG.entry_count(fx)

      bad = [
        String.duplicate("a", 65),
        "a b",
        "a\nb",
        "ab\n",
        " ab",
        "ab ",
        "ab\u202E",
        "a\u200Bb",
        "a\u0000b",
        ~s(a"b),
        "a'b",
        "a\#{b}",
        "a;b",
        "a/b",
        ".ab",
        "-ab",
        "_ab",
        "@ab",
        "é",
        "aé"
      ]

      for target <- [:shadow, :off], operator <- bad do
        assert oob(fx, target, %{reason: @reason, operator: operator}) ==
                 {:error, :invalid_operator},
               "#{target} / #{inspect(operator)}"
      end

      assert_untouched(fx, before, "invalid operators")
    end

    test "the rule itself: valid_operator_label?/1 is pure and exact" do
      for good <- [
            "a",
            "0",
            "A0._@+-x",
            "ops.handle-2883",
            "x@example.org",
            String.duplicate("a", 64)
          ] do
        assert ScopeEnforcement.valid_operator_label?(good), inspect(good)
      end

      for bad <- ["", "ab\n", String.duplicate("a", 65), "a b", ".a", nil, 1, :a, %{}] do
        refute ScopeEnforcement.valid_operator_label?(bad), inspect(bad)
      end
    end

    test "a 64-byte label with every allowed punctuation character is accepted and stored as given" do
      fx = BG.on_tenant!("t3c")
      label = "Z" <> String.duplicate("a.b_c@d+e-", 6) <> "xyz"
      assert byte_size(label) == 64

      assert {:ok, %{mode: :off}} = oob(fx, :off, %{operator: label, reason: @reason})
      assert [entry] = F.entries(fx, @disabled)
      assert entry.after_state["operator"] == label
    end
  end

  describe "T-BG-10 the target" do
    test "only :shadow and :off are accepted; :on, strings, nil and unknown atoms are :invalid_target" do
      fx = BG.on_tenant!("t10")
      before = BG.entry_count(fx)

      for target <- [:on, "on", "ON", "shadow", "off", nil, :bogus, 1, %{}] do
        assert oob(fx, target, attrs()) == {:error, :invalid_target}, inspect(target)
      end

      assert_untouched(fx, before, "invalid targets")
    end

    test "parse_out_of_band_target/1 accepts exactly the strings shadow and off and mints no atom" do
      assert ScopeEnforcement.parse_out_of_band_target("shadow") == {:ok, :shadow}
      assert ScopeEnforcement.parse_out_of_band_target("off") == {:ok, :off}

      junk = "gh2883-never-an-atom-#{System.unique_integer([:positive])}"

      for value <- [
            "on",
            "ON",
            "Shadow",
            "OFF",
            " shadow",
            "shadow ",
            "",
            junk,
            nil,
            :shadow,
            :off,
            1
          ] do
        assert ScopeEnforcement.parse_out_of_band_target(value) == {:error, :invalid_target},
               inspect(value)
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(junk) end
    end
  end

  # --- T-BG-11: the tenant ----------------------------------------------------------------------

  describe "T-BG-11 an unknown tenant" do
    test "a random id, malformed ids and non-ids are :tenant_not_found, never a raise, never a write" do
      fx = BG.on_tenant!("t11")
      before = BG.entry_count(fx)

      for id <- [Ecto.UUID.generate(), "not-a-uuid", "", nil, 123, :atom, fx.schema_name] do
        assert ScopeEnforcement.flip_out_of_band(id, :shadow, attrs()) ==
                 {:error, :tenant_not_found},
               inspect(id)
      end

      assert_untouched(fx, before, "unknown tenant ids")
    end

    test "a tenants row without a provisioned schema (no registration) is :tenant_not_found" do
      slug = Letflow.TenantSlugFixture.unique_slug("gh2883-t11-bare")

      tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: slug, display_name: "GH2883 bare tenant", idp_realm_id: "realm-#{slug}"},
          :disabled
        )
        |> Repo.insert!()

      on_exit(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id)) end)
      :ok = ScopeEnforcementFixture.set_stored_mode!(tenant.id, :on)
      BG.register_cleanup(%{tenant_id: tenant.id})

      assert ScopeEnforcement.flip_out_of_band(tenant.id, :shadow, attrs()) ==
               {:error, :tenant_not_found}

      assert {:ok, :on} = ScopeEnforcement.get_mode(tenant.id)
    end
  end

  # --- T-BG-4 .. T-BG-6, T-BG-12: the entry and the transaction -----------------------------------

  describe "T-BG-4 on -> shadow" do
    test "stores shadow and writes exactly one disabled entry with a NULL actor and the operator facts" do
      fx = BG.on_tenant!("t4")
      entries_before = BG.entry_count(fx)

      assert {:ok, %{mode: :shadow, previous: :on, changed: true}} =
               oob(fx, :shadow, %{operator: @op, reason: "  " <> @reason <> "  "})

      assert BG.mode(fx) == "shadow"
      assert BG.entry_count(fx) == entries_before + 1

      assert [entry] = F.entries(fx, @disabled)
      assert entry.actor_id == nil
      assert entry.action == "scope.enforcement_disabled"
      assert entry.resource_type == "tenant"
      assert entry.resource_id == fx.tenant_id
      assert entry.before_state == %{"mode" => "on"}

      # the padded reason is stored TRIMMED; the node is the VM that ran the write
      assert entry.after_state == %{
               "mode" => "shadow",
               "reason" => @reason,
               "operator" => @op,
               "source" => "operator_break_glass",
               "node" => Atom.to_string(node())
             }

      assert entry.trace_id =~ ~r/\Abreak-glass-[0-9a-f]{32}\z/

      # a NULL-actor entry is a valid link of the hash chain
      assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)
    end

    test "two runs generate two different trace ids" do
      first = BG.on_tenant!("t4b")
      second = BG.on_tenant!("t4c")
      assert {:ok, _} = go(first, :shadow)
      assert {:ok, _} = go(second, :shadow)
      [a] = F.entries(first, @disabled)
      [b] = F.entries(second, @disabled)
      refute a.trace_id == b.trace_id
    end
  end

  describe "T-BG-5 on -> off" do
    test "stores off, returns the documented result and writes the same entry shape" do
      fx = BG.on_tenant!("t5")

      assert {:ok, %{mode: :off, previous: :on, changed: true} = result} = go(fx, :off)
      assert Map.keys(result) |> Enum.sort() == [:changed, :mode, :previous]
      assert BG.mode(fx) == "off"

      assert [entry] = F.entries(fx, @disabled)
      assert entry.actor_id == nil
      assert entry.before_state == %{"mode" => "on"}

      assert entry.after_state == %{
               "mode" => "off",
               "reason" => @reason,
               "operator" => @op,
               "source" => "operator_break_glass",
               "node" => Atom.to_string(node())
             }

      assert F.entries(fx, "scope.enforcement_enabled") |> length() == 1
      assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)
    end
  end

  describe "T-BG-6 the flag and the entry commit together" do
    test "an audit insert that returns an error rolls the flag back: {:audit_failed, _}, still on, no entry" do
      fx = BG.on_tenant!("t6a")
      before = BG.entry_count(fx)

      result = BG.with_unwritable_audit(fx, fn -> go(fx, :shadow) end)

      assert {:error, {:audit_failed, :invalid_schema_name}} = result
      assert_untouched(fx, before, "audit_failed")

      # nothing is stuck: the same call succeeds once the audit is writable again
      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)
      assert BG.mode(fx) == "shadow"
    end

    test "an audit insert that RAISES is {:transaction_failed, _}: still on, no entry, for both targets" do
      fx = BG.on_tenant!("t6b")
      before = BG.entry_count(fx)
      name = "gh2883_audit_fault_#{System.unique_integer([:positive])}"
      SyncScopeFixture.create_audit_fault!(fx.schema_name, name, "NEW.action = '#{@disabled}'")

      try do
        for target <- [:shadow, :off] do
          assert {:error, {:transaction_failed, %Postgrex.Error{}}} = go(fx, target)
          assert_untouched(fx, before, "raised audit insert (#{target})")
        end
      after
        SyncScopeFixture.drop_audit_fault!(fx.schema_name, name)
      end

      assert {:ok, %{mode: :off}} = go(fx, :off)
      assert [_one] = F.entries(fx, @disabled)
    end

    test "without a fault the flag and the entry are both present: they cannot diverge" do
      fx = BG.on_tenant!("t6c")
      assert {:ok, _} = go(fx, :off)
      assert BG.mode(fx) == "off"
      assert length(F.entries(fx, @disabled)) == 1
    end
  end

  describe "T-BG-12 only :operator and :reason are read from attrs" do
    test "an actor id, a clock, a trace id, a mode and a node in attrs change nothing" do
      fx = BG.on_tenant!("t12")

      hostile =
        Map.merge(attrs(), %{
          actor_id: fx.admin.id,
          now: ~U[2000-01-01 00:00:00Z],
          trace_id: "attacker-trace-0001",
          mode: :on,
          node: "attacker@host",
          source: "interactive",
          previous: :shadow
        })

      assert {:ok, %{mode: :shadow, previous: :on, changed: true}} = oob(fx, :shadow, hostile)

      assert [entry] = F.entries(fx, @disabled)
      assert entry.actor_id == nil
      assert entry.trace_id =~ ~r/\Abreak-glass-[0-9a-f]{32}\z/
      assert entry.after_state["node"] == Atom.to_string(node())
      assert entry.after_state["source"] == "operator_break_glass"
      assert entry.after_state["mode"] == "shadow"
      refute inspect(entry.after_state) =~ "attacker"
      # the entry is stamped by the server clock
      assert abs(DateTime.diff(DateTime.utc_now(), entry.timestamp, :second)) < 300
    end
  end

  # --- T-BG-7, T-BG-8: only the flag; no admin needed -------------------------------------------

  describe "T-BG-7 only the flag changes" do
    test "every identity table, the tenant row (bar the flag) and the registration are identical; audit +1" do
      fx = BG.on_tenant!("t7")
      # give the snapshot something to compare: a token, a second user
      _token = F.raw_token!(fx.schema_name, fx.admin.id, ["TENANT_ADMIN"], fx.admin.id)
      Letflow.Support.TokenMintFixture.role_holder!(fx.schema_name, ["PROCESS_DESIGNER"])

      before = BG.snapshot(fx)
      entries_before = BG.entry_count(fx)
      assert BG.count(fx, "users") >= 2
      assert BG.count(fx, "api_tokens") >= 1
      assert BG.count(fx, "group_members") >= 2
      assert BG.count(fx, "role_scope_grants") >= 1

      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)

      assert BG.snapshot(fx) == before
      assert BG.entry_count(fx) == entries_before + 1
    end

    test "on -> off changes only the flag too" do
      fx = BG.on_tenant!("t7b")
      before = BG.snapshot(fx)
      assert {:ok, %{mode: :off}} = go(fx, :off)
      assert BG.snapshot(fx) == before
    end
  end

  describe "T-BG-8 it works without an interactive admin and with every gate fact failing" do
    test "(i) a tenant with no user at all" do
      fx = BG.bare_on_tenant!("t8a")
      assert BG.count(fx, "users") == 0
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)
      assert BG.mode(fx) == "shadow"
    end

    test "(ii) the only TENANT_ADMIN is a token owner" do
      fx = BG.on_tenant!("t8b")
      :ok = F.remove_memberships!(fx.schema_name, fx.admin.id)
      _token = F.raw_token!(fx.schema_name, fx.admin.id, ["TENANT_ADMIN"], fx.admin.id)
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      assert {:ok, %{mode: :off}} = go(fx, :off)
      assert BG.mode(fx) == "off"
    end

    test "(iii) the only TENANT_ADMIN is a flagged service principal" do
      fx = BG.on_tenant!("t8c")
      :ok = F.flag_service_principal!(fx.schema_name, fx.admin.id)
      assert Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name) == 0

      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)
    end

    test "(iv) every gate fact fails (T9 gaps, inconsistent tree, zero admins, ...): still succeeds, no gate consulted" do
      fx = BG.on_tenant!("t8d")
      :ok = F.break_all_facts!(fx)

      {_report, failed} = OnGate.evaluate(fx.tenant_id, fx.schema_name, DateTime.utc_now())
      assert :zero_tenant_wide_admins in failed
      assert :bindings_without_row in failed
      assert :org_inconsistent in failed

      assert {:ok, %{mode: :shadow, previous: :on}} = go(fx, :shadow)
      assert [entry] = F.entries(fx, @disabled)
      refute Map.has_key?(entry.after_state, "preconditions")
    end
  end

  # --- T-BG-9, T-BG-28: only an `on` tenant ------------------------------------------------------

  describe "T-BG-9 only a tenant stored on can be broken open" do
    test "stored off and stored shadow, both targets: {:not_enforced, mode}, nothing written, no refusal entry" do
      for stored <- [:off, :shadow] do
        fx = BG.on_tenant!("t9-#{stored}")
        :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, stored)
        before = BG.entry_count(fx)
        updated = BG.updated_at(fx)

        for target <- [:shadow, :off] do
          assert go(fx, target) == {:error, {:not_enforced, stored}}, "#{stored} -> #{target}"
        end

        assert BG.mode(fx) == Atom.to_string(stored)
        assert BG.entry_count(fx) == before
        assert BG.updated_at(fx) == updated
        assert F.entries(fx, @disabled) == []
        assert F.entries(fx, "scope.enforcement_refused") == []
      end
    end
  end

  describe "T-BG-28 a second identical run" do
    test "answers {:not_enforced, mode} and leaves exactly one entry" do
      for target <- [:shadow, :off] do
        fx = BG.on_tenant!("t28-#{target}")
        assert {:ok, %{mode: ^target}} = go(fx, target)

        assert go(fx, target) == {:error, {:not_enforced, target}}
        assert go(fx, :off) == {:error, {:not_enforced, target}}
        assert length(F.entries(fx, @disabled)) == 1
      end
    end
  end

  # --- T-BG-13: the shadow window ----------------------------------------------------------------

  describe "T-BG-13 the shadow window" do
    test "on -> shadow moves T0 to the new entry, the duration criterion is false and shadow -> on is refused" do
      fx = BG.on_tenant!("t13a")
      t0_before = F.latest_flip_entry!(fx).timestamp

      # gate evidence that WOULD satisfy the window of the old T0: not enough after the restart
      :ok = F.seed_requests!(fx, DateTime.utc_now(), 7, 20)

      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)

      entry = F.latest_flip_entry!(fx)
      assert entry.action == @disabled
      assert DateTime.compare(entry.timestamp, t0_before) == :gt

      {report, satisfied?} =
        ShadowWindow.evaluate(fx.tenant_id, fx.schema_name, DateTime.utc_now())

      assert report.shadow_since == entry.timestamp
      assert report.criteria.duration == false
      refute satisfied?

      assert {:error, {:on_precondition_failed, failed, _report}} = flip(fx, :on, nil)
      assert :shadow_evidence_insufficient in failed
      assert BG.mode(fx) == "shadow"
    end

    test "on -> off leaves no window: off -> on is :shadow_required and there is no shadow start" do
      fx = BG.on_tenant!("t13b")
      assert {:ok, %{mode: :off}} = go(fx, :off)

      {report, _satisfied?} =
        ShadowWindow.evaluate(fx.tenant_id, fx.schema_name, DateTime.utc_now())

      assert report.shadow_since == nil
      assert flip(fx, :on, nil) == {:error, :shadow_required}
      assert BG.mode(fx) == "off"
    end

    test "the command has no parameter that shortens the window: extra keys and options change nothing" do
      fx = BG.on_tenant!("t13c")
      hostile = Map.merge(attrs(), %{min_days: 0, window: :skip, now: ~U[2000-01-01 00:00:00Z]})
      assert {:ok, %{mode: :shadow}} = oob(fx, :shadow, hostile)

      {report, _} = ShadowWindow.evaluate(fx.tenant_id, fx.schema_name, DateTime.utc_now())
      assert report.criteria.duration == false
    end
  end

  # --- T-BG-14: lock order, bounded waits ---------------------------------------------------------

  describe "T-BG-14a serialisation on lock A" do
    test "the command blocks behind a held lock A, and commits once it is released" do
      fx = BG.on_tenant!("t14a")
      {holder, barrier_pid} = BG.hold_lock_a!(fx.schema_name)

      {task, pid} = Locks.start_worker(fn -> go(fx, :shadow) end)
      Locks.wait_for_blocked([pid], 1)
      assert barrier_pid in Locks.blockers(pid)
      # nothing is committed while it waits
      assert BG.mode(fx) == "on"

      BG.release!(holder)

      assert {{:ok, %{mode: :shadow, previous: :on}}, _done} = Task.await(task, Locks.await_ms())
      assert BG.mode(fx) == "shadow"
    end
  end

  describe "T-BG-14b lock order: A before T" do
    test "while the command waits for A, the tenants row is still free (NOWAIT succeeds)" do
      fx = BG.on_tenant!("t14b")
      {:ok, id} = Ecto.UUID.dump(fx.tenant_id)
      {holder, barrier_pid} = BG.hold_lock_a!(fx.schema_name)

      {task, pid} = Locks.start_worker(fn -> go(fx, :off) end)
      Locks.wait_for_blocked([pid], 1)
      assert barrier_pid in Locks.blockers(pid)

      # T is not held by the waiting command: a second connection takes it at once
      assert {:ok, %{num_rows: 1}} =
               Repo.transaction(fn ->
                 Repo.query!("SELECT 1 FROM tenants WHERE id = $1 FOR UPDATE NOWAIT", [id])
               end)

      BG.release!(holder)
      assert {{:ok, %{mode: :off}}, _done} = Task.await(task, Locks.await_ms())
    end
  end

  describe "T-BG-14c every lock wait is bounded and a lock expiry is :lock_conflict" do
    test "(i) a held lock A: :lock_conflict, no write, no entry" do
      fx = BG.on_tenant!("t14c1")
      before = BG.entry_count(fx)
      {holder, _pid} = BG.hold_lock_a!(fx.schema_name)

      result = BG.with_env(@lock_timeout_key, 300, fn -> go(fx, :shadow) end)

      assert result == {:error, :lock_conflict}
      BG.release!(holder)
      assert_untouched(fx, before, "lock A held")
    end

    test "(ii) a held tenants row (the second wait): :lock_conflict" do
      fx = BG.on_tenant!("t14c2")
      before = BG.entry_count(fx)
      {holder, _pid} = BG.hold_tenant_row!(fx.tenant_id)

      result = BG.with_env(@lock_timeout_key, 300, fn -> go(fx, :off) end)

      assert result == {:error, :lock_conflict}
      BG.release!(holder)
      assert_untouched(fx, before, "tenants row held")
    end

    test "(ii) a held audit chain lock (the third wait): :lock_conflict and the flag change is rolled back" do
      fx = BG.on_tenant!("t14c3")
      before = BG.entry_count(fx)
      {holder, _pid} = Locks.hold_row(fx.schema_name, :audit_chain)

      result = BG.with_env(@lock_timeout_key, 300, fn -> go(fx, :shadow) end)

      assert result == {:error, :lock_conflict}
      BG.release!(holder)
      assert_untouched(fx, before, "audit chain held")
    end

    test "(iii) the transaction timeout is strictly above three lock waits and above the 15 s default" do
      for lock_ms <- [1, 300, 10_000, 30_000] do
        assert ScopeEnforcement.transaction_timeout_ms(lock_ms) == 3 * lock_ms + 10_000
        assert ScopeEnforcement.transaction_timeout_ms(lock_ms) > 3 * lock_ms
      end

      # the production default: the key is unset and the lock wait is 10 s
      assert Application.fetch_env(:letflow, @lock_timeout_key) == :error
      assert ScopeEnforcement.transaction_timeout_ms(10_000) == 40_000
      assert ScopeEnforcement.transaction_timeout_ms(10_000) > 15_000
    end
  end

  # --- T-BG-15: a race with the interactive flip -------------------------------------------------

  describe "T-BG-15 a race with the interactive flip/4" do
    test "flip/4 queued first: it wins, the break-glass sees off and refuses; exactly one new entry" do
      fx = BG.on_tenant!("t15a")
      before = BG.entry_count(fx)

      {flip_result, oob_result} =
        BG.queue_two!(
          fx.schema_name,
          fn -> flip(fx, :off, "gh2883 interactive off") end,
          fn -> go(fx, :shadow) end
        )

      assert {:ok, %{mode: :off, previous: :on, changed: true}} = flip_result
      assert oob_result == {:error, {:not_enforced, :off}}
      assert BG.mode(fx) == "off"
      assert BG.entry_count(fx) == before + 1
      assert [entry] = F.entries(fx, @disabled)
      refute Map.has_key?(entry.after_state, "operator")
      assert entry.actor_id == fx.admin.id
    end

    test "the break-glass queued first: it wins, flip/4 then finds the mode already off (no-op); one new entry" do
      fx = BG.on_tenant!("t15b")
      before = BG.entry_count(fx)

      {oob_result, flip_result} =
        BG.queue_two!(
          fx.schema_name,
          fn -> go(fx, :off) end,
          fn -> flip(fx, :off, "gh2883 interactive off") end
        )

      assert {:ok, %{mode: :off, previous: :on}} = oob_result
      assert {:ok, %{mode: :off, changed: false}} = flip_result
      assert BG.entry_count(fx) == before + 1
      assert [entry] = F.entries(fx, @disabled)
      assert entry.after_state["operator"] == @op
    end

    test "two break-glass runs queued together: exactly one applies" do
      fx = BG.on_tenant!("t15c")
      before = BG.entry_count(fx)

      {first, second} =
        BG.queue_two!(fx.schema_name, fn -> go(fx, :shadow) end, fn -> go(fx, :off) end)

      assert {:ok, %{mode: :shadow}} = first
      assert second == {:error, {:not_enforced, :shadow}}
      assert BG.entry_count(fx) == before + 1
    end
  end

  # --- T-BG-16 .. T-BG-18 -------------------------------------------------------------------------

  describe "T-BG-16 the platform tenant" do
    test "a platform tenant stored on can be broken open; its PLATFORM_ADMIN platform scope is unaffected" do
      fx = BG.on_tenant!("t16")
      PlatformTenantFixture.pin!(fx.tenant_id)

      facts = fn ->
        {PlatformTenant.platform_tenant?(fx.tenant_id),
         PlatformTenant.effective_role_strings(fx.tenant_id, ["PLATFORM_ADMIN", "TENANT_ADMIN"]),
         PlatformTenant.scope_facts(fx.tenant_id, ["PLATFORM_ADMIN"])}
      end

      assert {true, roles_before, _scope} = facts_before = facts.()
      assert "PLATFORM_ADMIN" in roles_before
      before = BG.snapshot(fx)

      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)

      assert facts.() == facts_before
      assert BG.snapshot(fx) == before
    end
  end

  describe "T-BG-17 an inactive tenant" do
    test "a tenant with status inactive stored on can be broken open" do
      fx = BG.on_tenant!("t17")
      {:ok, id} = Ecto.UUID.dump(fx.tenant_id)
      Repo.query!("UPDATE tenants SET status = 'inactive' WHERE id = $1", [id])

      assert {:ok, %{mode: :off}} = go(fx, :off)
      assert BG.mode(fx) == "off"
    end
  end

  describe "T-BG-18 the effect on the next request" do
    test "the auth pipeline context carries the new mode on the very next request, uncached" do
      fx = BG.on_tenant!("t18a")

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(fx.admin.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: fx.schema_name
        )

      request_mode = fn ->
        conn =
          conn(:get, "/whatever")
          |> put_req_header("authorization", "Bearer " <> plaintext)
          |> put_req_header("x-tenant-slug", fx.tenant.slug)
          |> AuthPipeline.call(AuthPipeline.init([]))

        refute conn.halted
        conn.assigns.auth_context.scope_enforcement
      end

      assert request_mode.() == :on
      assert {:ok, %{mode: :shadow}} = go(fx, :shadow)
      assert request_mode.() == :shadow
    end

    test "and the same for on -> off" do
      fx = BG.on_tenant!("t18b")

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(fx.admin.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: fx.schema_name
        )

      request_mode = fn ->
        conn(:get, "/whatever")
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> put_req_header("x-tenant-slug", fx.tenant.slug)
        |> AuthPipeline.call(AuthPipeline.init([]))
        |> then(& &1.assigns.auth_context.scope_enforcement)
      end

      assert request_mode.() == :on
      assert {:ok, %{mode: :off}} = go(fx, :off)
      assert request_mode.() == :off
    end
  end
end
