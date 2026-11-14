defmodule Letflow.Modules.Assets.CardPrintSource do
  @moduledoc """
  T-1924 (official forms audit T-1906, slice 8): the impure side of the printed card form ДА-2 / ҰМА-2.
  `read/3` reads the card (live, so a retired card is found), at most two non-zero register rows of it
  and the names of the unit, its legal entity and the materially responsible person.

  Isolation: the tenant is the `prefix` of the token only (INV-1); an unknown, malformed, deleted or
  other-tenant id is `{:error, :not_found}` (INV-5). Every read is bound and parameterised (INV-7).
  The register is read only with a tenant-wide `Letflow.Ledger.Authorized`: a scoped reader would see a
  filtered page. A refused or missing register read gives no holders, so the form prints the person
  blank, never a guess (INV-8: no raise).
  """

  require Logger

  alias Letflow.Ledger
  alias Letflow.Modules.Assets.DocumentPrintSource
  alias Letflow.Modules.Assets.Views
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi

  @spec read(String.t(), term(), term()) ::
          {:ok, %{card: map(), names: map()}} | {:error, :not_found}
  def read(prefix, id, authorized) when is_binary(prefix) do
    case ReadApi.lookup(prefix, id, ["assets_card"]) do
      {:ok, card} ->
        holders = holders(authorized, card["record_id"])
        {:ok, %{card: card, names: names(prefix, card, holders)}}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp holders(authorized, record_id) do
    if is_map(authorized) and Map.get(authorized, :scope) == :all do
      case Ledger.balances(authorized, {:posting_seq, :latest}, %{"asset" => record_id}, %{
             limit: 2,
             nonzero: true
           }) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.map(&Views.asset_balance/1)
          |> Enum.filter(&Map.has_key?(&1, :org_unit))
          |> Enum.map(&Map.take(&1, [:org_unit, :material_responsible]))

        {:error, reason} ->
          Logger.warning("assets card print register read refused: #{inspect(tag(reason))}")
          []
      end
    else
      []
    end
  end

  defp tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp tag(reason), do: reason

  defp names(prefix, card, holders) do
    unit_ids =
      [card["org_unit_id"] | Enum.map(holders, & &1.org_unit)]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    employee_ids =
      holders |> Enum.map(& &1.material_responsible) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    %{
      holders: holders,
      org_units: Map.new(unit_ids, &{&1, named(Org.lookup(prefix, &1))}),
      legal_entities:
        Enum.reduce(unit_ids, %{}, &Map.merge(&2, DocumentPrintSource.legal_entity(prefix, &1))),
      employees: Map.new(employee_ids, &{&1, employee(Org.lookup(prefix, &1))})
    }
  end

  defp named({:ok, r}), do: %{code: r["code"], name: r["name"]}
  defp named(_), do: nil

  defp employee({:ok, r}), do: %{full_name: r["full_name"], code: r["code"]}
  defp employee(_), do: nil
end
