defmodule Letflow.SharedStockAccess.IntIds do
  @moduledoc """
  REQ-859 (decision 0091 section 7): the stable integer the old Qoimeks app sees for a Letflow uuid.
  One mapping table per kind in the tenant schema (`catalog_item_int_ids` for `sku_id`,
  `location_node_int_ids` for `location_id`, `movement_int_ids` for a movement `id`), each a
  bigserial next to the uuid: assigned once on first use, never changed, starting at 1 per
  tenant. A lost insert race leaves a gap in the integers, never a second integer for one uuid.

  The tenant is the `prefix` argument only (INV-1); every value is a bound parameter (INV-7). The
  only writes are the mapping rows themselves (`assign/3`); no stock, ledger or catalog row is
  written here.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Repo

  @tables %{
    sku: "catalog_item_int_ids",
    location: "location_node_int_ids",
    movement: "movement_int_ids"
  }

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "int_ids" do
      field(:int_id, :integer)
      field(:ref_id, :binary_id)
    end
  end

  @type kind :: :sku | :location | :movement

  @doc "uuid => integer for every given uuid, creating the missing mappings. Non-uuid text is left out."
  @spec assign(String.t(), kind(), [term()]) :: %{String.t() => pos_integer()}
  def assign(prefix, kind, refs) when is_binary(prefix) and is_list(refs) do
    uuids = uuids(refs)

    if uuids == [] do
      %{}
    else
      source = table(kind)

      Repo.insert_all(
        {source, Row},
        Enum.map(uuids, &%{ref_id: &1}),
        prefix: prefix,
        on_conflict: :nothing,
        conflict_target: [:ref_id]
      )

      lookup(prefix, kind, uuids)
    end
  end

  @doc "uuid => integer for the given uuids that already have one (nothing is created)."
  @spec lookup(String.t(), kind(), [term()]) :: %{String.t() => pos_integer()}
  def lookup(prefix, kind, refs) when is_binary(prefix) and is_list(refs) do
    case uuids(refs) do
      [] ->
        %{}

      uuids ->
        from(r in {table(kind), Row}, where: r.ref_id in ^uuids, select: {r.ref_id, r.int_id})
        |> Repo.all(prefix: prefix)
        |> Map.new()
    end
  end

  @doc "The uuid behind one integer, or `nil` (an unknown, zero, negative or oversized integer)."
  @spec uuid_for(String.t(), kind(), term()) :: String.t() | nil
  def uuid_for(prefix, kind, int)
      when is_binary(prefix) and is_integer(int) and int > 0 and int < 9_000_000_000_000_000_000 do
    Repo.one(from(r in {table(kind), Row}, where: r.int_id == ^int, select: r.ref_id),
      prefix: prefix
    )
  end

  def uuid_for(_prefix, _kind, _int), do: nil

  defp table(kind), do: Map.fetch!(@tables, kind)

  defp uuids(refs) do
    refs
    |> Enum.flat_map(fn ref ->
      case is_binary(ref) && Ecto.UUID.cast(ref) do
        {:ok, uuid} -> [uuid]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end
end
