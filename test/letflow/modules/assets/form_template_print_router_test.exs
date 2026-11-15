Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Modules.Assets.FormTemplatePrintRouterTest do
  @moduledoc """
  T-1985 (0089 S3), design tests A1-A2: `GET /cards/:id/print?form=da2` prints from the company's
  active template, and refuses an outdated one, through the full `Letflow.Router`. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.CompanyTemplateFixture, as: C

  @moduletag timeout: 240_000

  setup do
    D.setup!([:a])
    |> then(&{:ok, &1})
  end

  defp card!(ctx) do
    card =
      D.card!(ctx.schema, "fixed", ctx.ma.unit, %{
        "currency" => "KZT",
        "acquisition_date" => "2026-03-01",
        "acquisition_cost" => "1200000.000000000",
        "accumulated_depreciation" => "49360.500000000",
        "book_value" => "1150639.500000000"
      })

    ctx = %{ctx | ma: %{ctx.ma | fixed: card}}
    D.commission!(ctx)
    card
  end

  defp print(ctx, id, q), do: D.request(:get, "/cards/#{id}/print?#{q}", ctx.tok_a)

  test "A1 an active da2 template is printed", ctx do
    C.active!(ctx.schema, "da2", "ru")
    conn = print(ctx, card!(ctx), "form=da2&format=docx&lang=ru")
    assert conn.status == 200, conn.resp_body
    {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    assert xml =~ C.marker()
  end

  test "A2 an outdated da2 template answers 422; the PDF still prints", ctx do
    C.outdated!(ctx.schema, ctx.a.tenant_id, "da2", "default")
    card = card!(ctx)
    conn = print(ctx, card, "form=da2&format=docx&lang=kk")
    assert conn.status == 422, conn.resp_body
    assert Jason.decode!(conn.resp_body)["reason"] == "form_template_outdated"
    refute conn.resp_body =~ "SKIN"
    assert print(ctx, card, "form=da2&format=pdf&lang=kk").status == 200
  end
end
