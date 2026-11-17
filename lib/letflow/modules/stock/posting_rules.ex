defmodule Letflow.Modules.Stock.PostingRules do
  @moduledoc """
  REQ-836 (decision 0090): the one place where module stock asks whether the tenant allows a balance
  below zero. It reads the core setting (`Letflow.Ledger.negative_balances_allowed?/3`) with the
  caller's tenant prefix only (INV-1), against the module's own `stock` ledger registration, so a
  registration that stops declaring `:tenant_setting` answers refuse here too. No cache: every call
  is one bound-parameter read.
  """

  alias Letflow.Ledger

  @ledger "stock"

  @doc "True when the tenant schema `prefix` allows negative stock balances."
  @spec negative_allowed?(String.t()) :: boolean()
  def negative_allowed?(prefix) when is_binary(prefix) do
    registration = Letflow.Modules.Stock.manifest() |> Map.fetch!(:ledger) |> Map.fetch!(@ledger)
    Ledger.negative_balances_allowed?(prefix, @ledger, registration)
  end
end
