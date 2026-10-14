defmodule Letflow.Modules.InstallsManagedByTest do
  @moduledoc """
  REQ-496 / GH #2530 AC3, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §2.4-§2.7 and §9 T-14, T-15, T-18, T-19 (spec `test/specs/REQ-496.md`): the install step is the
  only thing that stamps `managed_by`, and no later path clears it.

    * T-14: installing `fixture_managed` stamps every row of its seven declared names, leaves the
      undeclared `fxm_free` unstamped, and activates all eight.
    * T-15: a re-install is refused and leaves the stamps; a later `SolutionPack.install/4` by the
      owning module's `Owner` adds a new, stamped version; any other module's `Owner` is refused.
    * T-18: a tenant's own pre-existing type of a declared name is never taken over: the whole
      install fails with `{:managed_name_taken, name}` and rolls back.
    * T-19: a declared managed name the pack does not insert fails the install
      (`Letflow.Modules.FixtureManagedNoPack`, no pack at all).

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @managed [
    "org_legal_entity",
    "org_site",
    "org_unit",
    "org_unit_membership",
    "catalog_item",
    "catalog_uom",
    "fxm_ledger"
  ]

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-install")

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp install(module_id, schema) do
    Installs.install(module_id, Ecto.UUID.generate(),
      prefix: schema,
      rationale: "REQ-496 install test"
    )
  end

  # {name, managed_by, status} of every entity_definitions row, sorted.
  defp rows(schema) do
    Repo.all(
      from(d in EntityDefinition,
        select: {d.name, d.managed_by, d.status},
        order_by: [d.name, d.inserted_at]
      ),
      prefix: schema
    )
  end

  defp count_named(schema, name) do
    Repo.aggregate(from(d in EntityDefinition, where: d.name == ^name), :count, prefix: schema)
  end

  defp module_installed?(schema, module_id) do
    Repo.exists?(from(m in TenantModule, where: m.module_id == ^module_id), prefix: schema)
  end

  defp new_org_unit_shape_pack do
    name = "org_unit"

    %{
      "pack_id" => "req496-owner-upgrade-#{System.unique_integer([:positive])}",
      "version" => "0.2.0",
      "bpm_export_schema_version" => "bpm/definition/v1",
      "exported_at" => "2026-10-14T00:00:00Z",
      "manifest" => %{"required_roles" => []},
      "definitions" => [],
      "variable_schemas" => [],
      "service_catalog_entries" => [],
      "entity_definitions" => [
        %{
          "entity_definition_id" => Ecto.UUID.generate(),
          "name" => name,
          "display_name" => "Org Unit v2",
          "logical_shape_version" =>
            Base.encode16(:crypto.hash(:sha256, "org_unit v2"), case: :lower),
          "definition_json" => %{
            "name" => name,
            "display_name" => "Org Unit v2",
            "fields" => [
              %{"name" => "name", "type" => "string", "required" => true},
              %{"name" => "code", "type" => "string"}
            ]
          }
        }
      ]
    }
  end

  test "T-14: install stamps the seven declared names, not fxm_free, and activates all eight",
       ctx do
    assert {:ok, %TenantModule{module_id: "fixture_managed"}} =
             install("fixture_managed", ctx.schema)

    rows = rows(ctx.schema)
    assert length(rows) == 8

    for {name, managed_by, status} <- rows do
      expected = if name in @managed, do: "fixture_managed", else: nil
      assert managed_by == expected, "#{name}: #{inspect(managed_by)}"
      assert status == :active, name
    end

    assert {"fxm_free", nil, :active} in rows

    for name <- @managed do
      assert ManagedTypes.owner_of(name, ctx.schema) == {:ok, "fixture_managed"}
    end

    assert ManagedTypes.owner_of("fxm_free", ctx.schema) == :unmanaged
  end

  test "T-15: re-install is refused and the stamps survive; only the owner may add a new version",
       ctx do
    assert {:ok, _} = install("fixture_managed", ctx.schema)
    before = rows(ctx.schema)

    assert install("fixture_managed", ctx.schema) == {:error, :already_installed}
    assert rows(ctx.schema) == before

    # Another module's Owner (built the same way, from a compiled manifest) is refused.
    other = ManagedTypes.module_owner(Letflow.Modules.Fixture)

    assert SolutionPack.install(
             new_org_unit_shape_pack(),
             Ecto.UUID.generate(),
             [prefix: ctx.schema],
             other
           ) ==
             {:error, :entity_type_managed}

    # The tenant (install/3 == install/4 with :tenant) is refused the same way.
    assert SolutionPack.install(new_org_unit_shape_pack(), Ecto.UUID.generate(),
             prefix: ctx.schema
           ) ==
             {:error, :entity_type_managed}

    assert rows(ctx.schema) == before

    # The owning module's Owner adds a new, inactive version, stamped.
    owner = ManagedTypes.module_owner(FixtureManaged)

    assert {:ok, _result} =
             SolutionPack.install(
               new_org_unit_shape_pack(),
               Ecto.UUID.generate(),
               [prefix: ctx.schema],
               owner
             )

    assert count_named(ctx.schema, "org_unit") == 2

    assert Repo.all(
             from(d in EntityDefinition,
               where: d.name == "org_unit",
               select: {d.managed_by, d.status},
               order_by: d.inserted_at
             ),
             prefix: ctx.schema
           ) == [{"fixture_managed", :active}, {"fixture_managed", :inactive}]
  end

  test "T-18: a tenant's own type of a declared name blocks the install with managed_name_taken",
       ctx do
    assert {:ok, own} =
             Definitions.create_definition(
               %{
                 definition: %{
                   name: "org_site",
                   display_name: "Tenant's own site",
                   fields: [%{name: "address", type: :string}]
                 },
                 created_by: Ecto.UUID.generate()
               },
               ctx.schema
             )

    assert install("fixture_managed", ctx.schema) ==
             {:error, {:pack_install_failed, {:managed_name_taken, "org_site"}}}

    # Rolled back: nothing stamped, nothing installed, only the tenant's own row remains.
    assert rows(ctx.schema) == [{"org_site", nil, :inactive}]
    assert Repo.get!(EntityDefinition, own.id, prefix: ctx.schema).managed_by == nil
    refute module_installed?(ctx.schema, "fixture_managed")

    refute Repo.exists?(
             from(i in SolutionPackInstall,
               where: i.tenant_id == ^ctx.tenant_id and i.pack_id == "fixture-managed-foundation"
             )
           )

    assert ManagedTypes.owner_of("org_site", ctx.schema) == :unmanaged
  end

  test "T-19: a declared managed type the pack does not insert fails the install and rolls back",
       ctx do
    assert install("fixture_managed_no_pack", ctx.schema) ==
             {:error, {:pack_install_failed, {:managed_type_not_in_pack, "fxm_missing_type"}}}

    refute module_installed?(ctx.schema, "fixture_managed_no_pack")
    assert rows(ctx.schema) == []
  end
end
