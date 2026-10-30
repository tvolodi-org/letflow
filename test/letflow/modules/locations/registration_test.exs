defmodule Letflow.Modules.Locations.RegistrationTest do
  @moduledoc """
  GH #3501 / REQ-625 criterion 2 (R-1..R-3): the `locations` manifest is
  accepted by `Catalog.validate/1` and the entry module is registered with the Catalog.

  Pure: no database. `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog

  @four ["org_legal_entity", "org_site", "org_unit", "org_unit_membership"]

  test "R-01: Catalog.validate/1 accepts the org manifest" do
    assert Catalog.validate(Letflow.Modules.Org.manifest()) == :ok
  end

  test "R-02: the manifest is id org, no dependencies, and manages exactly the four types" do
    manifest = Letflow.Modules.Org.manifest()

    assert manifest.id == "org"
    assert manifest.depends_on == []
    assert Enum.sort(manifest.manages_entity_types) == @four
    assert manifest.pack == "modules/org/pack.json"
    assert manifest.permissions == []
    assert manifest.role_grants == %{}
  end

  test "R-03: the manifest's managed list equals the private @types list on_install/3 activates" do
    # `@types` is a private module attribute (defmanifest takes literals, so the manifest list
    # cannot reference it); read its literal from the source, the one place both lists live.
    source = File.read!(Path.join([File.cwd!(), "lib", "letflow", "modules", "org", "org.ex"]))
    [_, types_block] = Regex.run(~r/@types \[(.*?)\]/s, source)
    types = Regex.scan(~r/"([a-z_]+)"/, types_block) |> Enum.map(&List.last/1)

    assert types == Letflow.Modules.Org.manifest().manages_entity_types
  end

  test "R-04: Catalog.entry_modules/0 includes the Org module and fetch/1 resolves it" do
    assert Letflow.Modules.Org in Catalog.entry_modules()
    assert Catalog.fetch("org") == {:ok, Letflow.Modules.Org}
  end
end
