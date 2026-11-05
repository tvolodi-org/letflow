Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.MovementsDocumentNumberTest do
  @moduledoc """
  GH #3735 R7 (M-1, A-2): the movements read carries `document_number` for a numbered stock document, and
  the posted document carries `posted_by_label` (a person name, not the id). Real router, real token.
  Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Stock.DocumentNumbers
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  setup do
    P.setup!([:a, :b])
  end

  test "M-1 a posted receipt: the movement row carries its number, RCP-<year>-<padded>", ctx do
    doc = P.issue!(ctx)
    posted = P.post_and_complete!(ctx, doc["id"])

    [row | _] = P.movements(ctx, doc["id"])
    assert row["document_id"] == doc["id"]
    assert row["document_number"] == posted["number"]
    assert row["document_number"] == "RCP-#{Date.utc_today().year}-000001"
  end

  test "A-2 the posted document names who posted it, and the id stays", ctx do
    doc = P.issue!(ctx)
    posted = P.post_and_complete!(ctx, doc["id"])

    assert posted["posted_by"] == ctx.holder.id
    assert posted["posted_by_label"] == "GH2552 Role Holder"
    assert posted["reversed_by"] == nil and posted["reversed_by_label"] == nil
  end

  test "M-1 a non-uuid id and an unknown uuid give nil; the list read still works", ctx do
    assert DocumentNumbers.for_ids(ctx.schema, ["doc-1", Ecto.UUID.generate(), nil, 7]) == %{}

    assert [%{document_number: nil}] =
             DocumentNumbers.put_numbers(ctx.schema, [%{document_id: "count.differences"}])

    assert %{"rows" => _} = S.get("/movements", ctx.tok_a) |> P.status!(200)
  end

  test "M-1 a document of another tenant gets no number (INV-1)", ctx do
    doc = P.issue!(ctx)
    P.post_and_complete!(ctx, doc["id"])
    other = P.tenant_b!(ctx)

    assert DocumentNumbers.for_ids(other.b.schema_name, [doc["id"]]) == %{}
    assert %{} != DocumentNumbers.for_ids(ctx.schema, [doc["id"]])
  end

  test "M-1 the xlsx export of movements still builds", ctx do
    doc = P.issue!(ctx)
    P.post_and_complete!(ctx, doc["id"])
    conn = S.get("/movements?format=xlsx", ctx.tok_a)
    assert conn.status == 200
  end
end
