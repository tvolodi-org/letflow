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

  test "K6: only config/test.exs sets the test seam" do
    for file <- ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs) do
      refute File.read!(file) =~ "document_resolver_test_seam", file
    end

    assert File.read!("config/test.exs") =~ "document_resolver_test_seam, true"
  end
end
