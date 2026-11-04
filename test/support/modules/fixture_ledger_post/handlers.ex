defmodule Letflow.Modules.FixtureLedgerPost.Handlers do
  @moduledoc """
  Handler functions of `Letflow.Modules.FixtureLedgerPost` (REQ-684). `post_alpha` and `post_beta`
  are the handlers that register `posts_ledger`: they write their bookkeeping row through
  `Letflow.Entities.HandlerWrites.create/3` and, when the optional `"posting"` argument is given
  (a string-keyed map: `ledger_id`, `cause`, `document_type`, `document_id`, `client_op_id`,
  `legs` with `k`/`quantity`/`unit_ref`, plus test hooks), one `HandlerWrites.post/3` (REQ-685);
  `"twice"` posts the command a second time in the same call, `"before"` makes that many extra
  `create/3` calls first (write-slot budget tests). `plain` only writes the bookkeeping row.
  Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, :invalid_arguments | :not_permitted}`.
  The platform scans (`handler_writes_callers_test.exs`, H4) cover this file.
  """

  alias Letflow.Entities.HandlerWrites

  @spec post_alpha(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_alpha(multi, ctx, args), do: note_and_post(multi, ctx, args, "fixture_ledger_post")

  @spec post_beta(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def post_beta(multi, ctx, args), do: note_and_post(multi, ctx, args, "fixture_ledger_post:beta")

  @spec plain(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}
  def plain(multi, ctx, args), do: note(multi, ctx, args)

  defp note_and_post(multi, ctx, args, ledger_id) do
    with {:ok, multi} <- extra_notes(multi, ctx, Map.get(args, "before", 0)),
         {:ok, multi} <- note(multi, ctx, args, Map.get(args, "skip_note") == true) do
      case Map.get(args, "posting") do
        posting when is_map(posting) -> post(multi, ctx, posting, ledger_id, args)
        _none -> {:ok, multi}
      end
    end
  end

  defp extra_notes(multi, _ctx, 0), do: {:ok, multi}

  defp extra_notes(multi, ctx, n) when is_integer(n) and n > 0 do
    Enum.reduce_while(1..n, {:ok, multi}, fn _i, {:ok, acc} ->
      case HandlerWrites.create(acc, ctx, %{
             entity_type: "fxlp_note",
             field_values: %{"note" => "x"}
           }) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} -> {:halt, {:error, :not_permitted}}
      end
    end)
  end

  defp post(multi, ctx, posting, ledger_id, args) do
    command = command(posting, {ledger_id, op_id(ctx, ledger_id)})

    with {:ok, multi} <- do_post(multi, ctx, command) do
      if Map.get(args, "twice") == true, do: do_post(multi, ctx, command), else: {:ok, multi}
    end
  end

  defp do_post(multi, ctx, command) do
    case HandlerWrites.post(multi, ctx, command) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  # The command the policy sees: atom keys from the whitelist only, legs rebuilt.
  @keys ~w(ledger_id cause document_type document_id related_document_id client_op_id reason_code
           reverses_entry_id scope_ref client_event_time device_id client_seq prefix subject_id
           credential)a

  @explosions %{
    "raise" => :raise,
    "exit" => :exit,
    "throw" => :throw,
    "other_code" => :other_code,
    "not_a_tuple" => :not_a_tuple,
    "bad_reason" => :bad_reason
  }

  defp command(posting, {ledger_id, op_id}) do
    base =
      for key <- @keys, Map.has_key?(posting, Atom.to_string(key)), into: %{} do
        {key, Map.fetch!(posting, Atom.to_string(key))}
      end

    base = Map.put_new(base, :ledger_id, ledger_id)

    base =
      Map.put_new(
        base,
        :client_op_id,
        op_id
      )

    base =
      case Map.get(posting, "legs") do
        legs when is_list(legs) -> Map.put(base, :legs, Enum.map(legs, &leg/1))
        _ -> Map.put_new(base, :legs, [])
      end

    case Map.get(posting, "explode") do
      nil -> base
      kind -> Map.put(base, :explode, Map.fetch!(@explosions, kind))
    end
  end

  defp op_id(%{origin: {_tag, id}}, ledger_id), do: "op-" <> id <> "-" <> ledger_id

  defp leg(leg) when is_map(leg) do
    %{
      k: Map.get(leg, "k"),
      quantity: Map.get(leg, "quantity"),
      unit_ref: Map.get(leg, "unit_ref")
    }
  end

  defp leg(other), do: other

  defp note(multi, _ctx, args, true) when is_map(args), do: {:ok, multi}
  defp note(multi, ctx, args, false), do: note(multi, ctx, args)

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
