Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.DocumentPrintRouterTest do
  @moduledoc """
  T-1915 / GH #4443 (design tests R1..R8): `GET /documents/:id/print` of the asset module through
  the full `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Identity
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.Support.TokenMintFixture
  alias Letflow.AssetsRegisterFixture, as: S

  @moduletag timeout: 240_000

  setup do
    ctx = D.setup!([:a, :b])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp print(ctx, id, q \\ "", tok \\ nil),
    do: D.request(:get, "/documents/#{id}/print#{q}", tok || ctx.tok_a)

  defp texts(conn), do: PdfProbe.items(conn.resp_body)
  defp strip(conn), do: M.strip_conn(conn)

  defp title(kind, lang), do: DocumentPrint.labels()[:"title_#{kind}"][lang]

  # One issued document of each kind (the card is commissioned and posted first).
  defp issued_of(ctx, "commission"), do: D.issue!(ctx)

  defp issued_of(ctx, "change") do
    D.commission!(ctx)
    D.issue!(ctx, D.change_body(ctx.ma))
  end

  defp issued_of(ctx, "handover") do
    D.commission!(ctx)
    D.issue!(ctx, D.handover_body(ctx.ma, D.place!(ctx.schema)))
  end

  defp issued_of(ctx, "writeoff") do
    D.commission!(ctx)

    D.issue!(
      ctx,
      D.writeoff_body(ctx.ma, %{"reason_code" => "broken", "reason_text" => "dropped"})
    )
  end

  describe "R1 R3 R5 each kind prints" do
    for kind <- DocumentPrint.kinds() do
      test "#{kind}: 200 application/pdf, number as file name, content of the issued version",
           ctx do
        kind = unquote(kind)
        doc = issued_of(ctx, kind)
        conn = print(ctx, doc["id"], "?lang=en")
        assert conn.status == 200, "#{kind}: #{conn.resp_body}"
        assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"
        assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

        assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
                 [~s(attachment; filename="#{doc["number"]}.pdf")]

        assert "%PDF-" <> _ = conn.resp_body
        text = texts(conn)
        assert title(kind, :en) in text

        {:ok, card} = Letflow.Modules.ReadApi.lookup(ctx.schema, ctx.ma.fixed, ["assets_card"])
        assert card["inventory_number"] in text
        assert "1" in text
        assert ("Number: " <> doc["number"]) in text

        if kind == "writeoff" do
          assert "Reason: Broken" in text and "Details: dropped" in text
        end
      end
    end

    test "the default language is ru, kk and en have their own titles, bad lang is 422", ctx do
      doc = issued_of(ctx, "commission")
      assert title("commission", :ru) in texts(print(ctx, doc["id"]))
      assert title("commission", :kk) in texts(print(ctx, doc["id"], "?lang=kk"))
      assert title("commission", :en) in texts(print(ctx, doc["id"], "?lang=en"))

      for q <- ["?lang=de", "?lang[]=ru"] do
        conn = print(ctx, doc["id"], q)
        assert D.status!(conn, 422)["reason"] == "invalid_lang", q
      end
    end
  end

  describe "R2 R4 states and kinds" do
    test "a posted and a reversed document print too", ctx do
      doc = issued_of(ctx, "commission")
      assert print(ctx, doc["id"]).status == 200
      assert D.run_task!(ctx, doc["id"])["state"] == "posted"
      assert print(ctx, doc["id"]).status == 200

      D.mark_reversed!(ctx, doc["id"], "assets_commission", ctx.ma.unit)
      assert D.get!(ctx, doc["id"])["state"] == "reversed"
      assert print(ctx, doc["id"]).status == 200
    end

    test "a draft is not issued, an opening is not printable, nothing leaks as a PDF", ctx do
      draft = D.save!(ctx)
      conn = print(ctx, draft["id"])
      assert D.status!(conn, 422)["reason"] == "document_not_issued"
      refute String.starts_with?(conn.resp_body, "%PDF")

      opening = D.save!(ctx, D.opening_body(ctx.ma))
      assert D.status!(print(ctx, opening["id"]), 422)["reason"] == "print_not_available"
    end
  end

  test "R6 another tenant's id is the same 404 as an unknown or malformed id", ctx do
    doc = issued_of(ctx, "commission")
    assert print(ctx, doc["id"]).status == 200

    got = print(ctx, doc["id"], "", ctx.tok_b)
    unknown = print(ctx, Ecto.UUID.generate(), "", ctx.tok_b)
    malformed = print(ctx, "not-a-uuid", "", ctx.tok_b)
    assert got.status == 404
    refute String.starts_with?(got.resp_body, "%PDF")
    assert strip(got) == strip(unknown) and strip(got) == strip(malformed)

    # and the other way round: A's token on B's document id
    b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    doc_b = D.issue!(b)
    assert print(b, doc_b["id"]).status == 200
    back = print(ctx, doc_b["id"])
    assert back.status == 404 and strip(back) == strip(print(ctx, Ecto.UUID.generate()))
  end

  describe "R7 access" do
    test "an API token gets the answer of GET /documents/:id; a TASK_WORKER is forbidden", ctx do
      doc = issued_of(ctx, "commission")
      user = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.schema
        )

      slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      api = fn path ->
        Plug.Test.conn(:get, "/api/v1/modules/assets" <> path)
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
        |> Plug.Conn.put_req_header("x-tenant-slug", slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
      end

      read = api.("/documents/#{doc["id"]}")
      printed = api.("/documents/#{doc["id"]}/print")
      assert printed.status == read.status
      assert printed.status == 404
      assert strip(printed) == strip(read)

      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-print")
      conn = print(ctx, doc["id"], "", tok)
      assert D.status!(conn, 403)["title"] == "Forbidden"
    end
  end

  test "R8 a glyph the font lacks is 422 and no bytes", ctx do
    emp =
      OrgFixture.create!(
        ctx.schema,
        "org_employee",
        OrgFixture.values("org_employee", "ZH#{System.unique_integer([:positive])}", %{
          "org_unit_id" => ctx.ma.unit,
          "full_name" => "漢字"
        })
      ).record_id

    doc = D.issue!(ctx, D.body(ctx.ma, %{"material_responsible_id" => emp}))
    conn = print(ctx, doc["id"], "?lang=en")
    assert D.status!(conn, 422)["reason"] == "print_unsupported_character"
    refute String.starts_with?(conn.resp_body, "%PDF")
  end
end
