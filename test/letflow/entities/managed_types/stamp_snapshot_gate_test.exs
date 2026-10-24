defmodule Letflow.Entities.ManagedTypes.StampSnapshotGateTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 10
  and 18.3 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`), tests T-36 and T-57a: the fail-closed
  gate on the infra stamp of the six exam runtime types.

  While `config :letflow, :exam_snapshot_complete` is not exactly `true`, a REAL stamp is refused
  on every entry point (`Stamp.run/1`, `Stamp.run_tenant/2`, `Letflow.Release.ManagedTypes.stamp/1`
  and the Mix task) and stamps nothing and writes no audit entry; a dry run is never blocked. In PR
  a the shipped config was `false` in `config/config.exs` and `true` in `config/test.exs`; this
  file overrides the flag per test with `Application.put_env/3` and restores it. The flag is never read from the environment, `runtime.exs` or written from `lib/`.

  PR b (the single flip, design 10.1/18.3): the shipped config is now `true` in BOTH
  `config/config.exs` and `config/test.exs`; the closed-gate tests below still pass because they
  set the flag to `false` themselves. The per-tenant prerequisites that replace the flag as the
  live gate are tested in `stamp_snapshot_prerequisites_test.exs`.

  Runs outside the sandbox transaction (`Stamp` refuses to run inside one): `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO

  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Release.ManagedTypes
  alias Mix.Tasks.Letflow.StampManagedTypes

  @tenant_report_keys [
    :conflicts,
    :differences,
    :error,
    :exam_named_types_present,
    :prerequisites_missing,
    :rows_already_stamped,
    :rows_stamped,
    :schema_name,
    :status,
    :tenant_id,
    :types_absent,
    :types_stamped
  ]

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  # Runs `fun` with the flag set to `value` (`:unset` removes the key) and restores it after.
  defp with_flag(value, fun) do
    previous = Application.fetch_env(:letflow, :exam_snapshot_complete)

    case value do
      :unset -> Application.delete_env(:letflow, :exam_snapshot_complete)
      other -> Application.put_env(:letflow, :exam_snapshot_complete, other)
    end

    try do
      fun.()
    after
      case previous do
        {:ok, original} -> Application.put_env(:letflow, :exam_snapshot_complete, original)
        :error -> Application.delete_env(:letflow, :exam_snapshot_complete)
      end
    end
  end

  defp report_for(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  defp assert_untouched!(schema) do
    for {name, values} <- Map.take(Fx.managed_by_map(schema), Fx.runtime_types()) do
      assert {name, values} == {name, [nil]}
    end

    assert Fx.stamp_audit_count(schema) == 0
  end

  # ── T-36: the gate is closed ───────────────────────────────────────────────────────────────

  describe "T-36 gate closed" do
    test "Stamp.run/1 returns {:error, :snapshot_not_complete}; the tenant is untouched and no audit entry exists" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t36-run")

      with_flag(false, fn ->
        assert {:error, :snapshot_not_complete} = Stamp.run([])
        assert {:error, :snapshot_not_complete} = Stamp.run(module: "exam")
        assert {:error, :snapshot_not_complete} = Stamp.run(dry_run: false)
      end)

      assert_untouched!(schema)
    end

    test "Stamp.run_tenant/2 returns a snapshot_not_complete report that stamped nothing" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t36-tenant")

      report = with_flag(false, fn -> Stamp.run_tenant(schema, []) end)

      assert Enum.sort(Map.keys(report)) == @tenant_report_keys

      assert %{
               status: :snapshot_not_complete,
               rows_stamped: 0,
               rows_already_stamped: 0,
               types_stamped: [],
               conflicts: [],
               error: nil,
               schema_name: ^schema
             } = report

      assert_untouched!(schema)
    end

    test "Letflow.Release.ManagedTypes.stamp/1 returns {:error, :snapshot_not_complete}; the same call with dry_run: true still reports" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t36-release")

      with_flag(false, fn ->
        assert {:error, :snapshot_not_complete} = ManagedTypes.stamp([])
        assert {:error, :snapshot_not_complete} = ManagedTypes.stamp(module: "exam")

        assert {:ok, report} = ManagedTypes.stamp(dry_run: true)
        assert report.dry_run == true
        assert report.gate_blocked_total == 0
        assert %{status: status} = report_for(report, schema)
        refute status == :snapshot_not_complete
      end)

      assert_untouched!(schema)
    end

    test "a dry run is never blocked: Stamp.run/1 and Stamp.run_tenant/2 report the tenant and write nothing" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t36-dry")

      with_flag(false, fn ->
        assert {:ok, report} = Stamp.run(dry_run: true)
        assert report.dry_run == true
        assert report.gate_blocked_total == 0
        assert %{status: :stamped, rows_stamped: 12, error: nil} = report_for(report, schema)

        assert %{status: :stamped, rows_stamped: 12} = Stamp.run_tenant(schema, dry_run: true)
      end)

      assert_untouched!(schema)
    end

    test "only the literal true opens the gate: false, nil, the key absent, \"true\", 1 and :yes all refuse" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t36-strict")

      for value <- [false, nil, :unset, "true", 1, :yes] do
        with_flag(value, fn ->
          assert {value, Stamp.run([])} == {value, {:error, :snapshot_not_complete}}

          assert {value, Stamp.run_tenant(schema, []).status} ==
                   {value, :snapshot_not_complete}
        end)
      end

      assert_untouched!(schema)
    end

    test "an unsupported module is reported as such before the gate is consulted" do
      with_flag(false, fn ->
        assert {:error, :unsupported_module} = Stamp.run(module: "other")
      end)
    end

    test "CONTROL: with the flag true (the test config) the same real run stamps the six types" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t36-open")

      assert Application.get_env(:letflow, :exam_snapshot_complete) == true

      assert %{status: :stamped, rows_stamped: 12, error: nil} = Stamp.run_tenant(schema, [])

      for {name, values} <- Map.take(Fx.managed_by_map(schema), Fx.runtime_types()) do
        assert {name, values} == {name, ["exam"]}
      end
    end

    test "the Mix task: a dry run is not blocked and says how many tenants the gate blocked (0)" do
      %{schema_name: _schema} = Fx.legacy_tenant!("gh2682-t36-task")

      with_flag(false, fn ->
        # The task halts the VM when ANY tenant of this database failed; only run it in-process
        # when the sweep is clean.
        {:ok, probe} = Stamp.run(dry_run: true)

        if probe.failed_total == 0 do
          output = capture_io(fn -> StampManagedTypes.run(["--dry-run"]) end)

          assert output =~ "managed-type stamp complete (dry run)"
          assert output =~ "0 gate-blocked"
        end
      end)
    end

    test "the Mix task refuses a real run with a message and exit status 1 (source guard: System.halt(1) cannot run in-process)" do
      source = File.read!(Path.join(File.cwd!(), "lib/mix/tasks/letflow.stamp_managed_types.ex"))

      assert source =~ "{:error, :snapshot_not_complete} ->"
      assert source =~ "stamp refused: exam snapshot gate is closed"
      assert source =~ "report.failed_total > 0 or report.gate_blocked_total > 0"
      assert source =~ "System.halt(1)"
    end
  end

  # ── T-36: the flag's provenance ────────────────────────────────────────────────────────────

  describe "T-36 flag provenance" do
    @flag "exam_snapshot_complete"

    # GH #2682 / REQ-511 PR b is the SINGLE flip (design 10.1, 18.3): `false` in PR a, `true` here.
    # The gate that matters from now on is the per-tenant prerequisite (see
    # `stamp_snapshot_prerequisites_test.exs`); the closed-gate tests in this file drive the flag
    # with `Application.put_env/3` and restore it.
    test "config.exs and test.exs both set true, nothing else sets it, and runtime.exs / the environment never do" do
      assert File.read!("config/config.exs") =~
               ~r/^config :letflow, :exam_snapshot_complete, true$/m

      refute File.read!("config/config.exs") =~
               ~r/^config :letflow, :exam_snapshot_complete, false$/m

      refute File.read!("config/runtime.exs") =~ @flag

      assert File.read!("config/test.exs") =~
               ~r/^config :letflow, :exam_snapshot_complete, true$/m

      others =
        "config/*.exs"
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) in ["config.exs", "test.exs"]))

      assert others != []

      for path <- others do
        refute {path, File.read!(path) =~ @flag} == {path, true}
      end
    end

    test "lib/ never writes the flag and never reads it from the environment; its only read is Application.get_env with a false default" do
      lines =
        for path <- Path.wildcard("lib/**/*.ex"),
            {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            String.contains?(line, @flag),
            do: {path, number, String.trim(line)}

      assert lines != []

      for {path, number, line} <- lines do
        refute {path, number,
                line =~ ~r/put_env|System\.(get|fetch)_env|Application\.fetch_env|delete_env/} ==
                 {path, number, true}
      end

      reads =
        Enum.filter(lines, fn {_path, _number, line} ->
          String.starts_with?(line, "do: Application.get_env")
        end)

      assert [{path, _number, line}] = reads
      assert path == "lib/letflow/entities/managed_types/stamp.ex"
      assert line == "do: Application.get_env(:letflow, :exam_snapshot_complete, false) != true"
    end

    test "the fail-closed default holds when the key is absent (no value means refuse)" do
      assert Application.get_env(:letflow, :exam_snapshot_complete, false) == true

      with_flag(:unset, fn ->
        assert Application.get_env(:letflow, :exam_snapshot_complete, false) == false
        assert {:error, :snapshot_not_complete} = Stamp.run([])
      end)
    end
  end

  # ── T-57a: the report fields PR a adds ─────────────────────────────────────────────────────

  describe "T-57a: the report fields of the gate" do
    test "a sweep report carries gate_blocked_total (an integer, 0 when the gate is open and for a dry run)" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t57a")

      assert {:ok, report} = Stamp.run(dry_run: true)
      assert report.gate_blocked_total == 0

      assert Enum.sort(Map.keys(report)) ==
               Enum.sort([
                 :conflict_total,
                 :dry_run,
                 :failed_total,
                 :gate_blocked_total,
                 :module,
                 :rows_stamped_total,
                 :tenants
               ])

      assert %{status: :stamped} = report_for(report, schema)
    end

    test "the tenant report carries prerequisites_missing (empty for a rolled-out tenant and for a dry run); the PR b key list is exact" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2682-t57a-keys")

      report = Stamp.run_tenant(schema, dry_run: true)

      assert Enum.sort(Map.keys(report)) == @tenant_report_keys
      assert report.prerequisites_missing == []
      refute report.status == :snapshot_prerequisite_missing
    end
  end
end
