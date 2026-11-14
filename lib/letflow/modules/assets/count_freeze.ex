defmodule Letflow.Modules.Assets.CountFreeze do
  @moduledoc """
  REQ-820 / GH #4371 (asset count slice K5, owner decision D-128, spec `docs/assets/asset-count.md`
  section 6): the freeze of the counted scope. A copy of the idea of `Letflow.Modules.Stock.FreezeState`
  and `FreezeGuard` for the ledger `assets` (module `assets` does not call `stock`, boundary Rule 4).

  The asset ledger has no posting guard and K5 changes no ledger policy, so the freeze is checked in
  the one place every asset document passes: `Documents.issue/4`, inside the per-tenant asset issue
  lock, before a number is taken. Drafts (save, replace, discard) are never refused.

  The freeze of an order is worked out from stored data, nothing is written on its way:

    * `none`: the order does not ask for `freeze_locations`, or it is not opened yet;
    * `ended`: the order is `cancelled` or `signed`;
    * `expired`: `now >= freeze_until` (the limit `count_freeze_limit_minutes` read at open; an
      unreadable `freeze_until` counts as expired, a freeze never lasts for ever);
    * `active`: otherwise.

  `open_fields/3` fixes the scope at the cut-off: `freeze_started_at`, `freeze_until`,
  `freeze_whole_unit` and `freeze_location_ids` (the roots and everything below them). A location
  created later is not frozen. A side of a document is frozen when it has the order's org unit and
  either a location in the set (any location for a whole-unit order), or no location (an intangible
  card) while the order counts intangibles.

  Known gap: a document issued before the cut-off whose posting completes during the freeze is not
  refused (closing it needs a posting guard on the ledger registration, a ledger-policy change). The
  book read stays exact because the hold and `cutoff_seq` leave later postings out. The freeze does
  not read the `count_enabled` flag: switching the flag off does not end a running freeze, the limit
  does.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.Locations.Tree
  alias Letflow.Repo

  @max_locations 5_000

  @doc "The freeze state of an order header (string keys) at `now`."
  @spec state(map(), DateTime.t()) :: String.t()
  def state(header, now) do
    cond do
      Map.get(header, "freeze_locations") != true -> "none"
      blank?(Map.get(header, "freeze_started_at")) -> "none"
      Map.get(header, "status") in ["cancelled", "signed"] -> "ended"
      expired?(Map.get(header, "freeze_until"), now) -> "expired"
      true -> "active"
    end
  end

  @doc "The freeze keys of the order view."
  @spec view_fields(map(), DateTime.t()) :: map()
  def view_fields(header, now) do
    %{
      "freeze_state" => state(header, now),
      "freeze_started_at" => Map.get(header, "freeze_started_at"),
      "freeze_until" => Map.get(header, "freeze_until")
    }
  end

  @doc """
  The freeze fields stored when the order is opened at `cut_off`. `roots` are the scope roots
  (`[]` for a whole-unit order). Refuses a scope of more than 5000 locations.
  """
  @spec open_fields(String.t(), [String.t()], DateTime.t(), pos_integer()) ::
          {:ok, map()} | {:error, :count_too_large}
  def open_fields(prefix, roots, %DateTime{} = cut_off, limit_minutes) do
    ids =
      roots
      |> Enum.flat_map(fn root -> [root | Tree.descendant_ids(prefix, root)] end)
      |> Enum.uniq()
      |> Enum.sort()

    if length(ids) > @max_locations do
      {:error, :count_too_large}
    else
      {:ok,
       %{
         "freeze_started_at" => DateTime.to_iso8601(cut_off),
         "freeze_until" =>
           DateTime.to_iso8601(DateTime.add(cut_off, limit_minutes * 60, :second)),
         "freeze_whole_unit" => roots == [],
         "freeze_location_ids" => ids
       }}
    end
  end

  @doc """
  `:ok`, or `{:error, {"count_in_progress", extras}}` when a side of the document view is in the
  scope of an active freeze. `extras.held_by` is the number of the first such order.
  """
  @spec check(String.t(), map(), DateTime.t()) :: :ok | {:error, {String.t(), map()}}
  def check(prefix, view, now) do
    case pairs(view) do
      [] ->
        :ok

      pairs ->
        units = pairs |> Enum.map(&elem(&1, 0)) |> Enum.filter(&is_binary/1) |> Enum.uniq()

        prefix
        |> active_orders(units, now)
        |> Enum.find(fn order -> Enum.any?(pairs, &frozen?(&1, order)) end)
        |> case do
          nil ->
            :ok

          order ->
            held_by = Map.get(order, "number")
            held_by = if blank?(held_by), do: "count", else: held_by

            {:error,
             {"count_in_progress", %{"field" => nil, "line_no" => nil, "held_by" => held_by}}}
        end
    end
  end

  # The `{org_unit, location}` of every side of the document.
  defp pairs(%{kind: "kind_change"} = view) do
    for line <- view.lines,
        do: {line.asset_org_unit_id || view.org_unit_id, line.asset_location_id}
  end

  defp pairs(%{kind: "opening"} = view) do
    for line <- view.lines, do: {view.org_unit_id, line.location_id}
  end

  defp pairs(%{kind: kind} = view) do
    spec = Kinds.get(kind)
    {from, to} = Kinds.sides(spec, Kinds.header_of(spec, view))

    for side <- [from, to], side != nil, do: {side.org_unit, side.location}
  end

  defp active_orders([], _units, _now), do: []
  defp active_orders(_prefix, [], _now), do: []

  defp active_orders(prefix, units, now) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "assets_count_order" and l.deleted == false and
            fragment("?->>'freeze_locations' = 'true'", l.field_values) and
            fragment("coalesce(?->>'freeze_started_at', '') <> ''", l.field_values) and
            fragment("coalesce(?->>'status', '') NOT IN ('cancelled', 'signed')", l.field_values) and
            fragment("?->>'org_unit_id' = ANY(?)", l.field_values, ^units)
      ),
      prefix: prefix
    )
    |> Enum.map(fn row -> Map.put(row.field_values, "record_id", row.record_id) end)
    |> Enum.filter(&(state(&1, now) == "active"))
    |> Enum.sort_by(&to_string(Map.get(&1, "number")))
  end

  defp frozen?({unit, location}, order) do
    unit == Map.get(order, "org_unit_id") and
      if is_nil(location) do
        "intangible" in List.wrap(Map.get(order, "kinds"))
      else
        Map.get(order, "freeze_whole_unit") == true or
          location in List.wrap(Map.get(order, "freeze_location_ids"))
      end
  end

  defp expired?(until, now) do
    case until do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _} -> DateTime.compare(now, at) != :lt
          _ -> true
        end

      _ ->
        true
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
