defmodule Letflow.Modules.Stock.DocumentPrintSource do
  @moduledoc """
  REQ-737 / GH #3860: the impure side of the printed two-sided stock document. `read/3` checks, in
  this order and with nothing built before all pass: the document exists in the caller's tenant
  (`Documents.fetch/3`, the read behind `GET /documents/:id`), its kind is transfer, hand over or
  return (or the `kinds:` option, see `read/4`), its live version is issued (posted and reversed documents are issued ones), then reads
  the ISSUED version content (never the live header and line records) and the names.

  Isolation: the tenant is the `prefix` of the token only (INV-1); an unknown, malformed,
  discarded or other-tenant id is `{:error, :not_found}` (INV-5). The route has already proved
  tenant-wide read access, so no name is hidden. Name reads are one indexed read per distinct id
  (at most 1000 lines since REQ-774; print layout at that size is not measured). A time zone offset is one bound-parameter statement per instant, shared
  with the count paperwork (`CountPaperworkSource.offset/2`).

  This module holds no query of its own: it reads through `Documents`, `CountPaperworkSource` and
  the lookup contexts.
  """

  alias Letflow.Documents, as: CoreDocuments
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.Documents

  @kinds ["transfer", "hand_over", "return"]
  @issued_states ["issued", "posted", "reversed"]

  @doc """
  Options: `kinds:` (default the act kinds above) lets the official-form print (T-1416, Z-2) read
  an `issue` document; `legal_entities: true` adds `names.legal_entities`, the name and BIN of
  the legal entity of the header `org_unit_id`, keyed by that org unit id (two bound reads,
  `Org.lookup` of the unit and of its legal entity, both through the tenant prefix).
  """
  @spec read(String.t(), term(), term(), keyword()) ::
          {:ok, %{issued: map(), names: map()}}
          | {:error, :not_found | :print_not_available | :document_not_issued}
  def read(prefix, id, tenant_id, opts \\ []) when is_binary(prefix) do
    kinds = Keyword.get(opts, :kinds, @kinds)

    with {:ok, view} <- Documents.fetch(prefix, id),
         :ok <- check_kind(view.kind, kinds),
         :ok <- check_state(view.state),
         {:ok, issued} <- issued(prefix, view.id, kinds) do
      names = names(prefix, issued, tenant_id)

      names =
        if opts[:legal_entities],
          do: Map.put(names, :legal_entities, legal_entities(prefix, issued)),
          else: names

      {:ok, %{issued: issued, names: names}}
    end
  end

  defp check_kind(kind, kinds) do
    if kind in kinds, do: :ok, else: {:error, :print_not_available}
  end

  defp check_state(state) when state in @issued_states, do: :ok
  defp check_state(_), do: {:error, :document_not_issued}

  defp issued(prefix, doc_id, kinds) do
    with {:ok, summary} <- CoreDocuments.issued_summary(prefix, doc_id),
         %DocumentVersion{content: %{} = content} <-
           CountPaperworkSource.version(prefix, doc_id, summary.version_no),
         true <- content["kind"] in kinds do
      {:ok, Map.put(summary, :content, content)}
    else
      _ -> {:error, :document_not_issued}
    end
  end

  # -- names ----------------------------------------------------------------------------------

  defp names(prefix, issued, tenant_id) do
    header = issued.content["header"] |> map()
    lines = lines(issued.content)
    zone = CountPaperworkSource.zone(tenant_id)
    header_ids = fn keys -> Enum.map(keys, &header[&1]) end

    %{
      timezone: zone,
      offsets: %{
        issued_at: CountPaperworkSource.offset(zone, issued[:issued_at]),
        event_time: CountPaperworkSource.offset(zone, header["event_time"])
      },
      org_units:
        header_ids.(~w(org_unit_id from_org_unit_id to_org_unit_id))
        |> resolve(&named(Org.lookup(prefix, &1))),
      locations:
        header_ids.(~w(location_id from_location_id to_location_id))
        |> resolve(&named(Locations.lookup(prefix, &1))),
      employees:
        header_ids.(~w(responsible_id from_responsible_id to_responsible_id))
        |> resolve(&employee(prefix, &1)),
      items: lines |> ids("catalog_item_id") |> resolve(&named(CatalogItems.lookup(prefix, &1))),
      uoms: lines |> ids("catalog_uom_id") |> resolve(&named(CatalogItems.lookup(prefix, &1))),
      lots: lines |> ids("catalog_lot_id") |> resolve(&lot(prefix, &1))
    }
  end

  # The legal entity (name, BIN) of the header org unit, keyed by the unit id.
  defp legal_entities(prefix, issued),
    do: legal_entity(prefix, issued.content["header"] |> map() |> Map.get("org_unit_id"))

  @doc false
  # The legal entity (name, BIN) of an org unit, keyed by the unit id; `%{}` when any link is missing.
  # Shared with the count forms (`CountPaperworkSource.read_form/4`). Two bound reads by `prefix`.
  @spec legal_entity(String.t(), term()) :: map()
  def legal_entity(prefix, unit_id) do
    with unit_id when is_binary(unit_id) <- unit_id,
         {:ok, unit} <- Org.lookup(prefix, unit_id),
         le_id when is_binary(le_id) <- unit["legal_entity_id"],
         {:ok, le} <- Org.lookup(prefix, le_id) do
      %{unit_id => %{name: le["name"], bin: le["bin"]}}
    else
      _ -> %{}
    end
  end

  defp map(%{} = m), do: m
  defp map(_), do: %{}

  defp lines(content) do
    case content["lines"] do
      l when is_list(l) -> Enum.filter(l, &is_map/1)
      _ -> []
    end
  end

  defp ids(lines, key), do: Enum.map(lines, & &1[key])

  defp resolve(ids, fun) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, fun.(id)} end)
  end

  defp named({:ok, r}), do: %{code: r["code"], name: r["name"]}
  defp named(_), do: nil

  defp lot(prefix, id) do
    case CatalogItems.lookup(prefix, id) do
      {:ok, r} -> r["code"]
      _ -> nil
    end
  end

  defp employee(prefix, id) do
    case Org.lookup(prefix, id) do
      {:ok, r} -> %{full_name: r["full_name"], code: r["code"]}
      _ -> nil
    end
  end
end
