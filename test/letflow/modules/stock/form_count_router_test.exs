Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Stock.FormCountRouterTest do
  @moduledoc """
  T-1418 (E5d), design tests R1..R6: `GET /counts/:id/print/:kind?form=inv18|inv10` through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`), the real
  HTTP path (D-098). `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.Entities.Records
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe
  alias Letflow.OrgFixture
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, S.base() <> path)
        b -> Plug.Test.conn(method, S.base() <> path, Jason.encode!(b))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp strip(conn), do: M.strip_conn(conn)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  defp fv(schema, id) do
    {:ok, r} = Org.lookup(schema, id)
    Map.drop(r, ["record_id", "entity_type"])
  end

  defp update!(schema, type, id, extra) do
    {:ok, _} =
      Records.update_record(
        %{
          entity_type: type,
          record_id: id,
          field_values: Map.merge(fv(schema, id), extra),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        OrgFixture.owner()
      )
  end

  # A tenant with a world; the unit has a legal entity, the chair and the member have a position.
  defp world!(ctx, name, slug \\ "form") do
    t = S.tenant!(slug, Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    member_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "member-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    status!(call(:get, "/counts", member_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    member_user = Repo.one!(from(u in User, where: u.username == ^"member-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)

    le =
      OrgFixture.create!(s, "org_legal_entity", OrgFixture.values("org_legal_entity", "LE-1")).record_id

    update!(s, "org_unit", w.unit, %{"legal_entity_id" => le})

    pos =
      OrgFixture.create!(
        s,
        "org_position",
        OrgFixture.values("org_position", "P-1", %{"org_unit_id" => w.unit, "name" => "Кладовщик"})
      ).record_id

    update!(s, "org_employee", chair, %{"position_id" => pos})
    update!(s, "org_employee", member, %{"position_id" => pos})

    w = %{w | chair: chair, members: [member]}
    %{t: t, s: s, w: w, chair_tok: chair_tok, member_tok: member_tok, le: fv(s, le)}
  end

  defp counted!(x) do
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(x.w.unit, x.w.a)})]})
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "4", %{to: S.side(x.w.unit, x.w.a1)})]})

    id = status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)["id"]
    status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)
    status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)

    for n <- 1..2 do
      body = %{"counted_quantity" => "3"}
      status!(call(:put, "/counts/#{id}/lines/#{n}/count", x.member_tok, body), 200)
    end

    status!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)
    id
  end

  # Counted, sheet signed, differences issued: both forms can be printed.
  defp ready!(x) do
    id = counted!(x)
    ids = [x.w.chair | x.w.members]
    body = %{"signer_employee_ids" => ids}
    status!(call(:post, "/counts/#{id}/sheet-signatures", x.chair_tok, body), 200)
    status!(call(:post, "/counts/#{id}/differences", x.chair_tok, %{}), 200)
    id
  end

  defp form(id, kind, form, tok, q \\ ""),
    do: call(:get, "/counts/#{id}/print/#{kind}?form=#{form}#{q}", tok)

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  describe "R1 Inv-18, R2 Inv-10: both formats, both languages" do
    test "the matrix", ctx do
      x = world!(ctx, :a)
      id = ready!(x)
      chair = fv(x.s, x.w.chair)

      cases = [
        {"inv18", "differences", "Inv-18",
         "СЛИЧИТЕЛЬНАЯ ВЕДОМОСТЬ РЕЗУЛЬТАТОВ ИНВЕНТАРИЗАЦИИ ЗАПАСОВ",
         "ҚОРЛАРДЫ ТҮГЕНДЕУ НӘТИЖЕЛЕРІНІҢ САЛЫСТЫРУ ВЕДОМОСІ", "Форма Инв-18", "Түг-18 нысаны"},
        {"inv10", "sheet", "Inv-10", "ИНВЕНТАРИЗАЦИОННАЯ ОПИСЬ ЗАПАСОВ",
         "ҚОРЛАРДЫ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ", "Форма Инв-10", "Түг-10 нысаны"}
      ]

      for {form, kind, suffix, ru, kk, ru_code, kk_code} <- cases, lang <- ["ru", "kk"] do
        # docx
        conn = form(id, kind, form, x.chair_tok, "&format=docx&lang=#{lang}")
        assert conn.status == 200, conn.resp_body
        assert header(conn, "content-type") =~ @docx

        assert header(conn, "content-disposition") =~
                 ~r/filename="C[DS]-\d{4}-\d+_#{suffix}\.docx"/

        assert {:ok, _} = :zip.unzip(conn.resp_body, [:memory])

        text = docx_text(conn)
        {title, code} = if lang == "ru", do: {ru, ru_code}, else: {kk, kk_code}

        for t <- [title, code, x.le["name"], x.le["bin"]],
            do: assert(text =~ t, "#{form} #{lang} #{t}")

        # nothing in the other language
        refute text =~ if(lang == "ru", do: kk, else: ru)

        # pdf (also the default format)
        pdf = form(id, kind, form, x.chair_tok, "&lang=#{lang}")
        assert pdf.status == 200, pdf.resp_body
        assert header(pdf, "content-type") == "application/pdf"
        assert "%PDF-" <> _ = pdf.resp_body
        assert header(pdf, "content-disposition") =~ ~r/_#{suffix}\.pdf"/
        items = PdfProbe.items(pdf.resp_body)
        assert Enum.any?(items, &(&1 =~ code)), "#{form} #{lang} pdf code"
        assert x.le["name"] in items or Enum.any?(items, &(&1 =~ x.le["name"]))
      end

      # Inv-10: the commission chair and the position of an employee from the master data
      docx = form(id, "sheet", "inv10", x.chair_tok, "&format=docx")
      text = docx_text(docx)
      assert text =~ chair["full_name"] and text =~ "Кладовщик"
      # the count lines: counted and book quantity
      assert text =~ "3.000000000"
      # Inv-18: no invented sums; the account columns stay empty
      inv18 = form(id, "differences", "inv18", x.chair_tok, "&format=docx")
      assert docx_text(inv18) =~ "Итого"
    end
  end

  describe "R3 refusals" do
    test "wrong pairing, format, language, not issued", ctx do
      x = world!(ctx, :a)
      draft = status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)["id"]
      reason = fn conn -> status!(conn, 422)["reason"] end

      assert reason.(form(draft, "differences", "inv18", x.chair_tok)) == "document_not_issued"

      id = ready!(x)
      assert reason.(form(id, "sheet", "inv18", x.chair_tok)) == "invalid_form"
      assert reason.(form(id, "differences", "inv10", x.chair_tok)) == "invalid_form"
      assert reason.(form(id, "order", "inv10", x.chair_tok)) == "invalid_form"
      assert reason.(form(id, "sheet", "inv99", x.chair_tok)) == "invalid_form"
      assert reason.(form(id, "sheet", "inv10", x.chair_tok, "&format=xlsx")) == "invalid_format"
      assert reason.(form(id, "sheet", "inv10", x.chair_tok, "&lang=en")) == "invalid_lang"
      assert form(id, "other", "inv10", x.chair_tok).status == 404
    end
  end

  describe "R4 tenancy and scope" do
    test "another tenant's count and an unseen unit are 404 as the count route", ctx do
      _a = world!(ctx, :a)
      b = world!(ctx, :b)
      id = ready!(b)
      unknown = Ecto.UUID.generate()

      got = form(id, "sheet", "inv10", ctx.tok_a)
      want = form(unknown, "sheet", "inv10", ctx.tok_a)
      assert got.status == 404
      assert strip(got) == strip(want)
      refute got.resp_body =~ "%PDF"
    end

    test "an employee of a unit the caller cannot see has no name and no position", ctx do
      t = S.tenant!("form-s", Map.fetch!(ctx.names, :s))
      s = t.schema_name
      wx = F.world!(s)
      wz = F.world!(s)
      [mx, _] = wx.members
      [mz, _] = wz.members
      S.post!(s, "receipt", %{lines: [S.line(S.uuid(), "10", %{to: S.side(wx.unit, wx.a)})]})

      pos =
        OrgFixture.create!(
          s,
          "org_position",
          OrgFixture.values("org_position", "PZ", %{
            "org_unit_id" => wz.unit,
            "name" => "Скрытая должность"
          })
        ).record_id

      update!(s, "org_employee", mz, %{"position_id" => pos})
      {:ok, ez} = Org.lookup(s, mz)

      chair_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "form-chair")
      status!(call(:get, "/counts", chair_tok), 200)
      cu = Repo.one!(from(u in User, where: u.username == "form-chair"), prefix: s)
      wx = %{wx | chair: F.employee!(s, wx.unit, user: cu.id)}

      input = F.input(wx, Map.put(window(), "member_employee_ids", [mx, mz]))
      id = status!(call(:post, "/counts", chair_tok, input), 201)["id"]
      status!(call(:post, "/counts/#{id}/issue", chair_tok, %{}), 200)
      status!(call(:post, "/counts/#{id}/open", chair_tok, %{}), 200)

      status!(
        call(:put, "/counts/#{id}/lines/1/count", chair_tok, %{"counted_quantity" => "3"}),
        200
      )

      status!(call(:post, "/counts/#{id}/close", chair_tok, %{}), 200)

      all = docx_text(form(id, "sheet", "inv10", chair_tok, "&format=docx"))
      assert all =~ ez["full_name"] and all =~ "Скрытая должность"

      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "form-scoped")
      status!(call(:get, "/counts", scoped), 200)
      user = Repo.one!(from(u in User, where: u.username == "form-scoped"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      conn = form(id, "sheet", "inv10", scoped, "&format=docx")
      assert conn.status == 200
      text = docx_text(conn)
      refute text =~ ez["full_name"]
      refute text =~ "Скрытая должность"
    end
  end

  describe "R5 row cap" do
    test "999 lines print as pdf, 1000 lines are refused for pdf and fine as docx", ctx do
      x = world!(ctx, :a)
      id = ready!(x)
      doc_ids = status!(call(:get, "/counts/#{id}", x.chair_tok), 200)

      # The issued version is immutable (guard trigger); this test tenant's own copy is rewritten
      # with disabled triggers, as audit_test.exs does for audit_entries.
      Repo.query!(~s(ALTER TABLE "#{x.s}".document_versions DISABLE TRIGGER USER))

      set_lines = fn doc_key, n ->
        doc_id = Ecto.UUID.dump!(doc_ids[doc_key])

        lines =
          for i <- 1..n do
            %{
              "line_no" => i,
              "catalog_item_id" => Ecto.UUID.generate(),
              "unit_ref" => Ecto.UUID.generate(),
              "book_quantity" => "2",
              "counted_quantity" => "3",
              "difference" => "1",
              "direction" => "surplus"
            }
          end

        %{num_rows: 1} =
          Repo.query!(
            ~s|UPDATE "#{x.s}".document_versions SET content = jsonb_set(content, '{lines}', $1::jsonb) WHERE document_id = $2 AND status = 'issued'|,
            [lines, doc_id]
          )
      end

      for {form, kind, key} <- [
            {"inv18", "differences", "differences_document_id"},
            {"inv10", "sheet", "sheet_document_id"}
          ] do
        set_lines.(key, 999)
        ok = form(id, kind, form, x.chair_tok, "&format=pdf")
        assert ok.status == 200, "#{form} 999: #{ok.resp_body}"
        assert "%PDF-" <> _ = ok.resp_body

        set_lines.(key, 1000)
        big = form(id, kind, form, x.chair_tok, "&format=pdf")
        assert status!(big, 422)["reason"] == "print_too_large"

        docx = form(id, kind, form, x.chair_tok, "&format=docx")
        assert docx.status == 200
      end
    end
  end

  describe "R6 the E1a print is unchanged" do
    test "no form parameter still answers the PDF, lang en included", ctx do
      x = world!(ctx, :a)
      id = ready!(x)
      conn = call(:get, "/counts/#{id}/print/differences?lang=en", x.chair_tok)
      assert conn.status == 200
      assert "%PDF-" <> _ = conn.resp_body
      assert header(conn, "content-disposition") =~ ~r/filename="CD-\d{4}-\d+\.pdf"/

      assert status!(call(:get, "/counts/#{id}/print/differences?lang=de", x.chair_tok), 422)[
               "reason"
             ] == "invalid_lang"
    end
  end
end
