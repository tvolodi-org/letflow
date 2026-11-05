defmodule Letflow.Modules.Stock.CountPaperworkSource do
  @moduledoc """
  REQ-719 / GH #3762: the impure side of the count paperwork. `fetch/4` reads, in this order: the
  scope-checked order header, the document id of the asked kind, the ISSUED version content (never
  the live records), the names, the tenant time zone offsets; then calls the pure
  `Letflow.Modules.Stock.CountPaperwork.build/3`. Nothing is built before every check passed, so a
  refusal carries no workbook bytes.

  Isolation: the tenant is the `prefix` of the token only (INV-1). An unknown, other-tenant or
  out-of-scope count is `{:error, :not_found}` (INV-5). An employee's name and code are given only
  when `Letflow.Api.Scope.allowed?/3` allows `:StockRead` on the employee's org unit (decision 0076
  owner answer 7, INV-2); otherwise the cells stay empty and the signer line stays. The time zone
  offsets are one bound-parameter statement per instant (INV-7); a failing statement gives offset 0
  (INV-8).

  Name reads are one indexed read per distinct id (no line cap in REQ-701); a batch read is a
  follow-up if the speed test needs it. Assumption, owner may change at GATE B.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Scope
  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Identity
  alias Letflow.Identity.TenantTimezone
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.CountPaperwork
  alias Letflow.Repo

  @doc_keys %{
    order: "document_id",
    sheet: "sheet_document_id",
    differences: "differences_document_id"
  }

  @type ctx :: %{scope: term(), principal: term(), tenant_id: term()}

  @doc """
  The one read path (REQ-736): scope-checked header, ISSUED content and names, with no output built.
  `fetch/4` (xlsx) and the PDF route both start here, so the scope and name rules exist once.
  """
  @spec read(String.t(), term(), CountPaperwork.kind(), ctx()) ::
          {:ok, %{kind: CountPaperwork.kind(), issued: map(), names: map()}}
          | {:error, :not_found | :document_not_issued}
  def read(prefix, id, kind, %{scope: scope, principal: principal, tenant_id: tenant_id})
      when is_binary(prefix) and kind in [:order, :sheet, :differences] do
    with {:ok, header} <- Counts.header(prefix, id, scope),
         {:ok, issued} <- issued(prefix, header, kind),
         {:ok, order_content} <- order_content(prefix, header, kind, issued) do
      issued = Map.put(issued, :order_content, order_content)

      {:ok,
       %{kind: kind, issued: issued, names: names(prefix, kind, issued, principal, tenant_id)}}
    end
  end

  @spec fetch(String.t(), term(), CountPaperwork.kind(), ctx()) ::
          {:ok, binary(), String.t()}
          | {:error, :not_found | :document_not_issued | :xlsx_write_failed}
  def fetch(prefix, id, kind, ctx) do
    with {:ok, %{issued: issued, names: names}} <- read(prefix, id, kind, ctx),
         {:ok, binary} <- CountPaperwork.build(kind, issued, names) do
      {:ok, binary, file_name(issued.number_label)}
    end
  end

  @doc "The download file name: the number label with unsafe characters replaced, plus `.xlsx`."
  @spec file_name(term()) :: String.t()
  def file_name(label), do: file_name(label, "xlsx")

  @doc "Same, with the extension given (`\"pdf\"` for REQ-736)."
  @spec file_name(term(), String.t()) :: String.t()
  def file_name(label, ext) do
    safe = label |> to_string() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    if(safe == "", do: "count", else: safe) <> "." <> ext
  end

  # -- issued content -------------------------------------------------------------------------

  defp issued(prefix, header, kind) do
    with doc_id when is_binary(doc_id) <- header[Map.fetch!(@doc_keys, kind)],
         {:ok, summary} <- Documents.issued_summary(prefix, doc_id),
         %DocumentVersion{content: content} when is_map(content) <-
           version(prefix, doc_id, summary.version_no) do
      {:ok, Map.put(summary, :content, content)}
    else
      _ -> {:error, :document_not_issued}
    end
  end

  # The version the summary named, so label, version number and content cannot disagree.
  @doc false
  def version(prefix, doc_id, version_no) do
    with {:ok, id} <- Ecto.UUID.cast(doc_id) do
      Repo.one(
        from(v in DocumentVersion,
          join: d in Document,
          on: d.id == v.document_id,
          where: d.id == ^id and v.version_no == ^version_no and v.status == :issued,
          select: v
        ),
        prefix: prefix
      )
    else
      _ -> nil
    end
  end

  defp order_content(_prefix, _header, :order, issued), do: {:ok, issued.content}

  defp order_content(prefix, header, _kind, _issued) do
    with doc_id when is_binary(doc_id) <- header["document_id"],
         {:ok, summary} <- Documents.issued_summary(prefix, doc_id),
         %DocumentVersion{content: content} when is_map(content) <-
           version(prefix, doc_id, summary.version_no) do
      {:ok, content}
    else
      _ -> {:error, :document_not_issued}
    end
  end

  # -- names ----------------------------------------------------------------------------------

  defp names(prefix, kind, issued, principal, tenant_id) do
    content = issued.content
    order = issued.order_content
    lines = lines(content)

    zone = zone(tenant_id)

    %{
      timezone: zone,
      offsets: offsets(zone, issued, content),
      org_unit: unit(prefix, content["org_unit_id"] || order["org_unit_id"]),
      employees: employees(prefix, kind, order, lines, principal),
      locations: locations(prefix, order, lines),
      items: for_ids(lines, "catalog_item_id", &item(prefix, &1)),
      lots: for_ids(lines, "catalog_lot_id", &lot(prefix, &1))
    }
  end

  defp lines(content) do
    case content["lines"] || content["items"] do
      l when is_list(l) -> Enum.filter(l, &is_map/1)
      _ -> []
    end
  end

  defp for_ids(lines, key, fun) do
    lines
    |> Enum.map(& &1[key])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, fun.(id)} end)
  end

  defp unit(prefix, id) do
    case Org.lookup(prefix, id) do
      {:ok, r} -> %{code: r["code"], name: r["name"]}
      _ -> nil
    end
  end

  defp item(prefix, id) do
    case CatalogItems.lookup(prefix, id) do
      {:ok, r} -> %{code: r["code"], name: r["name"]}
      _ -> nil
    end
  end

  defp lot(prefix, id) do
    case CatalogItems.lookup(prefix, id) do
      {:ok, r} -> r["code"]
      _ -> nil
    end
  end

  defp locations(prefix, order, lines) do
    ids =
      (List.wrap(order["location_ids"]) ++ Enum.map(lines, & &1["location_id"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Map.new(ids, fn id ->
      case Locations.lookup(prefix, id) do
        {:ok, r} -> {id, %{code: r["code"], name: r["name"]}}
        _ -> {id, nil}
      end
    end)
  end

  defp employees(prefix, kind, order, lines, principal) do
    line_ids = if kind == :order, do: [], else: Enum.map(lines, & &1["responsible_employee_id"])

    ([order["chair_employee_id"]] ++ List.wrap(order["member_employee_ids"]) ++ line_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, employee(prefix, id, principal)} end)
  end

  # Visible iff the caller's grant covers the employee's org unit; anything else is hidden (nil).
  defp employee(prefix, id, principal) do
    with {:ok, r} <- Org.lookup(prefix, id),
         unit when is_binary(unit) <- r["org_unit_id"],
         {:allow, _} <- Scope.allowed?(principal, :StockRead, {:node, unit}) do
      %{full_name: r["full_name"], code: r["code"]}
    else
      _ -> nil
    end
  end

  # -- time zone ------------------------------------------------------------------------------

  @doc false
  def zone(tenant_id) do
    with {:ok, tenant} <- Identity.get_tenant(tenant_id),
         name = TenantTimezone.of(tenant),
         true <- TenantTimezone.known_zone?(name) do
      name
    else
      _ -> TenantTimezone.default()
    end
  end

  defp offsets(zone, issued, content) do
    for {key, value} <- [
          issued_at: issued[:issued_at],
          cut_off_at: content["cut_off_at"],
          planned_start: content["planned_start"],
          planned_end: content["planned_end"]
        ],
        into: %{} do
      {key, offset(zone, value)}
    end
  end

  @doc false
  def offset(zone, value) do
    with {:ok, at} <- instant(value),
         {:ok, %{rows: [[seconds]]}} when is_integer(seconds) <-
           Repo.query(
             "SELECT EXTRACT(EPOCH FROM ($1::timestamptz AT TIME ZONE $2) - ($1::timestamptz AT TIME ZONE 'UTC'))::int",
             [at, zone]
           ) do
      seconds
    else
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp instant(%DateTime{} = dt), do: {:ok, dt}

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp instant(_), do: :error
end
