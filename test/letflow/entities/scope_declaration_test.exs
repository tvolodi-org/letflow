defmodule Letflow.Entities.ScopeDeclarationTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, AC 4 (decision 0051 D6; design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.2; spec
  `test/specs/REQ-518-2c-i-a.md`, T-D1, T-D3, T-D4, T-D8 for_type half):
  `Letflow.Entities.ScopeDeclaration`.

    * T-D1: `for_type/2` is `{:column, field}`, `:tenant_wide` or `:undeclared` for the four
      declared fixture types, and `:undeclared` with ZERO queries for a type no manifest names;
      `for_types/2` reads the installed modules once whatever the number of types;
    * the declaring module must be installed, the type must be managed by it (or be on the
      test-only unmanaged allowlist), a type stamped by another module is `:undeclared`;
    * T-D3: a tenant-editable `definition_json` carrying `scope_node` / `scope_column` /
      `tenant_wide` keys changes nothing, and the module reads no definition at all;
    * T-D4: the definitions API cannot take over a declared managed name.

  `async: false`: real tenants, the VM-global allowlist application env, a committed stamp edit.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Scope
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @allowlist_key :scope_declaration_unmanaged_modules
  @source "lib/letflow/entities/scope_declaration.ex"

  defp set_allowlist!(value) do
    original = Application.fetch_env(:letflow, @allowlist_key)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, @allowlist_key, v)
        :error -> Application.delete_env(:letflow, @allowlist_key)
      end
    end)

    Application.put_env(:letflow, @allowlist_key, value)
  end

  defp names(rows), do: rows |> Enum.map(& &1.field_values["name"]) |> Enum.sort()

  describe "valid_declaration?/1 is the single owner of declaration validity (GH #2809)" do
    test "accepts :tenant_wide and a column with a managed-format name, rejects the rest" do
      assert ScopeDeclaration.valid_declaration?(:tenant_wide)
      assert ScopeDeclaration.valid_declaration?({:column, "warehouse_id"})
      refute ScopeDeclaration.valid_declaration?({:column, "Not Managed!"})
      refute ScopeDeclaration.valid_declaration?({:column, :warehouse_id})
      refute ScopeDeclaration.valid_declaration?(:undeclared)
      refute ScopeDeclaration.valid_declaration?(nil)
    end
  end

  # ===========================================================================================
  describe "T-D1 for_type/2 and for_types/2" do
    setup do
      {:ok, fx: F.provision!("req518-decl")}
    end

    test "the four declared fixture types resolve to their declaration", %{fx: fx} do
      s = fx.schema_name

      assert ScopeDeclaration.for_type("scoped_item", s) == {:column, "scope_node"}
      assert ScopeDeclaration.for_type("scoped_child", s) == {:column, "scope_node"}
      assert ScopeDeclaration.for_type("scoped_master", s) == :tenant_wide
      # MANAGED by fixture_scoped: the owner stamp equals the declaring module
      assert ScopeDeclaration.for_type("scoped_managed_item", s) == {:column, "scope_node"}
    end

    test "a type no manifest names is :undeclared with ZERO queries, whatever it is", %{fx: fx} do
      for type <- ["plain_undeclared", "does_not_exist", "scoped_item_2", "Scoped_Item", ""] do
        {declaration, queries} =
          Fixture.capture_repo_queries(fn -> ScopeDeclaration.for_type(type, fx.schema_name) end)

        assert declaration == :undeclared, type
        assert queries == [], "#{type}: an undeclared type must cost no query"
      end
    end

    test "for_types/2 returns every requested type as a key, reads the installed modules ONCE",
         %{fx: fx} do
      types = ["scoped_item", "scoped_child", "scoped_master", "scoped_managed_item", "nobody"]

      {result, queries} =
        Fixture.capture_repo_queries(fn -> ScopeDeclaration.for_types(types, fx.schema_name) end)

      assert Map.keys(result) |> Enum.sort() == Enum.sort(types)
      assert result["nobody"] == :undeclared
      assert result["scoped_master"] == :tenant_wide
      assert Enum.count(queries, &(&1.query =~ "tenant_modules")) == 1

      # duplicates in the request do not add keys or reads
      {dup, dup_queries} =
        Fixture.capture_repo_queries(fn ->
          ScopeDeclaration.for_types(["scoped_item", "scoped_item"], fx.schema_name)
        end)

      assert dup == %{"scoped_item" => {:column, "scope_node"}}
      assert Enum.count(dup_queries, &(&1.query =~ "tenant_modules")) == 1
    end

    test "for_types([]) is an empty map and costs nothing", %{fx: fx} do
      assert {%{}, []} ==
               Fixture.capture_repo_queries(fn ->
                 ScopeDeclaration.for_types([], fx.schema_name)
               end)
    end

    test "a malformed prefix is :undeclared (fail closed), also for a declared type", %{fx: _fx} do
      for prefix <- ["", "not a schema", "tenant_xyz", ~s(x"; DROP SCHEMA public; --)] do
        assert ScopeDeclaration.for_type("scoped_item", prefix) == :undeclared, inspect(prefix)
        assert ScopeDeclaration.for_type("nobody", prefix) == :undeclared
      end
    end
  end

  # ===========================================================================================
  describe "the declaring module must be installed" do
    test "in a tenant where fixture_scoped is NOT installed every type is :undeclared" do
      fx = S.tenant!("req518-decl-noinst")

      for type <- ["scoped_item", "scoped_child", "scoped_master", "scoped_managed_item"] do
        assert ScopeDeclaration.for_type(type, fx.schema_name) == :undeclared, type
      end
    end
  end

  # ===========================================================================================
  describe "T-D8 (for_type half): the unmanaged-type allowlist" do
    setup do
      {:ok, fx: F.provision!("req518-decl-allow")}
    end

    test "with the allowlist emptied the three UNMANAGED types are :undeclared, the managed one stays declared",
         %{fx: fx} do
      s = fx.schema_name
      set_allowlist!([])

      assert ScopeDeclaration.for_type("scoped_item", s) == :undeclared
      assert ScopeDeclaration.for_type("scoped_child", s) == :undeclared
      assert ScopeDeclaration.for_type("scoped_master", s) == :undeclared
      assert ScopeDeclaration.for_type("scoped_managed_item", s) == {:column, "scope_node"}
    end

    test "another module id on the allowlist does not help fixture_scoped", %{fx: fx} do
      set_allowlist!(["some_other_module"])

      assert ScopeDeclaration.for_type("scoped_item", fx.schema_name) == :undeclared
    end

    test "an emptied allowlist makes the compiler return nothing for the type (end to end, MU37)",
         %{fx: fx} do
      F.seed_items!(fx)
      set = {:nodes, [F.nodes().a]}
      request = %{entity_type: "scoped_item"}

      assert {:ok, query} = Compiler.compile(request, fx.schema_name, set)
      assert names(Repo.all(query, prefix: fx.schema_name)) == ["item-a"]

      set_allowlist!([])

      assert {:ok, closed} = Compiler.compile(request, fx.schema_name, set)
      assert Repo.all(closed, prefix: fx.schema_name) == []
    end

    test "a MANAGED type whose owner stamp is another module is :undeclared", %{fx: fx} do
      s = fx.schema_name
      assert ScopeDeclaration.for_type("scoped_managed_item", s) == {:column, "scope_node"}

      # the stamp is immutable by trigger once set; a session setting is the only legal change, so
      # build the "other owner" case by re-stamping inside a transaction with the trigger
      # bypassed for this session only
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!(
          ~s(UPDATE "#{s}".entity_definitions SET managed_by = 'someone_else' WHERE name = 'scoped_managed_item')
        )
      end)

      assert ScopeDeclaration.for_type("scoped_managed_item", s) == :undeclared
      # the other declarations are not affected
      assert ScopeDeclaration.for_type("scoped_item", s) == {:column, "scope_node"}
    end
  end

  # ===========================================================================================
  describe "T-D3 a tenant-editable definition cannot declare, widen or remove a declaration" do
    setup do
      fx = F.provision!("req518-decl-json")
      items = F.seed_items!(fx)
      F.create_plain_undeclared!(fx, items)
      {:ok, fx: fx}
    end

    defp inject_scope_keys!(fx, name) do
      keys = %{
        "scope_node" => "name",
        "scope_column" => "name",
        "scope_declaration" => %{"column" => "name"},
        "tenant_wide" => true,
        "managed_by" => "fixture_scoped"
      }

      for row <-
            Repo.all(from(d in EntityDefinition, where: d.name == ^name), prefix: fx.schema_name) do
        Repo.update_all(
          from(d in EntityDefinition, where: d.id == ^row.id),
          [set: [definition_json: Map.merge(row.definition_json, keys)]],
          prefix: fx.schema_name
        )
      end
    end

    test "keys named like a scope declaration on an undeclared type change nothing", %{fx: fx} do
      inject_scope_keys!(fx, "plain_undeclared")

      assert ScopeDeclaration.for_type("plain_undeclared", fx.schema_name) == :undeclared

      assert {:ok, query} =
               Compiler.compile(
                 %{entity_type: "plain_undeclared"},
                 fx.schema_name,
                 {:nodes, [F.nodes().a]}
               )

      assert Repo.all(query, prefix: fx.schema_name) == []
    end

    test "keys on a DECLARED type neither widen nor redirect its declaration (tenant_wide / other column)",
         %{fx: fx} do
      inject_scope_keys!(fx, "scoped_item")

      assert ScopeDeclaration.for_type("scoped_item", fx.schema_name) == {:column, "scope_node"}

      assert {:ok, query} =
               Compiler.compile(
                 %{entity_type: "scoped_item"},
                 fx.schema_name,
                 {:nodes, [F.nodes().a]}
               )

      assert names(Repo.all(query, prefix: fx.schema_name)) == ["item-a"]
    end

    test "the module reads no definition: no alias of the entity definition modules (AST)" do
      aliases =
        @source
        |> File.read!()
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {:__aliases__, _meta, parts} = node, acc -> {node, [parts | acc]}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      assert aliases != []

      for parts <- aliases do
        refute :EntityDefinition in parts, "ScopeDeclaration must not touch #{inspect(parts)}"
        refute :Definitions in parts, "ScopeDeclaration must not touch #{inspect(parts)}"
        refute :Records in parts
      end
    end
  end

  # ===========================================================================================
  describe "T-D4 the definitions API cannot alter a declaration" do
    setup do
      {:ok, fx: F.provision!("req518-decl-api")}
    end

    test "creating a definition with the name of the declared MANAGED type is refused; the declaration is unchanged",
         %{fx: fx} do
      result =
        Definitions.create_definition(
          %{
            definition: %{
              name: "scoped_managed_item",
              display_name: "Takeover",
              fields: [%{name: "name", type: :string}]
            },
            created_by: Ecto.UUID.generate()
          },
          fx.schema_name
        )

      assert match?({:error, _}, result), "got #{inspect(result)}"

      assert ScopeDeclaration.for_type("scoped_managed_item", fx.schema_name) ==
               {:column, "scope_node"}
    end

    test "a tenant type of a NEW name is undeclared and no api call on it can make it declared",
         %{
           fx: fx
         } do
      assert {:ok, definition} =
               Definitions.create_definition(
                 %{
                   definition: %{
                     name: "tenant_made",
                     display_name: "Tenant Made",
                     fields: [%{name: "scope_node", type: :string, queried: true}]
                   },
                   created_by: Ecto.UUID.generate()
                 },
                 fx.schema_name
               )

      assert {:ok, _active} =
               Definitions.activate_definition(
                 definition.name,
                 Ecto.UUID.generate(),
                 "go-live",
                 fx.schema_name
               )

      # a field NAMED scope_node on a tenant type declares nothing
      assert ScopeDeclaration.for_type("tenant_made", fx.schema_name) == :undeclared

      assert {:ok, query} =
               Compiler.compile(%{entity_type: "tenant_made"}, fx.schema_name, {:nodes, ["x"]})

      assert Repo.all(query, prefix: fx.schema_name) == []
    end
  end

  # ===========================================================================================
  describe "the scope set reaches the compiler through the declaration only" do
    test "Scope.allowed_set for a scoped worker plus the declaration give the in-scope rows (smoke)" do
      fx = F.provision!("req518-decl-smoke")
      F.seed_items!(fx)
      assert {:ok, set} = Scope.allowed_set(F.principal(fx, {:nodes, [:b]}), :EntitiesQuery)

      assert {:ok, query} = Compiler.compile(%{entity_type: "scoped_item"}, fx.schema_name, set)
      assert names(Repo.all(query, prefix: fx.schema_name)) == ["item-b", "item-b1"]
    end
  end
end
