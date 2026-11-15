defmodule Letflow.Modules.Assets.CountPrintSource do
  @moduledoc """
  T-1932 / GH #4370 (REQ-821, asset count K6): the impure side of the printed count sheet, one path for
  both prints (the official form Inv-8 / Түг-8 and the plain sheet), so the scope and name rules exist
  once. `read/3` checks, in this order and with nothing built before all pass: the count order exists in
  the caller's tenant, it names an issued sheet document, the sheet's ISSUED version holds a `"lines"`
  list (never the live line records), then reads the names.

  Isolation: the tenant is the `prefix` of the token only (INV-1). An unknown, malformed or other-tenant
  id is `{:error, :not_found}` (INV-5). Every read below takes `prefix`. Only tenant-wide interactive users
  reach asset routes (`Letflow.Modules.Assets.Access`: a scoped principal and an API token get `:error`), so
  the name reads need no principal-scope filter. Name reads are one indexed read per distinct id (a sheet
  has at most 2000 lines). A time zone offset is one bound-parameter statement per instant (INV-7).

  An issued sheet stays printable whatever the order's later state (`counted`, `sheet_signed`, `signed`,
  cancelled after close); a count that never closed has no sheet: `{:error, :document_not_issued}`.

  The reads are copies of the stock count paperwork ones, not calls: `core-extraction-design.md` section 2
  says "down, never sideways", so assets does not call `Letflow.Modules.Stock.*`.
  """

  alias Letflow.Documents, as: CoreDocuments
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.Assets.DocumentPrintSource
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi

  # The PDF engine refuses a table of more than 1000 rows (`PrintLayout.check_projection`); the official
  # form adds a totals row, so 999 lines is the most a PDF takes (same cap as the stock count forms).
  @pdf_max_lines 999

  @spec read(String.t(), term(), term()) ::
          {:ok, %{issued: map(), names: map()}} | {:error, :not_found | :document_not_issued}
  def read(prefix, id, tenant_id) when is_binary(prefix) do
    with {:ok, header} <- order(prefix, id),
         {:ok, issued} <- issued(prefix, header) do
      {:ok, %{issued: issued, names: names(prefix, issued, tenant_id)}}
    end
  end

  @doc "True when the issued sheet has more lines than a form PDF can hold (`print_too_large`)."
  @spec pdf_too_large?(map()) :: boolean()
  def pdf_too_large?(%{content: content}), do: length(lines(content)) > @pdf_max_lines

  @doc "The lines of an issued sheet content in line order."
  @spec lines(map()) :: [map()]
  def lines(content) do
    case Map.get(content, "lines") do
      l when is_list(l) -> l |> Enum.filter(&is_map/1) |> Enum.sort_by(&(&1["line_no"] || 0))
      _ -> []
    end
  end

  @doc """
  The ids of the people a sheet names, in print order: the first the material responsible persons of the
  lines (book, then observed, each in line order, first occurrence kept).
  """
  @spec responsible_ids(map()) :: [String.t()]
  def responsible_ids(content) do
    content
    |> lines()
    |> Enum.flat_map(
      &[&1["book_material_responsible_id"], &1["observed_material_responsible_id"]]
    )
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp order(prefix, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, header} <- ReadApi.lookup(prefix, uuid, ["assets_count_order"]) do
      {:ok, header}
    else
      _ -> {:error, :not_found}
    end
  end

  defp issued(prefix, header) do
    with doc_id when is_binary(doc_id) <- header["sheet_document_id"],
         {:ok, summary} <- CoreDocuments.issued_summary(prefix, doc_id),
         %DocumentVersion{content: %{"lines" => lines} = content} when is_list(lines) <-
           DocumentPrintSource.version(prefix, doc_id, summary.version_no) do
      {:ok, Map.put(summary, :content, content)}
    else
      _ -> {:error, :document_not_issued}
    end
  end

  # -- names ----------------------------------------------------------------------------------

  defp names(prefix, issued, tenant_id) do
    content = issued.content
    zone = DocumentPrintSource.zone(tenant_id)
    order = order_summary(prefix, content["order_document_id"])
    unit_id = content["org_unit_id"]

    employee_ids =
      ([content["chair_employee_id"]] ++
         List.wrap(content["member_employee_ids"]) ++ responsible_ids(content))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    employees = Map.new(employee_ids, &{&1, employee(prefix, &1)})

    %{
      timezone: zone,
      offsets: %{
        issued_at: DocumentPrintSource.offset(zone, issued[:issued_at]),
        cut_off_at: DocumentPrintSource.offset(zone, content["cut_off_at"]),
        order_issued_at: DocumentPrintSource.offset(zone, order && order[:issued_at])
      },
      order: order,
      legal_entities: DocumentPrintSource.legal_entity(prefix, unit_id),
      org_units: resolve([unit_id], &named(Org.lookup(prefix, &1))),
      locations:
        resolve(List.wrap(content["location_ids"]), &named(Locations.lookup(prefix, &1))),
      employees: employees,
      positions: positions(prefix, employees),
      card_currency: card_currency(prefix, content)
    }
  end

  defp order_summary(prefix, doc_id) when is_binary(doc_id) do
    case CoreDocuments.issued_summary(prefix, doc_id) do
      {:ok, summary} -> %{number_label: summary[:number_label], issued_at: summary[:issued_at]}
      _ -> nil
    end
  end

  defp order_summary(_prefix, _), do: nil

  defp resolve(ids, fun) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, fun.(id)} end)
  end

  defp named({:ok, r}), do: %{code: r["code"], name: r["name"]}
  defp named(_), do: nil

  defp employee(prefix, id) do
    case Org.lookup(prefix, id) do
      {:ok, r} -> %{full_name: r["full_name"], code: r["code"]}
      _ -> nil
    end
  end

  # employee id => position name, for the employees already resolved.
  defp positions(prefix, employees) do
    for {id, %{}} <- employees, into: %{} do
      with {:ok, e} <- Org.lookup(prefix, id),
           pid when is_binary(pid) <- e["position_id"],
           {:ok, p} <- Org.lookup(prefix, pid) do
        {id, p["name"]}
      else
        _ -> {id, nil}
      end
    end
  end

  # asset id => the live card currency (the sheet stores `book_value` without one).
  defp card_currency(prefix, content) do
    content
    |> lines()
    |> Enum.map(& &1["asset_id"])
    |> resolve(fn id ->
      case ReadApi.lookup(prefix, id, ["assets_card"]) do
        {:ok, r} -> r["currency"]
        _ -> nil
      end
    end)
  end
end
