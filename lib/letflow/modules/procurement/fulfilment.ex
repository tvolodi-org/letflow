defmodule Letflow.Modules.Procurement.Fulfilment do
  @moduledoc """
  The derived status of a purchase request line and of the request (GH #3188, REQ-558 part 2).
  Pure functions over exact decimals: no database, no floats, nothing here is ever set by a caller.
  `Letflow.Modules.Procurement.LineEvents` reads the quantities and the cancelled marks and passes
  them in.

  Line status, checked in this order:

    1. `fulfilled >= quantity` is `:fulfilled` (over-fulfilment too);
    2. `fulfilled > 0` is `:partial`;
    3. the line is marked cancelled: `:cancelled`;
    4. otherwise `:open`.

  A cancelled line that already has fulfilled quantity keeps `:partial` or `:fulfilled`; the mark is
  reported separately by the line view. These definitions are UAT assumptions until the process
  owner confirms them.

  Request status (only for a request with an approved version; the caller passes `nil` otherwise):
  every line `:cancelled` is `:cancelled`; every line `:fulfilled` or cancelled-marked is `:closed`;
  any line with fulfilled quantity is `:partial`; else `nil`, which means the request keeps the state
  REQ-544 gives (`approved`). The check for `:cancelled` comes first because an all-cancelled
  request is also all-marked.
  """

  @type line_status :: :open | :partial | :fulfilled | :cancelled
  @type request_status :: :cancelled | :closed | :partial | nil

  @doc "Status of one line from its quantity, its fulfilled quantity and the cancelled mark."
  @spec line_status(Decimal.t(), Decimal.t(), boolean()) :: line_status()
  def line_status(%Decimal{} = quantity, %Decimal{} = fulfilled, cancelled?) do
    cond do
      Decimal.compare(fulfilled, quantity) != :lt -> :fulfilled
      Decimal.compare(fulfilled, 0) == :gt -> :partial
      cancelled? -> :cancelled
      true -> :open
    end
  end

  @doc """
  Status of a request from its lines, each `%{quantity: Decimal, fulfilled: Decimal, cancelled?: boolean}`.
  An empty list has no status.
  """
  @spec request_status([map()]) :: request_status()
  def request_status([]), do: nil

  def request_status(lines) when is_list(lines) do
    statuses = Enum.map(lines, &line_status(&1.quantity, &1.fulfilled, &1.cancelled?))

    cond do
      Enum.all?(statuses, &(&1 == :cancelled)) -> :cancelled
      Enum.zip(statuses, lines) |> Enum.all?(&settled?/1) -> :closed
      Enum.any?(lines, &(Decimal.compare(&1.fulfilled, 0) == :gt)) -> :partial
      true -> nil
    end
  end

  defp settled?({:fulfilled, _line}), do: true
  defp settled?({_status, line}), do: line.cancelled?
end
