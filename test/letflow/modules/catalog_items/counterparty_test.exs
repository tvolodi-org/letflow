Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.CounterpartyTest do
  @moduledoc """
  GH #3407 / REQ-604 criteria 4..8 and 10 (tests C-01..C-09): the supplier master
  `catalog_counterparty` of the `catalog_items` module, on a real provisioned tenant.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.CatalogItems

  import Letflow.CatalogItemsFixture, except: [values: 3]

  defp values(type, code, extra \\ %{}), do: Letflow.CatalogItemsFixture.values(type, code, extra)

  @type_name "catalog_counterparty"
  @trace "gh3407-counterparty-fixed-trace"
  @entities_opts Letflow.Routers.Entities.init([])

  @runbook Path.expand("../../../../docs/runbooks/wms-foundation.md", __DIR__)

  setup do
    {:ok, installed_tenant!("gh3407-cp")}
  end

  defp ref(system, id), do: %{"external_ref_system" => system, "external_ref_id" => id}

  defp supplier_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^@type_name), :count,
        prefix: schema
      )

  defp call_entities(tenant_id, method, path, body) do
    Plug.Test.conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  describe "criterion 4: definition-level rules through the owner path" do
    test "C-01: a duplicate code is refused with a unique violation on [code]", %{schema: schema} do
      assert {:ok, _} = create(schema, @type_name, values(@type_name, "S-1"))

      assert {:error, {:record_payload_invalid, [violation]}} =
               create(schema, @type_name, values(@type_name, "S-1"))

      assert %Violation{rule: :unique, path: ["code"]} = violation
      assert supplier_count(schema) == 1
    end

    test "C-02: an unknown kind and each missing required field are refused", %{schema: schema} do
      assert {:error, _} =
               create(schema, @type_name, values(@type_name, "S-2", %{"kind" => "carrier"}))

      for field <- ["code", "name", "kind", "active"] do
        vals = Map.delete(values(@type_name, "S-3"), field)
        assert {:error, _} = create(schema, @type_name, vals), "missing #{field} was accepted"
      end

      assert {:ok, _} =
               create(schema, @type_name, values(@type_name, "S-4", %{"kind" => "contractor"}))

      assert supplier_count(schema) == 1
    end

    test "C-03: the same non-null external_ref pair is refused, any number of null pairs pass",
         %{schema: schema} do
      assert {:ok, _} = create(schema, @type_name, values(@type_name, "R-1", ref("1c", "42")))

      assert {:error, {:record_payload_invalid, [violation]}} =
               create(schema, @type_name, values(@type_name, "R-2", ref("1c", "42")))

      assert %Violation{rule: :unique, path: ["external_ref_system", "external_ref_id"]} =
               violation

      for n <- 1..3,
          do: assert({:ok, _} = create(schema, @type_name, values(@type_name, "N-#{n}")))

      assert supplier_count(schema) == 4
    end

    test "C-04: a supplier with only external_ref_system is accepted (both-or-neither not enforced)",
         %{schema: schema} do
      assert {:ok, _} =
               create(
                 schema,
                 @type_name,
                 values(@type_name, "H-1", %{"external_ref_system" => "1c"})
               )
    end
  end

  describe "criterion 5: retire is active false, never a delete" do
    test "C-05: an inactive supplier stays readable; the generic delete is refused; no delete function",
         %{schema: schema, tenant_id: tenant_id} do
      rec = counterparty!(schema, "RET-1", %{"tax_id" => "123456789012"})
      assert CatalogItems.active?(schema, rec.record_id)

      update!(
        schema,
        rec,
        values(@type_name, "RET-1", %{"tax_id" => "123456789012", "active" => false})
      )

      assert {:ok, %{"active" => false, "code" => "RET-1"}} =
               CatalogItems.lookup(schema, rec.record_id)

      assert CatalogItems.active?(schema, rec.record_id) == false

      conn = call_entities(tenant_id, :delete, "/records/#{@type_name}/#{rec.record_id}", %{})
      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})
      assert {:ok, _} = CatalogItems.lookup(schema, rec.record_id)

      source =
        File.read!(
          Path.join([
            File.cwd!(),
            "lib",
            "letflow",
            "modules",
            "catalog_items",
            "catalog_items.ex"
          ])
        )

      refute source =~ ~r/def\s+(delete|remove|destroy)/
    end
  end

  describe "criterion 6: lookup/2 and active?/2 return suppliers" do
    test "C-06: lookup returns the supplier map; active? is true; other ids are false",
         %{schema: schema} do
      rec = counterparty!(schema, "LK-1", %{"kind" => "contractor"})

      assert {:ok, map} = CatalogItems.lookup(schema, rec.record_id)
      assert map["record_id"] == rec.record_id
      assert map["entity_type"] == @type_name
      assert map["code"] == "LK-1"
      assert map["name"] == "Supplier LK-1"
      assert map["kind"] == "contractor"
      assert map["active"] == true
      assert CatalogItems.active?(schema, rec.record_id) == true

      assert CatalogItems.active?(schema, Ecto.UUID.generate()) == false
      uom = uom!(schema, "LK-U")
      assert {:ok, %{"entity_type" => "catalog_uom"}} = CatalogItems.lookup(schema, uom.record_id)

      assert {:ok, %{"entity_type" => "catalog_item"}} =
               CatalogItems.lookup(schema, item!(schema, "LK-I", uom.record_id).record_id)
    end
  end

  describe "criterion 7: the generic import is refused" do
    test "C-07: a valid import body for the supplier type is 403 and writes nothing",
         %{schema: schema, tenant_id: tenant_id} do
      body = fn type ->
        %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => type,
          "records" => [%{"field_values" => values(type, "IMP-1")}]
        }
      end

      for type <- [@type_name, "catalog_item"] do
        conn = call_entities(tenant_id, :post, "/records/#{type}/import", body.(type))
        assert conn.status == 403, "#{type}: #{conn.status} #{conn.resp_body}"

        assert conn.resp_body ==
                 Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})
      end

      assert supplier_count(schema) == 0
    end
  end

  describe "criterion 8: tenant isolation (INV-1, INV-5, INV-10)" do
    test "C-08: tenant A's supplier is not found with tenant B's prefix, same as an absent id",
         %{schema: schema_a} do
      b = installed_tenant!("gh3407-cp-b")
      rec = counterparty!(schema_a, "ISO-1")

      assert {:ok, %{"code" => "ISO-1"}} = CatalogItems.lookup(schema_a, rec.record_id)

      assert CatalogItems.lookup(b.schema, rec.record_id) == {:error, :not_found}

      assert CatalogItems.lookup(b.schema, rec.record_id) ==
               CatalogItems.lookup(b.schema, Ecto.UUID.generate())

      assert CatalogItems.active?(b.schema, rec.record_id) == false
    end
  end

  describe "T-0862: a tenant installed before the type existed" do
    test "U-01: reactivate is upgrade_required (old hash), reinstall is refused, lookup still works",
         %{schema: schema} do
      alias Letflow.Modules.{Installs, TenantModule}

      actor = Ecto.UUID.generate()
      opts = [prefix: schema, rationale: "T-0862 old tenant"]
      rec = counterparty!(schema, "OLD-1")

      # A row stamped before GH #3407 carries the hash of the two-type manifest.
      {:ok, _} = Installs.uninstall("catalog_items", actor, opts)

      Repo.get_by!(TenantModule, [module_id: "catalog_items"], prefix: schema)
      |> Ecto.Changeset.change(%{manifest_hash: String.duplicate("0", 64)})
      |> Repo.update!(prefix: schema)

      assert {:error, :upgrade_required} = Installs.reactivate("catalog_items", actor, opts)
      assert {:error, :already_installed} = Installs.install("catalog_items", actor, opts)

      assert {:ok, %{"code" => "OLD-1"}} = CatalogItems.lookup(schema, rec.record_id)
    end
  end

  describe "criterion 10: runbook" do
    test "C-09: the runbook names the type, its kind values, the multi-type lookup and the gaps" do
      text = File.read!(@runbook)

      for needle <- [
            "catalog_counterparty",
            "supplier",
            "contractor",
            "entity_type",
            "D12",
            "upgrade"
          ] do
        assert text =~ needle, "runbook does not mention #{needle}"
      end
    end
  end
end
