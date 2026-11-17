defmodule Letflow.Modules.Stock.CountHold do
  @moduledoc """
  REQ-854 / GH #4564 (Qoimeks parity G5 part 2): the formal-count rule of the quick count. A quick count
  on a key inside the scope of a count order of the SAME org unit that has been opened and is not
  posted or cancelled (status `counting`, `counted` or `signed`, and no `posted` mark on its
  differences document; the pair rule of decision 0079 section 4) is held, whether or not the order
  freezes locations. Why: in the default no-freeze mode the formal count posts a delta from the cut-off,
  so a quick count after the cut-off would be counted twice (`docs/runbooks/stock-counts.md`).

  The scope of an order is the `location_id` of each of its `count_order_scope` rows and every location
  below one (`Letflow.Modules.Locations.Tree.descendant_ids/2`), the same set the count sheet open reads.
  The answer is `:ok` or `{:held, number}`, the number of the first (by number) holding order; an order
  without a number is named `count` (the fallback of `Letflow.Modules.Stock.FreezeGuard`).

  Used by `Letflow.Modules.Stock.Documents.quick_count/4` (the route's 422 `count_in_progress`) and by
  `Letflow.Modules.Stock.FreezeGuard.check/2` (the approval and the reversal: `location_frozen`). Reads
  only; every query takes the tenant schema `prefix:` (INV-1); text is compared with text.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Locations.Tree
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Repo

  @open_states ["counting", "counted", "signed"]

  @doc "`:ok`, or `{:held, number}` when `org_unit` / `location` is inside an opened, unposted, uncancelled count."
  @spec check(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:held, String.t()}
  def check(prefix, org_unit, location), do: check_pairs(prefix, [{org_unit, location}])

  @doc "As `check/3` for the `org_unit` / `location` slots of the keys of a posting summary."
  @spec check_keys(String.t(), [map()]) :: :ok | {:held, String.t()}
  def check_keys(prefix, keys) when is_list(keys) do
    check_pairs(prefix, for(key <- keys, is_map(key), do: {key["org_unit"], key["location"]}))
  end

  defp check_pairs(prefix, pairs) do
    pairs = Enum.filter(pairs, fn {unit, location} -> is_binary(unit) and is_binary(location) end)
    units = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    case open_orders(prefix, units) do
      [] -> :ok
      orders -> first_held(prefix, orders, pairs)
    end
  end

  defp first_held(prefix, orders, pairs) do
    scopes = scopes(prefix, Enum.map(orders, & &1["record_id"]))
    expanded = expand(prefix, scopes)

    held =
      Enum.find(orders, fn order ->
        set = Map.get(expanded, order["record_id"], MapSet.new())

        Enum.any?(pairs, fn {unit, location} ->
          unit == order["org_unit_id"] and MapSet.member?(set, location)
        end)
      end)

    case held do
      nil -> :ok
      %{"number" => number} when is_binary(number) and number != "" -> {:held, number}
      _unnumbered -> {:held, "count"}
    end
  end

  defp open_orders(_prefix, []), do: []

  defp open_orders(prefix, units) do
    from(l in Latest,
      where:
        l.entity_type == "count_order" and l.deleted == false and
          fragment(
            "?->>'status' = ANY(?)",
            l.field_values,
            type(^@open_states, {:array, :string})
          ) and
          fragment("?->>'org_unit_id' = ANY(?)", l.field_values, type(^units, {:array, :string})),
      select: {l.record_id, l.field_values}
    )
    |> Repo.all(prefix: prefix)
    |> Enum.map(fn {record_id, fv} -> Map.put(fv, "record_id", record_id) end)
    |> Enum.reject(&posted?(prefix, &1))
    |> Enum.sort_by(&{to_string(&1["number"]), &1["record_id"]})
  end

  # The mark commits with the ledger entry of the differences document; the stored status `posted`
  # follows later (`posting-record`), so the mark decides.
  defp posted?(prefix, header) do
    case header["differences_document_id"] do
      id when is_binary(id) and id != "" ->
        prefix |> Posting.marks([id]) |> Map.get(id, %{}) |> Map.has_key?("posted")

      _none ->
        false
    end
  end

  defp scopes(prefix, ids) do
    from(l in Latest,
      where:
        l.entity_type == "count_order_scope" and l.deleted == false and
          fragment("?->>'count_order_id' = ANY(?)", l.field_values, type(^ids, {:array, :string})),
      select: {
        fragment("?->>'count_order_id'", l.field_values),
        fragment("?->>'location_id'", l.field_values)
      }
    )
    |> Repo.all(prefix: prefix)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The roots and everything below them (`Tree.descendant_ids/2` lists descendants only).
  defp expand(prefix, scopes) do
    Map.new(scopes, fn {order, roots} ->
      set =
        Enum.reduce(roots, MapSet.new(), fn root, acc ->
          acc |> MapSet.put(root) |> MapSet.union(MapSet.new(Tree.descendant_ids(prefix, root)))
        end)

      {order, set}
    end)
  end
end
