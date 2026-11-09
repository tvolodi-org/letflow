Code.require_file("../modules/locations/locations_fixture.exs", __DIR__)

defmodule Letflow.Routers.EntitiesImportAtomicTest do
  @moduledoc """
  Import error report (BA batch 2 item 4): `atomic=true` never half-applies a managed upsert
  import, the refusal names the column, and a refused xlsx header names the offending headers.
  Real router, real API-token bearer, the real `locations` module (`location_node`), so
  `async: false`.

    * T-A1/T-A3: one refused row, nothing is written, `applied: false`, every row is reported
    * T-D1: fix the bad row, upload again: all created, `applied: true`; again: all unchanged
    * T-A6/T-A7: `atomic` on a non-managed type / a bad value is 422; absent = partial success
    * T-A10: a clean file is committed
    * T-C1b: `cycle`, `parent_inactive` render `header: parent_id`; T-C1d row-wide stay bare
    * T-B1..B3: the 422 of a wrong xlsx header carries the offending names, detail unchanged
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture, as: Fx
  alias Letflow.Modules.Locations
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ["code", "name", "node_kind", "parent_id", "external_ref_system", "external_ref_id"]

  defp tenant_ctx(prefix) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "atomic-user-#{Ecto.UUID.generate()}",
        display_name: "atomic test user",
        email: "atomic-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    %{tenant_id: tenant_id, schema: schema, slug: slug, plaintext: plaintext, actor: user.id}
  end

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp post_xlsx(ctx, type, bytes, query) do
    conn(:post, "/api/v1/entities/records/#{type}/import" <> query, bytes)
    |> put_req_header("content-type", @xlsx)
    |> authed(ctx)
  end

  defp import_xlsx(ctx, rows, query \\ "?upsert_by=external_ref") do
    post_xlsx(ctx, "location_node", XlsxFixture.build([[@header | rows]]), query)
  end

  defp r(code, name, parent, id, kind \\ "zone"), do: [code, name, kind, parent, "erp", id]

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp results(conn), do: body(conn)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp node_count(ctx), do: Repo.aggregate(Latest, :count, prefix: ctx.schema)

  defp event_count(ctx),
    do: Repo.aggregate(from(e in "events", select: e.id), :count, prefix: ctx.schema)

  defp good_rows, do: [r("W", "Warehouse", "", "W"), r("A", "Aisle", "W", "A")]
  # a parent that does not exist: refused with reference_not_found / parent_id
  defp bad_row, do: r("X", "Broken", "NOPE", "X")

  @atomic "?upsert_by=external_ref&atomic=true"

  describe "atomic import" do
    test "T-A1/T-A3: one refused row writes nothing and every row is reported" do
      ctx = tenant_ctx("atomic-a1")
      {nodes, events} = {node_count(ctx), event_count(ctx)}

      conn = import_xlsx(ctx, good_rows() ++ [bad_row()], @atomic)
      assert conn.status == 200, conn.resp_body
      assert body(conn)["applied"] == false
      assert outcomes(conn) == ["created", "created", "reference_not_found"]
      assert Enum.at(results(conn), 2)["reason"]["header"] == "parent_id"
      assert {node_count(ctx), event_count(ctx)} == {nodes, events}
    end

    test "T-D1/T-A10: fix the bad row, upload again: committed; again: unchanged" do
      ctx = tenant_ctx("atomic-d1")
      assert body(import_xlsx(ctx, good_rows() ++ [bad_row()], @atomic))["applied"] == false

      fixed = good_rows() ++ [r("X", "Fixed", "W", "X")]
      conn = import_xlsx(ctx, fixed, @atomic)
      assert body(conn)["applied"] == true
      assert outcomes(conn) == ["created", "created", "created"]
      assert node_count(ctx) == 3

      again = import_xlsx(ctx, fixed, @atomic)
      assert body(again)["applied"] == true
      assert outcomes(again) == ["unchanged", "unchanged", "unchanged"]
      assert node_count(ctx) == 3
    end

    test "T-A7: without atomic the good rows are written and there is no applied member" do
      ctx = tenant_ctx("atomic-a7")
      conn = import_xlsx(ctx, good_rows() ++ [bad_row()])
      assert outcomes(conn) == ["created", "created", "reference_not_found"]
      refute Map.has_key?(body(conn), "applied")
      assert node_count(ctx) == 2
    end

    test "T-A7b: atomic=false is today's partial success" do
      ctx = tenant_ctx("atomic-a7b")
      conn = import_xlsx(ctx, good_rows() ++ [bad_row()], "?upsert_by=external_ref&atomic=false")
      assert node_count(ctx) == 2
      refute Map.has_key?(body(conn), "applied")
    end

    test "T-A6: a bad atomic value is 422, nothing written (non-managed type: catalog_items T-A6)" do
      ctx = tenant_ctx("atomic-a6")
      bad = import_xlsx(ctx, good_rows(), "?upsert_by=external_ref&atomic=maybe")
      assert bad.status == 422
      assert bad.resp_body =~ "atomic must be true or false"
      assert node_count(ctx) == 0
    end

    test "atomic with dry_run=true is a dry run: nothing written" do
      ctx = tenant_ctx("atomic-dry")
      conn = import_xlsx(ctx, good_rows(), @atomic <> "&dry_run=true")
      assert body(conn)["dry_run"] == true
      assert body(conn)["applied"] == false
      assert node_count(ctx) == 0
    end

    test "T-A9: the same file under another tenant does not touch this tenant" do
      a = tenant_ctx("atomic-x-a")
      b = tenant_ctx("atomic-x-b")
      assert body(import_xlsx(a, good_rows(), @atomic))["applied"] == true
      assert node_count(a) == 2
      assert node_count(b) == 0
    end
  end

  describe "the column of a refusal" do
    test "T-C1b: cycle and parent_inactive name parent_id" do
      ctx = tenant_ctx("atomic-c1b")
      tree = good_rows() ++ [r("S", "Shelf", "A", "S")]
      assert import_xlsx(ctx, tree).status == 200

      cycle = import_xlsx(ctx, [r("W", "Warehouse", "S", "W")])

      assert [%{"reason" => %{"type" => "cycle", "header" => "parent_id"}, "line" => 2}] =
               results(cycle)

      lookup = fn id ->
        Repo.one(
          from(t in "entity_location_node",
            where: t.external_ref_system == "erp" and t.external_ref_id == ^id,
            select: type(t.record_id, Ecto.UUID)
          ),
          prefix: ctx.schema
        )
      end

      opts = %{actor_id: ctx.actor, idempotency_key: Ecto.UUID.generate()}
      {:ok, _} = Locations.retire_node(ctx.schema, lookup.("S"), opts)
      opts = %{opts | idempotency_key: Ecto.UUID.generate()}
      {:ok, _} = Locations.retire_node(ctx.schema, lookup.("A"), opts)

      inactive = import_xlsx(ctx, [r("N", "New", "A", "N")])

      assert [%{"reason" => %{"type" => "parent_inactive", "header" => "parent_id"}}] =
               results(inactive)
    end

    test "T-C1b2: every constant reason of the scoped imports names its column" do
      render = &Letflow.Routers.Entities.RecordImport.import_reason_json/1

      for {reason, column} <- [
            {:org_unit_mismatch, "org_unit_id"},
            {:quantity_invalid, "quantity"},
            {{:price_invalid, "unit_price"}, "unit_price"},
            {{:price_invalid, "line_value"}, "line_value"},
            {:asset_inventory_number_taken, "inventory_number"},
            {:asset_inventory_number_locked, "inventory_number"},
            {:asset_kind_invalid, "kind"},
            {:asset_kind_locked, "kind"},
            {:asset_currency_mismatch, "currency"},
            {:asset_valid_until_not_allowed, "valid_until"},
            {:external_ref_invalid, "external_ref_id"},
            {:duplicate_external_ref_in_request, "external_ref_id"}
          ] do
        assert %{"header" => ^column} = render.(reason), inspect(reason)
      end
    end

    test "T-C1d: row-wide refusals stay without a column" do
      render = &Letflow.Routers.Entities.RecordImport.import_reason_json/1

      for reason <- [
            :node_not_found,
            :document_not_draft,
            :lines_count,
            :asset_row_invalid,
            :card_inactive,
            :price_invalid
          ] do
        refute Map.has_key?(render.(reason), "header"), inspect(reason)
      end
    end
  end

  describe "a wrong xlsx header names the column" do
    defp header_error(ctx, header, query \\ "?upsert_by=external_ref") do
      conn = post_xlsx(ctx, "location_node", XlsxFixture.build([[header, ["x"]]]), query)
      assert conn.status == 422, conn.resp_body
      conn
    end

    test "T-B1: unknown header: detail unchanged, headers listed" do
      ctx = tenant_ctx("atomic-b1")
      conn = header_error(ctx, ["code", "Inv no"])
      assert conn.resp_body =~ "xlsx header has a column that is not a field of the entity type"
      assert body(conn)["headers"] == ["Inv no"]
      assert body(conn)["code"] == "xlsx_unknown_header"
    end

    test "T-B2: duplicate header lists the repeated name" do
      ctx = tenant_ctx("atomic-b2")
      conn = header_error(ctx, ["code", "name", "code"])
      assert conn.resp_body =~ "xlsx header has a duplicate column"
      assert body(conn)["headers"] == ["code"]
    end

    test "T-B3: at most 5 names, cut at 40 characters, control characters removed" do
      ctx = tenant_ctx("atomic-b3")
      long = String.duplicate("a", 60)
      names = ["bad1\u0007", "bad2", "bad3", "bad4", "bad5", "bad6", long]
      conn = header_error(ctx, ["code" | names])
      headers = body(conn)["headers"]
      assert length(headers) == 5
      assert hd(headers) == "bad1"
      long_conn = header_error(ctx, ["code", long])
      assert body(long_conn)["headers"] == [String.duplicate("a", 40)]
    end

    test "the external ref pair names the missing column" do
      ctx = tenant_ctx("atomic-b4")
      conn = header_error(ctx, ["code", "external_ref_system"])
      assert body(conn)["headers"] == ["external_ref_id"]
    end
  end
end
