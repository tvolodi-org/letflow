defmodule Letflow.Modules.Assets.Documents.KindChangePosting do
  @moduledoc """
  GH #3901 / REQ-760 part A (assets C15): the posting side of a change of kind document, called only
  from `Letflow.Modules.Assets.Documents.Posting` so that module keeps one kind-specific branch per
  function. A change of kind posts TWO entries in one transaction: the stock entry (cause
  `kind_change_out`, negative legs at the stock place) and the asset entry (cause `kind_change_in`,
  positive legs at the NEW cards), with the same `document_type`, `document_id` and `correlation_id`.

    * `commands/2` builds the two posting commands from the frozen issued content (the same
      line-record join as `Posting`). The asset lines carry the card fields the handler reads
      (`inventory_number`, `asset_name`, `target_kind`) and NO `asset`: the handler derives the card ids.
    * `check/4` is the `posting_check` of the document (`"ok"` / `"mismatch"`). The binding of the
      task variables to the issued content is detected here, not enforced (decision 0078 D5).
    * `card_ids/1` maps each line record id to the card its asset leg names (the stored
      `asset_card_id` stays empty until part B; it is derived on read).

  Pure apart from the reads of `check/4` (the tenant `prefix` is always passed, INV-1).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Repo

  @type_key "assets_kind_change"
  @device "assets-kind-change"
  @unit "pcs"

  @doc """
  `{:ok, %{assets: command, stock: command}}` (string keys) for the document `view` and its `issued`
  version, or `{:error, reason}` (`:number_out_of_range`, `:line_record_missing`, `:quantity_not_whole`).
  """
  @spec commands(map(), map()) :: {:ok, %{assets: map(), stock: map()}} | {:error, atom()}
  def commands(view, %{content: content, number: number, period: period} = issued) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])
    line_ids = Map.new(view.lines, &{&1.line_no, &1.line_id})

    with {:ok, seq} <- Posting.client_seq(period, number),
         {:ok, built} <- build_lines(lines, header, line_ids) do
      common = %{
        "document_type" => @type_key,
        "document_id" => view.id,
        "client_op_id" => issued.version_id,
        "device_id" => @device,
        "client_seq" => seq,
        "client_event_time" => Map.get(header, "event_time"),
        "correlation_id" => issued.version_id
      }

      {:ok,
       %{
         assets:
           Map.merge(common, %{
             "cause" => "kind_change_in",
             "lines" => Enum.map(built, & &1.asset)
           }),
         stock:
           Map.merge(common, %{
             "cause" => "kind_change_out",
             "lines" => Enum.map(built, & &1.stock)
           })
       }}
    end
  end

  defp build_lines(lines, header, line_ids) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      with {:ok, line_id} <- Map.fetch(line_ids, Map.get(line, "line_no")),
           {:ok, quantity} <- Posting.whole_text(Map.get(line, "quantity")) do
        {:cont,
         {:ok,
          [
            %{
              asset: asset_line(line, header, line_id, quantity),
              stock: stock_line(line, header, line_id, quantity)
            }
            | acc
          ]}}
      else
        :error -> {:halt, {:error, :line_record_missing}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp stock_line(line, header, line_id, quantity) do
    %{
      "line_id" => line_id,
      "sku" => Map.get(line, "catalog_item_id"),
      "lot" => Map.get(line, "catalog_lot_id"),
      "unit" => Map.get(line, "catalog_uom_id"),
      "quantity" => quantity,
      "from" => %{
        "org_unit" => Map.get(header, "org_unit_id"),
        "location" => Map.get(line, "stock_location_id"),
        "responsible" => Map.get(line, "stock_responsible_id")
      },
      "to" => nil
    }
  end

  defp asset_line(line, header, line_id, quantity) do
    %{
      "line_id" => line_id,
      "quantity" => quantity,
      "inventory_number" => Map.get(line, "inventory_number"),
      "asset_name" => Map.get(line, "asset_name"),
      "target_kind" => Map.get(line, "target_kind"),
      "from" => nil,
      "to" => asset_side(line, header)
    }
  end

  defp asset_side(line, header) do
    %{
      "org_unit" => Map.get(line, "asset_org_unit_id") || Map.get(header, "org_unit_id"),
      "location" => Map.get(line, "asset_location_id"),
      "material_responsible" => Map.get(line, "material_responsible_id"),
      "actual_user" => Map.get(line, "actual_user_id")
    }
  end

  @doc """
  `%{line_record_id => card_id}` from the legs of the asset `posting` entry (`document_line_id` and
  the first key component). Empty for anything that is not a list of legs.
  """
  @spec card_ids(map() | nil) :: %{String.t() => String.t()}
  def card_ids(%{legs: legs}) when is_list(legs) do
    for %{document_line_id: line_id, k: [card | _]} <- legs, is_binary(line_id), into: %{} do
      {line_id, card}
    end
  end

  def card_ids(_other), do: %{}

  @doc """
  The `posting_check` of a posted change of kind: `"ok"` when the asset entry (card component left
  out), the stock entry and the cards all equal what the issued content asks for, one entry each, and
  both share the document's `correlation_id`; else `"mismatch"`. `nil` when the stock rows are not
  readable (`:error`).
  """
  @spec check(String.t(), map(), term(), term()) :: String.t() | nil
  def check(prefix, base, asset_rows, stock_rows) do
    with {:ok, a_rows} <- ok_rows(asset_rows),
         {:ok, s_rows} <- ok_rows(stock_rows),
         %{content: content} <- Posting.issued(prefix, base.id),
         [asset] <- Enum.filter(a_rows, &(&1.cause == "kind_change_in")),
         [stock] <- Enum.filter(s_rows, &(&1.cause == "kind_change_out")) do
      verdict(prefix, base, content, asset, stock)
    else
      :error -> nil
      _other -> "mismatch"
    end
  end

  defp ok_rows({:ok, rows}), do: {:ok, rows}
  defp ok_rows(:truncated), do: {:ok, []}
  defp ok_rows(_unavailable), do: :error

  defp verdict(prefix, base, content, asset, stock) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])

    ok? =
      asset.correlation_id != nil and asset.correlation_id == stock.correlation_id and
        asset_legs(asset, lines, header) and stock_legs(stock, lines, header) and
        cards_match?(prefix, base, asset, lines, header)

    if ok?, do: "ok", else: "mismatch"
  end

  defp asset_legs(asset, lines, header) do
    expected =
      lines
      |> Enum.map(fn line ->
        side = asset_side(line, header)

        {side["org_unit"], blank(side["location"]), side["material_responsible"],
         blank(side["actual_user"]), @unit, dec(Map.get(line, "quantity"))}
      end)
      |> Enum.sort()

    actual =
      asset.legs
      |> Enum.map(fn leg ->
        [_card, org, loc, resp, user] = pad(Map.get(leg, :k, []))
        {org, blank(loc), resp, blank(user), leg.unit_ref, dec(leg.quantity)}
      end)
      |> Enum.sort()

    actual == expected and
      length(Enum.uniq_by(asset.legs, &hd(Map.get(&1, :k, [nil])))) == length(asset.legs)
  end

  defp stock_legs(stock, lines, header) do
    expected =
      lines
      |> Enum.map(fn line ->
        {Map.get(line, "catalog_item_id"), Map.get(line, "stock_location_id"),
         Map.get(header, "org_unit_id"), blank(Map.get(line, "stock_responsible_id")),
         blank(Map.get(line, "catalog_lot_id")), Map.get(line, "catalog_uom_id"),
         dec(negate(Map.get(line, "quantity")))}
      end)
      |> Enum.sort()

    actual =
      stock.legs
      |> Enum.map(fn leg ->
        [sku, loc, org, resp, lot] = pad(Map.get(leg, :k, []))
        {sku, loc, org, blank(resp), blank(lot), leg.unit_ref, dec(leg.quantity)}
      end)
      |> Enum.sort()

    actual == expected
  end

  # Every asset leg names an `assets_card` whose number, name, kind and org unit equal the issued
  # line's (the line is found through the leg's `document_line_id`).
  defp cards_match?(prefix, base, asset, lines, header) do
    by_line = Map.new(base.lines, &{&1.line_id, &1.line_no})
    by_no = Map.new(lines, &{Map.get(&1, "line_no"), &1})
    ids = Enum.map(asset.legs, &(Map.get(&1, :k, []) |> List.first()))

    cards =
      Repo.all(
        from(r in Latest,
          where:
            r.entity_type == "assets_card" and not r.deleted and r.record_id in ^cast_ids(ids),
          select: {r.record_id, r.field_values}
        ),
        prefix: prefix
      )
      |> Map.new()

    Enum.all?(asset.legs, fn leg ->
      with line_no when not is_nil(line_no) <- by_line[leg.document_line_id],
           %{} = line <- by_no[line_no],
           %{} = fv <- cards[List.first(leg.k)] do
        fv["inventory_number"] == line["inventory_number"] and fv["name"] == line["asset_name"] and
          fv["kind"] == line["target_kind"] and
          fv["org_unit_id"] == asset_side(line, header)["org_unit"]
      else
        _ -> false
      end
    end)
  end

  defp cast_ids(ids),
    do:
      Enum.flat_map(
        ids,
        &case Ecto.UUID.cast(&1) do
          {:ok, id} -> [id]
          _ -> []
        end
      )

  defp pad(k), do: k |> Enum.take(5) |> then(&(&1 ++ List.duplicate(nil, 5 - length(&1))))
  defp blank(nil), do: ""
  defp blank(value), do: value

  defp negate(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> Decimal.negate(d)
      _bad -> "invalid"
    end
  end

  defp dec(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> d |> Decimal.normalize() |> Decimal.to_string(:normal)
      _bad -> "invalid"
    end
  end
end
