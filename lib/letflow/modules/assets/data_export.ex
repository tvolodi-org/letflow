defmodule Letflow.Modules.Assets.DataExport do
  @moduledoc """
  Asset balances for Data export, using the module's existing read authority and
  allowlisted view. `unit_ref` is literal text (`pcs`), not a catalog record id.
  """
  @behaviour Letflow.DataExport.Dataset
  alias Letflow.DataExport.Dataset
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.Views

  @impl true
  def dataset_ids, do: ["asset_balances"]
  @impl true
  def module_id, do: "assets"
  @impl true
  def authorize(_id, conn), do: Ledger.authorize(conn, "assets", :read)
  @impl true
  def filters(_id),
    do: [
      {"as_of_date", :date},
      {"scope_subtree", :org_unit},
      {"org_unit", :org_unit},
      {"location", :location},
      {"asset", :asset}
    ]

  @impl true
  def validate_filters(id, raw), do: Dataset.validate(raw, filters(id))
  @impl true
  def columns(_id),
    do:
      Dataset.columns(
        ~w(asset org_unit location material_responsible actual_user unit_ref quantity last_posting_seq)a,
        %{
          quantity: :number,
          last_posting_seq: :integer,
          asset: {:ref, "assets_card"},
          org_unit: {:ref, "org_unit"},
          location: {:ref, "location_node"},
          material_responsible: {:ref, "org_employee"},
          actual_user: {:ref, "org_employee"}
        }
      )

  @impl true
  def fetch_page(_id, ctx, filters, cursor),
    do: Dataset.read(fn -> Dataset.balance_page(ctx, filters, cursor, &Views.asset_balance/1) end)
end
