defmodule Letflow.Modules.FixtureLedger.Handlers do
  @moduledoc """
  Handler functions of `Letflow.Modules.FixtureLedger` (GH #2590 R1). Inert
  stubs: they only check their arguments and return the Multi unchanged.
  Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, :invalid_arguments}`.
  No `Repo`, no `Records`: nothing here writes.
  """

  @spec post_entry(Ecto.Multi.t(), term(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments}
  def post_entry(multi, _ctx, %{"item" => item, "quantity" => quantity})
      when is_binary(item) and is_integer(quantity),
      do: {:ok, multi}

  def post_entry(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  @spec post_balance_only(Ecto.Multi.t(), term(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments}
  def post_balance_only(multi, _ctx, %{"item" => item}) when is_binary(item), do: {:ok, multi}
  def post_balance_only(_multi, _ctx, _args), do: {:error, :invalid_arguments}
end
