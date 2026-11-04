defmodule Letflow.Modules.FixtureLedgerPost.Handlers do
  @moduledoc """
  Handler functions of `Letflow.Modules.FixtureLedgerPost` (REQ-684). `post_alpha` and `post_beta`
  are the handlers that register `posts_ledger`; until `HandlerWrites.post/3` exists (slice L3b) they
  write only their bookkeeping row through `Letflow.Entities.HandlerWrites.create/3`, like `plain`.
  Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, :invalid_arguments | :not_permitted}`.
  The platform scans (`handler_writes_callers_test.exs`, H4) cover this file.
  """

  alias Letflow.Entities.HandlerWrites

  @spec post_alpha(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_alpha(multi, ctx, args), do: note(multi, ctx, args)

  @spec post_beta(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_beta(multi, ctx, args), do: note(multi, ctx, args)

  @spec plain(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def plain(multi, ctx, args), do: note(multi, ctx, args)

  defp note(multi, ctx, %{"note" => note}) when is_binary(note) do
    case HandlerWrites.create(multi, ctx, %{
           entity_type: "fxlp_note",
           field_values: %{"note" => note}
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  defp note(_multi, _ctx, _args), do: {:error, :invalid_arguments}
end
