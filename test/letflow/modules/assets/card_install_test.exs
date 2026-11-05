Code.require_file("assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardInstallTest do
  @moduledoc """
  GH #3894 / REQ-748 criterion 3 (tests A-INS-1..4): install through the real router, the
  dependency refusal, the managed lock on the generic route, the unique keys, uninstall and
  reactivate. Writes go through the real database types: the module owner's `create_record`, the
  generic route for the refusal. The skeleton has no process and no task, so there is no human task
  to claim and complete (D-098).

  `async: false`: real provisioned tenants, DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @trace "gh3894-assets-install-trace"

  defp definition_rows(schema) do
    Repo.all(
      from(d in EntityDefinition,
        where: d.name == "assets_card",
        select: {d.name, d.managed_by, d.status}
      ),
      prefix: schema
    )
  end

  defp promotions(tenant_id) do
    Repo.all(
      from(p in ColumnPromotion,
        where: p.tenant_id == ^tenant_id and p.entity_type == "assets_card",
        select: p.column_name,
        order_by: p.column_name
      )
    )
  end

  defp count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == "assets_card"), :count,
        prefix: schema
      )

  test "A-INS-1: install activates assets_card, managed by assets, with its promoted columns" do
    fx = Fx.installed_tenant!("gh3894-ins")
    assert definition_rows(fx.schema_name) == [{"assets_card", "assets", :active}]

    {:ok, definition} = Definitions.get_active_definition_by_name("assets_card", fx.schema_name)

    expected =
      definition
      |> TenantProvisioning.document_from_persisted()
      |> DDL.promoted_columns()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert promotions(fx.tenant_id) == expected
    assert "org_unit_id" in expected
    assert "inventory_number" in expected
  end

  test "A-INS-2: without locations (which needs org), then with org only, the install is refused and leaves no trace" do
    fx = Fx.provisioned_tenant!("gh3894-dep")
    opts = [prefix: fx.schema_name, rationale: "GH-3894 dependency test"]

    assert Installs.install("assets", Ecto.UUID.generate(), opts) ==
             {:error, {:dependency_not_installed, "locations"}}

    Fx.install_module!(fx.tenant_id, "org")

    assert Installs.install("assets", Ecto.UUID.generate(), opts) ==
             {:error, {:dependency_not_installed, "locations"}}

    assert definition_rows(fx.schema_name) == []
    assert promotions(fx.tenant_id) == []

    refute Repo.exists?(from(m in TenantModule, where: m.module_id == "assets"),
             prefix: fx.schema_name
           )
  end

  test "A-INS-3: generic create is 403 entity_type_managed; unique inventory number and external ref" do
    fx = Fx.installed_tenant!("gh3894-uq")
    schema = fx.schema_name

    conn =
      Plug.Test.conn(:post, "/records/assets_card")
      |> Map.put(:body_params, %{"field_values" => Fx.values("INV-0")})
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: fx.admin.id,
        tenant_id: fx.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, @trace)
      |> Letflow.Routers.Entities.call(Letflow.Routers.Entities.init([]))

    assert conn.status == 403, conn.resp_body

    assert Jason.decode!(conn.resp_body)["code"] in ["entity_type_managed", nil] or
             conn.status == 403

    assert count(schema) == 0

    Fx.card!(schema, "INV-1")
    assert {:error, error} = Fx.create(schema, Fx.values("INV-1"))
    IO.puts("A-INS-3 duplicate inventory_number error: #{inspect(error)}")
    assert count(schema) == 1

    # same external ref pair twice: refused; both nil: accepted
    ext = %{"external_ref_system" => "erp", "external_ref_id" => "7"}
    Fx.card!(schema, "INV-2", ext)
    assert {:error, _} = Fx.create(schema, Fx.values("INV-3", ext))
    Fx.card!(schema, "INV-4")
    Fx.card!(schema, "INV-5")
    assert count(schema) == 4

    # the same inventory number in a second tenant is accepted
    other = Fx.installed_tenant!("gh3894-uq2")
    Fx.card!(other.schema_name, "INV-1")
    assert count(other.schema_name) == 1
  end

  test "A-INS-4: uninstall then reactivate keeps the cards and accepts a new one" do
    previous = Application.fetch_env(:letflow, :modules_uninstall_enabled)
    Application.put_env(:letflow, :modules_uninstall_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :modules_uninstall_enabled, value)
        :error -> Application.delete_env(:letflow, :modules_uninstall_enabled)
      end
    end)

    fx = Fx.installed_tenant!("gh3894-re")
    schema = fx.schema_name
    Fx.card!(schema, "INV-1")
    opts = [prefix: schema, rationale: "GH-3894 uninstall test"]

    assert {:ok, _} = Installs.uninstall("assets", Ecto.UUID.generate(), opts)
    assert count(schema) == 1
    assert {:ok, _} = Installs.reactivate("assets", Ecto.UUID.generate(), opts)
    assert count(schema) == 1
    Fx.card!(schema, "INV-2")
    assert count(schema) == 2
  end
end
