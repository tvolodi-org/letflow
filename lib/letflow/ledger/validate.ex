defmodule Letflow.Ledger.Validate do
  @moduledoc """
  REQ-621 / GH #3469 part A: the pure validation of a declarative posting (note gh2657 section 9.1,
  7.1 steps 3 and 4). It cannot query: `Letflow.Ledger.post/1` calls it before it takes any lock,
  so a refusal here leaves the database untouched.

  A refusal is `{:error, {:ledger_refused, code, wire_code, details}}` where the wire code equals
  the neutral core code (the capability carries no aliases). `invalid_posting` details hold only
  `leg_no` (or nil) and a reason from the closed enum `t:reason/0`; no value is echoed.

  Part C (offline fields): `device_id`, `client_seq` and `client_event_time` are read from the raw
  command only. A posting that carries them, or an `event_time`, is `:posting_shape` (the posting is
  the server-derived declaration; the client never sets the event time directly). The client time is
  an ISO 8601 string with an offset (or a `DateTime`), year 2000..2100.

  Reversal (REQ-637 part A): a posting with cause `reversal` or a `reverses_entry_id` is a reversal.
  It carries no legs (the engine derives them from the target), needs a `reason_code`
  (`:reason_required`), and its target id must be a UUID: a malformed id is refused exactly as an
  unknown one (`validation_failed` / `movement_not_found`, one body for every unreadable target).
  The normalised posting has `reversal: true`, `sign_rule` `"reversal"`, `legs: []`.
  """

  @type reason ::
          :reason_required
          | :offline_fields_incomplete
          | :device_id_invalid
          | :client_seq_invalid
          | :client_event_time_invalid
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

  @device_id ~r/\A[A-Za-z0-9._:-]+\z/
  @max_client_seq 9_223_372_036_854_775_807

  @text_fields [reason_code: 64, document_type: 128, document_id: 128, related_document_id: 128]

  @reasons [
    :reason_required,
    :offline_fields_incomplete,
    :device_id_invalid,
    :client_seq_invalid,
    :client_event_time_invalid,
    :unknown_cause,
    :no_legs,
    :too_many_legs,
    :quantity_invalid,
    :quantity_scale,
    :quantity_zero,
    :quantity_range,
    :k1_empty,
    :slot_invalid,
    :unit_invalid,
    :unit_not_allowed,
    :sign_mismatch,
    :ledger_id_invalid,
    :client_op_id_invalid,
    :text_field,
    :attrs_invalid,
    :posting_shape
  ]

  @future_seconds 300

  @doc "The closed set of `invalid_posting` reasons (kept in step with `reason/0` by a test)."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  The event-time window of a posting (REQ-621, moved here by REQ-685 so the build-time check and
  the run-time check under the counter lock use ONE function): not later than 300 s after the
  posting time, not older than the registration's lateness allowance. Pure.
  """
  @spec check_event_window(DateTime.t(), DateTime.t(), map()) ::
          :ok | {:error, {:ledger_refused, atom(), String.t(), map()}}
  def check_event_window(event_time, posting_time, registration) do
    oldest = DateTime.add(posting_time, -registration.max_event_lateness_hours * 3600, :second)
    newest = DateTime.add(posting_time, @future_seconds, :second)

    cond do
      DateTime.compare(event_time, newest) == :gt -> refuse(:event_time_in_future, %{})
      DateTime.compare(event_time, oldest) == :lt -> refuse(:event_time_too_old, %{})
      true -> :ok
    end
  end

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
         :ok <- check_unavailable(posting),
         {:ok, offline} <- check_offline(command) do
      if reversal?(posting),
        do: reversal_posting(posting, offline),
        else: ordinary_posting(posting, offline, registration)
    end
  end

  defp reversal?(posting),
    do: posting.cause == "reversal" or Map.get(posting, :reverses_entry_id) != nil

  # The target is resolved by `Letflow.Ledger` (it needs a read); here only the shape.
  defp reversal_posting(posting, offline) do
    target = Map.get(posting, :reverses_entry_id)

    with :ok <- check_reversal_shape(posting, target),
         :ok <- check_reason(Map.get(posting, :reason_code)),
         :ok <- check_text(posting),
         {:ok, target_id} <- cast_target(target) do
      {:ok,
       %{
         ledger_id: posting.ledger_id,
         cause: "reversal",
         sign_rule: "reversal",
         reversal: true,
         reverses_entry_id: target_id,
         legs: [],
         reason_code: Map.get(posting, :reason_code),
         document_type: Map.get(posting, :document_type),
         document_id: Map.get(posting, :document_id),
         related_document_id: Map.get(posting, :related_document_id),
         correlation_id: Map.get(posting, :correlation_id),
         scope_ref: Map.get(posting, :scope_ref),
         device_id: offline.device_id,
         client_seq: offline.client_seq,
         client_event_time: offline.client_event_time
       }}
    end
  end

  defp check_reversal_shape(posting, target) do
    if posting.cause == "reversal" and target != nil and posting.legs == [],
      do: :ok,
      else: invalid(:posting_shape)
  end

  defp check_reason(reason) when is_binary(reason) and reason != "", do: :ok
  defp check_reason(_reason), do: invalid(:reason_required)

  defp cast_target(target) when is_binary(target) do
    case Ecto.UUID.cast(target) do
      {:ok, id} -> {:ok, id}
      :error -> movement_not_found()
    end
  end

  defp cast_target(_target), do: movement_not_found()

  @doc "The one refusal for an unreadable reversal target (unknown, malformed, other ledger or tenant)."
  @spec movement_not_found() :: {:error, {:ledger_refused, atom(), String.t(), map()}}
  def movement_not_found, do: refuse(:validation_failed, %{reason: "movement_not_found"})

  defp ordinary_posting(posting, offline, registration) do
    with {:ok, cause} <- check_cause(posting.cause, registration),
         {:ok, legs} <- check_legs(posting.legs, registration),
         :ok <- check_text(posting),
         :ok <- check_sign(cause.sign_rule, legs) do
      {:ok,
       %{
         ledger_id: posting.ledger_id,
         cause: posting.cause,
         sign_rule: Atom.to_string(cause.sign_rule),
         reversal: false,
         reverses_entry_id: nil,
         legs: legs,
         reason_code: Map.get(posting, :reason_code),
         document_type: Map.get(posting, :document_type),
         document_id: Map.get(posting, :document_id),
         related_document_id: Map.get(posting, :related_document_id),
         correlation_id: Map.get(posting, :correlation_id),
         scope_ref: Map.get(posting, :scope_ref),
         device_id: offline.device_id,
         client_seq: offline.client_seq,
         client_event_time: offline.client_event_time
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
        if byte_size(id) in 1..128 and String.valid?(id) and not Regex.match?(@control, id) and
             not String.starts_with?(id, "sys:"),
           do: :ok,
           else: invalid(:client_op_id_invalid)

      _ ->
        invalid(:client_op_id_invalid)
    end
  end

  defp check_unavailable(posting) do
    offline = [:device_id, :client_seq, :client_event_time, :event_time]

    cond do
      Enum.any?(offline, &(Map.get(posting, &1) != nil)) ->
        invalid(:posting_shape)

      true ->
        :ok
    end
  end

  # The offline triple comes from the raw command; all nil for an online command.
  defp check_offline(command) do
    device = Map.get(command, :device_id)
    seq = Map.get(command, :client_seq)
    time = Map.get(command, :client_event_time)

    cond do
      device == nil and seq == nil and time == nil ->
        {:ok, %{device_id: nil, client_seq: nil, client_event_time: nil}}

      device == nil or seq == nil ->
        invalid(:offline_fields_incomplete)

      not (is_binary(device) and byte_size(device) in 1..64 and Regex.match?(@device_id, device)) ->
        invalid(:device_id_invalid)

      not (is_integer(seq) and seq in 0..@max_client_seq) ->
        invalid(:client_seq_invalid)

      time == nil ->
        {:ok, %{device_id: device, client_seq: seq, client_event_time: nil}}

      true ->
        with {:ok, dt} <- parse_client_time(time),
             do: {:ok, %{device_id: device, client_seq: seq, client_event_time: dt}}
    end
  end

  defp parse_client_time(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, dt, _offset} -> normalise_time(dt)
      {:error, _} -> invalid(:client_event_time_invalid)
    end
  end

  defp parse_client_time(%DateTime{} = dt), do: normalise_time(dt)
  defp parse_client_time(_other), do: invalid(:client_event_time_invalid)

  defp normalise_time(%DateTime{} = dt) do
    utc = dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond)

    if utc.year in 2000..2100,
      do: {:ok, utc},
      else: invalid(:client_event_time_invalid)
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
