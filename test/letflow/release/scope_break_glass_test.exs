defmodule Letflow.Release.ScopeBreakGlassTest do
  @moduledoc """
  GH #2883 (design `lib/letflow/design/gh2883-scope-enforcement-break-glass.md` sections 3.2,
  3.9, 3.10 and 5, tests T-BG-20..T-BG-26; spec `test/specs/GH2883-break-glass.md`): the operator
  entry point `Letflow.Release.ScopeBreakGlass.run/5`, called in-process.

    * the slug resolves by exact match against the public `tenants` table and every other
      spelling is the same `ERROR unknown_tenant` (T-BG-20);
    * a real run needs `confirm: <slug>` and a dry run writes nothing (T-BG-21);
    * the printed protocol: `TARGET`, then `DRYRUN` / `OK` / `ERROR <tag>`, and NEVER an id, a
      schema name, the reason, the operator label, the node name or an exception message
      (T-BG-22);
    * the order of the checks (T-BG-23) and the constant log lines: ONE fault line per fault, one
      refusal line per refusal, the operator label only when it passes the label rule
      (T-BG-24, T-BG-25);
    * the function never halts, `exit_code/1` maps the result (T-BG-26).

  The log assertions look ONLY at the lines that carry the `scope_break_glass_` marker: a log
  capture also holds the Ecto debug QUERY lines, which legitimately contain ids and the slug.

  `async: false`: committed state, advisory locks, DDL and VM-global application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Letflow.Release.ScopeBreakGlass
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.BreakGlassFixture, as: BG
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.SyncScopeFixture

  @op "gh2883.op-marker"
  @reason "GH2883-REASON-MARKER ticket 7"
  @lock_timeout_key :scope_break_glass_lock_timeout_ms
  @release_path "lib/letflow/release/scope_break_glass.ex"

  setup do
    BG.purge_stale!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  # `{result, output_lines, log}` of one in-process call.
  defp call(slug, target, reason, operator, opts) do
    {{result, out}, log} =
      with_log(fn ->
        with_io(fn -> ScopeBreakGlass.run(slug, target, reason, operator, opts) end)
      end)

    {result, String.split(out, "\n", trim: true), log}
  end

  defp apply_opts(fx), do: [confirm: fx.tenant.slug]

  # the marker lines of the log (never the Ecto debug lines), reduced to the constant part
  defp marker_lines(log, marker) do
    for line <- String.split(log, "\n"),
        String.contains?(line, marker),
        [constant] <- [Regex.run(~r/#{marker}.*$/, line)],
        do: String.trim_trailing(constant)
  end

  defp bg_lines(log), do: marker_lines(log, "scope_break_glass_")

  defp target_line(fx, current, target),
    do: ~s(TARGET slug=#{inspect(fx.tenant.slug)} current_mode=#{current} target=#{target})

  defp assert_untouched(fx, entries_before, label) do
    assert BG.mode(fx) == "on", "#{label}: the flag changed"
    assert BG.entry_count(fx) == entries_before, "#{label}: an audit entry was written"
  end

  # --- the success protocol ------------------------------------------------------------------------

  describe "a successful run" do
    test "on -> shadow prints TARGET and OK, returns the result and writes one entry" do
      fx = BG.on_tenant!("r1")
      before = BG.entry_count(fx)

      {result, lines, log} = call(fx.tenant.slug, "shadow", @reason, @op, apply_opts(fx))

      assert result == {:ok, %{outcome: :applied, previous: :on, mode: :shadow}}

      assert lines == [
               target_line(fx, "on", "shadow"),
               ~s(OK slug=#{inspect(fx.tenant.slug)} previous=on mode=shadow ) <>
                 "action=scope.enforcement_disabled shadow_window_restarted=true"
             ]

      assert BG.mode(fx) == "shadow"
      assert BG.entry_count(fx) == before + 1
      assert [entry] = F.entries(fx, "scope.enforcement_disabled")
      assert entry.actor_id == nil
      assert entry.after_state["operator"] == @op
      assert entry.after_state["reason"] == @reason

      # T-BG-25: ONE success line, operator only, no slug, id or reason
      assert bg_lines(log) == [
               "scope_break_glass_applied previous=on mode=shadow operator=" <> @op
             ]
    end

    test "on -> off reports shadow_window_restarted=false and run/4 defaults the options" do
      fx = BG.on_tenant!("r2")

      assert {{:error, :confirm_required}, _lines, _log} =
               call_four(fx.tenant.slug, "off", @reason, @op)

      assert BG.mode(fx) == "on"

      {result, lines, log} = call(fx.tenant.slug, "off", @reason, @op, apply_opts(fx))

      assert result == {:ok, %{outcome: :applied, previous: :on, mode: :off}}

      assert List.last(lines) ==
               ~s(OK slug=#{inspect(fx.tenant.slug)} previous=on mode=off ) <>
                 "action=scope.enforcement_disabled shadow_window_restarted=false"

      assert bg_lines(log) == ["scope_break_glass_applied previous=on mode=off operator=" <> @op]
    end

    test "unknown option keys are ignored" do
      fx = BG.on_tenant!("r3")

      {result, _lines, _log} =
        call(fx.tenant.slug, "shadow", @reason, @op, confirm: fx.tenant.slug, frobnicate: true)

      assert {:ok, %{outcome: :applied}} = result
    end
  end

  defp call_four(slug, target, reason, operator) do
    {{result, out}, log} =
      with_log(fn -> with_io(fn -> ScopeBreakGlass.run(slug, target, reason, operator) end) end)

    {result, String.split(out, "\n", trim: true), log}
  end

  # --- T-BG-20 ----------------------------------------------------------------------------------------

  describe "T-BG-20 slug resolution" do
    test "only the exact slug resolves; every other spelling is the same uniform unknown_tenant" do
      fx = BG.on_tenant!("t20")
      slug = fx.tenant.slug
      before = BG.entry_count(fx)

      variants = [
        "gh2883-no-such-tenant-#{System.unique_integer([:positive])}",
        String.upcase(slug),
        " " <> slug,
        slug <> " ",
        slug <> "\n",
        slug <> <<0>>,
        String.slice(slug, 0, 12),
        String.slice(slug, 0, byte_size(slug) - 1),
        fx.tenant_id,
        fx.schema_name,
        "",
        nil,
        123,
        :atom,
        ["x"],
        String.duplicate("a", 129),
        <<0xFF, 0xFE, 0xFD>>
      ]

      for variant <- variants, target <- ["shadow", "off"] do
        {result, lines, _log} = call(variant, target, @reason, @op, confirm: variant)

        assert result == {:error, :unknown_tenant}, inspect(variant)
        assert lines == ["ERROR unknown_tenant"], inspect(variant)
      end

      assert_untouched(fx, before, "unknown slugs")
    end

    test "a tenants row with no provisioned schema is unknown_tenant too" do
      slug = Letflow.TenantSlugFixture.unique_slug("gh2883-t20-bare")

      tenant =
        %Letflow.Identity.Tenant{}
        |> Letflow.Identity.Tenant.create_changeset(
          %{slug: slug, display_name: "GH2883 bare", idp_realm_id: "realm-#{slug}"},
          :disabled
        )
        |> Repo.insert!()

      on_exit(fn ->
        Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant.id))
      end)

      :ok = ScopeEnforcementFixture.set_stored_mode!(tenant.id, :on)
      BG.register_cleanup(%{tenant_id: tenant.id})

      {result, lines, _log} = call(slug, "shadow", @reason, @op, confirm: slug)
      assert result == {:error, :unknown_tenant}
      assert lines == ["ERROR unknown_tenant"]
      assert {:ok, :on} = ScopeEnforcement.get_mode(tenant.id)
    end
  end

  # --- T-BG-21 ----------------------------------------------------------------------------------------

  describe "T-BG-21 confirm and dry run" do
    test "a real run without confirm, or with another slug, changes nothing" do
      fx = BG.on_tenant!("t21a")
      slug = fx.tenant.slug
      before = BG.entry_count(fx)

      {result, lines, _log} = call(slug, "shadow", @reason, @op, [])
      assert result == {:error, :confirm_required}
      assert lines == [target_line(fx, "on", "shadow"), "ERROR confirm_required"]

      for wrong <- [
            "gh2883-other-slug",
            String.upcase(slug),
            slug <> " ",
            " " <> slug,
            String.slice(slug, 0, 10),
            "",
            123,
            :atom
          ] do
        {result, lines, _log} = call(slug, "shadow", @reason, @op, confirm: wrong)
        assert result == {:error, :confirm_mismatch}, inspect(wrong)
        assert List.last(lines) == "ERROR confirm_mismatch", inspect(wrong)
      end

      # only a boolean true is a dry run; a truthy look-alike is a real run that needs confirm
      for not_true <- [1, "true", :yes, nil] do
        {result, _lines, _log} = call(slug, "shadow", @reason, @op, dry_run: not_true)
        assert result == {:error, :confirm_required}, inspect(not_true)
      end

      assert_untouched(fx, before, "confirm guard")
    end

    test "the exact slug as confirm applies" do
      fx = BG.on_tenant!("t21b")
      {result, _lines, _log} = call(fx.tenant.slug, "off", @reason, @op, confirm: fx.tenant.slug)
      assert {:ok, %{outcome: :applied, mode: :off}} = result
      assert BG.mode(fx) == "off"
    end

    test "a dry run needs no confirm and writes nothing: entries, flag and updated_at are identical" do
      fx = BG.on_tenant!("t21c")
      before = BG.entry_count(fx)
      updated = BG.updated_at(fx)
      snapshot = BG.snapshot(fx)

      for target <- ["shadow", "off"] do
        {result, lines, log} = call(fx.tenant.slug, target, @reason, @op, dry_run: true)

        assert result ==
                 {:ok, %{outcome: :dry_run, previous: :on, mode: String.to_existing_atom(target)}}

        assert lines == [target_line(fx, "on", target), "DRYRUN would_change=true"]
        # a dry run logs nothing of its own
        assert bg_lines(log) == []
      end

      assert_untouched(fx, before, "dry run")
      assert BG.updated_at(fx) == updated
      assert BG.snapshot(fx) == snapshot
    end

    test "a dry run on a tenant not stored on prints ERROR not_enforced and still writes nothing" do
      for stored <- [:off, :shadow] do
        fx = BG.on_tenant!("t21d-#{stored}")
        :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, stored)
        before = BG.entry_count(fx)

        {result, lines, _log} = call(fx.tenant.slug, "shadow", @reason, @op, dry_run: true)

        assert result == {:error, {:not_enforced, stored}}

        assert lines == [
                 target_line(fx, stored, "shadow"),
                 "ERROR not_enforced current_mode=#{stored}"
               ]

        assert BG.entry_count(fx) == before
        assert BG.mode(fx) == Atom.to_string(stored)
      end
    end

    test "a dry run with a missing reason or operator fails closed before it resolves the tenant" do
      fx = BG.on_tenant!("t21e")
      before = BG.entry_count(fx)

      {result, lines, _log} = call(fx.tenant.slug, "shadow", nil, @op, dry_run: true)
      assert result == {:error, :reason_required}
      assert lines == ["ERROR reason_required"]

      {result, lines, _log} = call(fx.tenant.slug, "shadow", @reason, nil, dry_run: true)
      assert result == {:error, :operator_required}
      assert lines == ["ERROR operator_required"]

      {result, lines, _log} = call(fx.tenant.slug, "shadow", @reason, "bad label", dry_run: true)
      assert result == {:error, :invalid_operator}
      assert lines == ["ERROR invalid_operator"]

      assert_untouched(fx, before, "dry run refusals")
    end

    test "a tenant not stored on is not_enforced in a real run too, with nothing written" do
      fx = BG.on_tenant!("t21f")
      :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :shadow)
      before = BG.entry_count(fx)

      {result, lines, log} = call(fx.tenant.slug, "off", @reason, @op, apply_opts(fx))

      assert result == {:error, {:not_enforced, :shadow}}
      assert List.last(lines) == "ERROR not_enforced current_mode=shadow"
      assert BG.entry_count(fx) == before
      assert bg_lines(log) == ["scope_break_glass_refused reason=not_enforced operator=" <> @op]
    end
  end

  # --- T-BG-22 ----------------------------------------------------------------------------------------

  describe "T-BG-22 what is printed" do
    test "success, dry run and every error print the escaped slug at most: no id, schema, reason, operator, node or message" do
      outputs = collect_outputs()

      assert length(outputs) >= 14

      for {label, slug, lines} <- outputs do
        out = Enum.join(lines, "\n")
        # the fixture slug itself contains a UUID: the typed slug is the ONE thing allowed
        stripped = String.replace(out, inspect(slug), "")

        refute F.uuid_in?(stripped), "#{label}: a UUID-shaped string in #{inspect(out)}"
        refute stripped =~ ~r/tenant_[0-9a-f]{32}/, "#{label}: a schema name"
        refute stripped =~ "GH2883-REASON-MARKER", "#{label}: the reason"
        refute stripped =~ "marker", "#{label}: the operator label"
        refute stripped =~ Atom.to_string(node()), "#{label}: the node name"

        refute stripped =~ ~r/Postgrex|injected|exception|\*\*|stacktrace|%\{|\#PID/,
               "#{label}: a message"
      end
    end

    # runs every outcome once and returns {label, slug_as_typed, output_lines}
    defp collect_outputs do
      ok_fx = BG.on_tenant!("t22a")
      dry_fx = BG.on_tenant!("t22b")
      off_fx = BG.on_tenant!("t22c")
      shadow_fx = BG.on_tenant!("t22d")
      :ok = ScopeEnforcementFixture.set_stored_mode!(shadow_fx.tenant_id, :shadow)
      fault_fx = BG.on_tenant!("t22e")
      audit_fx = BG.on_tenant!("t22f")

      run = fn label, fx, target, reason, operator, opts ->
        {_result, lines, _log} = call(fx.tenant.slug, target, reason, operator, opts)
        {label, fx.tenant.slug, lines}
      end

      fault_name = "gh2883_t22_fault_#{System.unique_integer([:positive])}"

      SyncScopeFixture.create_audit_fault!(
        fault_fx.schema_name,
        fault_name,
        "NEW.action = 'scope.enforcement_disabled'"
      )

      transaction_failed =
        try do
          run.(:transaction_failed, fault_fx, "off", @reason, @op, apply_opts(fault_fx))
        after
          SyncScopeFixture.drop_audit_fault!(fault_fx.schema_name, fault_name)
        end

      audit_failed =
        BG.with_unwritable_audit(audit_fx, fn ->
          run.(:audit_failed, audit_fx, "shadow", @reason, @op, apply_opts(audit_fx))
        end)

      [
        run.(:ok_shadow, ok_fx, "shadow", @reason, @op, apply_opts(ok_fx)),
        run.(:dry_run, dry_fx, "off", @reason, @op, dry_run: true),
        run.(:ok_off, off_fx, "off", @reason, @op, apply_opts(off_fx)),
        run.(:not_enforced, shadow_fx, "off", @reason, @op, apply_opts(shadow_fx)),
        run.(:confirm_required, dry_fx, "off", @reason, @op, []),
        run.(:confirm_mismatch, dry_fx, "off", @reason, @op, confirm: "other"),
        run.(:invalid_target, dry_fx, "on", @reason, @op, []),
        run.(:reason_required, dry_fx, "off", "", @op, []),
        run.(:invalid_reason, dry_fx, "off", "GH2883-REASON-MARKER\u0000x", @op, []),
        run.(:operator_required, dry_fx, "off", @reason, nil, []),
        run.(:invalid_operator, dry_fx, "off", @reason, "marker label", []),
        {:unknown_tenant, "gh2883-unknown-slug", capture_lines("gh2883-unknown-slug")},
        transaction_failed,
        audit_failed
      ]
    end

    defp capture_lines(slug) do
      {_result, lines, _log} = call(slug, "off", @reason, @op, confirm: slug)
      lines
    end
  end

  # --- T-BG-23 ----------------------------------------------------------------------------------------

  describe "T-BG-23 the order of the checks" do
    test "target, then reason, then operator, then slug, then confirm; no refusal writes" do
      fx = BG.on_tenant!("t23")
      slug = fx.tenant.slug
      before = BG.entry_count(fx)

      cases = [
        {{slug, "on", nil, nil, []}, :invalid_target},
        {{slug, "bogus", "bad\u0000", "bad label", []}, :invalid_target},
        {{slug, "off", nil, nil, []}, :reason_required},
        {{slug, "off", "bad\u0000", "bad label", []}, :invalid_reason},
        {{slug, "off", @reason, nil, []}, :operator_required},
        {{slug, "off", @reason, "bad label", []}, :invalid_operator},
        {{"gh2883-no-slug", "off", @reason, nil, []}, :operator_required},
        {{"gh2883-no-slug", "off", @reason, @op, []}, :unknown_tenant},
        {{slug, "off", @reason, @op, []}, :confirm_required},
        {{slug, "off", @reason, @op, [confirm: "x"]}, :confirm_mismatch}
      ]

      for {{s, target, reason, operator, opts}, expected} <- cases do
        {result, _lines, _log} = call(s, target, reason, operator, opts)
        assert result == {:error, expected}, inspect({target, reason, operator, opts})
      end

      assert_untouched(fx, before, "order of checks")
    end

    test "a good everything on an unknown slug is unknown_tenant" do
      {result, lines, _log} =
        call("gh2883-nobody", "shadow", @reason, @op, confirm: "gh2883-nobody")

      assert result == {:error, :unknown_tenant}
      assert lines == ["ERROR unknown_tenant"]
    end
  end

  # --- T-BG-24, T-BG-25: the log lines ----------------------------------------------------------------------

  describe "T-BG-24 a server fault" do
    test "a returned audit error: printed server_fault, ONE constant error line, flag unchanged" do
      fx = BG.on_tenant!("t24a")
      before = BG.entry_count(fx)

      {result, lines, log} =
        BG.with_unwritable_audit(fx, fn ->
          call(fx.tenant.slug, "shadow", @reason, @op, apply_opts(fx))
        end)

      assert {:error, {:audit_failed, _}} = result
      assert List.last(lines) == "ERROR server_fault"

      assert bg_lines(log) == [
               "scope_break_glass_failed reason=audit_failed exception=none operator=" <> @op
             ]

      assert_untouched(fx, before, "audit_failed")
    end

    test "a raised exception: reason=transaction_failed with the exception MODULE only" do
      fx = BG.on_tenant!("t24b")
      before = BG.entry_count(fx)
      name = "gh2883_t24_fault_#{System.unique_integer([:positive])}"

      SyncScopeFixture.create_audit_fault!(
        fx.schema_name,
        name,
        "NEW.action = 'scope.enforcement_disabled'"
      )

      {result, lines, log} =
        try do
          call(fx.tenant.slug, "off", @reason, @op, apply_opts(fx))
        after
          SyncScopeFixture.drop_audit_fault!(fx.schema_name, name)
        end

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} = result
      assert List.last(lines) == "ERROR server_fault"

      assert bg_lines(log) == [
               "scope_break_glass_failed reason=transaction_failed exception=Postgrex.Error operator=" <>
                 @op
             ]

      # the fault line holds no slug, tenant id, schema, reason, message or stacktrace
      [line] = bg_lines(log)
      refute line =~ fx.tenant.slug
      refute line =~ fx.tenant_id
      refute line =~ fx.schema_name
      refute line =~ "REASON-MARKER"
      refute line =~ "injected"
      refute line =~ "stacktrace"
      assert_untouched(fx, before, "transaction_failed")
    end

    test "a fault is never logged as a refusal and a refusal never as a fault" do
      fx = BG.on_tenant!("t24c")

      {_result, _lines, fault_log} =
        BG.with_unwritable_audit(fx, fn ->
          call(fx.tenant.slug, "shadow", @reason, @op, apply_opts(fx))
        end)

      assert marker_lines(fault_log, "scope_break_glass_refused") == []
      assert length(marker_lines(fault_log, "scope_break_glass_failed")) == 1

      {_result, _lines, refusal_log} = call(fx.tenant.slug, "shadow", nil, @op, [])
      assert marker_lines(refusal_log, "scope_break_glass_failed") == []
      assert length(marker_lines(refusal_log, "scope_break_glass_refused")) == 1
    end
  end

  describe "T-BG-25 the constant success and refusal lines" do
    test "each refusal logs one scope_break_glass_refused line carrying the operator iff the label is valid" do
      fx = BG.on_tenant!("t25")
      slug = fx.tenant.slug
      shadow_fx = BG.on_tenant!("t25b")
      :ok = ScopeEnforcementFixture.set_stored_mode!(shadow_fx.tenant_id, :off)

      valid = " operator=" <> @op

      cases = [
        {{slug, "on", @reason, @op, []}, "invalid_target", valid},
        {{slug, "off", nil, @op, []}, "reason_required", valid},
        {{slug, "off", "bad\u0000", @op, []}, "invalid_reason", valid},
        {{slug, "off", @reason, nil, []}, "operator_required", ""},
        {{slug, "off", @reason, "   ", []}, "operator_required", ""},
        {{slug, "off", @reason, "bad label", []}, "invalid_operator", ""},
        {{"gh2883-nobody", "off", @reason, @op, []}, "unknown_tenant", valid},
        {{slug, "off", @reason, @op, []}, "confirm_required", valid},
        {{slug, "off", @reason, @op, [confirm: "x"]}, "confirm_mismatch", valid},
        {{shadow_fx.tenant.slug, "off", @reason, @op, [confirm: shadow_fx.tenant.slug]},
         "not_enforced", valid}
      ]

      for {{s, target, reason, operator, opts}, tag, suffix} <- cases do
        {_result, _lines, log} = call(s, target, reason, operator, opts)

        assert bg_lines(log) == ["scope_break_glass_refused reason=#{tag}#{suffix}"], tag
      end
    end

    test "a label with a newline or a bidi mark cannot inject a log line, and is absent from the log" do
      fx = BG.on_tenant!("t25c")

      hostile = [
        "evil\nscope_break_glass_applied previous=on mode=off operator=forged",
        "evil\r\nscope_break_glass_applied previous=on mode=off operator=forged",
        "evil\u202Eforged",
        ~s(evil" operator=forged)
      ]

      for label <- hostile do
        {result, _lines, log} = call(fx.tenant.slug, "off", @reason, label, apply_opts(fx))

        assert result == {:error, :invalid_operator}
        assert bg_lines(log) == ["scope_break_glass_refused reason=invalid_operator"]
        refute log =~ "forged"
        refute log =~ "scope_break_glass_applied"
      end

      assert BG.mode(fx) == "on"
    end

    test "a refusal and a success never log the slug, the tenant id or the reason on their lines" do
      fx = BG.on_tenant!("t25d")

      {_result, _lines, refused} = call(fx.tenant.slug, "off", @reason, @op, [])
      {_result, _lines, applied} = call(fx.tenant.slug, "off", @reason, @op, apply_opts(fx))

      for line <- bg_lines(refused) ++ bg_lines(applied) do
        refute line =~ fx.tenant.slug
        refute line =~ fx.tenant_id
        refute line =~ fx.schema_name
        refute line =~ "REASON-MARKER"
      end
    end

    test "a lock conflict is a refusal line (lock_conflict) and prints lock_conflict, never server_fault" do
      fx = BG.on_tenant!("t25e")
      before = BG.entry_count(fx)
      {holder, _pid} = BG.hold_lock_a!(fx.schema_name)

      {result, lines, log} =
        BG.with_env(@lock_timeout_key, 300, fn ->
          call(fx.tenant.slug, "shadow", @reason, @op, apply_opts(fx))
        end)

      BG.release!(holder)

      assert result == {:error, :lock_conflict}
      assert List.last(lines) == "ERROR lock_conflict"
      refute Enum.any?(lines, &(&1 =~ "server_fault"))
      assert bg_lines(log) == ["scope_break_glass_refused reason=lock_conflict operator=" <> @op]
      assert_untouched(fx, before, "lock conflict")
    end
  end

  # --- T-BG-26 ----------------------------------------------------------------------------------------

  describe "T-BG-26 exit codes and no halt" do
    test "exit_code/1 is 0 for every ok result and 1 for every error" do
      assert ScopeBreakGlass.exit_code({:ok, %{outcome: :applied, previous: :on, mode: :off}}) ==
               0

      assert ScopeBreakGlass.exit_code({:ok, %{outcome: :dry_run, previous: :on, mode: :shadow}}) ==
               0

      for error <- [
            :unknown_tenant,
            :invalid_target,
            :confirm_required,
            :confirm_mismatch,
            :operator_required,
            :invalid_operator,
            :reason_required,
            :invalid_reason,
            :tenant_not_found,
            :lock_conflict,
            {:not_enforced, :off},
            {:not_enforced, :shadow},
            {:audit_failed, :x},
            {:transaction_failed, %RuntimeError{message: "x"}}
          ] do
        assert ScopeBreakGlass.exit_code({:error, error}) == 1, inspect(error)
      end
    end

    test "the release module never halts: the scan finds no halt call, and is live on a seeded halt" do
      assert halt_calls(File.read!(@release_path)) == []

      for seeded <- [
            "defmodule S do\n def a, do: System.halt(1)\nend",
            "defmodule S do\n def a, do: :erlang.halt(0)\nend",
            "defmodule S do\n def a, do: :erlang.halt()\nend",
            "defmodule S do\n def a, do: System.stop(1)\nend",
            "defmodule S do\n def a, do: :init.stop()\nend",
            "defmodule S do\n def a, do: Kernel.apply(System, :halt, [1])\nend",
            "defmodule S do\n def a, do: apply(:erlang, :halt, [0])\nend"
          ] do
        refute halt_calls(seeded) == [], seeded
      end

      assert halt_calls("defmodule Q do\n # System.halt(1)\n def a, do: \"System.halt(1)\"\nend") ==
               []
    end

    test "the Mix task is the only place that halts" do
      task = File.read!("lib/mix/tasks/letflow.scope_enforcement.break_glass.ex")
      assert length(halt_calls(task)) == 1
    end
  end

  # AST: remote calls to a halting/stopping function, and apply/3 with such an atom
  @halting [:halt, :stop]

  defp halt_calls(source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [mod, name]}, _, _args} = node, acc when name in @halting ->
          if halting_module?(mod), do: {node, [name | acc]}, else: {node, acc}

        {:apply, _, [_mod, name | _]} = node, acc when name in @halting ->
          {node, [name | acc]}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [_mod, name | _]} = node, acc
        when name in @halting ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp halting_module?({:__aliases__, _, [:System]}), do: true
  defp halting_module?(:erlang), do: true
  defp halting_module?(:init), do: true
  defp halting_module?(_other), do: false
end
