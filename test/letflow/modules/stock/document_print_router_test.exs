Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentPrintRouterTest do
  @moduledoc """
  REQ-737 / GH #3860 (design T-1350 tests R1..R9): `GET /documents/:id/print` through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity.User
  alias Letflow.Modules.Stock
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    Map.put(ctx, :m2, T.b2!(ctx))
  end

  defp print(ctx, id, q \\ "", tok \\ nil),
    do: D.request(:get, "/documents/#{id}/print#{q}", tok || ctx.tok_a)

  defp texts(conn), do: PdfProbe.items(conn.resp_body)
  defp strip(conn), do: conn |> S.json() |> Map.delete("trace_id")

  defp issued_two_side(ctx, kind, quantity \\ "4") do
    {from, to} = if kind == "return", do: {ctx.m2, ctx.ma}, else: {ctx.ma, ctx.m2}

    body =
      T.body(kind, ctx.ma, from, to, %{
        "lines" => [
          %{
            "catalog_item_id" => ctx.ma.item,
            "catalog_uom_id" => ctx.ma.uom,
            "quantity" => quantity
          }
        ]
      })

    {T.issue!(ctx, body), from, to}
  end

  defp employee_name(ctx, id) do
    {:ok, r} = Letflow.Modules.Org.lookup(ctx.schema, id)
    r["full_name"]
  end

  defp plain_body(ctx, kind, extra) do
    ctx.ma
    |> D.body(nil, %{
      "kind" => kind,
      "lines" => [
        %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"}
      ]
    })
    |> Map.delete("counterparty_id")
    |> Map.merge(extra)
  end

  describe "R1 issued, posted and reversed documents" do
    test "each kind answers 200 application/pdf with the number label as file name", ctx do
      for kind <- T.kinds() do
        {doc, from, to} = issued_two_side(ctx, kind)
        conn = print(ctx, doc["id"], "?lang=en")
        assert conn.status == 200, conn.resp_body
        assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"

        assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
                 [~s(attachment; filename="#{doc["number"]}.pdf")]

        assert "%PDF-" <> _ = conn.resp_body
        text = texts(conn)
        assert Stock.DocumentPrint.labels()[:"title_#{kind}"].en in text
        assert employee_name(ctx, from.employee) in text
        assert employee_name(ctx, to.employee) in text
      end
    end

    test "a posted and a reversed document print too", ctx do
      T.receive!(ctx, ctx.ma, "10")
      {doc, _from, _to} = issued_two_side(ctx, "transfer", "2")
      posted = P.post_and_complete!(ctx, doc["id"])
      assert posted["state"] == "posted"
      assert print(ctx, doc["id"]).status == 200

      P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
      |> P.status!(200)

      assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "reverse"))
      assert P.get!(ctx, doc["id"])["state"] == "reversed"
      assert print(ctx, doc["id"]).status == 200

      P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"}) |> P.status!(200)
      assert P.get!(ctx, doc["id"])["state"] == "cancelled"
      cancelled = print(ctx, doc["id"])
      assert cancelled.status == 422 and S.json(cancelled)["reason"] == "document_not_issued"
    end
  end

  describe "R2 language" do
    test "absent is ru, kk and en are accepted, anything else is 422 invalid_lang", ctx do
      {doc, _, _} = issued_two_side(ctx, "transfer")
      titles = Stock.DocumentPrint.labels().title_transfer

      assert titles.ru in texts(print(ctx, doc["id"]))
      assert titles.kk in texts(print(ctx, doc["id"], "?lang=kk"))
      assert titles.en in texts(print(ctx, doc["id"], "?lang=en"))

      for bad <- ["?lang=fr", "?lang=RU", "?lang="] do
        conn = print(ctx, doc["id"], bad)
        assert conn.status == 422
        assert S.json(conn)["reason"] == "invalid_lang"
      end
    end
  end

  describe "R3 refusals" do
    test "a draft is document_not_issued; other kinds print_not_available", ctx do
      {from, to} = {ctx.ma, ctx.m2}
      draft = T.save!(ctx, T.body("transfer", ctx.ma, from, to))
      conn = print(ctx, draft["id"])
      assert conn.status == 422 and S.json(conn)["reason"] == "document_not_issued"
      refute conn.resp_body =~ "%PDF"

      for kind <- ["receipt", "issue", "write_off"] do
        extra = if kind == "write_off", do: %{"reason_code" => "damaged"}, else: %{}
        body = plain_body(ctx, kind, extra)
        body = if kind == "receipt", do: D.body(ctx.ma), else: body
        issued = P.issue!(ctx, body)
        conn = print(ctx, issued["id"])
        assert conn.status == 422, "#{kind}: #{conn.resp_body}"
        assert S.json(conn)["reason"] == "print_not_available"
      end
    end

    test "R4 the route is declared in the module manifest" do
      assert {"GET", "/documents/:id/print", :StockRead} in Stock.manifest().route_policies
    end
  end

  describe "R5 issued content" do
    test "a change to the live line record does not reach the PDF", ctx do
      {doc, _, _} = issued_two_side(ctx, "hand_over", "5")
      first = print(ctx, doc["id"], "?lang=en")
      assert "5.000000000" in texts(first)

      type = Kinds.get("hand_over").line_type

      line =
        Repo.one!(from(l in Latest, where: l.entity_type == ^type and not l.deleted),
          prefix: ctx.schema
        )

      fv = Map.put(line.field_values, "quantity", "9")

      {:ok, _} =
        Records.update_record(
          %{
            entity_type: type,
            record_id: line.record_id,
            field_values: fv,
            actor_id: Ecto.UUID.generate(),
            idempotency_key: "docprint:" <> Ecto.UUID.generate()
          },
          ctx.schema,
          ManagedTypes.owner_for!(Stock)
        )

      second = print(ctx, doc["id"], "?lang=en")
      assert second.status == 200
      assert texts(second) == texts(first)
      refute "9.000000000" in texts(second)
    end
  end

  describe "R6..R8 isolation and permission" do
    test "another tenant's document id is the same 404 as an unknown id", ctx do
      body = D.body(ctx.mb)
      doc_b = D.request(:post, "/documents", ctx.tok_b, body) |> P.status!(201)
      unknown = Ecto.UUID.generate()

      got = print(ctx, doc_b["id"])
      want = print(ctx, unknown)
      assert got.status == 404
      assert strip(got) == strip(want)
      refute got.resp_body =~ "%PDF"
    end

    test "a scoped caller gets the same 404 as GET /documents/:id", ctx do
      {doc, _, _} = issued_two_side(ctx, "transfer")
      tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "print-scoped")
      D.request(:get, "/documents", tok) |> P.status!(200)
      user = Repo.one!(from(u in User, where: u.username == "print-scoped"), prefix: ctx.schema)
      group = RSG.group_of!(ctx.schema, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(ctx.schema, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(ctx.schema, user.id, "TENANT_ADMIN", ctx.ma.unit)

      read = D.request(:get, "/documents/#{doc["id"]}", tok)
      got = print(ctx, doc["id"], "", tok)
      refute got.resp_body =~ "%PDF"
      assert got.status == read.status
      assert got.status in [403, 404]
      assert strip(got) == strip(read)
    end

    test "a user without StockRead is 403", ctx do
      {doc, _, _} = issued_two_side(ctx, "transfer")
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "print-worker")
      assert print(ctx, doc["id"], "", worker).status == 403
    end
  end

  describe "R9 unsupported character" do
    test "a name the font lacks is 422 and no bytes", ctx do
      bad =
        Letflow.OrgFixture.create!(
          ctx.schema,
          "org_employee",
          Letflow.OrgFixture.values("org_employee", "E-GLYPH", %{
            "org_unit_id" => ctx.ma.unit,
            "full_name" => "Bob 漢字"
          })
        ).record_id

      m = %{ctx.ma | employee: bad}
      {doc, _from, _to} = issued_two_side(%{ctx | ma: m}, "transfer")
      conn = print(ctx, doc["id"], "?lang=en")
      assert conn.status == 422
      assert S.json(conn)["reason"] == "print_unsupported_character"
      refute conn.resp_body =~ "%PDF"
    end
  end
end
