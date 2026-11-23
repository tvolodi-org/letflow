defmodule Letflow.SecurityProbe.G09MigrationImpactTest do
  @moduledoc """
  G-09: the migration impact runner (team coverage map, `docs/security-coverage.md` §4, gap G-09).

  A tenant-scoped migration is appended to `Letflow.TenantProvisioning`'s manifest, and every test
  that pins a *position* of that manifest (`Enum.at(manifest, -12)`, `List.last(manifest)`) then
  pins the wrong migration. T-2588's deep gate found two such files that the changed-path test
  mapping never selected: the breakage stayed invisible until the heavy pin tests ran in CI, and
  only two of the family were seen.

  The probe is mechanical (no model, no database, no network, no clock). It:

    * derives the manifest, the manifest-position pins of the test corpus and the test files a
      migration change must run (`Letflow.Support.MigrationImpact`);
    * proves that every position pin names the migration the manifest really holds at that
      position -- the class of the T-2588 finding, detected in milliseconds instead of in a
      twenty-minute migration suite;
    * proves that every positional read of the manifest is judged as a pin, so a pin the scanner
      cannot read is reported instead of skipped;
    * proves that the changed-path test mapping runs those test files for a migration change;
    * proves it is not vacuous: a seeded stale pin, a seeded positional read the scanner cannot
      judge and a seeded mapping that omits a required test are all caught.

  The class table is `docs/security-probes/G-09.md`.
  """

  use ExUnit.Case, async: false

  @moduletag :unit
  @moduletag :security_probe
  @moduletag probe_cost_s: 15
  @moduletag timeout: 180_000

  alias Letflow.Support.MigrationImpact

  @required_list "test/fixtures/security_probes/g09_migration_impact_tests.txt"
  @seeded_pin "test/fixtures/security_probes/g09/stale_position_pin.exs"
  @unresolved_read "test/fixtures/security_probes/g09/unresolved_position_read.exs"
  @class_table "docs/security-probes/G-09.md"
  @selector "scripts/ci_select_tests.py"
  @probe_file "test/letflow/security_probe/g09_migration_impact_test.exs"

  setup_all do
    {:ok, manifest: MigrationImpact.manifest()}
  end

  describe "M1 the derivation reads something" do
    test "the manifest, the pins and every required family are not empty", %{manifest: manifest} do
      assert length(manifest) > 0
      assert Enum.all?(manifest, &(&1.version > 0))
      assert Enum.all?(manifest, &(&1.filename != nil))

      pins = MigrationImpact.position_pins("test")
      assert length(pins) > 0, "no manifest-position pin found: the derivation reads nothing"

      required = MigrationImpact.required_test_files()

      for {family, files} <- required do
        assert length(files) > 0, "the #{family} family of the required set is empty"
      end

      assert length(MigrationImpact.required_test_file_list()) > 0
    end

    test "the reviewed list of required tests is not empty and every file of it exists" do
      listed = read_required_list()

      assert length(listed) > 0, "#{@required_list} is empty"

      for file <- listed do
        assert File.exists?(file), "#{file} is listed in #{@required_list} but does not exist"
      end
    end
  end

  describe "M2 the manifest-position pins are current" do
    test "no pin names a migration the manifest does not hold at its position" do
      stale = MigrationImpact.stale_position_pins("test")

      assert stale == [],
             "a manifest-position pin names a migration the manifest does not hold at that " <>
               "position (a migration was appended or the pin is stale):\n" <>
               Enum.map_join(
                 stale,
                 "\n",
                 &("  #{&1.file}:#{&1.line} index #{&1.index} " <>
                     "expects #{inspect(&1.expected_version)} (#{&1.module})")
               )
    end

    test "no pin is left unresolved: a version the scanner cannot read is a failure" do
      unresolved = MigrationImpact.unresolved_position_pins("test")

      assert unresolved == [],
             "the expected version of a manifest-position pin could not be read:\n" <>
               Enum.map_join(unresolved, "\n", &"  #{&1.file}:#{&1.line} index #{&1.index}")
    end
  end

  describe "M3 the impact runner reports what a manifest change breaks" do
    test "appending a migration to the manifest breaks the position pins", %{manifest: manifest} do
      # The corpus pins of the test tree. Their indexes count from the end of the manifest, so
      # every one of them names another migration as soon as a migration is appended -- the
      # assertion does not depend on WHICH position the corpus happens to pin today: a new
      # migration moves the whole family, and the runner must report that.
      pins = MigrationImpact.position_pins("test")

      appended =
        manifest ++
          [%{version: 2_999_991_231_245_999, module: G09.SeededMigration, filename: nil}]

      broken = MigrationImpact.broken_pins(pins, manifest, appended)

      negative = Enum.filter(pins, &(&1.index < 0))

      assert length(negative) > 0,
             "no manifest-position pin counts from the end of the manifest: the class is empty"

      assert length(broken) == length(negative),
             "appending a migration broke #{length(broken)} of the #{length(negative)} " <>
               "position pins: the runner does not see the whole shift"

      for change <- broken do
        assert change.before.version != change.after.version,
               "a broken pin names the same migration before and after the change"
      end
    end

    test "appending a migration breaks the pin of the last manifest entry", %{manifest: manifest} do
      # The seeded fixture pins the last entry of the manifest by position (`List.last/1`). The
      # runner must report that pin as moved when a migration is appended -- independently of
      # which position the corpus happens to pin today.
      pins = MigrationImpact.position_pins_in([@seeded_pin])

      assert length(pins) == 1, "the seeded pin was not read"
      assert hd(pins).index == -1

      appended =
        manifest ++
          [%{version: 2_999_991_231_245_999, module: G09.SeededMigration, filename: nil}]

      broken = MigrationImpact.broken_pins(pins, manifest, appended)

      assert length(broken) == 1,
             "appending a migration to the manifest did not break the pin of the last entry"

      assert hd(broken).before.version != hd(broken).after.version
      assert hd(broken).after.version == 2_999_991_231_245_999
    end
  end

  describe "M4 the changed-path test mapping runs the required tests" do
    test "a migration change runs every manifest-position, table-oracle and replay test" do
      changed = [migration_path()]
      {mode, selected} = select(changed)

      assert mode in ["selective", "full"],
             "the changed-path test mapping failed: #{inspect(mode)}"

      missing =
        MigrationImpact.missing_test_files(MigrationImpact.required_test_file_list(), selected)

      assert missing == [],
             "a migration change does not run these required tests:\n" <>
               Enum.map_join(missing, "\n", &"  #{&1}")
    end
  end

  describe "M5 the seeded failing case is caught" do
    test "a pin that names another migration is reported as stale" do
      pins = MigrationImpact.position_pins_in([@seeded_pin])

      assert length(pins) == 1, "the seeded pin was not read"
      assert hd(pins).status == :stale, "the seeded stale pin was not reported as stale"
    end
  end

  describe "M6 a mapping that omits a required test is caught" do
    test "the coverage check names the required test the plan leaves out" do
      required = MigrationImpact.required_test_file_list()
      omitted = List.last(required)

      missing = MigrationImpact.missing_test_files(required, required -- [omitted])

      assert missing == [omitted],
             "a plan that omits #{omitted} was not reported as missing"
    end
  end

  describe "M7 the reviewed list and the derived set agree" do
    test "the required-test list is the one the tree derives" do
      listed = read_required_list()
      derived = MigrationImpact.required_test_file_list()

      assert listed == derived,
             "the reviewed list and the derived set disagree.\n" <>
               "only in the list: #{inspect(listed -- derived)}\n" <>
               "only in the tree: #{inspect(derived -- listed)}"
    end
  end

  describe "M8 the derivation reads every positional manifest access" do
    test "every positional read of the manifest is judged as a pin" do
      reads = MigrationImpact.manifest_reads("test")

      assert length(reads) > 0,
             "no positional manifest read found: the derivation reads nothing"

      unjudged = MigrationImpact.unjudged_reads("test")

      assert unjudged == [],
             "a positional read of the tenant manifest is not judged as a pin, so the class " <>
               "does not cover it (the read names a migration by position, and the runner " <>
               "cannot say which one):\n" <>
               Enum.map_join(
                 unjudged,
                 "\n",
                 &"  #{&1.file}:#{&1.line} index #{&1.index}"
               )
    end

    test "the reads and the pins are the same set" do
      reads = Enum.map(MigrationImpact.manifest_reads("test"), &{&1.file, &1.line, &1.index})
      pins = Enum.map(MigrationImpact.position_pins("test"), &{&1.file, &1.line, &1.index})

      assert Enum.sort(reads) == Enum.sort(pins),
             "the positional reads and the judged pins are different sets.\n" <>
               "a read with no pin: #{inspect(Enum.sort(reads -- pins))}\n" <>
               "a pin with no read: #{inspect(Enum.sort(pins -- reads))}"
    end
  end

  describe "M9 the seeded unresolved read is caught" do
    test "a positional read the runner cannot resolve is reported, not skipped" do
      reads = MigrationImpact.reads_in([@unresolved_read])

      assert length(reads) == 2, "the seeded reads were not seen: the runner skipped them"

      # The manifest arrives as a parameter: the runner cannot resolve the read to the manifest.
      by_position = Enum.find(reads, &(&1.index == -2))

      assert by_position,
             "the seeded read with a literal position was not seen: the runner skipped it"

      assert by_position.resolved == false,
             "the seeded read was resolved to the manifest: the runner followed a parameter"

      assert by_position.judged == false,
             "the seeded read was judged as a pin: the runner says which migration it names"

      # The position arrives as a parameter: the runner cannot read which position is read.
      by_unknown_position = Enum.find(reads, &is_nil(&1.index))

      assert by_unknown_position,
             "the seeded read with an unreadable position was not seen: the runner skipped it"

      assert by_unknown_position.resolved == false,
             "the seeded read was resolved: the runner read a position it cannot read"

      assert by_unknown_position.judged == false,
             "the seeded read was judged as a pin: the runner says which migration it names"
    end
  end

  describe "M10 the class table is complete" do
    test "every case of the probe has a row in the class table" do
      table = File.read!(@class_table)
      rows = table_rows(table)
      cases = probe_cases()

      assert length(cases) > 0, "the probe has no case: the table check would pass on nothing"

      # The per-case check first: it names the case that has no row.
      for {name, test_file} <- cases do
        assert Enum.any?(rows, fn {_case, file, test} ->
                 file == test_file and String.contains?(test, name)
               end),
               "the class table has no row for the case #{inspect(name)} of #{test_file}"
      end

      # The rows of THIS file only: the table also carries the rows of the other files,
      # and counting those would let a missing row of the probe hide behind them.
      probe_rows = Enum.filter(rows, fn {_case, file, _test} -> file == @probe_file end)

      assert length(probe_rows) >= length(cases),
             "the class table has #{length(probe_rows)} rows for #{length(cases)} cases of " <>
               "the probe"
    end

    test "every row of the class table names a test that exists" do
      for {case_name, file, test} <- table_rows(File.read!(@class_table)) do
        assert File.exists?(file),
               "the class table row #{inspect(case_name)} names #{file}, which does not exist"

        source = File.read!(file)

        # The table names a test the way ExUnit names it ("<describe>: <test>"); the source
        # carries the two halves, so both must occur in it.
        assert names_the_test?(source, test),
               "the class table row #{inspect(case_name)} names the test #{inspect(test)}, " <>
                 "which does not occur in #{file}"
      end
    end
  end

  # Whether the source names the test the way the table does. The table names it the way ExUnit
  # names it ("<describe>: <test>"); a plain test name occurs as it is.
  defp names_the_test?(source, test) do
    case String.split(test, ": ", parts: 2) do
      [describe, name] ->
        String.contains?(source, describe) and String.contains?(source, name)

      [name] ->
        String.contains?(source, name)
    end
  end

  # The rows of the class table: the case, the test file and the test name it names. A row that
  # says "same file" names the file of the row above it.
  defp table_rows(table) do
    {rows, _last_file} =
      Enum.reduce(String.split(table, "\n"), {[], nil}, fn line, {rows, last_file} ->
        if String.starts_with?(line, "|") and not String.starts_with?(line, "|---") do
          case Regex.run(
                 ~r{^\|\s*([^|]*?)\s*\|.*?`([\w./-]+\.exs)`\s*::\s*`([^`]+)`},
                 line
               ) do
            [_, case_name, file, test] ->
              {[{case_name |> String.trim(), file, test} | rows], file}

            _ ->
              case Regex.run(
                     ~r{^\|\s*([^|]*?)\s*\|.*?same file\s*::\s*`([^`]+)`},
                     line
                   ) do
                [_, case_name, test] when is_binary(last_file) ->
                  {[{case_name |> String.trim(), last_file, test} | rows], last_file}

                _ ->
                  {rows, last_file}
              end
          end
        else
          {rows, last_file}
        end
      end)

    Enum.reverse(rows)
  end

  # The cases of the probe: every test in this file, with the `describe` block it sits in (the
  # class table names a case as "<describe>: <test>", the way ExUnit names it).
  defp probe_cases do
    source = File.read!(__ENV__.file)

    ast =
      Code.string_to_quoted!(source,
        columns: true,
        token_metadata: true,
        emit_warnings: false
      )

    names = collect_cases(ast, nil)

    for name <- Enum.reverse(names),
        do: {name, @probe_file}
  end

  # A `describe` block holds its tests in its body; a test outside one is named by itself.
  # A describe may take a context of its own, so the body is the last of its arguments.
  defp collect_cases({:describe, _, [describe | rest]}, _outside) when is_binary(describe) do
    collect_cases(List.last(rest), describe)
  end

  # A test carries its name, its block and -- when it takes one -- a context between
  # them. Both shapes name the same case, so both are collected: a test that takes a
  # context is `{:test, _, [name, context, [do: body]]}`, and a collector that matches
  # only the two-argument form never sees it.
  defp collect_cases({:test, _, [name | _rest]}, outside) when is_binary(name) do
    case outside do
      nil -> [name]
      describe -> ["#{describe}: #{name}"]
    end
  end

  defp collect_cases({_, _, args}, outside) when is_list(args) do
    Enum.flat_map(args, &collect_cases(&1, outside))
  end

  # A keyword list (`[do: body]`) carries its values under the keys.
  defp collect_cases(args, outside) when is_list(args) do
    Enum.flat_map(args, fn
      {_key, value} -> collect_cases(value, outside)
      value -> collect_cases(value, outside)
    end)
  end

  defp collect_cases(_node, _outside), do: []

  defp read_required_list do
    @required_list
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.sort()
  end

  # A migration file of the tree: the last entry of the manifest.
  defp migration_path do
    manifest = MigrationImpact.manifest()

    manifest
    |> Enum.reverse()
    |> Enum.find_value(
      "priv/repo/migrations/20261121100001_allow_zero_count_set_legs.exs",
      fn entry ->
        entry.filename
      end
    )
  end

  # The changed-path test mapping of the product CI: the plan of the tests it selects.
  defp select(changed) do
    plan_path =
      Path.join(System.tmp_dir!(), "g09-plan-#{System.unique_integer([:positive])}.txt")

    on_exit(fn -> File.rm(plan_path) end)

    {output, code} =
      System.cmd(
        "bash",
        [
          "-c",
          "printf '%s' \"$IN\" | python3 -I -B \"$@\"",
          "_",
          @selector,
          "--event",
          "pull_request",
          "--plan-out",
          plan_path
        ],
        cd: File.cwd!(),
        env: [{"IN", Enum.join(changed, "\n") <> "\n"}],
        stderr_to_stdout: true
      )

    mode =
      case Regex.run(~r/^mode=(\w+)$/m, output) do
        [_, mode] -> mode
        _ -> "error:#{code}"
      end

    selected =
      case File.read(plan_path) do
        {:ok, plan} ->
          plan
          |> String.split("\n")
          |> Enum.map(&String.split(&1, " "))
          |> Enum.filter(&(&1 != []))
          |> Enum.map(&List.last/1)

        {:error, _reason} ->
          []
      end

    {mode, selected}
  end
end
