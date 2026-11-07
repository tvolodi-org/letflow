Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.DocumentsRouterTest do
  @moduledoc """
  GH #3891 / REQ-751 (assets C10): the draft side of the commission document through the full
  `Letflow.Router` with real OIDC bearer tokens. Committed tenants, Sandbox `:auto`, `async: false`.
  Tests: D1 save, D2 replace and discard, D3 shape refusals, D4 reads and exact key sets, T1 the
  access matrix (API token, scoped grant, TASK_WORKER, foreign and malformed ids), T2 the INV-10
  cross-tenant negatives, S1 the scoped caller.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Documents.DocumentType
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = D.setup!([:a, :b, :s, :n])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp reason(conn, status), do: conn |> D.status!(status) |> Map.fetch!("reason")
  defp strip(body), do: Map.delete(body, "trace_id")

  describe "D1 save" do
    test "creates a versioned draft, the header and the lines", ctx do
      doc = D.save!(ctx)
      m = ctx.ma

      assert doc["kind"] == "commission" and doc["state"] == "draft"
      assert doc["number"] == nil and doc["issued_at"] == nil
      assert doc["org_unit_id"] == m.unit and doc["location_id"] == m.location
      assert doc["material_responsible_id"] == m.employee
      assert doc["actual_user_id"] == m.employee2 and doc["note"] == "new equipment"

      assert [%{"line_no" => 1, "asset_id" => asset, "quantity" => "1.000000000"}] =
               doc["lines"]

      assert asset == m.fixed

      row = Repo.get!(Letflow.Documents.Document, doc["id"], prefix: ctx.schema)
      assert row.type_key == "assets_commission"
      assert row.issuing_org_unit_id == m.unit and row.number == nil
    end

    test "the document type is registered at install (prefix ACM, yearly, pad 6)", ctx do
      type = Repo.get!(DocumentType, "assets_commission", prefix: ctx.schema)
      assert {type.owner_module, type.number_prefix, type.number_pad} == {"assets", "ACM", 6}
      assert type.numbering_scope == :year
    end

    test "empty location and actual user are the same as absent", ctx do
      body = D.body(ctx.ma, %{"location_id" => "", "actual_user_id" => ""})
      doc = D.save!(ctx, body)
      assert doc["location_id"] == nil and doc["actual_user_id"] == nil
    end
  end

  describe "D2 replace and discard" do
    test "replace takes the whole document: a line left out is deleted", ctx do
      m = ctx.ma

      two =
        D.body(m, %{
          "lines" => [
            %{"asset_id" => m.fixed, "quantity" => "1"},
            %{"asset_id" => m.low, "quantity" => "5"}
          ]
        })

      doc = D.save!(ctx, two)
      assert length(doc["lines"]) == 2

      one =
        D.body(m, %{"note" => "changed", "lines" => [%{"asset_id" => m.low, "quantity" => "7"}]})

      one = Map.delete(one, "actual_user_id")
      replaced = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, one) |> D.status!(200)

      assert replaced["note"] == "changed" and replaced["actual_user_id"] == nil
      assert [%{"asset_id" => low, "quantity" => "7.000000000"}] = replaced["lines"]
      assert low == m.low
      assert D.get!(ctx, doc["id"]) == replaced
    end

    test "another org unit in a replace is 422 field_invalid", ctx do
      doc = D.save!(ctx)
      other = D.body(ctx.ma, %{"org_unit_id" => D.unit!(ctx.schema)})
      conn = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, other)
      body = D.status!(conn, 422)
      assert body["reason"] == "field_invalid" and body["field"] == "org_unit_id"
    end

    test "discard answers 204, then the document is 404", ctx do
      doc = D.save!(ctx)
      assert D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a) |> D.status!(204) == nil
      D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> D.status!(404)
      assert {0, _discarded} = D.written(ctx.schema)
    end
  end

  describe "D3 shape refusals" do
    test "each refusal names its reason and only field / line_no", ctx do
      m = ctx.ma
      line = %{"asset_id" => m.fixed, "quantity" => "1"}

      cases = [
        {%{"kind" => "nope"}, "unknown_kind", nil},
        {%{"tenant" => "x"}, "field_not_allowed", "tenant"},
        {%{"prefix" => "x"}, "field_not_allowed", "prefix"},
        {%{"lines" => [Map.put(line, "line_no", 3)]}, "field_not_allowed", "line_no"},
        {%{"org_unit_id" => "not-a-uuid"}, "field_invalid", "org_unit_id"},
        {%{"event_time" => "2026-11-05T10:00:00"}, "field_invalid", "event_time"},
        {%{"lines" => []}, "lines_count", nil},
        {%{"lines" => List.duplicate(line, 101)}, "lines_count", nil},
        {%{"lines" => [%{"asset_id" => m.fixed, "quantity" => 1}]}, "field_invalid", "quantity"},
        {%{"lines" => [%{"asset_id" => "x", "quantity" => "1"}]}, "field_invalid", "asset_id"}
      ]

      for {extra, want_reason, field} <- cases do
        body = D.request(:post, "/documents", ctx.tok_a, D.body(m, extra)) |> D.status!(422)
        assert body["reason"] == want_reason, inspect(extra)
        assert body["field"] == field, inspect(extra)
      end

      missing = D.body(m) |> Map.delete("material_responsible_id")
      body = D.request(:post, "/documents", ctx.tok_a, missing) |> D.status!(422)
      assert {body["reason"], body["field"]} == {"field_required", "material_responsible_id"}

      assert D.written(ctx.schema) == {0, 0}
    end
  end

  describe "D4 reads" do
    test "list newest first with a cursor, filters and the exact key sets", ctx do
      first = D.save!(ctx)
      second = D.save!(ctx)

      page = D.request(:get, "/documents?limit=1", ctx.tok_a) |> D.status!(200)
      assert Map.keys(page) |> Enum.sort() == ["next_cursor", "rows"]
      assert [row] = page["rows"]
      assert row["id"] == second["id"]

      assert Map.keys(row) |> Enum.sort() ==
               ~w(event_time id issued_at kind number org_unit_id state)

      next = D.request(:get, "/documents?limit=1&cursor=#{page["next_cursor"]}", ctx.tok_a)
      assert [%{"id" => id}] = D.status!(next, 200)["rows"]
      assert id == first["id"]

      for query <- ["state=draft", "kind=commission", "org_unit_id=#{ctx.ma.unit}"] do
        rows = D.request(:get, "/documents?" <> query, ctx.tok_a) |> D.status!(200)
        assert length(rows["rows"]) == 2, query
      end

      other = D.request(:get, "/documents?org_unit_id=#{Ecto.UUID.generate()}", ctx.tok_a)
      assert D.status!(other, 200)["rows"] == []
      issued = D.request(:get, "/documents?state=posted", ctx.tok_a) |> D.status!(200)
      assert issued["rows"] == []

      for bad <- [
            "foo=1",
            "cursor=zzz",
            "org_unit_id=nope",
            "limit=0",
            "state=weird",
            "limit=1&limit=2"
          ] do
        assert reason(D.request(:get, "/documents?" <> bad, ctx.tok_a), 422) == "invalid_filter",
               bad
      end
    end

    test "get: the exact key sets of a document and a line", ctx do
      doc = D.save!(ctx)

      assert Map.keys(doc) |> Enum.sort() ==
               ~w(actual_user_id entry_id event_time header_id id issued_at kind lines location_id material_responsible_id note number org_unit_id posted_at posted_by posting_check reversed_at reversed_by state)

      assert doc["lines"] |> hd() |> Map.keys() |> Enum.sort() ==
               ~w(asset_id line_id line_no quantity)

      # a hand-written posting field cannot be stored: no price, value or status field exists
      for key <- ~w(price value status number posted_at) do
        refute Enum.any?(
                 ["assets_commission", "assets_commission_line"],
                 fn type -> key in definition_fields(ctx.schema, type) end
               ),
               key
      end
    end
  end

  defp definition_fields(schema, type) do
    pack = Path.join(["priv", "modules", "assets", "entity_definitions", type <> ".json"])
    _ = schema
    pack |> File.read!() |> Jason.decode!() |> Map.fetch!("fields") |> Enum.map(& &1["name"])
  end

  # -- access ---------------------------------------------------------------------------------------

  defp tenant!(prefix, realm, modules) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    ExUnit.Callbacks.on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- modules do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-751"
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
      {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}},
      {:get, "/documents", nil},
      {:get, "/documents/#{id}", nil}
    ]
  end

  defp reference(ctx) do
    tenant!("ast-dn", ctx.names.n, ["org"])

    D.request(:post, "/documents", S.token(ctx, :n, ["TENANT_ADMIN"]), %{})
    |> D.status!(404)
    |> strip()
  end

  test "T1 an API token gets the 404 of a tenant without the module", ctx do
    doc = D.save!(ctx)
    before = D.written(ctx.schema)
    user = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: ctx.schema
      )

    slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
    reference = reference(ctx)

    for {method, path, body} <- routes(doc["id"], D.body(ctx.ma)) do
      conn =
        Plug.Test.conn(method, "/api/v1/modules/assets" <> path, body && Jason.encode!(body))
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-tenant-slug", slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert conn |> D.status!(404) |> strip() == reference, path
    end

    assert D.written(ctx.schema) == before
    assert D.get!(ctx, doc["id"])["state"] == "draft"
  end

  test "S1 a scoped TENANT_ADMIN cannot save, issue, reverse or read documents", ctx do
    s =
      tenant!("ast-ds", ctx.names.s, [
        "org",
        "catalog_items",
        "locations",
        "codes",
        "stock",
        "assets"
      ])

    scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-doc-writer")
    D.request(:get, "/documents", scoped)

    user =
      Repo.one!(from(u in User, where: u.username == "scoped-doc-writer"), prefix: s.schema_name)

    _ =
      RSG.raw_delete_rows!(
        s.schema_name,
        RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
        "TENANT_ADMIN"
      )

    :ok = RSG.raw_user_row!(s.schema_name, user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))

    reference = reference(ctx)
    before = D.written(s.schema_name)

    for {method, path, body} <- routes(Ecto.UUID.generate(), D.body(ctx.ma)) do
      assert D.request(method, path, scoped, body) |> D.status!(404) |> strip() == reference, path
    end

    assert D.written(s.schema_name) == before
    %{rows: [[entries]]} = Repo.query!(~s|SELECT count(*) FROM "#{s.schema_name}".ledger_entry|)
    assert entries == 0
  end

  test "T1 a TASK_WORKER is forbidden on every route and nothing is written", ctx do
    doc = D.save!(ctx)
    before = D.written(ctx.schema)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

    for {method, path, body} <- routes(doc["id"], D.body(ctx.ma)) do
      conn = D.request(method, path, tok, body)
      assert D.status!(conn, 403)["title"] == "Forbidden", path
    end

    assert D.written(ctx.schema) == before
  end

  test "T1 unknown, malformed, discarded and foreign ids give one identical 404", ctx do
    foreign = D.save!(Map.put(ctx, :tok_a, ctx.tok_b), D.body(ctx.mb))["id"]

    gone = D.save!(ctx)["id"]
    D.request(:delete, "/documents/#{gone}", ctx.tok_a) |> D.status!(204)

    bodies =
      for id <- [Ecto.UUID.generate(), "not-a-uuid", foreign, gone],
          {m, p, b} <- [
            {:get, "/documents/#{id}", nil},
            {:put, "/documents/#{id}", D.body(ctx.ma)},
            {:delete, "/documents/#{id}", nil},
            {:post, "/documents/#{id}/issue", nil},
            {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}}
          ] do
        D.request(m, p, ctx.tok_a, b) |> D.status!(404) |> strip()
      end

    assert bodies |> Enum.uniq() |> length() == 1
  end

  describe "T2 INV-10 cross-tenant negatives" do
    test "tenant B cannot read, replace, discard, issue or reverse tenant A's document", ctx do
      doc = D.save!(ctx)
      id = doc["id"]
      before = D.written(ctx.b.schema_name)

      for {m, p, b} <- [
            {:get, "/documents/#{id}", nil},
            {:put, "/documents/#{id}", D.body(ctx.mb)},
            {:delete, "/documents/#{id}", nil},
            {:post, "/documents/#{id}/issue", nil},
            {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}}
          ] do
        D.request(m, p, ctx.tok_b, b) |> D.status!(404)
      end

      assert D.get!(ctx, id) == doc
      assert D.written(ctx.b.schema_name) == before

      list = D.request(:get, "/documents?org_unit_id=#{ctx.ma.unit}", ctx.tok_b)
      assert D.status!(list, 200)["rows"] == []
      all = D.request(:get, "/documents", ctx.tok_b) |> D.status!(200)
      refute Enum.any?(all["rows"], &(&1["id"] == id))
    end

    test "a B draft naming A's card, org unit or employee is refused at issue", ctx do
      tb = Map.put(ctx, :tok_a, ctx.tok_b) |> Map.put(:schema, ctx.b.schema_name)

      foreign_card =
        D.body(ctx.mb, %{"lines" => [%{"asset_id" => ctx.ma.fixed, "quantity" => "1"}]})

      foreign_employee = D.body(ctx.mb, %{"material_responsible_id" => ctx.ma.employee})

      for {body, want} <- [
            {foreign_card, "card_not_active"},
            {foreign_employee, "employee_not_active"}
          ] do
        doc = D.save!(tb, body)
        conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_b)
        assert reason(conn, 422) == want
        assert D.get!(tb, doc["id"])["state"] == "draft"
      end

      # A's org unit does not exist in B: the draft is refused at save, nothing is written.
      before = D.written(ctx.b.schema_name)
      foreign_unit = D.body(ctx.mb, %{"org_unit_id" => ctx.ma.unit, "location_id" => ""})
      conn = D.request(:post, "/documents", ctx.tok_b, foreign_unit)
      assert reason(conn, 422) == "org_unit_invalid"
      assert D.written(ctx.b.schema_name) == before
    end
  end
end
