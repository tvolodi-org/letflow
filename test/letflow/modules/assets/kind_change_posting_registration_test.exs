defmodule Letflow.Modules.Assets.KindChangePostingRegistrationTest do
  @moduledoc """
  REQ-760 part A (R1, R2): the manifest facts of the posting half of a change of kind (causes, handlers,
  pack definition) and the pure `declare/2` of both ledger policies for the new causes. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets.LedgerPolicy, as: A
  alias Letflow.Modules.Stock.LedgerPolicy, as: S

  @id "11111111-1111-4111-8111-111111111111"
  @org "44444444-4444-4444-8444-444444444444"
  @loc "33333333-3333-4333-8333-333333333333"
  @resp "55555555-5555-4555-8555-555555555555"
  @line "66666666-6666-4666-8666-666666666666"

  test "R1 manifests: causes, handlers, and the pack definition with its two module_writes" do
    assets = Letflow.Modules.Assets.manifest()
    stock = Letflow.Modules.Stock.manifest()

    assert assets.ledger["assets"].causes["kind_change_in"] ==
             %{sign_rule: :positive, reason_required: false}

    assert stock.ledger["stock"].causes["kind_change_out"] ==
             %{sign_rule: :negative, reason_required: false}

    handler = Enum.find(assets.write_handlers, &(&1.name == "post_kind_change"))
    assert handler.targets == ["assets_posting_mark", "assets_card"]
    assert handler.posts_ledger == "assets"
    out = Enum.find(stock.write_handlers, &(&1.name == "post_kind_change_out"))
    assert out.targets == ["stock_posting_mark"] and out.posts_ledger == "stock"

    pack = File.read!("priv/modules/assets/pack.json") |> Jason.decode!()
    assert pack["version"] == "0.4.0"
    definition = Enum.find(pack["definitions"], &(&1["process_key"] == "assets_kind_change"))
    assert [task] = Enum.filter(definition["graph"]["nodes"], &(&1["node_type"] == "HUMAN_TASK"))
    assert task["id"] == "post"

    assert [
             %{"module" => "assets", "handler" => "post_kind_change"} = a,
             %{"module" => "stock", "handler" => "post_kind_change_out"} = s
           ] =
             task["attributes"]["module_writes"]

    assert a["args"]["posting"] == %{"var" => "posting"}
    assert s["args"]["posting"] == %{"var" => "stock_posting"}
    # the plain reversal definition is not the pair reversal (part B)
    refute Enum.any?(pack["definitions"], &(&1["process_key"] == "assets_kind_change_reversal"))
  end

  defp side(extra), do: Map.merge(%{org_unit: @org, location: @loc}, extra)

  test "R2 assets kind_change_in: one positive pcs leg at to; from is refused" do
    to = side(%{material_responsible: @resp})
    line = %{line_id: @line, asset: @id, quantity: "20", from: nil, to: to}

    cmd = %{
      cause: "kind_change_in",
      lines: [line],
      document_type: "d",
      document_id: "x",
      correlation_id: "c"
    }

    assert {:ok, posting} = A.declare(cmd, %{})
    assert [leg] = posting.legs
    assert leg.k == [@id, @org, @loc, @resp, ""] and leg.unit_ref == "pcs"
    assert Decimal.equal?(leg.quantity, 20)

    assert A.declare(put_in(cmd, [:lines, Access.at(0), :from], to), %{}) ==
             {:error, {:invalid_posting, %{leg_no: 1}}}
  end

  test "R2 stock kind_change_out: one negative leg at from; to is refused" do
    from = side(%{responsible: @resp})
    line = %{line_id: @line, sku: @id, lot: nil, unit: @id, quantity: "20", from: from, to: nil}
    cmd = %{cause: "kind_change_out", lines: [line], document_type: "d", document_id: "x"}

    assert {:ok, posting} = S.declare(cmd, %{})
    assert [leg] = posting.legs
    assert Decimal.equal?(leg.quantity, -20) and leg.unit_ref == @id
    assert {:error, _} = S.declare(put_in(cmd, [:lines, Access.at(0), :to], from), %{})
  end
end
