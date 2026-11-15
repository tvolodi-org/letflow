Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountPrintRouterTest do
  @moduledoc """
  T-1932 (REQ-821, asset count K6) design tests R1..R6: `GET /counts/:id/print/sheet` through the full
  `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`). R1/R2/R3 the
  official form Inv-8, R4 the plain sheet, R5 tenant B on tenant A's count, R6 the flag and the
  permission. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @moduletag timeout: 300_000
  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    ctx = D.setup!([:a, :b, :n])
    n = S.tenant!("ast-ck6n", ctx.names.n, install: false)
    F.enable!(ctx.schema)
    b = D.tenant_b!(ctx)
    F.enable!(b.b.schema_name)
    ctx = Map.merge(ctx, Map.merge(b, %{n: n, tok_n: S.token(ctx, :n, ["TENANT_ADMIN"])}))
    {:ok, Map.put(ctx, :sw, F.sheet_world!(ctx.schema, ctx.ma))}
  end

  defp strip(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{} = map} -> Map.delete(map, "trace_id")
      _ -> conn.resp_body
    end
  end

  defp print(id, q, tok), do: D.request(:get, "/counts/#{id}/print/sheet#{q}", tok)
  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()
  defp reason(conn, status), do: D.status!(conn, status)["reason"]

  defp docx_text(conn) do
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  # A real count flow: two fixed cards, one found and one not, a surplus line with a description.
  defp closed!(ctx) do
    w = F.world7!(ctx)
    w.id
  end

  describe "the official form Inv-8" do
    test "R1: ru and kk, pdf and docx answer 200 with the right type", ctx do
      id = closed!(ctx)

      for lang <- ["ru", "kk"], format <- ["pdf", "docx"] do
        conn = print(id, "?form=inv8&format=#{format}&lang=#{lang}", ctx.tok_a)
        assert conn.status == 200, "#{lang} #{format}"

        if format == "pdf" do
          assert header(conn, "content-type") =~ "application/pdf"
          assert binary_part(conn.resp_body, 0, 4) == "%PDF"
        else
          assert header(conn, "content-type") =~ @docx
          assert binary_part(conn.resp_body, 0, 2) == "PK"
        end

        assert header(conn, "content-disposition") =~ "_Inv-8.#{format}"
      end

      kk = print(id, "?form=inv8&format=docx&lang=kk", ctx.tok_a)
      assert docx_text(kk) =~ "ҰЗАҚ МЕРЗІМДІ АКТИВТЕРДІ ТҮГЕНДЕУ ТІЗІМДЕМЕСІ"
      ru = print(id, "?form=inv8&format=docx&lang=ru", ctx.tok_a)
      assert docx_text(ru) =~ "ИНВЕНТАРИЗАЦИОННАЯ ОПИСЬ ДОЛГОСРОЧНЫХ АКТИВОВ"
      assert docx_text(ru) =~ "unknown chair"
    end

    test "R2: a bad form, format or language is refused before any read", ctx do
      id = closed!(ctx)
      assert reason(print(id, "?form=inv8&lang=en", ctx.tok_a), 422) == "invalid_lang"
      assert reason(print(id, "?form=inv9", ctx.tok_a), 422) == "invalid_form"
      assert reason(print(id, "?form=inv8&format=xlsx", ctx.tok_a), 422) == "invalid_format"

      # the refusal does not depend on the id: an unknown id gets the same answer
      unknown = print(Ecto.UUID.generate(), "?form=inv9", ctx.tok_a)
      assert reason(unknown, 422) == "invalid_form"
    end

    test "R3: a count that is not closed has no sheet to print", ctx do
      id = F.ordered!(ctx)
      assert reason(print(id, "?form=inv8", ctx.tok_a), 422) == "document_not_issued"
      assert reason(print(id, "", ctx.tok_a), 422) == "document_not_issued"
    end
  end

  describe "the plain sheet" do
    test "R4: ru, kk, en and the default answer a PDF; another language is refused", ctx do
      id = closed!(ctx)

      for q <- ["", "?lang=ru", "?lang=kk", "?lang=en", "?format=docx"] do
        conn = print(id, q, ctx.tok_a)
        assert conn.status == 200, q
        assert header(conn, "content-type") =~ "application/pdf"
        assert binary_part(conn.resp_body, 0, 4) == "%PDF"
      end

      en = print(id, "?lang=en", ctx.tok_a)
      assert Enum.any?(PdfProbe.items(en.resp_body), &(&1 =~ "Asset count sheet"))
      assert reason(print(id, "?lang=de", ctx.tok_a), 422) == "invalid_lang"
    end
  end

  describe "isolation" do
    test "R5: tenant B gets the 404 of an unknown id on tenant A's count", ctx do
      id = closed!(ctx)

      for q <- ["", "?form=inv8&format=pdf&lang=ru"] do
        unknown = print(Ecto.UUID.generate(), q, ctx.tok_b)
        foreign = print(id, q, ctx.tok_b)
        assert unknown.status == 404 and foreign.status == 404, q
        assert strip(foreign) == strip(unknown), q
      end

      assert print(id, "", ctx.tok_a).status == 200
    end

    test "R6: flag off is the 404 of a tenant without the module; a worker is 403", ctx do
      id = closed!(ctx)
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-k6")
      F.disable!(ctx.schema)

      mine = print(id, "", ctx.tok_a)
      theirs = print(id, "", ctx.tok_n)
      assert mine.status == 404 and theirs.status == 404
      assert strip(mine) == strip(theirs)
      assert print(id, "?form=inv8", ctx.tok_a).status == 404
      assert print(id, "", worker).status == 403
    end
  end
end
