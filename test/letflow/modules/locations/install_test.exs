defmodule Letflow.Modules.Locations.InstallTest do
  @moduledoc """
  GH #3501 / REQ-625 criteria 3, 4, 5 and 10 (tests I-1, N-1, N-2, M-1, M-2, S-2): install through
  the real `Letflow.Routers.TenantModules`, the managed-name conflict rollback, the managed lock on
  the generic entity routes, and the absence of any route or permission.

  Everything runs against a real provisioned tenant on real Postgres. `async: false`: tenant
  provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @trace "gh3501-locations-install-fixed-trace"

  @install_opts Letflow.Routers.TenantModules.init([])
  @entities_opts Letflow.Routers.Entities.init([])

  setup do
    tenant = fresh_tenant!("gh3501-loc")
    {:ok, tenant_id: tenant.tenant_id, schema: tenant.schema_name}
  end

  # A provisioned tenant plus the cleanup of the GLOBAL rows an install writes with an FK onto
  # `tenants` (registered after the fixture's own on_exit, so it runs first).
  defp fresh_tenant!(prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: prefix)

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

  defp post_install(tenant_id, body) do
    Plug.Test.conn(:post, "/")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.TenantModules.call(@install_opts)
  end

  defp install_locations!(ctx) do
    conn =
      post_install(ctx.tenant_id, %{
        "module_id" => "locations",
        "rationale" => "GH-3501 install test"
      })

    assert conn.status == 201, conn.resp_body
    conn
  end

  defp rows(schema) do
    Repo.all(
      from(d in EntityDefinition,
        select: {d.name, d.managed_by, d.status},
        order_by: [d.name, d.inserted_at]
      ),
      prefix: schema
    )
  end

  defp module_installed?(schema) do
    Repo.exists?(from(m in TenantModule, where: m.module_id == "locations"), prefix: schema)
  end

  defp promotions(tenant_id) do
    Repo.all(
      from(p in ColumnPromotion,
        where: p.tenant_id == ^tenant_id,
        select: {p.entity_type, p.column_name},
        order_by: [p.entity_type, p.column_name]
      )
    )
  end

  # The promoted columns the activation must have registered, computed from the persisted
  # definition by the same function the DDL uses, never hard-coded.
  defp expected_promotions(schema) do
    {:ok, definition} = Definitions.get_active_definition_by_name("location_node", schema)

    definition
    |> TenantProvisioning.document_from_persisted()
    |> DDL.promoted_columns()
    |> Enum.map(&{"location_node", &1.name})
    |> Enum.sort()
  end

  defp record_count(schema) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == "location_node"), :count,
      prefix: schema
    )
  end

  defp call_entities(ctx, method, path, body) do
    Plug.Test.conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  describe "criterion 3: POST /tenant/modules as TENANT_ADMIN" do
    test "I-1a: a missing, blank or non-string rationale is 422 and installs nothing; a real one is 201",
         ctx do
      for body <- [
            %{"module_id" => "locations"},
            %{"module_id" => "locations", "rationale" => nil},
            %{"module_id" => "locations", "rationale" => ""},
            %{"module_id" => "locations", "rationale" => "   "},
            %{"module_id" => "locations", "rationale" => 7}
          ] do
        conn = post_install(ctx.tenant_id, body)
        assert conn.status == 422, "#{inspect(body)}: #{conn.status} #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["detail"] == "rationale is required"
      end

      refute module_installed?(ctx.schema)
      assert rows(ctx.schema) == []
      assert promotions(ctx.tenant_id) == []

      conn = install_locations!(ctx)
      body = Jason.decode!(conn.resp_body)
      assert body["module_id"] == "locations"
      assert body["version"] == Letflow.Modules.Locations.manifest().version
      assert module_installed?(ctx.schema)
    end

    test "I-1b: afterwards location_node exists, active, managed_by locations", ctx do
      install_locations!(ctx)

      assert rows(ctx.schema) == [{"location_node", "locations", :active}]
    end

    test "I-1c: exactly one promotion row per promoted column, address and external_ref included",
         ctx do
      install_locations!(ctx)

      expected = expected_promotions(ctx.schema)
      assert promotions(ctx.tenant_id) == expected

      for column <-
            ~w(code node_kind parent_id address location_type active external_ref_system external_ref_id) do
        assert {"location_node", column} in expected, "#{column} should be promoted"
      end

      # `name` and `org_site_id` are not queried, so they have no column.
      refute {"location_node", "name"} in expected
      refute {"location_node", "org_site_id"} in expected
    end
  end

  describe "criterion 4: a tenant-created location_node blocks the install and everything rolls back" do
    setup ctx do
      # The tenant path refuses this name now; plant a pre-existing legacy squat.
      own =
        Letflow.ManagedTypesSupport.plant_legacy_squat!(ctx.schema, "location_node", [
          %{name: "address", type: :string}
        ])

      {:ok, own_id: own.id}
    end

    test "N-1: Installs.install/3 refuses with managed_name_taken and leaves no trace", ctx do
      assert Installs.install("locations", Ecto.UUID.generate(),
               prefix: ctx.schema,
               rationale: "GH-3501 conflict test"
             ) == {:error, {:pack_install_failed, {:managed_name_taken, "location_node"}}}

      assert rows(ctx.schema) == [{"location_node", nil, :inactive}]
      assert Repo.get!(EntityDefinition, ctx.own_id, prefix: ctx.schema).managed_by == nil
      refute module_installed?(ctx.schema)
      assert promotions(ctx.tenant_id) == []
      assert ManagedTypes.owner_of("location_node", ctx.schema) == :unmanaged

      refute Repo.exists?(
               from(i in SolutionPackInstall,
                 where: i.tenant_id == ^ctx.tenant_id and i.pack_id == "letflow-locations"
               )
             )
    end

    test "N-2: through the route the same refusal is a 422 and also installs nothing", ctx do
      conn =
        post_install(ctx.tenant_id, %{
          "module_id" => "locations",
          "rationale" => "GH-3501 route conflict"
        })

      assert conn.status == 422, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == "module installation failed"
      assert rows(ctx.schema) == [{"location_node", nil, :inactive}]
      refute module_installed?(ctx.schema)
      assert promotions(ctx.tenant_id) == []
    end
  end

  describe "criterion 5: managed lock" do
    setup ctx do
      install_locations!(ctx)
      :ok
    end

    test "M-1: POST /records/location_node is the uniform 403 entity_type_managed and writes nothing",
         ctx do
      conn =
        call_entities(ctx, :post, "/records/location_node", %{
          "field_values" => %{
            "code" => "x",
            "name" => "x",
            "node_kind" => "site",
            "active" => true
          }
        })

      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})
      assert record_count(ctx.schema) == 0
    end
  end

  describe "criterion 10: no route, no permission" do
    test "S-2: the manifest declares no permission, role grant or route policy" do
      manifest = Letflow.Modules.Locations.manifest()

      assert manifest.permissions == []
      assert manifest.role_grants == %{}
      assert manifest.route_policies == []
    end
  end
end
