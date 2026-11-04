defmodule Letflow.Modules.CatalogReferenceTargetsTest do
  @moduledoc """
  REQ-636 (decision 0070 slice C): the manifest key `:reference_targets` (Catalog rule 19), its
  place in the manifest hash, and `Catalog.reference_target/2`. Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.ManifestHash

  defp manifest do
    %{
      id: "probe",
      version: "0.1.0",
      depends_on: [],
      pack: nil,
      permissions: [],
      role_grants: %{},
      required_roles: [],
      settings_schema: nil,
      route_policies: [],
      manages_entity_types: ["probe_a", "probe_b"]
    }
  end

  defp with_targets(value), do: Map.put(manifest(), :reference_targets, value)

  test "C2-ok-absent and C2-ok-valid" do
    assert Catalog.validate(manifest()) == :ok
    assert Catalog.validate(with_targets([])) == :ok
    assert Catalog.validate(with_targets(["probe_a"])) == :ok
    assert Catalog.validate(with_targets(["probe_b", "probe_a"])) == :ok
  end

  test "C2-bad: non-list, unmanaged name, bad format, duplicate" do
    for bad <- [
          "probe_a",
          %{"probe_a" => 1},
          ["probe_c"],
          ["Probe_A"],
          [:probe_a],
          ["probe_a", "probe_a"]
        ] do
      assert Catalog.validate(with_targets(bad)) == {:error, {:invalid_reference_targets, bad}}
    end

    # a key without any managed types to point at
    no_managed =
      manifest() |> Map.delete(:manages_entity_types) |> Map.put(:reference_targets, ["x"])

    assert Catalog.validate(no_managed) == {:error, {:invalid_reference_targets, ["x"]}}
  end

  test "C2-hash-key: the key changes the hash only when present; order is irrelevant" do
    assert ManifestHash.compute(with_targets(["probe_a"])) != ManifestHash.compute(manifest())

    assert ManifestHash.compute(with_targets(["probe_b", "probe_a"])) ==
             ManifestHash.compute(with_targets(["probe_a", "probe_b"]))

    assert ManifestHash.compute(manifest()) == ManifestHash.compute(manifest())
  end

  test "C3-target: opted in resolves; other type, unknown module and non-binary do not" do
    assert Catalog.reference_target("fixture_ref_targets", "frt_target") ==
             {:ok, Letflow.Modules.FixtureRefTargets}

    # managed by the same module but not opted in
    assert Catalog.reference_target("fixture_ref_targets", "frt_other") == :error
    assert Catalog.reference_target("no_such_module", "frt_target") == :error
    assert Catalog.reference_target(nil, "frt_target") == :error
    assert Catalog.reference_target("fixture_ref_targets", :frt_target) == :error
  end

  test "C3-no-opt-in: no production manifest carries the key" do
    for entry <- Catalog.entry_modules(), entry != Letflow.Modules.FixtureRefTargets do
      refute Map.has_key?(entry.manifest(), :reference_targets), inspect(entry)
    end

    # Codes has lookup/2 but no active?/2 and no opt-in: never a target
    assert Catalog.reference_target("codes", "code_value") == :error
  end
end
