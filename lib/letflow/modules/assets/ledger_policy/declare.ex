defmodule Letflow.Modules.Assets.LedgerPolicy do
  @moduledoc """
  REQ-749 / GH #3893 (assets phase C, item C8; spec `docs/assets/asset-register.md` section 4 and
  `docs/assets/asset-workflow-documents.md` sections 2 to 5): the pure posting policy of module
  `assets`. `declare/2` turns an asset posting command into a declarative posting. It uses
  `Letflow.Ledger.Policy` and a few stdlib modules only (the allowlist scan of
  `mix letflow.check_boundaries`).

  Command keys (atom keys): `cause`, `lines`, `document_type`, `document_id`, `related_document_id`,
  `correlation_id`, `reason_code`, and `reverses_entry_id` for a reversal. Every other key is ignored.
  (`related_document_id` is not in the REQ-749 list; it is kept because the core posting key set
  accepts it and later documents may need it.) A line has `line_id`, `asset`, `quantity`, `from` and
  `to`; `from` and `to` are maps of `org_unit`, `location`, `material_responsible` and `actual_user`.

  | cause | `from` | `to` | legs per line |
  |---|---|---|---|
  | commission | absent | required | `+q` at `to` |
  | writeoff | required | absent | `-q` at `from` (needs `reason_code`) |
  | change | required | required, same org_unit and location, different responsible or user | `-q` at `from`, `+q` at `to` |
  | handover | required | required, different org_unit or location | `-q` at `from`, `+q` at `to` |

  The two legs of a line come from one `asset` and `quantity`; the sign rule `zero_sum_by_slot_1`
  conserves the quantity per asset. The key of a leg is
  `[asset, org_unit, location, material_responsible, actual_user]` (an absent location or actual
  user is the empty text). The unit is `pcs` on every leg. The quantity is a decimal text above zero
  with no fractional part (`"200"` passes; `"2.5"`, `"2.0"` and `"0"` are refused). The kind of the
  card (one asset per row, location empty for an intangible) is not known here: the documents check it.

  A `reversal` takes `reverses_entry_id` (uuid) and `reason_code`, no lines, and returns a posting
  with no legs; the core negates the target's legs. `cause: "reversal"` with lines is refused.

  The refusal is always `{:error, {:invalid_posting, %{leg_no: n}}}`, `n` the number of the first leg
  the bad line would produce; no reason, key or value is returned. Whole-command faults give 1; more
  than 100 lines give the first leg of line 101 (101 for a one-leg cause, 201 for a two-leg cause).
  Assumption, owner may change at GATE B: the four causes, the unit `pcs`, the 96-hour lateness.
  """

  @behaviour Letflow.Ledger.Policy

  alias Letflow.Ledger.Policy

  @max_lines 100
  @unit "pcs"
  @one_leg %{"commission" => :to, "writeoff" => :from}
  @two_leg ~w(change handover)
  @header [:reason_code, :document_type, :document_id, :related_document_id, :correlation_id]

  @impl Letflow.Ledger.Policy
  def declare(command, _registration) when is_map(command) do
    if Map.get(command, :cause) == "reversal", do: reversal(command), else: ordinary(command)
  end

  def declare(_command, _registration), do: invalid(1)

  defp reversal(command) do
    lines = Map.get(command, :lines)

    with true <- lines in [nil, []],
         {:ok, target} <- ok(Policy.uuid(Map.get(command, :reverses_entry_id))),
         reason when is_binary(reason) <- Map.get(command, :reason_code) do
      {:ok,
       Policy.posting(
         Map.merge(header(command), %{
           ledger_id: "assets",
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
         {:ok, lines} <- lines(Map.get(command, :lines), width),
         {:ok, legs} <- build(cause, command, lines, width) do
      {:ok,
       Policy.posting(
         Map.merge(header(command), %{ledger_id: "assets", cause: cause, legs: legs})
       )}
    end
  end

  defp header(command) do
    command
    |> Map.take(@header)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

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

  defp build(cause, command, lines, width) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      case line(cause, command, line) do
        {:ok, legs} -> {:cont, {:ok, [legs | acc]}}
        :error -> {:halt, invalid(index * width + 1)}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp line(cause, command, line) when is_map(line) do
    with {:ok, line_id} <- ok(Policy.uuid(Map.get(line, :line_id))),
         {:ok, asset} <- ok(Policy.uuid(Map.get(line, :asset))),
         {:ok, quantity} <- quantity(Map.get(line, :quantity)),
         {:ok, from, to} <- sides(cause, Map.get(line, :from), Map.get(line, :to)),
         :ok <- reason(cause, command) do
      base = %{asset: asset, quantity: quantity, line_id: line_id}
      {:ok, legs(cause, base, from, to)}
    end
  end

  defp line(_cause, _command, _line), do: :error

  defp reason("writeoff", command) do
    if is_binary(Map.get(command, :reason_code)), do: :ok, else: :error
  end

  defp reason(_cause, _command), do: :ok

  defp legs("commission", base, _from, to), do: [leg(base, to, false)]
  defp legs("writeoff", base, from, _to), do: [leg(base, from, true)]
  defp legs(_cause, base, from, to), do: [leg(base, from, true), leg(base, to, false)]

  defp leg(base, side, negate?) do
    quantity = if negate?, do: Decimal.negate(base.quantity), else: base.quantity

    Policy.leg(%{
      k: [
        base.asset,
        side.org_unit,
        side.location || "",
        side.material_responsible,
        side.actual_user || ""
      ],
      quantity: quantity,
      unit_ref: @unit,
      document_line_id: base.line_id
    })
  end

  # Scale 0: a fraction digit (also "2.0") is refused.
  defp quantity(text) do
    with {:ok, value} <- ok(Policy.decimal(text, 0)),
         true <- Decimal.gt?(value, 0) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp sides("commission", from, to) when is_nil(from) do
    with {:ok, to} <- side(to), do: {:ok, nil, to}
  end

  defp sides("writeoff", from, to) when is_nil(to) do
    with {:ok, from} <- side(from), do: {:ok, from, nil}
  end

  defp sides(cause, from, to) when cause in @two_leg do
    with {:ok, from} <- side(from),
         {:ok, to} <- side(to),
         true <- two_leg_rule(cause, from, to) do
      {:ok, from, to}
    else
      _ -> :error
    end
  end

  defp sides(_cause, _from, _to), do: :error

  # change: the same place, a different responsible or user. handover: a different place.
  defp two_leg_rule("change", from, to) do
    same_place?(from, to) and
      not (from.material_responsible == to.material_responsible and
             from.actual_user == to.actual_user)
  end

  defp two_leg_rule("handover", from, to), do: not same_place?(from, to)

  defp same_place?(from, to), do: from.org_unit == to.org_unit and from.location == to.location

  defp side(%{} = side) do
    with {:ok, org_unit} <- ok(Policy.uuid(Map.get(side, :org_unit))),
         {:ok, location} <- optional_uuid(Map.get(side, :location)),
         {:ok, responsible} <- ok(Policy.uuid(Map.get(side, :material_responsible))),
         {:ok, user} <- optional_uuid(Map.get(side, :actual_user)) do
      {:ok,
       %{
         org_unit: org_unit,
         location: location,
         material_responsible: responsible,
         actual_user: user
       }}
    end
  end

  defp side(_other), do: :error

  defp optional_uuid(value) when value in [nil, ""], do: {:ok, nil}
  defp optional_uuid(value), do: ok(Policy.uuid(value))

  defp ok({:ok, value}), do: {:ok, value}
  defp ok(_other), do: :error

  defp invalid(leg_no), do: {:error, {:invalid_posting, %{leg_no: leg_no}}}
end
