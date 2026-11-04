defmodule Letflow.Modules.Stock.LedgerPolicy do
  @moduledoc """
  REQ-687 / GH #3707 (slice L4, decision 0073 note 14.4): the pure posting policy of module `stock`.
  `declare/2` turns a stock posting command into a declarative posting. It uses `Letflow.Ledger.Policy`
  and a few stdlib modules only (the allowlist scan of `mix letflow.check_boundaries`).

  Command keys (atom keys): `cause`, `lines`, `document_type`, `document_id`, `correlation_id`,
  `reason_code`. Every other key is ignored, `event_time` included: the event time of an entry is the
  core's `client_event_time` rule (the posting time when online), not a policy field. A line has
  `line_id`, `sku`, `lot`, `unit`, `quantity`, `from` and `to`; `from` and `to` are maps of
  `org_unit`, `location` and `responsible`.

  | cause | `from` | `to` | legs per line |
  |---|---|---|---|
  | receipt | absent | required | `+q` at `to` |
  | issue, write_off | required | absent | `-q` at `from` |
  | transfer, hand_over, return | required | required, different from `from` in org_unit, location or responsible | `-q` at `from`, `+q` at `to` |

  The two legs of a line come from one `sku`, `lot`, `unit` and `quantity`: that keeps the lot and unit
  conservation that the sign rule `zero_sum_by_slot_1` (per sku) does not check. The key is
  `[sku, location, org_unit, responsible, lot]` (absent responsible and lot are empty text).

  The refusal is always `{:error, {:invalid_posting, %{leg_no: n}}}`, `n` the number of the first leg the
  bad line would produce; no reason, key or value is returned. Whole-command faults give 1; more than
  100 lines give the first leg of line 101. Assumption, owner may change at GATE B: the six causes.
  """

  @behaviour Letflow.Ledger.Policy

  alias Letflow.Ledger.Policy

  @max_lines 100
  @one_leg %{"receipt" => :to, "issue" => :from, "write_off" => :from}
  @two_leg ~w(transfer hand_over return)
  @header [:reason_code, :document_type, :document_id, :correlation_id]

  @impl Letflow.Ledger.Policy
  def declare(command, _registration) when is_map(command) do
    with {:ok, cause, width} <- cause(Map.get(command, :cause)),
         {:ok, lines} <- lines(Map.get(command, :lines), width),
         {:ok, legs} <- build(cause, lines, width) do
      header =
        command
        |> Map.take(@header)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, Policy.posting(Map.merge(header, %{ledger_id: "stock", cause: cause, legs: legs}))}
    end
  end

  def declare(_command, _registration), do: invalid(1)

  defp cause(cause) when is_binary(cause) do
    cond do
      Map.has_key?(@one_leg, cause) -> {:ok, cause, 1}
      cause in @two_leg -> {:ok, cause, 2}
      true -> invalid(1)
    end
  end

  defp cause(_other), do: invalid(1)

  defp lines([_ | _] = lines, width) do
    if length(lines) > @max_lines, do: invalid(@max_lines * width + 1), else: {:ok, lines}
  end

  defp lines(_other, _width), do: invalid(1)

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
         {:ok, unit} <- ok(Policy.token(Map.get(line, :unit), 32)),
         {:ok, quantity} <- quantity(Map.get(line, :quantity)),
         {:ok, from, to} <- sides(cause, Map.get(line, :from), Map.get(line, :to)) do
      base = %{sku: sku, lot: lot, unit: unit, quantity: quantity, line_id: line_id}
      {:ok, legs(cause, base, from, to)}
    end
  end

  defp line(_cause, _line), do: :error

  defp legs(cause, base, _from, to) when cause == "receipt", do: [leg(base, to, false)]

  defp legs(cause, base, from, _to) when cause in ["issue", "write_off"],
    do: [leg(base, from, true)]

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

  # receipt: no from, to required. issue/write_off: from required, no to. Two-leg: both, equal.
  defp sides("receipt", from, to) when is_nil(from) do
    with {:ok, to} <- side(to), do: {:ok, nil, to}
  end

  defp sides(cause, from, to) when cause in ["issue", "write_off"] and is_nil(to) do
    with {:ok, from} <- side(from), do: {:ok, from, nil}
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
