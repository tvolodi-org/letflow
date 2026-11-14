defmodule Letflow.Modules.Stock.DataExport do
  @moduledoc """
  Stock Data export providers. Authority and masking come from the same Ledger
  reads as the module routes; columns are allowlisted through Views. Balance
  pages pin the first cutoff. Movements are an append-only prefix in posting order.
  """
  @behaviour Letflow.DataExport.Dataset
  alias Letflow.DataExport.Dataset
  alias Letflow.Ledger
  alias Letflow.Modules.Stock.{DocumentNumbers, Views}

  @references %{
    sku: {:ref, "catalog_item"},
    location: {:ref, "location_node"},
    org_unit: {:ref, "org_unit"},
    responsible: {:ref, "org_employee"},
    lot: {:ref, "catalog_lot"},
    unit_ref: {:ref, "catalog_uom"}
  }

  @impl true
  def dataset_ids, do: ~w(stock_balances stock_movements)
  @impl true
  def module_id, do: "stock"
  @impl true
  def authorize(_id, conn), do: Ledger.authorize(conn, "stock", :read)
  @impl true
  def filters(id) do
    base = [
      {"scope_subtree", :org_unit},
      {"org_unit", :org_unit},
      {"location", :location},
      {"sku", :item}
    ]

    if id == "stock_balances", do: [{"as_of_date", :date} | base], else: base
  end

  @impl true
  def validate_filters(id, raw), do: Dataset.validate(raw, filters(id))
  @impl true
  def columns("stock_balances") do
    Dataset.columns(
      ~w(sku location org_unit responsible lot unit_ref quantity last_posting_seq)a,
      Map.merge(@references, %{quantity: :number, last_posting_seq: :integer})
    )
  end

  def columns("stock_movements") do
    Dataset.columns(
      ~w(entry_id posting_seq posting_time event_time cause reverses_entry_id reason_code
      document_type document_id document_number related_document_id correlation_id leg_no sku location
      org_unit responsible lot quantity unit_ref document_line_id masked)a,
      Map.merge(@references, %{
        quantity: :number,
        posting_seq: :integer,
        leg_no: :integer,
        masked: :bool,
        posting_time: :time,
        event_time: :time
      })
    )
  end

  @impl true
  def fetch_page("stock_balances", ctx, filters, cursor),
    do: Dataset.read(fn -> Dataset.balance_page(ctx, filters, cursor, &Views.stock_balance/1) end)

  def fetch_page("stock_movements", ctx, filters, cursor) do
    Dataset.read(fn ->
      {subtree, slots} = Map.pop(filters, "scope_subtree")
      filters = if map_size(slots) == 0, do: %{}, else: %{"leg_slots" => slots}
      filters = if subtree, do: Map.put(filters, "scope_subtree", subtree), else: filters

      with {:ok, report} <-
             Ledger.entries(ctx, filters, %{limit: Dataset.page_limit(), cursor: cursor}) do
        entries =
          DocumentNumbers.put_numbers(ctx.prefix, Enum.map(report.rows, &Views.stock_movement/1))

        rows =
          for entry <- entries,
              leg <- Enum.sort_by(entry.legs, & &1.leg_no),
              do:
                entry
                |> Map.delete(:legs)
                |> Map.merge(leg)
                |> Map.put(:masked, Map.get(leg, :masked, false))

        seqs = Enum.map(entries, & &1.posting_seq)

        {:ok,
         %{
           rows: rows,
           next: report.next_cursor,
           meta: [
             {"first_posting_seq", List.first(seqs)},
             {"last_posting_seq", List.last(seqs)},
             {"coverage", Map.get(report, :coverage)}
           ]
         }}
      end
    end)
  end
end
