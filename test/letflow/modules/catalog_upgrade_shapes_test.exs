defmodule Letflow.Modules.CatalogUpgradeShapesTest do
  @moduledoc """
  GH #3578 / REQ-640 criteria 1-5 and 9 (tests V*, M*, S*, G*, P*, H1): strict semver `:version`,
  `:min_upgradable_from`, `:migrations` steps (Catalog rules 15-17) and `Catalog.upgrade_path/3`.
  Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.ManifestHash
  alias Letflow.Modules.Step

  defp base, do: CatalogItems.manifest()
  defp with_key(key, value), do: Map.put(base(), key, value)

  defp step(id, from, to, over \\ []) do
    struct!(
      Step,
      Keyword.merge(
        [
          id: id,
          from: from,
          to: to,
          kind: :declarative,
          up: %{},
          down: :irreversible,
          lossy: false
        ],
        over
      )
    )
  end

  defp manifest(version, steps, extra \\ %{}),
    do: base() |> Map.merge(%{version: version, migrations: steps}) |> Map.merge(extra)

  @real_ids ~w(exam org catalog_items procurement locations codes)

  # Hashes of the registered manifests computed on unmodified origin/main before REQ-640.
  @hashes %{
    "exam" => "992e5266d1b81a138684f50228c5a3429393dcb90fdd0bb0dfb1fa9646252d8a",
    "org" => "caba62b2f3060c99ae03b3dcc2cdee841fded125aa92719f8ce74c77f39b9b11",
    "catalog_items" => "993457e555ef6b52d0517aee6cc86f65e37e953b2e7dedfcaff34746cf0a7f31",
    "procurement" => "265b5841f1705989bacfdf2ca82385fa0c9d83ad462e3f257f0ac87060f8dd61",
    "locations" => "a9f6b26a8d6df340267381c4a3025b7a8848eb0f02d288167b66d9134ba96116",
    "codes" => "e572003cee0f261c8cd5ace7021ab5420ecb558aa0e15d571ef0ccf8d2928eb6"
  }

  describe "criterion 1: strict semver version" do
    test "V1 accepts plain, prerelease and build versions" do
      for v <- ["0.1.0", "1.2.3-rc.1", "1.0.0+build.5", "10.20.30"] do
        assert Catalog.validate(with_key(:version, v)) == :ok, v
      end
    end

    test "V2..V7 refuses everything else" do
      for v <- [
            "1.0",
            "v1.0.0",
            "01.0.0",
            "1.0.0.0",
            "",
            100,
            nil,
            "1.0.0\n",
            "1.0.0-",
            "1.0.0-rc.01"
          ] do
        assert Catalog.validate(with_key(:version, v)) == {:error, {:invalid_version, v}},
               inspect(v)
      end
    end

    test "V8 every registered manifest validates" do
      for m <- Catalog.all_manifests(), do: assert(Catalog.validate(m) == :ok, m.id)
    end
  end

  describe "criterion 2: min_upgradable_from" do
    test "M1 absent validates" do
      refute Map.has_key?(base(), :min_upgradable_from)
      assert Catalog.validate(base()) == :ok
    end

    test "M2 below and equal to version validate" do
      assert Catalog.validate(with_key(:min_upgradable_from, "0.0.1")) == :ok
      assert Catalog.validate(with_key(:min_upgradable_from, base().version)) == :ok
    end

    test "M3 and M4 garbage or higher than version" do
      for v <- ["garbage", "9.9.9", 5, "1.0"] do
        assert Catalog.validate(with_key(:min_upgradable_from, v)) ==
                 {:error, {:invalid_min_upgradable_from, v}}
      end
    end
  end

  describe "criterion 3: Step struct" do
    test "S1 every key is enforced" do
      keys = [:id, :from, :to, :kind, :up, :down, :lossy]
      full = Map.new(keys, &{&1, 1})

      for k <- keys do
        assert_raise ArgumentError, fn -> struct!(Step, Map.delete(full, k)) end
      end
    end

    test "S2 and S3 a valid ordered list or no key validates" do
      steps = [step("a", "0.1.0", "0.2.0"), step("b", "0.2.0", "0.3.0", kind: :code, lossy: true)]
      assert Catalog.validate(with_key(:migrations, steps)) == :ok
      assert Catalog.validate(with_key(:migrations, [])) == :ok
      assert Catalog.validate(base()) == :ok
    end
  end

  describe "criterion 4: invalid_migrations" do
    defp bad(value),
      do:
        assert(
          Catalog.validate(with_key(:migrations, value)) == {:error, {:invalid_migrations, value}}
        )

    test "G1 non-list" do
      bad(%{})
      bad("steps")
    end

    test "G2 element not a Step", do: bad([%{id: "a", from: "0.1.0", to: "0.2.0"}])
    test "G3 kind", do: bad([step("a", "0.1.0", "0.2.0", kind: :other)])
    test "G4 lossy", do: bad([step("a", "0.1.0", "0.2.0", lossy: "yes")])
    test "G5 from", do: bad([step("a", "0.1", "0.2.0")])
    test "G6 to", do: bad([step("a", "0.1.0", "v0.2.0")])
    test "G7 to equals from", do: bad([step("a", "0.1.0", "0.1.0")])
    test "G8 to below from", do: bad([step("a", "0.2.0", "0.1.0")])
    test "G9 duplicate id", do: bad([step("a", "0.1.0", "0.2.0"), step("a", "0.2.0", "0.3.0")])

    test "G10 nil up or down" do
      bad([step("a", "0.1.0", "0.2.0", up: nil)])
      bad([step("a", "0.1.0", "0.2.0", down: nil)])
    end
  end

  describe "criterion 5: upgrade_path/3" do
    setup do
      a = step("a", "1.0.0", "1.1.0")
      b = step("b", "1.1.0", "1.2.0")
      {:ok, a: a, b: b, m: manifest("1.2.0", [a, b], %{min_upgradable_from: "1.0.0"})}
    end

    test("P1 chain of both steps", %{m: m, a: a, b: b},
      do: assert(Catalog.upgrade_path(m, "1.0.0", "1.2.0") == {:ok, [a, b]})
    )

    test("P2 first step only", %{m: m, a: a},
      do: assert(Catalog.upgrade_path(m, "1.0.0", "1.1.0") == {:ok, [a]})
    )

    test "P3 from equals to is empty; outside the window it is not", %{m: m} do
      assert Catalog.upgrade_path(m, "1.1.0", "1.1.0") == {:ok, []}

      assert Catalog.upgrade_path(m, "0.9.0", "0.9.0") ==
               {:error, {:no_upgrade_path, "0.9.0", "0.9.0"}}

      assert Catalog.upgrade_path(m, "1.5.0", "1.5.0") ==
               {:error, {:no_upgrade_path, "1.5.0", "1.5.0"}}
    end

    test "P4 gap" do
      m =
        manifest("1.3.0", [step("a", "1.0.0", "1.1.0"), step("c", "1.2.0", "1.3.0")], %{
          min_upgradable_from: "1.0.0"
        })

      assert Catalog.upgrade_path(m, "1.0.0", "1.3.0") ==
               {:error, {:no_upgrade_path, "1.0.0", "1.3.0"}}
    end

    test("P5 from below min", %{m: m},
      do:
        assert(
          Catalog.upgrade_path(m, "0.9.0", "1.2.0") ==
            {:error, {:no_upgrade_path, "0.9.0", "1.2.0"}}
        )
    )

    test("P6 to above version", %{m: m},
      do:
        assert(
          Catalog.upgrade_path(m, "1.0.0", "1.3.0") ==
            {:error, {:no_upgrade_path, "1.0.0", "1.3.0"}}
        )
    )

    test "P7 manifest order does not matter", %{m: m, a: a, b: b} do
      assert Catalog.upgrade_path(%{m | migrations: [b, a]}, "1.0.0", "1.2.0") == {:ok, [a, b]}
    end

    test "P8 backtracks from a skip step that dead-ends" do
      s1 = step("s1", "1.0.0", "1.2.0")
      s2 = step("s2", "1.0.0", "1.1.0")
      s3 = step("s3", "1.1.0", "1.3.0")
      m = manifest("1.3.0", [s1, s2, s3], %{min_upgradable_from: "1.0.0"})
      assert Catalog.upgrade_path(m, "1.0.0", "1.3.0") == {:ok, [s2, s3]}
    end

    test "P9 non-semver or non-binary arguments return the error tuple, no raise", %{m: m} do
      assert Catalog.upgrade_path(m, "x", "1.2.0") == {:error, {:no_upgrade_path, "x", "1.2.0"}}
      assert Catalog.upgrade_path(m, nil, 5) == {:error, {:no_upgrade_path, nil, 5}}
    end

    test("P10 from above to", %{m: m},
      do:
        assert(
          Catalog.upgrade_path(m, "1.2.0", "1.1.0") ==
            {:error, {:no_upgrade_path, "1.2.0", "1.1.0"}}
        )
    )
  end

  describe "criterion 9: no manifest hash moves" do
    test "H1 registered manifests hash to the pre-change values" do
      for m <- Catalog.all_manifests(), m.id in @real_ids do
        assert ManifestHash.compute(m) == @hashes[m.id], m.id
      end
    end

    test "H2 the new keys are not hashed" do
      m = base()

      moved =
        m
        |> Map.put(:min_upgradable_from, "0.0.1")
        |> Map.put(:migrations, [step("a", "0.1.0", "0.2.0")])

      assert ManifestHash.compute(moved) == ManifestHash.compute(m)
    end
  end
end
