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
    * proves that the changed-path test mapping runs those test files for a migration change;
    * proves it is not vacuous: a seeded stale pin and a seeded mapping that omits a required
      test are both caught.

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
  @selector "scripts/ci_select_tests.py"

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
      pins = MigrationImpact.position_pins("test")

      appended =
        manifest ++
          [%{version: 2_999_991_231_245_999, module: G09.SeededMigration, filename: nil}]

      broken = MigrationImpact.broken_pins(pins, manifest, appended)

      assert length(broken) > 0,
             "appending a migration to the manifest broke no pin: the runner does not see the shift"

      last_pin = Enum.find(broken, &(&1.pin.index == -1))
      assert last_pin, "the pin of the last manifest entry did not break"
      assert last_pin.before.version != last_pin.after.version
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
