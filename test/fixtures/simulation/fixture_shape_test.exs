defmodule Letflow.Simulation.FixtureShapeTest do
  @moduledoc """
  REQ-205 (`lib/letflow/design/req205-simulation-harness-foundation.md` §1). This is
  **not** AC1's "diff-style comparison test" -- that test requires R-Co's real
  `tests/simulation/companies/{swiftroute,vortex,meridian}/` fixture content to
  diff against, and R-Co's source tree (`c:\\Users\\tvolo\\dev\\ai-dala\\R-Co\\`) is a
  path on a different (Windows) host, unreachable from this Linux sandbox --
  confirmed this session (no `/mnt/c` mount, no R-Co checkout anywhere on this
  filesystem). `test/fixtures/simulation/{swiftroute,vortex,meridian}/` therefore
  holds self-authored, structurally-faithful synthetic data (see each `company.yaml`'s
  own header comment), not a port of R-Co's originals.

  What this test *does* verify, honestly: that all 12 fixture files exist, parse as
  valid YAML via `yaml_elixir`, and every file's load-bearing scalar fields match a
  literal value hardcoded here -- so a future accidental edit to these synthetic
  fixtures (which several other REQ-205 tests depend on for actor_id/slug
  stability) is caught. This is self-consistency, not R-Co parity.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @fixtures_root Path.join([__DIR__])

  @company_expectations %{
    "swiftroute" => %{"slug" => "swiftroute", "hostname" => "swiftroute.simulation.test"},
    "vortex" => %{"slug" => "vortex", "hostname" => "vortex.simulation.test"},
    "meridian" => %{"slug" => "meridian", "hostname" => "meridian.simulation.test"}
  }

  # Real R-Co actor_ids ported verbatim (ISS-0388). Every actor referenced by
  # REQ-206/207/208 scenario YAMLs must appear in the corresponding company's
  # org_structure.yaml -- these lists are the stable references for that contract.
  @actor_ids %{
    "swiftroute" => [
      "actor-swiftroute-alice",
      "actor-swiftroute-marco",
      "actor-swiftroute-lena",
      "actor-swiftroute-tobias",
      "actor-swiftroute-jan",
      "actor-swiftroute-petra",
      "actor-swiftroute-hans"
    ],
    "vortex" => [
      "actor-vortex-dirk",
      "actor-vortex-sabine",
      "actor-vortex-karl",
      "actor-vortex-nina",
      "actor-vortex-felix",
      "actor-vortex-anna",
      "actor-vortex-max",
      "actor-vortex-claudia",
      "actor-vortex-stefan"
    ],
    "meridian" => [
      "actor-meridian-eva",
      "actor-meridian-thomas",
      "actor-meridian-julia",
      "actor-meridian-ben",
      "actor-meridian-sophie",
      "actor-meridian-lars",
      "actor-meridian-miriam",
      "actor-meridian-oliver",
      "actor-meridian-claudia",
      "actor-meridian-marcus"
    ]
  }

  for company <- ["swiftroute", "vortex", "meridian"] do
    describe "#{company} fixtures" do
      test "company.yaml parses and matches its expected slug/hostname" do
        company = unquote(company)
        expected = @company_expectations |> Map.fetch!(company)

        {:ok, parsed} =
          YamlElixir.read_from_file(Path.join([@fixtures_root, company, "company.yaml"]))

        assert parsed["slug"] == expected["slug"]
        assert parsed["hostname"] == expected["hostname"]
      end

      test "org_structure.yaml parses and its actor_ids match the recorded set" do
        company = unquote(company)
        expected_actor_ids = @actor_ids |> Map.fetch!(company)

        {:ok, parsed} =
          YamlElixir.read_from_file(Path.join([@fixtures_root, company, "org_structure.yaml"]))

        actual_actor_ids = parsed["people"] |> Enum.map(& &1["actor_id"])
        assert actual_actor_ids == expected_actor_ids
        assert is_list(parsed["groups"])
      end

      test "exactly two process_*.yaml files exist and each parses with a name/version/graph" do
        company = unquote(company)

        process_files =
          Path.join([@fixtures_root, company, "process_*.yaml"]) |> Path.wildcard()

        assert length(process_files) == 2

        for file <- process_files do
          {:ok, parsed} = YamlElixir.read_from_file(file)
          assert is_binary(parsed["name"])
          assert is_binary(parsed["version"])
          assert is_map(parsed["graph"])
          assert is_list(parsed["graph"]["nodes"])
          assert is_list(parsed["graph"]["edges"])
        end
      end
    end
  end

  test "exactly 12 fixture files exist across the three companies (AC1's file count)" do
    total =
      ["swiftroute", "vortex", "meridian"]
      |> Enum.flat_map(fn company ->
        Path.join([@fixtures_root, company, "*.yaml"]) |> Path.wildcard()
      end)
      |> length()

    assert total == 12
  end
end
