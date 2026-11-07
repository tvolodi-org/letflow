Code.require_file("kind_change_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindChangeTest do
  @moduledoc """
  GH #3902 / REQ-759 (assets C15 part 2), criterion 2 and the access rows of criterion 5: D1 save of a
  `kind_change` draft through the real `Letflow.Router` with an OIDC bearer, D2 server-set and invalid
  fields, D3 replace and discard, D4 the pure `Shape` rows, T1 the API token, scoped grant and
  TASK_WORKER answers, T2 the cross-tenant negatives. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.KindChangeFixture, as: K
  alias Letflow.Modules.Assets.Documents.Shape
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @chain ["org", "catalog_items", "locations", "codes", "stock", "assets"]

  setup do
    ctx = D.setup!([:a, :b, :s, :n])
    ctx = Map.put(ctx, :ka, K.masters!(ctx.schema))
    b = D.tenant_b!(ctx)
    {:ok, ctx |> Map.merge(b) |> Map.put(:kb, K.masters!(b.b.schema_name))}
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  defp save!(ctx, body \\ nil), do: D.save!(ctx, body || K.body(ctx.ka))

  describe "D1 save" do
    test "creates the draft; the asset org unit defaults to the header unit; card id is null",
         ctx do
      m = ctx.ka
      doc = save!(ctx)

      assert doc["kind"] == "kind_change" and doc["state"] == "draft"
      assert doc["number"] == nil and doc["org_unit_id"] == m.unit
      assert doc["reason_text"] == "moved from stock" and doc["note"] == nil

      assert [line] = doc["lines"]
      assert line["line_no"] == 1 and line["quantity"] == "20.000000000"
      assert line["asset_org_unit_id"] == m.unit and line["asset_card_id"] == nil
      assert line["catalog_item_id"] == m.item and line["target_kind"] == "low_value"
      assert line["catalog_lot_id"] == nil and line["actual_user_id"] == nil

      assert D.get!(ctx, doc["id"]) == doc

      row = Repo.get!(Letflow.Documents.Document, doc["id"], prefix: ctx.schema)
      assert row.type_key == "assets_kind_change" and row.issuing_org_unit_id == m.unit

      listed = D.request(:get, "/documents?kind=kind_change", ctx.tok_a) |> D.status!(200)
      assert Enum.map(listed["rows"], & &1["id"]) == [doc["id"]]
    end

    test "the document type is registered at install", ctx do
      type = Repo.get!(Letflow.Documents.DocumentType, "assets_kind_change", prefix: ctx.schema)
      assert {type.owner_module, type.number_prefix, type.number_pad} == {"assets", "AKC", 6}
    end
  end

  describe "D2 refusals" do
    test "server-set keys are field_not_allowed, an unknown target kind is field_invalid", ctx do
      m = ctx.ka

      cases = [
        {K.body(m, %{}, [K.line(m, %{"asset_card_id" => Ecto.UUID.generate()})]),
         {"field_not_allowed", "asset_card_id", 1}},
        {K.body(m, %{"asset_card_id" => Ecto.UUID.generate()}),
         {"field_not_allowed", "asset_card_id", nil}},
        {K.body(m, %{}, [K.line(m, %{"header_id" => Ecto.UUID.generate()})]),
         {"field_not_allowed", "header_id", 1}},
        {K.body(m, %{}, [K.line(m, %{"line_no" => 3})]), {"field_not_allowed", "line_no", 1}},
        {K.body(m, %{}, [K.line(m, %{"target_kind" => "intangible"})]),
         {"field_invalid", "target_kind", 1}},
        {K.body(m, %{}, [K.line(m, %{"inventory_number" => nil})]),
         {"field_required", "inventory_number", 1}}
      ]

      before = K.written(ctx.schema)

      for {body, {reason, field, line_no}} <- cases do
        resp = D.request(:post, "/documents", ctx.tok_a, body) |> D.status!(422)
        assert {resp["reason"], resp["field"], resp["line_no"]} == {reason, field, line_no}
      end

      assert K.written(ctx.schema) == before
    end
  end

  describe "D3 replace and discard" do
    test "replace is whole-document; a line left out is deleted; the org unit cannot change",
         ctx do
      m = ctx.ka
      doc = save!(ctx, K.body(m, %{}, [K.line(m), K.line(m)]))
      assert length(doc["lines"]) == 2

      body = K.body(m, %{"reason_text" => "changed"}, [K.line(m, %{"asset_name" => "Desk"})])
      replaced = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, body) |> D.status!(200)
      assert replaced["reason_text"] == "changed"
      assert [%{"asset_name" => "Desk", "line_no" => 1}] = replaced["lines"]

      other = K.body(m, %{"org_unit_id" => m.other_unit})
      resp = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, other) |> D.status!(422)
      assert {resp["reason"], resp["field"]} == {"field_invalid", "org_unit_id"}
    end

    test "discard answers 204 and the document is gone", ctx do
      {records, _documents} = K.written(ctx.schema)
      doc = save!(ctx)
      assert elem(K.written(ctx.schema), 0) == records + 2
      D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a) |> D.status!(204)
      D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> D.status!(404)
      assert {^records, _} = K.written(ctx.schema)
    end
  end

  describe "D4 Shape (pure)" do
    @u1 "11111111-1111-4111-8111-111111111111"
    @u2 "22222222-2222-4222-8222-222222222222"

    defp shape_body(line_extra, header_extra \\ %{}) do
      line =
        Map.merge(
          %{
            "catalog_item_id" => @u1,
            "catalog_uom_id" => @u1,
            "quantity" => "1.5",
            "stock_location_id" => @u1,
            "stock_responsible_id" => @u1,
            "target_kind" => "fixed",
            "asset_location_id" => @u1,
            "material_responsible_id" => @u1,
            "inventory_number" => "  INV-1  ",
            "asset_name" => "Name"
          },
          line_extra
        )

      Map.merge(
        %{
          "kind" => "kind_change",
          "org_unit_id" => @u2,
          "event_time" => "2026-11-07T10:00:00Z",
          "lines" => [line]
        },
        header_extra
      )
    end

    test "defaults, trimming and dropped empty optional ids" do
      body = shape_body(%{"catalog_lot_id" => "", "actual_user_id" => ""})
      assert {:ok, %{kind: "kind_change", lines: [line]}} = Shape.parse(body, :create)
      assert line["asset_org_unit_id"] == @u2 and line["inventory_number"] == "INV-1"
      assert line["quantity"] == "1.500000000" and line["line_no"] == 1
      refute Map.has_key?(line, "catalog_lot_id") or Map.has_key?(line, "actual_user_id")

      given = shape_body(%{"asset_org_unit_id" => @u1})
      assert {:ok, %{lines: [%{"asset_org_unit_id" => @u1}]}} = Shape.parse(given, :create)
    end

    test "line count, bad ids, quantity and the byte caps" do
      many = shape_body(%{}) |> Map.update!("lines", &List.duplicate(hd(&1), 101))
      assert Shape.parse(many, :create) == {:error, {"lines_count", %{}}}

      for {extra, field} <- [
            {%{"catalog_item_id" => "nope"}, "catalog_item_id"},
            {%{"quantity" => "1e3"}, "quantity"},
            {%{"quantity" => 5}, "quantity"},
            {%{"inventory_number" => String.duplicate("x", 65)}, "inventory_number"},
            {%{"inventory_number" => "   "}, "inventory_number"},
            {%{"asset_name" => String.duplicate("я", 101)}, "asset_name"},
            {%{"asset_name" => 7}, "asset_name"}
          ] do
        assert Shape.parse(shape_body(extra), :create) ==
                 {:error, {"field_invalid", %{"field" => field, "line_no" => 1}}},
               inspect(extra)
      end

      ok = shape_body(%{"inventory_number" => String.duplicate("x", 64)})
      assert {:ok, _} = Shape.parse(ok, :create)
    end
  end

  # -- access (criterion 5) ---------------------------------------------------------------------

  defp tenant!(prefix, realm, modules) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- modules do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-759"
        )
    end

    t
  end

  defp routes(id, body) do
    [
      {:post, "/documents", body},
      {:put, "/documents/#{id}", body},
      {:delete, "/documents/#{id}", nil},
      {:post, "/documents/#{id}/issue", nil},
      {:get, "/documents/#{id}", nil}
    ]
  end

  defp reference(ctx) do
    tenant!("ast-kn", ctx.names.n, ["org"])

    D.request(:post, "/documents", S.token(ctx, :n, ["TENANT_ADMIN"]), %{})
    |> D.status!(404)
    |> strip()
  end

  test "T1 an API token and a scoped grant get the 404 of a tenant without the module", ctx do
    doc = save!(ctx)
    before = K.written(ctx.schema)
    user = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: ctx.schema
      )

    slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
    reference = reference(ctx)

    for {method, path, body} <- routes(doc["id"], K.body(ctx.ka)) do
      conn =
        Plug.Test.conn(method, "/api/v1/modules/assets" <> path, body && Jason.encode!(body))
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-tenant-slug", slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert conn |> D.status!(404) |> strip() == reference, path
    end

    s = tenant!("ast-ks", ctx.names.s, @chain)
    scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-kc-writer")
    D.request(:get, "/documents", scoped)

    scoped_user =
      Repo.one!(from(u in User, where: u.username == "scoped-kc-writer"), prefix: s.schema_name)

    _ =
      RSG.raw_delete_rows!(
        s.schema_name,
        RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
        "TENANT_ADMIN"
      )

    :ok =
      RSG.raw_user_row!(s.schema_name, scoped_user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))

    scoped_before = K.written(s.schema_name)

    for {method, path, body} <- routes(Ecto.UUID.generate(), K.body(ctx.ka)) do
      assert D.request(method, path, scoped, body) |> D.status!(404) |> strip() == reference, path
    end

    assert K.written(ctx.schema) == before
    assert K.written(s.schema_name) == scoped_before
  end

  test "T2 a TASK_WORKER is forbidden on create and issue and nothing is written", ctx do
    doc = save!(ctx)
    before = K.written(ctx.schema)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-kc")

    for {method, path, body} <- routes(doc["id"], K.body(ctx.ka)) do
      conn = D.request(method, path, tok, body)
      assert D.status!(conn, 403)["title"] == "Forbidden", path
    end

    assert K.written(ctx.schema) == before
    assert D.get!(ctx, doc["id"])["state"] == "draft"
  end

  test "T3 tenant B cannot touch A's document, and B's draft naming A's masters is refused",
       ctx do
    doc = save!(ctx)
    id = doc["id"]
    before = K.written(ctx.b.schema_name)

    for {m, p, b} <- [
          {:get, "/documents/#{id}", nil},
          {:put, "/documents/#{id}", K.body(ctx.kb)},
          {:delete, "/documents/#{id}", nil},
          {:post, "/documents/#{id}/issue", nil},
          {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}}
        ] do
      D.request(m, p, ctx.tok_b, b) |> D.status!(404)
    end

    assert D.get!(ctx, id) == doc
    assert K.written(ctx.b.schema_name) == before

    tb = ctx |> Map.put(:tok_a, ctx.tok_b) |> Map.put(:schema, ctx.b.schema_name)
    kb = ctx.kb

    for {extra, want, field} <- [
          {%{"catalog_item_id" => ctx.ka.item}, "item_not_active", nil},
          {%{"stock_location_id" => ctx.ka.location}, "location_not_active", "stock_location_id"},
          {%{"asset_org_unit_id" => ctx.ka.unit}, "org_unit_not_active", "asset_org_unit_id"}
        ] do
      draft = D.save!(tb, K.body(kb, %{}, [K.line(kb, extra)]))
      resp = D.request(:post, "/documents/#{draft["id"]}/issue", ctx.tok_b) |> D.status!(422)
      assert resp["reason"] == want and resp["field"] == field and resp["line_no"] == 1
      assert D.get!(tb, draft["id"])["state"] == "draft"
    end
  end
end
