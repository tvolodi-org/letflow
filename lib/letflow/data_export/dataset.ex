defmodule Letflow.DataExport.Dataset do
  @moduledoc """
  Dataset provider contract for Data export. Providers live in their owning modules;
  the core discovers them through `:data_export_datasets` at runtime (boundary Rule 5).
  Rows are flat, allowlisted maps; a movement leg is one file row.
  """

  @type column :: %{key: atom(), kind: term(), label: map()}
  @callback dataset_ids() :: [String.t()]
  @callback module_id() :: String.t()
  @callback filters(String.t()) :: [{String.t(), atom()}]
  @callback authorize(String.t(), Plug.Conn.t()) :: {:ok, term()} | :error
  @callback validate_filters(String.t(), map()) :: {:ok, term()} | {:error, :invalid_filter}
  @callback columns(String.t()) :: [column()]
  @callback fetch_page(String.t(), term(), term(), term()) ::
              {:ok, %{rows: [map()], next: term(), meta: list()}} | {:error, atom()}

  alias Letflow.Ledger

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc false
  def validate(raw, allowed) when is_map(raw) and not is_struct(raw) do
    if Enum.all?(raw, fn {key, value} -> valid_filter?(key, value, allowed) end) do
      {:ok, raw}
    else
      {:error, :invalid_filter}
    end
  end

  def validate(_, _), do: {:error, :invalid_filter}

  defp valid_filter?(key, value, allowed) when is_binary(value) do
    case List.keyfind(allowed, key, 0) do
      {_, :date} ->
        Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value) and
          match?({:ok, _}, Date.from_iso8601(value))

      {"scope_subtree", _} ->
        value != "" and byte_size(value) <= 64 and String.valid?(value)

      {_, _} ->
        Regex.match?(@uuid, value)

      nil ->
        false
    end
  end

  defp valid_filter?(_, _, _), do: false

  @doc false
  def columns(keys, kinds) do
    Enum.map(keys, fn key ->
      %{
        key: key,
        kind: Map.get(kinds, key, :text),
        label: Map.new(~w(en ru kk), &{&1, Atom.to_string(key)})
      }
    end)
  end

  @doc false
  def balance_page(authorized, filters, cursor, view) do
    {cutoff, next} = cursor || {:latest, nil}
    slots = Map.delete(filters, "as_of_date")
    page = %{limit: page_limit(), nonzero: true, cursor: next}

    result =
      case Map.fetch(filters, "as_of_date") do
        {:ok, raw} ->
          Ledger.balances_on_date(authorized, Date.from_iso8601!(raw), cutoff, slots, page)

        :error ->
          Ledger.balances(authorized, {:posting_seq, cutoff}, slots, page)
      end

    with {:ok, report} <- result do
      meta = [
        {"basis", report.basis.type},
        {"cutoff_seq", report.cutoff_seq},
        {"as_of_date", Map.get(report, :as_of_date)},
        {"timezone", report.timezone},
        {"coverage", report.coverage}
      ]

      {:ok,
       %{
         rows: Enum.map(report.rows, view),
         next: if(report.next_cursor, do: {report.cutoff_seq, report.next_cursor}),
         meta: meta
       }}
    end
  end

  @doc false
  def page_limit, do: Application.get_env(:letflow, :data_export_page_limit, Ledger.page_cap())

  @doc false
  def read(fun) do
    fun.()
  rescue
    error in Postgrex.Error ->
      case read_error(error) do
        :ledger_read_timeout -> {:error, :ledger_read_timeout}
        _ -> reraise error, __STACKTRACE__
      end
  end

  @doc false
  def read_error(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: :ledger_read_timeout
  def read_error({:error, :ledger_read_timeout}), do: :ledger_read_timeout
  def read_error(_), do: :internal_error
end
