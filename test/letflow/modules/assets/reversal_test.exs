Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.ReversalTest do
  @moduledoc """
  GH #3890 / REQ-752 (assets C10): the reversal of a posted commission through the real HTTP path
  (V1): `POST /documents/:id/reverse` starts `assets_reversal`, its `reverse` task is claimed and
  completed through the tasks routes, the reversal entry negates the commission entry, the document
  reads `reversed` and the balance is zero. Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S

  setup do
    D.setup!()
  end

  defp reverse(ctx, id, body), do: D.request(:post, "/documents/#{id}/reverse", ctx.tok_a, body)
  defp reason(conn, status), do: conn |> D.status!(status) |> Map.fetch!("reason")

  defp posted!(ctx, body \\ nil) do
    doc = D.issue!(ctx, body)
    D.run_task!(ctx, doc["id"])
  end

  test "V1 reverse over HTTP: entry negated, mark reversed, state reversed, balance zero", ctx do
    m = ctx.ma
    posted = posted!(ctx)
    id = posted["id"]
    before = D.status!(S.get("/balances", ctx.tok_a), 200)
    assert [%{"quantity" => q}] = Enum.filter(before["rows"], &(&1["asset"] == m.fixed))
    assert Decimal.equal?(Decimal.new(q), 1)

    started = reverse(ctx, id, %{"reason_code" => "wrong_document"}) |> D.status!(200)
    assert started["state"] == "posted"

    # a second request while the reversal task is pending
    assert reason(reverse(ctx, id, %{"reason_code" => "wrong_document"}), 409) ==
             "reversal_pending"

    reversed = D.run_task!(ctx, id, "reverse")
    assert reversed["state"] == "reversed" and reversed["posting_check"] == "ok"
    assert is_binary(reversed["reversed_at"]) and is_binary(reversed["reversed_by"])
    assert reversed["entry_id"] == posted["entry_id"]
    assert D.counts(ctx, id) == %{entries: %{"commission" => 1, "reversal" => 1}, marks: 2}

    entries = D.movements(ctx, id)
    reversal = Enum.find(entries, &(&1["cause"] == "reversal"))
    assert reversal["reverses_entry_id"] == posted["entry_id"]
    assert reversal["reason_code"] == "wrong_document"
    assert [leg] = reversal["legs"]
    assert Decimal.equal?(Decimal.new(leg["quantity"]), -1)

    after_ = D.status!(S.get("/balances", ctx.tok_a), 200)
    assert Enum.filter(after_["rows"], &(&1["asset"] == m.fixed)) == []

    assert reason(reverse(ctx, id, %{"reason_code" => "wrong_document"}), 409) ==
             "document_reversed"

    list = D.request(:get, "/documents?state=reversed", ctx.tok_a) |> D.status!(200)
    assert Enum.map(list["rows"], & &1["id"]) == [id]

    # the card can be commissioned again after the reversal
    again = D.issue!(ctx, D.body(m))
    assert again["state"] == "issued"
  end

  test "V1 reason refusals start nothing", ctx do
    id = posted!(ctx)["id"]

    for {body, want} <- [
          {%{}, "reason_invalid"},
          {%{"reason_code" => "nope"}, "reason_invalid"},
          {%{"reason_code" => "other"}, "reason_invalid"},
          {%{"reason_code" => "other", "reason_text" => "   "}, "reason_invalid"},
          {%{"reason_code" => "wrong_quantity", "reason_text" => String.duplicate("x", 501)},
           "reason_invalid"}
        ] do
      assert reason(reverse(ctx, id, body), 422) == want, inspect(body)
    end

    assert D.pending_task(ctx, id, "reverse") == nil
    assert D.get!(ctx, id)["state"] == "posted"

    # a reason text up to 500 characters is accepted
    ok = %{"reason_code" => "other", "reason_text" => String.duplicate("ж", 500)}
    assert reverse(ctx, id, ok).status == 200
  end
end
