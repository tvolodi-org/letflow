defmodule Letflow.Engine.Lua.ScriptValue do
  @moduledoc """
  GH 2534 (decision 0053 D7, F-B, F-D): values crossing the tenant-script boundary.
  Design: `lib/letflow/design/gh2534-7a-script-runtime.md` section 6.

    * `encode/1`: an Elixir input map -> a plain term `Lua.set!/3` turns into tables WITHOUT
      metatables. Unsupported terms are dropped and counted; it never raises.
    * `decode/3`: a RAW VM result (`{:tref, id}` and scalars, from `Lua.VM.execute/2`) ->
      a JSON-safe term. It reads tables only through `Lua.VM.State.get_table/2` and
      `Lua.VM.Table.to_map/1` (raw storage: no `__index`, `__pairs`, `__len` or any other
      metamethod runs), runs under a node / depth / size budget checked at every node, and
      creates no atoms (strings stay binaries). Anything else is `:error` (`output_invalid`).
  """

  alias Lua.VM.State
  alias Lua.VM.Table

  @max_nodes 10_000
  @max_depth 32
  @max_output_bytes 65_536

  @doc "The output byte cap (0053 D7, 64 KiB)."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  # ── encode ─────────────────────────────────────────────────────────────────

  @doc """
  Sanitises `input` for the script: string keys; nil, booleans, integers, finite floats,
  valid UTF-8 strings, lists and string-keyed maps. Returns `{value, dropped_count}`.
  """
  @spec encode(term()) :: {map(), non_neg_integer()}
  def encode(input) when is_map(input) and not is_struct(input) do
    {value, dropped} = encode_map(input)
    {value, dropped}
  end

  def encode(_input), do: {%{}, 1}

  defp encode_map(map) do
    Enum.reduce(map, {%{}, 0}, fn
      {key, value}, {acc, dropped} when is_binary(key) ->
        if String.valid?(key) do
          case encode_value(value) do
            {:ok, encoded, inner_dropped} -> {Map.put(acc, key, encoded), dropped + inner_dropped}
            :drop -> {acc, dropped + 1}
          end
        else
          {acc, dropped + 1}
        end

      _pair, {acc, dropped} ->
        {acc, dropped + 1}
    end)
  end

  defp encode_value(nil), do: {:ok, nil, 0}
  defp encode_value(value) when is_boolean(value), do: {:ok, value, 0}
  defp encode_value(value) when is_integer(value), do: {:ok, value, 0}

  # BEAM floats are always finite.
  defp encode_value(value) when is_float(value), do: {:ok, value, 0}

  defp encode_value(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value, 0}, else: :drop
  end

  defp encode_value(value) when is_list(value) do
    {items, dropped} =
      Enum.reduce(value, {[], 0}, fn item, {acc, dropped} ->
        case encode_value(item) do
          {:ok, encoded, inner} -> {[encoded | acc], dropped + inner}
          :drop -> {acc, dropped + 1}
        end
      end)

    {:ok, Enum.reverse(items), dropped}
  end

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    {map, dropped} = encode_map(value)
    {:ok, map, dropped}
  end

  defp encode_value(_other), do: :drop

  # ── decode ─────────────────────────────────────────────────────────────────

  @doc """
  Decodes the script's first return value. `nil` is the empty map. Returns `{:ok, term}`
  (a map or a list) or `:error`.
  """
  @spec decode(term(), State.t()) :: {:ok, map() | list()} | :error
  def decode(nil, _state), do: {:ok, %{}}

  def decode({:tref, _} = ref, state) do
    budget = %{nodes: 0, bytes: 0}

    with {:ok, value, _budget} <- decode_table(ref, state, MapSet.new(), 1, budget),
         {:ok, json} <- Jason.encode(value),
         true <- byte_size(json) <= @max_output_bytes do
      {:ok, value}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def decode(_other, _state), do: :error

  defp decode_table({:tref, id} = ref, state, path, depth, budget) do
    cond do
      depth > @max_depth ->
        :error

      MapSet.member?(path, id) ->
        :error

      true ->
        decode_entries(
          Table.to_map(State.get_table(state, ref)),
          state,
          MapSet.put(path, id),
          depth,
          budget
        )
    end
  end

  defp decode_entries(entries, state, path, depth, budget) do
    keys = Map.keys(entries)

    cond do
      keys == [] ->
        {:ok, %{}, budget}

      Enum.all?(keys, &is_binary/1) and Enum.all?(keys, &String.valid?/1) ->
        decode_pairs(Enum.sort(keys), entries, state, path, depth, budget, %{})

      list_keys?(keys) ->
        decode_list(1, length(keys), entries, state, path, depth, budget, [])

      true ->
        :error
    end
  end

  defp list_keys?(keys) do
    n = length(keys)
    Enum.all?(keys, &is_integer/1) and Enum.min(keys) == 1 and Enum.max(keys) == n
  end

  defp decode_pairs([], _entries, _state, _path, _depth, budget, acc), do: {:ok, acc, budget}

  defp decode_pairs([key | rest], entries, state, path, depth, budget, acc) do
    with {:ok, budget} <- charge(budget, byte_size(key) + 4),
         {:ok, value, budget} <-
           decode_value(Map.fetch!(entries, key), state, path, depth, budget) do
      decode_pairs(rest, entries, state, path, depth, budget, Map.put(acc, key, value))
    end
  end

  defp decode_list(i, n, _entries, _state, _path, _depth, budget, acc) when i > n,
    do: {:ok, Enum.reverse(acc), budget}

  defp decode_list(i, n, entries, state, path, depth, budget, acc) do
    with {:ok, budget} <- charge(budget, 1),
         {:ok, value, budget} <- decode_value(Map.fetch!(entries, i), state, path, depth, budget) do
      decode_list(i + 1, n, entries, state, path, depth, budget, [value | acc])
    end
  end

  defp decode_value(nil, _state, _path, _depth, budget), do: with_charge(nil, budget, 4)

  defp decode_value(value, _state, _path, _depth, budget) when is_boolean(value),
    do: with_charge(value, budget, 5)

  defp decode_value(value, _state, _path, _depth, budget) when is_integer(value),
    do: with_charge(value, budget, 20)

  # BEAM floats are always finite (the VM's math.huge is 1.0e308; NaN is the atom :nan,
  # rejected below as an unknown value).
  defp decode_value(value, _state, _path, _depth, budget) when is_float(value),
    do: with_charge(value, budget, 24)

  defp decode_value(value, _state, _path, _depth, budget) when is_binary(value) do
    if String.valid?(value), do: with_charge(value, budget, byte_size(value) + 2), else: :error
  end

  defp decode_value({:tref, _} = ref, state, path, depth, budget) do
    with {:ok, budget} <- charge(budget, 2) do
      decode_table(ref, state, path, depth + 1, budget)
    end
  end

  # functions ({:native_func, _}, {:lua_closure, ...}, {:compiled_closure, ...}),
  # userdata ({:udref, _}) and anything else
  defp decode_value(_other, _state, _path, _depth, _budget), do: :error

  defp with_charge(value, budget, bytes) do
    with {:ok, budget} <- charge(budget, bytes), do: {:ok, value, budget}
  end

  defp charge(%{nodes: nodes, bytes: bytes}, add) do
    nodes = nodes + 1
    bytes = bytes + add

    if nodes > @max_nodes or bytes > @max_output_bytes,
      do: :error,
      else: {:ok, %{nodes: nodes, bytes: bytes}}
  end
end
