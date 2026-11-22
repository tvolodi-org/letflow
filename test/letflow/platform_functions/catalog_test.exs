defmodule Letflow.PlatformFunctions.CatalogTest do
  @moduledoc """
  The COMPILED platform function catalogue (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (a)).

  The catalogue is code: an entry exists only if it is compiled into the build,
  and there is no write route and no run-time registration. This test pins what
  a caller of the read route sees: the closed list of entries, the platform
  family hidden from anybody outside the platform tenant (INV-10), and the shape
  of the entry map the response body is built from.

  The entry map is pinned by its EXACT key set, because the response is a wire
  contract: the key composition of an entry travels under `idempotency_inputs`
  (the input names that make a repeat the same call), never under the name of
  the CALLER's idempotency key -- that key belongs to `Letflow.Idempotency`
  alone, and the AC5 guard of `test/letflow/idempotency_test.exs` scans every
  source file for it.

  No database: the catalogue is compiled into the build, so nothing here needs a
  tenant. `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry

  @chain [
    "tenant.validate",
    "tenant.create",
    "tenant.provision",
    "tenant.bind_realm",
    "tenant.grant_first_admins",
    "tenant.install_default_modules"
  ]

  @entry_map_keys [
    "family",
    "idempotency_inputs",
    "inputs",
    "name",
    "outputs",
    "permission",
    "platform_tenant_only",
    "side_effects",
    "version"
  ]

  describe "the compiled catalogue" do
    test "it holds exactly the tenant family's chain" do
      assert Catalog.names() == Enum.sort(@chain)
    end

    test "every entry needs the platform atom and runs only in the platform tenant" do
      assert Catalog.permission_atoms() == [:TenantsManage]

      for name <- @chain do
        {:ok, entry} = Catalog.fetch(name)

        assert entry.permission == :TenantsManage
        assert entry.platform_tenant_only == true
        assert entry.family == :platform
      end
    end

    test "a name outside the catalogue is not found" do
      assert {:error, :not_found} = Catalog.fetch("tenant.not_in_the_catalogue")
    end

    test "a caller outside the platform tenant sees no platform entry at all" do
      assert Catalog.list(platform_tenant?: false) == []
      assert length(Catalog.list(platform_tenant?: true)) == length(@chain)
    end
  end

  describe "the entry map (the read route's response body)" do
    test "its keys are exactly the contract" do
      {:ok, entry} = Catalog.fetch("tenant.create")
      map = Catalog.entry_map(entry)

      assert map |> Map.keys() |> Enum.sort() == @entry_map_keys
    end

    test "no atom leaks: the permission and the source classes are strings" do
      {:ok, entry} = Catalog.fetch("tenant.create")
      map = Catalog.entry_map(entry)

      assert map["permission"] == "TenantsManage"
      assert map["platform_tenant_only"] == true

      for input <- map["inputs"] do
        assert is_binary(input["type"])
        assert is_binary(input["source_class"])
      end

      for effect <- map["side_effects"] do
        assert is_binary(effect["class"])
      end
    end

    test "the key composition travels as the input names that make a repeat the same call" do
      {:ok, entry} = Catalog.fetch("tenant.create")
      map = Catalog.entry_map(entry)

      assert map["idempotency_inputs"] == ["slug"]
    end

    test "a write-like entry never takes a write-like input from a person" do
      {:ok, entry} = Catalog.fetch("tenant.create")

      assert Entry.write_like?(entry)
      assert Enum.all?(entry.inputs, &(&1.source_class != :person))
    end

    test "catalogue validation refuses a write-like entry with a person input" do
      entry = entry_with_source(:person, :write_tenant_registry)

      assert_raise RuntimeError, ~r/write-like.*:person/, fn ->
        Entry.validate_catalogue!([entry])
      end
    end

    test "catalogue validation still allows a person input on a read-only entry" do
      assert Entry.validate_catalogue!([entry_with_source(:person, :read)]) == :ok
    end
  end

  defp entry_with_source(source_class, side_effect_class) do
    %Entry{
      name: "example.call",
      family: :platform,
      version: "1.0.0",
      inputs: [
        %Entry.Input{
          name: "value",
          type: :string,
          required: true,
          source_class: source_class
        }
      ],
      outputs: [],
      permission: :TenantsManage,
      side_effects: [
        %Entry.SideEffect{text: "an example side effect", class: side_effect_class}
      ],
      idempotency_key: ["value"],
      platform_tenant_only: true
    }
  end
end
