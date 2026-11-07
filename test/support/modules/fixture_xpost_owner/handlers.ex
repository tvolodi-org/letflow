defmodule Letflow.Modules.FixtureXpostOwner.Handlers do
  @moduledoc """
  Handler function of `Letflow.Modules.FixtureXpostOwner` (REQ-758): `post_own` registers
  `posts_ledger`, writes its bookkeeping row through `Letflow.Entities.HandlerWrites.create/3` and,
  when the optional `"posting"` argument is given (string keys: `ledger_id`, `cause`,
  `document_type`, `document_id`, `legs` with `k`/`quantity`/`unit_ref`), one
  `HandlerWrites.post/3`. Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, ...}`.
  The platform scans (`handler_writes_callers_test.exs`, H4) cover this file.
  """

  alias Letflow.Entities.HandlerWrites

  @spec post_own(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_own(multi, ctx, args) do
    with {:ok, multi} <- note(multi, ctx, args) do
      case Map.get(args, "posting") do
        posting when is_map(posting) -> post(multi, ctx, posting)
        _none -> {:ok, multi}
      end
    end
  end

  defp post(multi, ctx, posting) do
    case HandlerWrites.post(multi, ctx, command(posting, ctx)) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  @keys ~w(ledger_id cause document_type document_id related_document_id client_op_id reason_code
           reverses_entry_id scope_ref)a

  defp command(posting, %{origin: {_tag, id}}) do
    base =
      for key <- @keys, Map.has_key?(posting, Atom.to_string(key)), into: %{} do
        {key, Map.fetch!(posting, Atom.to_string(key))}
      end

    base
    |> Map.put_new(:ledger_id, "fixture_xpost_owner")
    |> Map.put_new(:client_op_id, "op-" <> id <> "-fixture_xpost_owner")
    |> Map.put(:legs, Enum.map(List.wrap(Map.get(posting, "legs")), &leg/1))
  end

  defp leg(leg) when is_map(leg) do
    %{
      k: Map.get(leg, "k"),
      quantity: Map.get(leg, "quantity"),
      unit_ref: Map.get(leg, "unit_ref")
    }
  end

  defp leg(other), do: other

  defp note(multi, ctx, %{"note" => note}) when is_binary(note) do
    case HandlerWrites.create(multi, ctx, %{
           entity_type: "fxxp_note",
           field_values: %{"note" => note}
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  defp note(_multi, _ctx, _args), do: {:error, :invalid_arguments}
end
