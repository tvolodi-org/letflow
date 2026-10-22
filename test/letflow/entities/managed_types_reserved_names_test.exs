defmodule Letflow.Entities.ManagedTypesReservedNamesTest do
  @moduledoc """
  GH #2581 (design `state/tasks/T-0143/design.md`): a tenant's first creation of a name that a
  registered, not-yet-installed module declares in `manages_entity_types` is refused with
  `{:error, :entity_type_managed}`, so the squat cannot block the module's later install.

    * R-01: refusal at creation, nothing written; the module then installs and stamps the name.
    * R-02: the route answers the uniform 403 and writes nothing.
    * R-03: a tenant solution-pack install of a reserved name is refused and rolls back.
    * R-04: a tenant that already owns an unmanaged type of the name still creates new versions.
    * R-05: with the module installed in the tenant the reserved rule does not apply.
    * R-06: a non-reserved name is not refused and costs no tenant_modules query.
    * R-07: the check is per tenant schema (cross-tenant negative).
    * R-09: the module's own `%Owner{}` path is unchanged.

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
  alias Letflow.ManagedTypesSupport
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  defp tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    tenant
  end

  defp install!(schema) do
    {:ok, _tenant_module} =
      Installs.install("fixture_managed", Ecto.UUID.generate(),
        prefix: schema,
        rationale: "GH #2581 reserved names test"
      )
  end

  defp attrs(name) do
    %{
      definition: %{
        name: name,
        display_name: "GH2581 #{name}",
        fields: [%{name: "name", type: :string, required: true}]
      },
      created_by: Ecto.UUID.generate()
    }
  end

  defp count(schema, name) do
    Repo.aggregate(from(e in EntityDefinition, where: e.name == ^name), :count, prefix: schema)
  end

  test "R-01: creating a name a not-installed module declares is refused, then the install works" do
    %{schema_name: schema} = tenant!("gh2581-r01")

    assert Definitions.create_definition(attrs("fxm_site"), schema) ==
             {:error, :entity_type_managed}

    assert count(schema, "fxm_site") == 0
    assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 0

    install!(schema)
    assert ManagedTypes.owner_of("fxm_site", schema) == {:ok, "fixture_managed"}
  end

  test "R-04: a tenant's existing unmanaged type of that name still accepts new versions" do
    %{schema_name: schema} = tenant!("gh2581-r04")
    ManagedTypesSupport.plant_legacy_squat!(schema, "fxm_site")
    assert count(schema, "fxm_site") == 1

    assert ManagedTypes.check_create("fxm_site", :tenant, schema) == {:ok, nil}

    changed = %{
      definition: %{
        name: "fxm_site",
        display_name: "GH2581 v2",
        fields: [%{name: "address", type: :string}]
      },
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, _v2} = Definitions.create_definition(changed, schema)
    assert count(schema, "fxm_site") == 2
  end

  test "R-05: with the module installed the reserved rule does not apply, the managed rule does" do
    %{schema_name: schema} = tenant!("gh2581-r05")
    install!(schema)

    assert ManagedTypes.check_create("fxm_site", :tenant, schema) ==
             {:error, :entity_type_managed}

    assert Installs.installed?("fixture_managed", prefix: schema)
  end

  test "R-06: a name no module declares is not refused" do
    %{schema_name: schema} = tenant!("gh2581-r06")

    assert ManagedTypes.check_create("gh2581_free", :tenant, schema) == {:ok, nil}
    assert ManagedTypes.check_create(123, :tenant, schema) == {:ok, nil}
    assert {:ok, _} = Definitions.create_definition(attrs("gh2581_free"), schema)
  end

  test "R-02: POST /definitions with a reserved name is the uniform 403 and writes no row" do
    %{schema_name: schema, tenant_id: tenant_id} = tenant!("gh2581-r02")

    conn =
      Plug.Test.conn(:post, "/definitions")
      |> Map.put(:body_params, %{
        "name" => "fxm_site",
        "display_name" => "Tenant attempt",
        "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> Plug.Conn.assign(:trace_id, "gh2581-r02-trace")
      |> Letflow.Routers.Entities.call(Letflow.Routers.Entities.init([]))

    assert conn.status == 403, conn.resp_body
    assert Jason.decode!(conn.resp_body)["code"] == "entity_type_managed"
    assert count(schema, "fxm_site") == 0
  end

  test "R-03: a tenant solution-pack install of a reserved name is refused and rolls back" do
    %{schema_name: schema, tenant_id: tenant_id} = tenant!("gh2581-r03")
    pack_id = "gh2581-tenant-pack-#{System.unique_integer([:positive])}"

    def_json = %{
      "name" => "fxm_site",
      "display_name" => "Tenant site",
      "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
    }

    pack = %{
      "pack_id" => pack_id,
      "version" => "1.0.0",
      "bpm_export_schema_version" => "bpm/definition/v1",
      "exported_at" => "2026-10-14T00:00:00Z",
      "manifest" => %{"required_roles" => []},
      "definitions" => [],
      "variable_schemas" => [],
      "service_catalog_entries" => [],
      "entity_definitions" => [
        %{
          "entity_definition_id" => Ecto.UUID.generate(),
          "name" => "fxm_site",
          "display_name" => "Tenant site",
          "logical_shape_version" =>
            Base.encode16(:crypto.hash(:sha256, "fxm_siteTenant site"), case: :lower),
          "definition_json" => def_json
        }
      ]
    }

    assert SolutionPack.install(pack, Ecto.UUID.generate(), prefix: schema) ==
             {:error, :entity_type_managed}

    assert count(schema, "fxm_site") == 0
    assert Repo.aggregate(ArtifactVersion, :count, prefix: schema) == 0

    refute Repo.exists?(
             from(i in SolutionPackInstall,
               where: i.tenant_id == ^tenant_id and i.pack_id == ^pack_id
             )
           )
  end

  test "R-06b: a name no module declares runs no tenant_modules query" do
    %{schema_name: schema} = tenant!("gh2581-r06b")
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {ref, metadata[:source]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert ManagedTypes.check_create("gh2581_free", :tenant, schema) == {:ok, nil}
    refute_received {^ref, "tenant_modules"}

    # control: a reserved name does read tenant_modules, so the probe above can fail
    assert ManagedTypes.check_create("fxm_site", :tenant, schema) ==
             {:error, :entity_type_managed}

    assert_received {^ref, "tenant_modules"}
  end

  test "R-07: the installed check is per tenant: B stays refused while A has the module" do
    %{schema_name: schema_a} = tenant!("gh2581-r07a")
    %{schema_name: schema_b} = tenant!("gh2581-r07b")
    install!(schema_a)

    assert ManagedTypes.check_create("fxm_site", :tenant, schema_a) ==
             {:error, :entity_type_managed}

    assert Definitions.create_definition(attrs("fxm_site"), schema_b) ==
             {:error, :entity_type_managed}

    assert count(schema_b, "fxm_site") == 0
    assert ManagedTypes.owner_of("fxm_site", schema_b) == :unmanaged
  end

  test "R-09: the owning module's own claim path is unchanged" do
    %{schema_name: schema} = tenant!("gh2581-r09")
    owner = ManagedTypes.module_owner(FixtureManaged)

    assert ManagedTypes.check_create("fxm_unit", owner, schema) == {:ok, "fixture_managed"}
  end
end
