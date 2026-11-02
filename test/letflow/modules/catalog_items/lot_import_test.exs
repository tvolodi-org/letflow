Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.LotImportTest do
  @moduledoc """
  GH #3599 / REQ-654: the import of lots through the real router (a real API-token bearer) on fresh
  tenants with the real `catalog_items` module installed. `async: false`: provisioning switches the
  sandbox to `:auto`.

  L1 create; L2 duplicate code; P1 re-import; P3 changes; F1 refusals; X1 tenancy.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CatalogItemsFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ~w(item_id code producer mark expiry_date external_ref_system external_ref_id)

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json_import(ctx, type, rows) do
    body = %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => type,
      "upsert_by" => "external_ref",
      "records" => rows
    }

    conn(:post, "/api/v1/entities/records/#{type}/import?upsert_by=external_ref", body)
    |> authed(ctx)
  end

  defp ref(id), do: %{"system" => "erp", "id" => id}

  # A tenant with catalog_items installed, a unit "U1" and items "I1", "I2" imported by the route.
  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3599-lot-#{Ecto.UUID.generate()}",
        display_name: "GH-3599 test user",
        email: "gh3599-lot-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    ctx = %{tenant_id: tenant_id, schema: schema, slug: slug, plaintext: plaintext}

    uom = %{
      "external_ref" => ref("U1"),
      "field_values" => %{"code" => "U1", "name" => "Unit", "active" => true}
    }

    assert json_import(ctx, "catalog_uom", [uom]).status == 200

    items =
      for id <- ["I1", "I2"] do
        %{
          "external_ref" => ref(id),
          "field_values" => %{
            "code" => id,
            "name" => "Item #{id}",
            "base_uom_id" => "U1",
            "kind" => "material",
            "active" => true
          }
        }
      end

    assert json_import(ctx, "catalog_item", items).status == 200
    ctx
  end

  defp lots(ctx, rows, header \\ @header, query \\ "") do
    bytes = XlsxFixture.build([[header | rows]])

    conn(
      :post,
      "/api/v1/entities/records/catalog_lot/import?upsert_by=external_ref" <> query,
      bytes
    )
    |> put_req_header("content-type", @xlsx)
    |> authed(ctx)
  end

  # item external id, code, producer, expiry text, external id
  defp l(item, code, id, producer \\ "Acme", expiry \\ "2027-01-31"),
    do: [item, code, producer, "mark", expiry, "erp", id]

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp lot(ctx, id) do
    row =
      Repo.one(
        from(t in "entity_catalog_lot",
          where: t.external_ref_system == "erp" and t.external_ref_id == ^id,
          select: type(t.record_id, Ecto.UUID)
        ),
        prefix: ctx.schema
      )

    row && elem(CatalogItems.lookup(ctx.schema, row), 1)
  end

  defp counts(schema) do
    {Repo.aggregate(from(e in "events", select: e.id), :count, prefix: schema),
     Repo.aggregate(Latest, :count, prefix: schema)}
  end

  test "L1: lots naming items by external id are created" do
    ctx = tenant_ctx("gh3599-l1")
    conn = lots(ctx, [l("I1", "L1", "L1"), l("I2", "L1", "L2")])
    assert conn.status == 200, conn.resp_body
    assert outcomes(conn) == ["created", "created"]

    i1 =
      Repo.one(
        from(t in "entity_catalog_item",
          where: t.external_ref_id == "I1",
          select: type(t.record_id, Ecto.UUID)
        ),
        prefix: ctx.schema
      )

    assert %{
             "item_id" => ^i1,
             "code" => "L1",
             "producer" => "Acme",
             "expiry_date" => "2027-01-31"
           } = lot(ctx, "L1")
  end

  test "L2: the same code twice for one item refuses the second row only" do
    ctx = tenant_ctx("gh3599-l2")
    conn = lots(ctx, [l("I1", "DUP", "A"), l("I1", "DUP", "B")])
    assert outcomes(conn) == ["created", "record_payload_invalid"]
    assert lot(ctx, "B") == nil
  end

  test "P1: the same file again is unchanged and writes nothing" do
    ctx = tenant_ctx("gh3599-p1")
    assert outcomes(lots(ctx, [l("I1", "L1", "L1")])) == ["created"]
    before = counts(ctx.schema)
    assert outcomes(lots(ctx, [l("I1", "L1", "L1")])) == ["unchanged"]
    assert counts(ctx.schema) == before
  end

  test "P3: changed fields update, a cleared optional cell clears the field" do
    ctx = tenant_ctx("gh3599-p3")
    assert outcomes(lots(ctx, [l("I1", "L1", "L1")])) == ["created"]
    assert outcomes(lots(ctx, [l("I1", "L1", "L1", "Other")])) == ["updated"]
    assert %{"producer" => "Other"} = lot(ctx, "L1")

    assert outcomes(lots(ctx, [["I1", "L1", nil, "mark", "2027-01-31", "erp", "L1"]])) == [
             "updated"
           ]

    refute Map.has_key?(lot(ctx, "L1"), "producer")
  end

  test "P4: a changed code or item and an active column are refused" do
    ctx = tenant_ctx("gh3599-p4")
    assert outcomes(lots(ctx, [l("I1", "L1", "L1")])) == ["created"]

    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "code"}}] =
             results(lots(ctx, [l("I1", "L9", "L1")]))

    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "item_id"}}] =
             results(lots(ctx, [l("I2", "L1", "L1")]))

    conn = lots(ctx, [l("I1", "L1", "L1") ++ [false]], @header ++ ["active"])
    assert [%{"reason" => %{"type" => "field_not_allowed", "header" => "active"}}] = results(conn)
    assert %{"code" => "L1", "active" => true} = lot(ctx, "L1")
  end

  test "F1: an unknown or inactive item names item_id and writes nothing" do
    ctx = tenant_ctx("gh3599-f1")
    before = counts(ctx.schema)

    assert [%{"reason" => %{"type" => "reference_not_found", "header" => "item_id"}}] =
             results(lots(ctx, [l("NOPE", "L1", "L1")]))

    assert counts(ctx.schema) == before
  end

  test "F2: a malformed date is refused by the reader with header expiry_date" do
    ctx = tenant_ctx("gh3599-f2")

    assert [%{"reason" => %{"type" => "csv_invalid_date", "header" => "expiry_date"}}] =
             results(lots(ctx, [l("I1", "L1", "L1", "Acme", "31.01.2027")]))

    assert lot(ctx, "L1") == nil
  end

  test "D1: a dry run answers as the real import and keeps nothing" do
    ctx = tenant_ctx("gh3599-d1")
    rows = [l("I1", "L1", "L1"), l("NOPE", "L2", "L2"), l("I2", "L3", "L3")]
    before = counts(ctx.schema)
    dry = lots(ctx, rows, @header, "&dry_run=true")
    assert dry.status == 200, dry.resp_body
    assert counts(ctx.schema) == before
    real = lots(ctx, rows)
    assert outcomes(real) == ["created", "reference_not_found", "created"]

    strip = fn conn -> Enum.map(results(conn), &Map.drop(&1, ["record_id"])) end
    assert strip.(dry) == strip.(real)
  end

  test "X1: an item that exists only in another tenant is reference_not_found" do
    a = tenant_ctx("gh3599-xa")

    only_a = %{
      "external_ref" => ref("I3"),
      "field_values" => %{
        "code" => "I3",
        "name" => "Item I3",
        "base_uom_id" => "U1",
        "kind" => "material",
        "active" => true
      }
    }

    assert json_import(a, "catalog_item", [only_a]).status == 200
    b = tenant_ctx("gh3599-xb")
    before_b = counts(b.schema)
    assert outcomes(lots(b, [l("I3", "L1", "L1")])) == ["reference_not_found"]
    assert counts(b.schema) == before_b
  end
end
