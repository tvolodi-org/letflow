defmodule Letflow.Routers.WriteHandlerRegistrationSurfaceTest do
  @moduledoc """
  GH #2590 / REQ-501 R1, AC "Registration only from module code": a write
  handler exists only as `:write_handlers` manifest data of a compiled-in
  entry module. Proofs (design section 11):

    1. static: no file under `lib/` outside the Catalog, `Module` and
       `ManifestHash` mentions the `write_handlers` key, and the routers,
       definitions, entities and engine code names no handler resolver, so no
       route, definition body or pack document is a registration surface;
    2. dynamic: tenant-supplied settings carrying a `write_handlers` key are
       refused by the module's settings schema, and resolving whatever such a
       payload names answers `{:error, :not_found}`.

  `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture

  @allowed [
    "lib/letflow/modules/catalog.ex",
    "lib/letflow/modules/module.ex",
    "lib/letflow/modules/manifest_hash.ex"
  ]

  test "no lib file outside the Catalog, Module and ManifestHash mentions write_handlers" do
    readers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
      |> Enum.reject(&(&1 in @allowed))
      |> Enum.filter(&String.contains?(File.read!(&1), "write_handlers"))

    assert readers == []
  end

  test "routers, definitions, entities, engine and installs name no handler resolver" do
    paths =
      Path.wildcard("lib/letflow/{routers,definitions,entities,engine}/**/*.ex") ++
        ["lib/letflow/modules/installs.ex"]

    assert length(paths) > 0

    for path <- paths do
      refute File.read!(path) =~ "write_handler", "#{path} references the write-handler registry"
    end
  end

  test "settings carrying a write_handlers key are refused and resolve to nothing" do
    %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r1-surface")

    {:ok, _} =
      Installs.install("fixture", Ecto.UUID.generate(),
        prefix: prefix,
        rationale: "test: module install"
      )

    payload = %{
      "write_handlers" => [
        %{
          "name" => "post_entry",
          "function" => ["Letflow.Repo", "all"],
          "targets" => ["anything"],
          "args" => %{}
        }
      ]
    }

    assert {:error, {:settings_validation_failed, _}} =
             Installs.put_settings("fixture", payload, prefix: prefix)

    assert Catalog.write_handler("fixture", "post_entry") == {:error, :not_found}
    assert Catalog.write_handler("fixture", "write_handlers") == {:error, :not_found}
  end
end
