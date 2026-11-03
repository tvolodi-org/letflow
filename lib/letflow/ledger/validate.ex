defmodule Letflow.Ledger.Validate do
  @moduledoc """
  REQ-621 / GH #3469 part A: the pure validation of a declarative posting (note gh2657 section 9.1,
  7.1 steps 3 and 4). It cannot query: `Letflow.Ledger.post/1` calls it before it takes any lock,
  so a refusal here leaves the database untouched.

  A refusal is `{:error, {:ledger_refused, code, wire_code, details}}` where the wire code equals
  the neutral core code (the capability carries no aliases). `invalid_posting` details hold only
  `leg_no` (or nil) and a reason from the closed enum `t:reason/0`; no value is echoed.

  `offline_fields_not_available`, `event_time_not_available` and `reversal_not_available` name
  what later slices replace (offline fields and event time: part C of REQ-621; reversal: L2b).
  """

  @type reason ::
          :reversal_not_available
          | :offline_fields_not_available
          | :event_time_not_available
          | :unknown_cause
          | :no_legs
          | :too_many_legs
          | :quantity_invalid
          | :quantity_scale
          | :quantity_zero
          | :quantity_range
          | :k1_empty
          | :slot_invalid
          | :unit_invalid
          | :unit_not_allowed
          | :sign_mismatch
          | :ledger_id_invalid
          | :client_op_id_invalid
          | :text_field
          | :attrs_invalid
          | :posting_shape

  @max_legs 200
  @max_abs Decimal.new("1.0E+20")
  @ledger_id ~r/\A[a-z0-9_]{1,32}(:[a-z0-9-]{1,32})?\z/
  @token ~r/\A[a-z0-9._:-]+\z/
  @slot_token ~r/\A[a-z0-9._:-]{0,128}\z/
  @slot_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @control ~r/[\x00-\x1f\x7f]/

  @text_fields [reason_code: 64, document_type: 128, document_id: 128, related_document_id: 128]

  @doc "A typed refusal tuple."
  @spec refuse(atom(), map()) :: {:error, {:ledger_refused, atom(), String.t(), map()}}
  def refuse(code, details), do: {:error, {:ledger_refused, code, Atom.to_string(code), details}}

  defp invalid(reason, leg_no \\ nil),
    do: refuse(:invalid_posting, %{leg_no: leg_no, reason: reason})

  @doc """
  Validates the capability's posting against its registration. Returns the normalised posting:
  `%{ledger_id, cause, sign_rule, legs, reason_code, document_type, document_id,
  related_document_id, correlation_id, scope_ref}` where each leg carries `leg_no`, `k` (exactly
  8 slot texts), `quantity`, `unit_ref`, `attrs`, `document_line_id`.
  """
  @spec posting(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def posting(posting, command, registration) do
    with :ok <- check_shape(posting, command),
         :ok <- check_ledger_id(posting.ledger_id),
         :ok <- check_client_op_id(command),
         :ok <- check_unavailable(posting, command),
         {:ok, cause} <- check_cause(posting.cause, registration),
         {:ok, legs} <- check_legs(posting.legs, registration),
         :ok <- check_text(posting),
         :ok <- check_sign(cause.sign_rule, legs) do
      {:ok,
       %{
         ledger_id: posting.ledger_id,
         cause: posting.cause,
         sign_rule: Atom.to_string(cause.sign_rule),
         legs: legs,
         reason_code: Map.get(posting, :reason_code),
         document_type: Map.get(posting, :document_type),
         document_id: Map.get(posting, :document_id),
         related_document_id: Map.get(posting, :related_document_id),
         correlation_id: Map.get(posting, :correlation_id),
         scope_ref: Map.get(posting, :scope_ref)
       }}
    end
  end

  defp check_shape(%{ledger_id: id, cause: cause, legs: legs}, command)
       when is_binary(id) and is_binary(cause) and is_list(legs) and is_map(command),
       do: :ok

  defp check_shape(_posting, _command), do: invalid(:posting_shape)

  defp check_ledger_id(id) do
    if byte_size(id) <= 64 and Regex.match?(@ledger_id, id),
      do: :ok,
      else: invalid(:ledger_id_invalid)
  end

  defp check_client_op_id(command) do
    case Map.get(command, :client_op_id) do
      id when is_binary(id) ->
        if byte_size(id) in 1..128 and String.valid?(id) and not Regex.match?(@control, id),
          do: :ok,
          else: invalid(:client_op_id_invalid)

      _ ->
        invalid(:client_op_id_invalid)
    end
  end

  defp check_unavailable(posting, command) do
    offline = [:device_id, :client_seq, :client_event_time]

    cond do
      Enum.any?(offline, &(Map.get(posting, &1) != nil or Map.get(command, &1) != nil)) ->
        invalid(:offline_fields_not_available)

      Map.get(posting, :event_time) != nil ->
        invalid(:event_time_not_available)

      posting.cause == "reversal" or Map.get(posting, :reverses_entry_id) != nil ->
        invalid(:reversal_not_available)

      true ->
        :ok
    end
  end

  defp check_cause(name, registration) do
    case registration.causes do
      %{^name => %{sign_rule: rule} = cause}
      when rule in [:positive, :negative, :zero_sum_by_slot_1, :any] ->
        {:ok, cause}

      _ ->
        invalid(:unknown_cause)
    end
  end

  defp check_legs([], _registration), do: invalid(:no_legs)

  defp check_legs(legs, _registration) when length(legs) > @max_legs, do: invalid(:too_many_legs)

  defp check_legs(legs, registration) do
    legs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {leg, n}, {:ok, acc} ->
      case check_leg(leg, n, registration) do
        {:ok, norm} -> {:cont, {:ok, [norm | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check_leg(leg, n, registration) when is_map(leg) do
    with {:ok, quantity} <- check_quantity(Map.get(leg, :quantity), n),
         {:ok, k} <- check_slots(Map.get(leg, :k), n, registration.slots),
         {:ok, unit} <- check_unit(Map.get(leg, :unit_ref), n, Map.get(registration, :units)),
         {:ok, attrs} <- check_attrs(Map.get(leg, :attrs), n),
         {:ok, line_id} <- check_line_id(Map.get(leg, :document_line_id), n) do
      {:ok,
       %{
         leg_no: n,
         k: k,
         quantity: quantity,
         unit_ref: unit,
         attrs: attrs,
         document_line_id: line_id
       }}
    end
  end

  defp check_leg(_leg, n, _registration), do: invalid(:posting_shape, n)

  defp check_quantity(%Decimal{coef: coef} = q, n) when is_integer(coef) do
    normal = Decimal.normalize(q)

    cond do
      Decimal.eq?(q, 0) -> invalid(:quantity_zero, n)
      normal.exp < -9 -> invalid(:quantity_scale, n)
      Decimal.compare(Decimal.abs(q), @max_abs) != :lt -> invalid(:quantity_range, n)
      true -> {:ok, Decimal.round(q, 9)}
    end
  end

  defp check_quantity(_other, n), do: invalid(:quantity_invalid, n)

  defp check_slots(k, n, slots) when is_list(k) and length(k) <= length(slots) do
    padded = k ++ List.duplicate("", 8 - length(k))

    cond do
      not Enum.all?(k, &is_binary/1) ->
        invalid(:slot_invalid, n)

      List.first(padded) == "" ->
        invalid(:k1_empty, n)

      true ->
        slots
        |> Enum.zip(padded)
        |> Enum.reduce_while({:ok, []}, fn {slot, value}, {:ok, acc} ->
          case slot_value(slot, value) do
            {:ok, v} -> {:cont, {:ok, [v | acc]}}
            :error -> {:halt, invalid(:slot_invalid, n)}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc) ++ Enum.drop(padded, length(slots))}
          error -> error
        end
    end
  end

  defp check_slots(k, n, _slots) when is_list(k), do: invalid(:slot_invalid, n)
  defp check_slots(_k, n, _slots), do: invalid(:k1_empty, n)

  defp slot_value(%{required: true}, ""), do: :error
  defp slot_value(_slot, ""), do: {:ok, ""}

  defp slot_value(%{format: :uuid}, value) do
    v = String.downcase(value)
    if String.valid?(v) and Regex.match?(@slot_uuid, v), do: {:ok, v}, else: :error
  end

  defp slot_value(_token_slot, value) do
    if String.valid?(value) and Regex.match?(@slot_token, value), do: {:ok, value}, else: :error
  end

  defp check_unit(unit, n, units) when is_binary(unit) do
    cond do
      byte_size(unit) > 128 or not Regex.match?(@token, unit) -> invalid(:unit_invalid, n)
      is_list(units) and unit not in units -> invalid(:unit_not_allowed, n)
      true -> {:ok, unit}
    end
  end

  defp check_unit(_unit, n, _units), do: invalid(:unit_invalid, n)

  defp check_attrs(nil, _n), do: {:ok, nil}

  defp check_attrs(attrs, n) when is_map(attrs) and not is_struct(attrs) do
    case Jason.encode(attrs) do
      {:ok, json} ->
        if jsonb_text_size(json) <= 4096, do: {:ok, attrs}, else: invalid(:attrs_invalid, n)

      {:error, _} ->
        invalid(:attrs_invalid, n)
    end
  end

  defp check_attrs(_attrs, n), do: invalid(:attrs_invalid, n)

  # `jsonb` text carries a space after each `:` and `,` outside strings; the column CHECK measures
  # that text, so measure it here and never reach the CHECK (INV-8).
  defp jsonb_text_size(json), do: byte_size(json) + separators(json, false, 0)

  defp separators(<<>>, _in_string, count), do: count

  defp separators(<<"\\", _escaped, rest::binary>>, true, count),
    do: separators(rest, true, count)

  defp separators(<<"\"", rest::binary>>, in_string, count),
    do: separators(rest, not in_string, count)

  defp separators(<<c, rest::binary>>, false, count) when c in [?:, ?,],
    do: separators(rest, false, count + 1)

  defp separators(<<_c, rest::binary>>, in_string, count), do: separators(rest, in_string, count)

  defp check_line_id(nil, _n), do: {:ok, nil}

  defp check_line_id(id, n) when is_binary(id),
    do: if(text_ok?(id, 128), do: {:ok, id}, else: invalid(:text_field, n))

  defp check_line_id(_id, n), do: invalid(:text_field, n)

  defp check_text(posting) do
    ok? =
      Enum.all?(@text_fields, fn {field, max} ->
        case Map.get(posting, field) do
          nil -> true
          value when is_binary(value) -> text_ok?(value, max)
          _ -> false
        end
      end) and
        Enum.all?([:correlation_id, :scope_ref], fn field ->
          case Map.get(posting, field) do
            nil -> true
            value when is_binary(value) -> text_ok?(value, 128)
            _ -> false
          end
        end)

    if ok?, do: :ok, else: invalid(:text_field)
  end

  defp text_ok?(value, max),
    do: byte_size(value) <= max and String.valid?(value) and not Regex.match?(@control, value)

  defp check_sign(:positive, legs), do: sign(legs, &Decimal.gt?(&1, 0))
  defp check_sign(:negative, legs), do: sign(legs, &Decimal.lt?(&1, 0))
  defp check_sign(:any, _legs), do: :ok

  defp check_sign(:zero_sum_by_slot_1, legs) do
    off =
      legs
      |> Enum.group_by(fn leg -> hd(leg.k) end, & &1.quantity)
      |> Enum.reject(fn {_k1, qs} ->
        qs |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> Decimal.eq?(0)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if off == [], do: :ok, else: refuse(:posting_not_balanced, %{k1: off})
  end

  defp sign(legs, ok?) do
    case Enum.find(legs, &(not ok?.(&1.quantity))) do
      nil -> :ok
      leg -> invalid(:sign_mismatch, leg.leg_no)
    end
  end
end
