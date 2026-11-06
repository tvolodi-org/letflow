defmodule Letflow.Modules.Assets.Handlers do
  @moduledoc """
  GH #3890 / REQ-752 (assets C10): the write handlers of module `assets`, called from the
  `module_writes` line of the HUMAN_TASK nodes of the process definitions `assets_commission`
  (`post_document`) and `assets_reversal` (`reverse_document`). Each does exactly two things in the
  completion transaction of the task: one `Letflow.Entities.HandlerWrites.create/3` of the
  bookkeeping record `assets_posting_mark`, and one `Letflow.Entities.HandlerWrites.post/3` of the
  posting. Mirrors `Letflow.Modules.Stock.Handlers`.

  Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, :invalid_arguments | :not_permitted}`.
  The handler reads nothing and trusts only its arguments (the binding of the posting to the issued
  content is by workflow order and detection on read, decision 0078 D5; the gap is stated in the
  runbook until slice L7). The posting command is rebuilt here from LITERAL keys of the string-keyed
  `posting` argument (no `String.to_atom`, scans H4); `ledger_id` is always `"assets"`, and a
  `prefix`, `subject_id` or `credential` in the arguments is never copied: the platform fills them
  from the context. `post_document` accepts only the cause `commission` (C11 widens it),
  `reverse_document` only `reversal`.

  A second mark of the same kind for one document violates the unique constraint of the mark type,
  so the completion rolls back before any ledger write.
  """

  alias Letflow.Entities.HandlerWrites

  @type result :: {:ok, Ecto.Multi.t()} | {:error, :invalid_arguments | :not_permitted}

  @spec post_document(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def post_document(multi, ctx, %{"posting" => %{"cause" => "commission"}} = args),
    do: run(multi, ctx, args, "posted", [])

  def post_document(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  @spec reverse_document(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def reverse_document(multi, ctx, %{"posting" => %{"cause" => "reversal"}} = args),
    do: run(multi, ctx, args, "reversed", ["reason_code"])

  def reverse_document(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  defp run(multi, ctx, args, mark, extra_keys) when is_map(args) do
    with true <- valid_args?(args, {mark, extra_keys}),
         {:ok, command} <- command(Map.get(args, "posting")),
         {:ok, multi} <- create_mark(multi, ctx, args, extra_keys) do
      case HandlerWrites.post(multi, ctx, command) do
        {:ok, multi} -> {:ok, multi}
        {:error, _contract_error} -> {:error, :not_permitted}
      end
    else
      false -> {:error, :invalid_arguments}
      :error -> {:error, :invalid_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp valid_args?(args, {mark, extra_keys}) do
    Enum.all?(~w(document_id document_type org_unit_id) ++ extra_keys, fn key ->
      is_binary(Map.get(args, key))
    end) and is_integer(Map.get(args, "version_no")) and Map.get(args, "mark") == mark and
      is_map(Map.get(args, "posting"))
  end

  defp create_mark(multi, ctx, args, extra_keys) do
    values = %{
      "document_id" => Map.get(args, "document_id"),
      "document_type" => Map.get(args, "document_type"),
      "version_no" => Map.get(args, "version_no"),
      "org_unit_id" => Map.get(args, "org_unit_id"),
      "mark" => Map.get(args, "mark")
    }

    values =
      if "reason_code" in extra_keys,
        do: Map.merge(values, %{"reason_code" => Map.get(args, "reason_code")}),
        else: values

    case HandlerWrites.create(multi, ctx, %{
           entity_type: "assets_posting_mark",
           field_values: values
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  # -- the posting command: literal keys only -----------------------------------------------------

  defp command(%{"cause" => "reversal"} = posting) do
    {:ok,
     %{
       ledger_id: "assets",
       cause: "reversal",
       document_type: Map.get(posting, "document_type"),
       document_id: Map.get(posting, "document_id"),
       client_op_id: Map.get(posting, "client_op_id"),
       reverses_entry_id: Map.get(posting, "reverses_entry_id"),
       reason_code: Map.get(posting, "reason_code")
     }}
  end

  defp command(%{"cause" => "commission", "lines" => lines} = posting) when is_list(lines) do
    with {:ok, lines} <- lines(lines) do
      {:ok,
       %{
         ledger_id: "assets",
         cause: "commission",
         document_type: Map.get(posting, "document_type"),
         document_id: Map.get(posting, "document_id"),
         client_op_id: Map.get(posting, "client_op_id"),
         device_id: Map.get(posting, "device_id"),
         client_seq: Map.get(posting, "client_seq"),
         client_event_time: Map.get(posting, "client_event_time"),
         lines: lines
       }}
    end
  end

  defp command(_other), do: :error

  defp lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case line(line) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp line(%{} = line) do
    {:ok,
     %{
       line_id: Map.get(line, "line_id"),
       asset: Map.get(line, "asset"),
       quantity: Map.get(line, "quantity"),
       to: side(Map.get(line, "to"))
     }}
  end

  defp line(_other), do: :error

  defp side(%{} = side) do
    %{
      org_unit: Map.get(side, "org_unit"),
      location: Map.get(side, "location"),
      material_responsible: Map.get(side, "material_responsible"),
      actual_user: Map.get(side, "actual_user")
    }
  end

  defp side(other), do: other
end
