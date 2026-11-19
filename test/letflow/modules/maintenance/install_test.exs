Code.require_file("../assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Maintenance.InstallTest do
  @moduledoc """
  REQ-893 criteria 2 to 5: the flag-off 404, the flag-on install, numbering and the record types.
  Real provisioned tenants and the real `Letflow.Routers.TenantModules`. `async: false`: DDL and the
  VM-global flag.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Documents
  alias Letflow.Documents.DocumentType
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Modules.Maintenance
  alias Letflow.Modules.TenantModule

  @router Letflow.Routers.TenantModules.init([])
  @actor "00000000-0000-4000-8000-0000000000a1"

  defp post_install(tenant_id, module_id) do
    Plug.Test.conn(:post, "/")
    |> Map.put(:body_params, %{"module_id" => module_id, "rationale" => "REQ-893 test"})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "req893-trace")
    |> Letflow.Routers.TenantModules.call(@router)
  end

  defp with_flag(value) do
    old = Application.get_env(:letflow, :maintenance_enabled)
    Application.put_env(:letflow, :maintenance_enabled, value)
    on_exit(fn -> Application.put_env(:letflow, :maintenance_enabled, old) end)
  end

  defp counts(schema) do
    %{
      modules: Repo.aggregate(TenantModule, :count, prefix: schema),
      definitions: Repo.aggregate(EntityDefinition, :count, prefix: schema),
      doc_types: Repo.aggregate(DocumentType, :count, prefix: schema)
    }
  end

  defp installed?(schema),
    do: Repo.exists?(from(m in TenantModule, where: m.module_id == "maintenance"), prefix: schema)

  defp rows(schema, name),
    do:
      Repo.all(
        from(d in EntityDefinition, where: d.name == ^name, select: {d.managed_by, d.status}),
        prefix: schema
      )

  test "I-01: flag off: install answers the 404 of an unknown module and writes nothing" do
    with_flag(false)
    fx = Fx.installed_tenant!("req893-off")
    before = counts(fx.schema_name)

    off = post_install(fx.tenant_id, "maintenance")
    unknown = post_install(fx.tenant_id, "no_such_module")

    assert off.status == 404
    assert unknown.status == 404
    assert Jason.decode!(off.resp_body) == Jason.decode!(unknown.resp_body)
    assert counts(fx.schema_name) == before
    refute installed?(fx.schema_name)
  end

  test "I-02: flag on, assets installed: 201, both types active and managed, both doc types registered" do
    with_flag(true)
    fx = Fx.installed_tenant!("req893-on")

    assert post_install(fx.tenant_id, "maintenance").status == 201
    assert installed?(fx.schema_name)

    for name <- ["maintenance_work_request", "maintenance_work_order"] do
      assert rows(fx.schema_name, name) == [{"maintenance", :active}]
    end

    keys =
      Repo.all(from(t in DocumentType, where: t.owner_module == "maintenance", select: t.key),
        prefix: fx.schema_name
      )

    assert Enum.sort(keys) == ["maintenance_order", "maintenance_request"]
  end

  test "I-03: without assets: 422 missing dependency, nothing installed" do
    with_flag(true)
    fx = Fx.provisioned_tenant!("req893-dep")
    before = counts(fx.schema_name)

    conn = post_install(fx.tenant_id, "maintenance")
    assert conn.status == 422, conn.resp_body
    assert conn.resp_body =~ "missing dependency: assets"
    assert counts(fx.schema_name) == before
    refute installed?(fx.schema_name)
  end

  test "I-04: installing in tenant A leaves tenant B without the module (INV-1)" do
    with_flag(true)
    a = Fx.installed_tenant!("req893-a")
    b = Fx.installed_tenant!("req893-b")

    assert post_install(a.tenant_id, "maintenance").status == 201
    assert installed?(a.schema_name)
    refute installed?(b.schema_name)
    assert rows(b.schema_name, "maintenance_work_request") == []

    refute Repo.exists?(from(t in DocumentType, where: t.owner_module == "maintenance"),
             prefix: b.schema_name
           )
  end

  test "I-05: numbering: WR and WO, year scope, pad 6, label WR-<year>-000001" do
    with_flag(true)
    fx = Fx.installed_tenant!("req893-num")
    assert post_install(fx.tenant_id, "maintenance").status == 201

    types =
      Repo.all(from(t in DocumentType, where: t.owner_module == "maintenance"),
        prefix: fx.schema_name
      )
      |> Map.new(&{&1.key, &1})

    assert %{number_prefix: "WR", numbering_scope: :year, number_pad: 6} =
             types["maintenance_request"]

    assert %{number_prefix: "WO", numbering_scope: :year, number_pad: 6} =
             types["maintenance_order"]

    year = Integer.to_string(Date.utc_today().year)
    assert Documents.number_label(types["maintenance_request"], 1, year) == "WR-#{year}-000001"
    assert Documents.number_label(types["maintenance_order"], 1, year) == "WO-#{year}-000001"
  end

  describe "I-06: record types" do
    setup do
      with_flag(true)
      fx = Fx.installed_tenant!("req893-types")
      assert post_install(fx.tenant_id, "maintenance").status == 201
      %{fx: fx, owner: ManagedTypes.owner_for!(Maintenance)}
    end

    defp create(fx, owner, type, values) do
      Records.create_record(
        %{
          entity_type: type,
          field_values: values,
          actor_id: @actor,
          idempotency_key: Ecto.UUID.generate()
        },
        fx.schema_name,
        owner
      )
    end

    defp request_values(extra \\ %{}) do
      Map.merge(
        %{
          "asset_card_id" => Ecto.UUID.generate(),
          "org_unit_id" => Ecto.UUID.generate(),
          "description" => "Leaking pump",
          "urgency" => "normal",
          "status" => "new",
          "reported_by" => @actor,
          "document_id" => Ecto.UUID.generate()
        },
        extra
      )
    end

    defp order_values(extra) do
      Map.merge(
        %{
          "asset_card_id" => Ecto.UUID.generate(),
          "org_unit_id" => Ecto.UUID.generate(),
          "description" => "Fix the pump",
          "urgency" => "urgent",
          "document_id" => Ecto.UUID.generate(),
          "instance_id" => Ecto.UUID.generate()
        },
        extra
      )
    end

    test "a valid request is stored; urgency 'high' is refused", %{fx: fx, owner: owner} do
      assert {:ok, _} = create(fx, owner, "maintenance_work_request", request_values())

      assert {:error, _} =
               create(
                 fx,
                 owner,
                 "maintenance_work_request",
                 request_values(%{"urgency" => "high"})
               )
    end

    test "an order whose request_id names no request is refused by the foreign key; a real one is stored",
         %{fx: fx, owner: owner} do
      assert {:error, _} =
               create(
                 fx,
                 owner,
                 "maintenance_work_order",
                 order_values(%{"request_id" => Ecto.UUID.generate()})
               )

      {:ok, %{record: req}} = create(fx, owner, "maintenance_work_request", request_values())

      assert {:ok, _} =
               create(
                 fx,
                 owner,
                 "maintenance_work_order",
                 order_values(%{"request_id" => req.record_id})
               )

      assert {:ok, _} = create(fx, owner, "maintenance_work_order", order_values(%{}))
    end

    test "the order type has no status field", %{fx: fx} do
      {:ok, definition} =
        Letflow.Entities.Definitions.get_active_definition_by_name(
          "maintenance_work_order",
          fx.schema_name
        )

      names =
        definition
        |> Letflow.TenantProvisioning.document_from_persisted()
        |> Map.fetch!(:fields)
        |> Enum.map(& &1.name)

      refute "status" in names
      assert "request_id" in names
    end
  end
end
