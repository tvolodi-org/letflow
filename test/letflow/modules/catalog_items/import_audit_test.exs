Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.ImportAuditTest do
  @moduledoc """
  GH #3739 / REQ-706: one audit entry for every created or updated row of the catalog masters
  (`catalog_uom`, `catalog_item`, `catalog_counterparty`), through the real import route on fresh
  tenants. E* entries (criterion 1); T* same transaction (2); N* no entry without a change (3);
  R* readable and cross-tenant (4).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.CatalogItemsFixture, as: Fx
  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems.Import

  @schema_version "entities/record-export/v1"

  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3739-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3739 test user",
        email: "gh3739-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{schema: schema, slug: slug, plaintext: plaintext, actor: user.id}
  end

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp upsert(ctx, type, records, query \\ "") do
    body = %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => type,
      "records" => records,
      "upsert_by" => "external_ref"
    }

    conn(:post, "/api/v1/entities/records/#{type}/import" <> query, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> authed(ctx)
  end

  defp ref(id), do: %{"system" => "erp", "id" => id}

  defp uom_row(id, name \\ nil),
    do: %{
      "external_ref" => ref(id),
      "field_values" => %{"code" => id, "name" => name || "Unit #{id}", "active" => true}
    }

  defp item_row(id, uom_id),
    do: %{
      "external_ref" => ref(id),
      "field_values" => %{
        "code" => id,
        "name" => "Item #{id}",
        "base_uom_id" => uom_id,
        "kind" => "material",
        "active" => true
      }
    }

  defp cp_row(id),
    do: %{
      "external_ref" => ref(id),
      "field_values" => %{
        "code" => id,
        "name" => "Supplier #{id}",
        "kind" => "supplier",
        "active" => true
      }
    }

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp entries(schema, like \\ "catalog_%") do
    Repo.all(from(a in Entry, where: like(a.action, ^like), order_by: a.timestamp),
      prefix: schema
    )
  end

  defp stored(schema, type, id) do
    {:ok, %Latest{field_values: fv}} = Latest.get_by_external_ref(type, "erp", id, schema)
    fv
  end

  describe "criterion 1: entries per row" do
    test "E1: created and updated rows of all three types are audited" do
      ctx = tenant_ctx("gh3739-e1")
      assert upsert(ctx, "catalog_uom", [uom_row("U1")]).status == 200
      assert upsert(ctx, "catalog_item", [item_row("I1", "U1")]).status == 200
      assert upsert(ctx, "catalog_counterparty", [cp_row("C1")]).status == 200

      assert Enum.map(entries(ctx.schema), &{&1.action, &1.resource_type}) == [
               {"catalog_uom.created", "catalog_uom"},
               {"catalog_item.created", "catalog_item"},
               {"catalog_counterparty.created", "catalog_counterparty"}
             ]

      [uom | _] = entries(ctx.schema)
      assert uom.before_state == nil
      assert uom.after_state == stored(ctx.schema, "catalog_uom", "U1")
      assert uom.actor_id == ctx.actor

      assert uom.resource_id ==
               elem(Latest.get_by_external_ref("catalog_uom", "erp", "U1", ctx.schema), 1).record_id

      before = stored(ctx.schema, "catalog_uom", "U1")
      assert outcomes(upsert(ctx, "catalog_uom", [uom_row("U1", "Renamed")])) == ["updated"]

      assert upsert(ctx, "catalog_item", [
               item_row("I1", "U1") |> put_in(["field_values", "name"], "I1b")
             ]).status == 200

      assert upsert(ctx, "catalog_counterparty", [
               put_in(cp_row("C1"), ["field_values", "name"], "S2")
             ]).status == 200

      acts = Enum.map(entries(ctx.schema), & &1.action)

      assert Enum.sort(acts) ==
               Enum.sort(~w(catalog_uom.created catalog_item.created catalog_counterparty.created
                    catalog_uom.updated catalog_item.updated catalog_counterparty.updated))

      upd = Enum.find(entries(ctx.schema), &(&1.action == "catalog_uom.updated"))
      assert upd.before_state == before
      assert upd.after_state["name"] == "Renamed"
    end
  end

  describe "criterion 2: same transaction" do
    test "T1: an audit failure gives internal_error and no record" do
      ctx = tenant_ctx("gh3739-t1")
      Repo.query!(~s(DROP TABLE "#{ctx.schema}".audit_entries))
      conn = upsert(ctx, "catalog_uom", [uom_row("TU1")])
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["internal_error"]

      assert {:error, :not_found} =
               Latest.get_by_external_ref("catalog_uom", "erp", "TU1", ctx.schema)
    end
  end

  describe "criterion 3: no entry without a change" do
    test "N1: refused rows write no entry" do
      ctx = tenant_ctx("gh3739-n1")

      conn =
        upsert(ctx, "catalog_item", [
          item_row("I1", "NOPE"),
          cp_row("X") |> Map.put("field_values", %{"bogus" => 1})
        ])

      assert conn.status == 200
      assert Enum.all?(outcomes(conn), &(&1 != "created"))

      assert upsert(ctx, "catalog_uom", [uom_row("DUP"), uom_row("DUP")]).status == 200
      assert length(entries(ctx.schema)) == 1
    end

    test "N2: a second import of the same file writes no entry" do
      ctx = tenant_ctx("gh3739-n2")
      rows = [uom_row("U1"), uom_row("U2")]
      assert upsert(ctx, "catalog_uom", rows).status == 200
      assert length(entries(ctx.schema)) == 2
      assert outcomes(upsert(ctx, "catalog_uom", rows)) == ["unchanged", "unchanged"]
      assert length(entries(ctx.schema)) == 2
    end

    test "N3: Import.row/3 with the same ctx twice writes one entry" do
      ctx = tenant_ctx("gh3739-n3")

      entry = %{
        entity_type: "catalog_uom",
        external_ref: %ExternalRef{system: "erp", id: "R1"},
        field_values: %{"code" => "R1", "name" => "Replay", "active" => true}
      }

      c = %{actor_id: ctx.actor, idempotency_key: Ecto.UUID.generate(), dry_run: false}
      assert {:ok, first} = Import.row(ctx.schema, entry, c)
      assert {:ok, again} = Import.row(ctx.schema, entry, c)
      assert again.record_id == first.record_id
      assert length(entries(ctx.schema)) == 1
    end

    test "N4: a dry run writes no entry and reports the real outcomes" do
      ctx = tenant_ctx("gh3739-n4")
      rows = [uom_row("D1"), uom_row("D2"), uom_row("D3")]
      dry = upsert(ctx, "catalog_uom", rows, "?dry_run=true")
      assert dry.status == 200
      assert entries(ctx.schema) == []
      real = upsert(ctx, "catalog_uom", rows)
      assert outcomes(dry) == outcomes(real)
      assert length(entries(ctx.schema)) == 3
    end
  end

  describe "criterion 4: readable" do
    test "R1: GET /audit shows the entries to the tenant, none to another tenant" do
      a = tenant_ctx("gh3739-ra")
      b = tenant_ctx("gh3739-rb")
      assert upsert(a, "catalog_uom", [uom_row("U1")]).status == 200
      assert upsert(a, "catalog_item", [item_row("I1", "U1")]).status == 200

      get = fn ctx ->
        conn = conn(:get, "/api/v1/audit?resource_type=catalog_item&page_size=200") |> authed(ctx)
        assert conn.status == 200, conn.resp_body
        Jason.decode!(conn.resp_body)["items"]
      end

      assert [item] = get.(a)
      assert item["action"] == "catalog_item.created"
      assert get.(b) == []
    end
  end
end
