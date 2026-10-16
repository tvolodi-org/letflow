defmodule Letflow.Modules.FixtureLedger.Handlers do
  @moduledoc """
  Handler functions of `Letflow.Modules.FixtureLedger` (GH #2590 R1; real writes since R4a).
  Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, :invalid_arguments | :not_permitted}`.

  They write ONLY through `Letflow.Entities.HandlerWrites.create/3` (no `Repo`, no `Records`,
  no `Owner`): `post_entry` appends a `fxl_ledger` row and a `fxl_balance` row,
  `post_balance_only` a `fxl_balance` row. Pure argument checking is their only logic. The
  platform scans (`handler_writes_callers_test.exs`, H4) cover this file.
  """

  alias Letflow.Entities.HandlerWrites

  @spec post_entry(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_entry(multi, ctx, %{"item" => item, "quantity" => quantity})
      when is_binary(item) and is_integer(quantity) do
    values = %{"item" => item, "quantity" => quantity}

    with {:ok, multi} <-
           HandlerWrites.create(multi, ctx, %{entity_type: "fxl_ledger", field_values: values}),
         {:ok, multi} <-
           HandlerWrites.create(multi, ctx, %{entity_type: "fxl_balance", field_values: values}) do
      {:ok, multi}
    else
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  def post_entry(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  @spec post_balance_only(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_balance_only(multi, ctx, %{"item" => item}) when is_binary(item) do
    case HandlerWrites.create(multi, ctx, %{
           entity_type: "fxl_balance",
           field_values: %{"item" => item}
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  def post_balance_only(_multi, _ctx, _args), do: {:error, :invalid_arguments}
end
