defmodule Letflow.Modules.Codes.RegistrationTest do
  @moduledoc """
  GH #3588 / REQ-648 criteria 2 and 13 (R-01..R-04, SD-01, SD-02, SD-04): manifest accepted by
  `Catalog.validate/1`, entry module and config registration, the scope declaration pin.
  Pure: no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Codes

  @types ["code_tag", "code_assignment", "code_value_change"]

  test "R-01: Catalog.validate/1 accepts the codes manifest" do
    assert Catalog.validate(Codes.manifest()) == :ok
  end

  test "R-02: id codes, no dependencies, the three managed types, no permissions or grants" do
    m = Codes.manifest()
    assert m.id == "codes"
    assert m.version == "0.1.0"
    assert m.depends_on == []
    assert m.manages_entity_types == @types
    assert m.pack == "modules/codes/pack.json"
    assert m.permissions == []
    assert m.role_grants == %{}
    assert m.route_policies == []
  end

  test "R-03: Catalog.entry_modules/0 has Codes right after Locations; fetch/1 resolves it" do
    mods = Catalog.entry_modules()
    idx = Enum.find_index(mods, &(&1 == Letflow.Modules.Locations))
    assert Enum.at(mods, idx + 1) == Codes
    assert Catalog.fetch("codes") == {:ok, Codes}
  end

  test "R-04: both config files list Codes right after Locations" do
    for file <- ["config.exs", "test.exs"] do
      source = File.read!(Path.join([File.cwd!(), "config", file]))

      assert source =~ ~r/Letflow\.Modules\.Locations,\s*Letflow\.Modules\.Codes\b/,
             "config/#{file}"
    end
  end

  test "R-05: the private @types equals manages_entity_types" do
    source =
      File.read!(Path.join([File.cwd!(), "lib", "letflow", "modules", "codes", "codes.ex"]))

    [_, block] = Regex.run(~r/@types \[(.*?)\]/s, source)
    types = Regex.scan(~r/"([a-z_]+)"/, block) |> Enum.map(&List.last/1)
    assert types == Codes.manifest().manages_entity_types
  end

  test "SD-01: scope_declarations is exactly the three tenant-wide entries (decision 0051 M4)" do
    assert Codes.manifest().scope_declarations == %{
             "code_tag" => :tenant_wide,
             "code_assignment" => :tenant_wide,
             "code_value_change" => :tenant_wide
           }
  end

  test "SD-02: Catalog.validate/1 accepts the declarations (decision 0051 M4 pin stays valid)" do
    assert Catalog.validate(Codes.manifest()) == :ok
  end

  test "SD-04: moduledoc and runbook state no scope is applied and the same-404 rule" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Codes)
    assert doc =~ "apply no scope"
    assert doc =~ "same 404 as an unknown code"

    runbook = File.read!(Path.join([File.cwd!(), "docs", "runbooks", "wms-foundation.md"]))
    assert runbook =~ "must check the scope of the resolved target"
    assert runbook =~ "same 404 as an unknown code"
  end
end
