defmodule Letflow.Modules.CatalogDocumentOrgResolverTest do
  @moduledoc """
  REQ-542 / GH #3164 criterion 3: `Catalog.document_org_resolver/0` and rule 12 of
  `Catalog.validate/2` (the optional `:document_org_resolver` manifest key). Design:
  state/tasks/T-0474/design.md, tests K1..K6.
  """

  use ExUnit.Case, async: false

  alias Letflow.Documents.OrgResolver.Default
  alias Letflow.Documents.TestResolvers
  alias Letflow.Modules.Catalog

  defp manifest(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        version: "0.1.0",
        depends_on: [],
        pack: nil,
        permissions: [],
        role_grants: %{},
        required_roles: [],
        settings_schema: nil,
        route_policies: []
      },
      overrides
    )
  end

  defp with_resolver(id), do: manifest(id, %{document_org_resolver: TestResolvers.Entity})

  test "K1: none declared gives the default" do
    assert {:ok, Default} = Catalog.document_org_resolver_in([])
    assert {:ok, Default} = Catalog.document_org_resolver_in([manifest("a"), manifest("b")])
  end

  test "K2: one declaration is used and validates" do
    m = with_resolver("a")
    assert {:ok, TestResolvers.Entity} = Catalog.document_org_resolver_in([manifest("b"), m])
    assert :ok = Catalog.validate(m, [m, manifest("b")])
  end

  test "K3: two declarations are ambiguous and fail validation" do
    [a, b] = [with_resolver("a"), with_resolver("b")]
    assert {:error, :ambiguous_org_resolver} = Catalog.document_org_resolver_in([a, b])
    assert {:error, {:duplicate_document_org_resolver, "b"}} = Catalog.validate(a, [a, b])
    assert {:error, {:duplicate_document_org_resolver, "a"}} = Catalog.validate(b, [a, b])
  end

  test "K4: a value that is not a resolver module is refused" do
    for bad <- ["Elixir.Foo", nil, Enum, NoSuchModuleAnywhere, %{}] do
      m = manifest("a", %{document_org_resolver: bad})
      assert {:error, {:invalid_document_org_resolver, ^bad}} = Catalog.validate(m, [m])
    end
  end

  test "K5: nothing at runtime changes the resolver" do
    assert {:ok, Default} = Catalog.document_org_resolver()

    Application.put_env(:letflow, :document_org_resolver, TestResolvers.Entity)
    on_exit(fn -> Application.delete_env(:letflow, :document_org_resolver) end)
    assert {:ok, Default} = Catalog.document_org_resolver()

    # on_install/3 context: a struct with fixed keys; an extra key is refused.
    assert_raise KeyError, fn ->
      struct!(Letflow.Modules.InstallContext, %{
        actor_id: "a",
        rationale: "r",
        tenant_prefix: "p",
        pack_entity_definition_ids: %{},
        document_org_resolver: TestResolvers.Entity
      })
    end

    paths = Enum.map(Letflow.Support.RouteInventory.routes(), &to_string(&1.path))
    refute Enum.any?(paths, &(&1 =~ "resolver"))
  end

  test "K5b: a tenant setting key document_org_resolver is rejected" do
    # API: the closed-vocabulary Ecto type behind PUT tenant settings (TenantSettings.cast/1).
    assert {:error, opts} =
             Letflow.Identity.TenantSettings.cast(%{
               "document_org_resolver" => "Elixir.Letflow.Documents.TestResolvers.Entity"
             })

    assert opts[:validation] == :unrecognized_key
    refute "document_org_resolver" in Letflow.Identity.TenantSettings.allowed_keys()
    assert {:ok, Default} = Catalog.document_org_resolver()
  end

  test "K5c: a pack section document_org_resolver sets nothing" do
    # API: SolutionPack.install/3. A wrong schema version stops it before any query,
    # and the pack parser has no reader for the key, so the resolver stays the default.
    doc = %{
      "pack_id" => "p",
      "version" => "1",
      "bpm_export_schema_version" => "no-such-version",
      "definitions" => [],
      "document_org_resolver" => "Elixir.Letflow.Documents.TestResolvers.Entity"
    }

    assert {:error, {:unknown_schema_version, "no-such-version"}} =
             Letflow.Definitions.SolutionPack.install(doc, Ecto.UUID.generate(), prefix: "none")

    refute File.read!("lib/letflow/definitions/solution_pack.ex") =~ "document_org_resolver"
    assert {:ok, Default} = Catalog.document_org_resolver()
  end

  test "K5d: a definition field document_org_resolver is not cast" do
    # API: ProcessDefinition.create_changeset/2, used by Definitions.create/2.
    cs =
      Letflow.Definitions.ProcessDefinition.create_changeset(
        %Letflow.Definitions.ProcessDefinition{},
        %{
          name: "n",
          version: "1",
          graph: %{},
          created_by: Ecto.UUID.generate(),
          document_org_resolver: "Elixir.Letflow.Documents.TestResolvers.Entity"
        }
      )

    refute Map.has_key?(cs.changes, :document_org_resolver)
    refute :document_org_resolver in Letflow.Definitions.ProcessDefinition.__schema__(:fields)
    assert {:ok, Default} = Catalog.document_org_resolver()
  end

  test "K6: only config/test.exs sets the test seam" do
    for file <- ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs) do
      refute File.read!(file) =~ "document_resolver_test_seam", file
    end

    assert File.read!("config/test.exs") =~ "document_resolver_test_seam, true"
  end
end
