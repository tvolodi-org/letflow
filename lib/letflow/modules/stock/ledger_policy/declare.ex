defmodule Letflow.Modules.Stock.LedgerPolicy do
  @moduledoc """
  REQ-687 / GH #3707 (slice L4, decision 0073 note 14.4): the pure posting policy of module `stock`.
  `declare/2` turns a stock posting command into a declarative posting. It uses `Letflow.Ledger.Policy`
  and a few stdlib modules only (the allowlist scan of `mix letflow.check_boundaries`).

  Command keys (atom keys): `cause`, `lines`, `document_type`, `document_id`, `related_document_id`,
  `correlation_id`, `reason_code`. Every other key is ignored, `event_time` included: the event time of an entry is the
  core's `client_event_time` rule (the posting time when online), not a policy field. The exception is
  cause `opening` (REQ-726): it has NO event time from the client, so a non-nil `event_time`,
  `client_event_time`, `device_id` or `client_seq` on an opening command is refused (leg 1). A line has
  `line_id`, `sku`, `lot`, `unit`, `quantity`, `from` and `to`; `from` and `to` are maps of
  `org_unit`, `location` and `responsible`.

  | cause | `from` | `to` | legs per line |
  |---|---|---|---|
  | receipt, opening | absent | required | `+q` at `to` |
  | issue, write_off | required | absent | `-q` at `from` |
  | transfer, hand_over, return | required | required, different from `from` in org_unit, location or responsible | `-q` at `from`, `+q` at `to` |
  | count_difference (REQ-718) | exactly one of the two | exactly one of the two | `+q` at `to` or `-q` at `from`; up to 200 lines (REQ-718) |

  The two legs of a line come from one `sku`, `lot`, `unit` and `quantity`: that keeps the lot and unit
  conservation that the sign rule `zero_sum_by_slot_1` (per sku) does not check. The key is
  `[sku, location, org_unit, responsible, lot]` (absent responsible and lot are empty text).

  A `reversal` (REQ-713) takes `reverses_entry_id` (uuid) and `reason_code`, no lines, and returns a
  posting with no legs; the core negates the target's legs. `cause: "reversal"` with lines is refused.
  The line `unit` is a token of at most 64 bytes (a uom uuid is 36).

  The refusal is always `{:error, {:invalid_posting, %{leg_no: n}}}`, `n` the number of the first leg the
  bad line would produce; no reason, key or value is returned. Whole-command faults give 1; more than
  1000 lines give the first leg of line 1001 (leg 2001 for a two-leg line; REQ-774: the core cap is 2000
  legs). A `count_difference` keeps its own 200 lines, so 201 lines give leg 201. Assumption, owner may change at GATE B: the seven causes.
  """

  @behaviour Letflow.Ledger.Policy

  alias Letflow.Ledger.Policy

  @max_lines 1000
  @max_count_lines 200
  @one_leg %{
    "receipt" => :to,
    "opening" => :to,
    "issue" => :from,
    "write_off" => :from,
    "count_difference" => :either
  }
  @client_time_keys [:event_time, :client_event_time, :device_id, :client_seq]
  @two_leg ~w(transfer hand_over return)
  @header [:reason_code, :document_type, :document_id, :related_document_id, :correlation_id]

  @impl Letflow.Ledger.Policy
  def declare(command, _registration) when is_map(command) do
    if Map.get(command, :cause) == "reversal", do: reversal(command), else: ordinary(command)
  end

  def declare(_command, _registration), do: invalid(1)

  # REQ-713: a reversal carries the target entry and a reason code and NO lines; the core negates
  # the legs (`Letflow.Ledger.Validate.reversal_posting/2`). A reversal with lines is refused.
  defp reversal(command) do
    lines = Map.get(command, :lines)

    with true <- lines in [nil, []],
         {:ok, target} <- ok(Policy.uuid(Map.get(command, :reverses_entry_id))),
         reason when is_binary(reason) <- Map.get(command, :reason_code) do
      header =
        command
        |> Map.take(@header)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok,
       Policy.posting(
         Map.merge(header, %{
           ledger_id: "stock",
           cause: "reversal",
           legs: [],
           reverses_entry_id: target,
           reason_code: reason
         })
       )}
    else
      _ -> invalid(1)
    end
  end

  defp ordinary(command) do
    with {:ok, cause, width} <- cause(Map.get(command, :cause)),
         :ok <- no_client_time(cause, command),
         {:ok, lines} <- lines(cause, Map.get(command, :lines), width),
         {:ok, legs} <- build(cause, lines, width) do
      header =
        command
        |> Map.take(@header)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, Policy.posting(Map.merge(header, %{ledger_id: "stock", cause: cause, legs: legs}))}
    end
  end

  # REQ-726: an opening carries no event time from the client (decision 0079 D1).
  defp no_client_time("opening", command) do
    if Enum.all?(@client_time_keys, &is_nil(Map.get(command, &1))), do: :ok, else: invalid(1)
  end

  defp no_client_time(_cause, _command), do: :ok

  defp cause(cause) when is_binary(cause) do
    cond do
      Map.has_key?(@one_leg, cause) -> {:ok, cause, 1}
      cause in @two_leg -> {:ok, cause, 2}
      true -> invalid(1)
    end
  end

  defp cause(_other), do: invalid(1)

  defp lines(cause, [_ | _] = lines, width) do
    max = if cause == "count_difference", do: @max_count_lines, else: @max_lines
    if length(lines) > max, do: invalid(max * width + 1), else: {:ok, lines}
  end

  defp lines(_cause, _other, _width), do: invalid(1)

  defp build(cause, lines, width) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      case line(cause, line) do
        {:ok, legs} -> {:cont, {:ok, [legs | acc]}}
        :error -> {:halt, invalid(index * width + 1)}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp line(cause, line) when is_map(line) do
    with {:ok, line_id} <- ok(Policy.uuid(Map.get(line, :line_id))),
         {:ok, sku} <- ok(Policy.uuid(Map.get(line, :sku))),
         {:ok, lot} <- optional_uuid(Map.get(line, :lot)),
         {:ok, unit} <- ok(Policy.token(Map.get(line, :unit), 64)),
         {:ok, quantity} <- quantity(Map.get(line, :quantity)),
         {:ok, from, to} <- sides(cause, Map.get(line, :from), Map.get(line, :to)) do
      base = %{sku: sku, lot: lot, unit: unit, quantity: quantity, line_id: line_id}
      {:ok, legs(cause, base, from, to)}
    end
  end

  defp line(_cause, _line), do: :error

  defp legs(cause, base, _from, to) when cause in ["receipt", "opening"],
    do: [leg(base, to, false)]

  defp legs(cause, base, from, _to) when cause in ["issue", "write_off"],
    do: [leg(base, from, true)]

  # REQ-718: a surplus line has a `to` side (+q), a shortage line a `from` side (-q).
  defp legs("count_difference", base, nil, to), do: [leg(base, to, false)]
  defp legs("count_difference", base, from, nil), do: [leg(base, from, true)]

  defp legs(_cause, base, from, to), do: [leg(base, from, true), leg(base, to, false)]

  defp leg(base, side, negate?) do
    quantity = if negate?, do: Decimal.negate(base.quantity), else: base.quantity

    Policy.leg(%{
      k: [base.sku, side.location, side.org_unit, side.responsible || "", base.lot || ""],
      quantity: quantity,
      unit_ref: base.unit,
      document_line_id: base.line_id
    })
  end

  defp quantity(text) do
    with {:ok, value} <- ok(Policy.decimal(text, 9)),
         true <- Decimal.gt?(value, 0) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  # receipt, opening: no from, to required. issue/write_off: from required, no to. Two-leg: both, equal.
  defp sides(cause, from, to) when cause in ["receipt", "opening"] and is_nil(from) do
    with {:ok, to} <- side(to), do: {:ok, nil, to}
  end

  defp sides(cause, from, to) when cause in ["issue", "write_off"] and is_nil(to) do
    with {:ok, from} <- side(from), do: {:ok, from, nil}
  end

  # REQ-718: exactly one of the two sides (both or neither is the leg-number refusal).
  defp sides("count_difference", from, to) when is_nil(from) != is_nil(to) do
    if is_nil(from) do
      with {:ok, to} <- side(to), do: {:ok, nil, to}
    else
      with {:ok, from} <- side(from), do: {:ok, from, nil}
    end
  end

  defp sides(cause, from, to) when cause in @two_leg do
    with {:ok, from} <- side(from),
         {:ok, to} <- side(to),
         true <- from != to do
      {:ok, from, to}
    else
      _ -> :error
    end
  end

  defp sides(_cause, _from, _to), do: :error

  defp side(%{} = side) do
    with {:ok, org_unit} <- ok(Policy.uuid(Map.get(side, :org_unit))),
         {:ok, location} <- ok(Policy.uuid(Map.get(side, :location))),
         {:ok, responsible} <- optional_uuid(Map.get(side, :responsible)) do
      {:ok, %{org_unit: org_unit, location: location, responsible: responsible}}
    end
  end

  defp side(_other), do: :error

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: ok(Policy.uuid(value))

  defp ok({:ok, value}), do: {:ok, value}
  defp ok(_other), do: :error

  defp invalid(leg_no), do: {:error, {:invalid_posting, %{leg_no: leg_no}}}
end
