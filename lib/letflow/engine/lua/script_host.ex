defmodule Letflow.Engine.Lua.ScriptHost do
  @moduledoc """
  GH 2534 (decision 0053 D4, D5 subset, D7, D11): the host side of a tenant-script VM.
  Design: `lib/letflow/design/gh2534-7a-script-runtime.md` sections 2.4 and 5.

  `install/2` is the `:host` function `Letflow.Engine.Lua.Sandbox.new_script/1` calls. It
  installs:

    * `ctx` = `%{now, input, uuid()}`;
    * `fail(code, details)`: validated, stored host-side, then `throw`n with the run's own
      ref, so `pcall` cannot catch it and an `error(...)` string cannot forge it;
    * `print(...)`: a capped per-run buffer, NEVER logged;
    * `math.random` (deterministic, seeded from the run's ids) and a no-op `math.randomseed`;
    * size-checked `table.concat`, `string.format`, `string.gsub` (string replacement only)
      and `string.char`: `lua` 1.0.2 enforces `max_string_bytes` only for `..`,
      `string.rep` and `load`, so these check the result size BEFORE building it.

  Per-run state lives in the WORKER's process dictionary under `{__MODULE__, run_ref, key}`
  (the worker is a fresh process per run). Every host function rescues every exception and
  raises only fixed-text Lua errors; the one exemption is `fail`'s own throw.
  """

  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.Lua.ScriptValue
  alias Lua.VM.State
  alias Lua.VM.Table

  @uuid_namespace "7c5a1e3b-2f4d-5a6b-8c9d-0e1f2a3b4c5d"
  @fail_code_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @fail_details_max_keys 16
  @fail_details_max_string 256
  @print_max_lines 20
  @print_max_line_bytes 256
  @too_large "resulting string too large"

  @typedoc "What `install/2` needs for one run."
  @type run :: %{
          run_ref: reference(),
          ctx: %{
            required(:instance_id) => String.t(),
            required(:node_id) => String.t(),
            required(:token_id) => String.t(),
            required(:now) => DateTime.t()
          },
          input: map(),
          fail_codes: [String.t()] | nil
        }

  @doc "The fixed UUIDv5 namespace of `ctx.uuid()` (0053 D5)."
  @spec uuid_namespace() :: String.t()
  def uuid_namespace, do: @uuid_namespace

  @doc """
  Installs the host globals and host library members into `lua` for `run`. The input's
  dropped-term count is recorded in the run state (`run_state/1`) for the runner's stats.
  """
  @spec install(Lua.t(), run()) :: Lua.t()
  def install(lua, run) do
    {input, dropped} = ScriptValue.encode(run.input)
    put(run, :input_dropped, dropped)
    put(run, :uuid_counter, 0)
    put(run, :print, {[], 0})
    put(run, :rand, :rand.seed_s(:exsss, rand_seed(run.ctx)))

    original_format = library_function(lua, "string", "format")
    original_gsub = library_function(lua, "string", "gsub")
    original_char = library_function(lua, "string", "char")

    lua
    |> Lua.set!(["ctx"], %{
      "now" => DateTime.to_iso8601(run.ctx.now),
      "input" => input
    })
    |> Lua.set!(["ctx", "uuid"], guarded("ctx.uuid", fn _args, l -> {[next_uuid(run)], l} end))
    |> Lua.set!(["fail"], fn args, l -> fail(run, args, l) end)
    |> Lua.set!(["print"], guarded("print", fn args, l -> {print(run, args, l), l} end))
    |> Lua.set!(
      ["math", "random"],
      guarded("math.random", fn args, l -> {random(run, args), l} end)
    )
    |> Lua.set!(["math", "randomseed"], fn _args, l -> {[], l} end)
    |> Lua.set!(["table", "concat"], guarded("table.concat", &concat/2))
    |> Lua.set!(
      ["string", "format"],
      guarded("string.format", fn args, l -> format(args, l, original_format) end)
    )
    |> Lua.set!(
      ["string", "gsub"],
      guarded("string.gsub", fn args, l -> gsub(args, l, original_gsub) end)
    )
    |> Lua.set!(
      ["string", "char"],
      guarded("string.char", fn args, l -> char(args, l, original_char) end)
    )
  end

  @doc "Run-state readers for the runner (worker process only)."
  @spec run_state(reference()) :: %{
          input_dropped: non_neg_integer(),
          prints: [String.t()],
          prints_dropped: non_neg_integer(),
          fail: map() | nil
        }
  def run_state(run_ref) do
    {lines, dropped} = Process.get({__MODULE__, run_ref, :print}, {[], 0})

    %{
      input_dropped: Process.get({__MODULE__, run_ref, :input_dropped}, 0),
      prints: Enum.reverse(lines),
      prints_dropped: dropped,
      fail: Process.get({__MODULE__, run_ref, :fail})
    }
  end

  # ── guarded host functions ─────────────────────────────────────────────────

  # Every host function except `fail` runs inside this guard: any exception becomes the
  # fixed-text Lua error "invalid argument to <name>" (never a host message, module name or
  # value); a "resulting string too large" refusal keeps its own fixed text.
  defp guarded(name, fun) do
    fn args, lua ->
      try do
        fun.(args, lua)
      rescue
        _exception -> {:error, "invalid argument to " <> name, lua}
      catch
        :throw, {:script_too_large, ^name} -> {:error, @too_large, lua}
      end
    end
  end

  defp too_large!(name), do: throw({:script_too_large, name})

  # ── ctx.uuid / math.random (deterministic, 0053 D5) ────────────────────────

  defp next_uuid(run) do
    counter = get(run, :uuid_counter) + 1
    put(run, :uuid_counter, counter)
    %{instance_id: i, node_id: n, token_id: t} = run.ctx
    uuid_v5(@uuid_namespace, i <> ":" <> n <> ":" <> t <> ":" <> Integer.to_string(counter))
  end

  @doc false
  # RFC 9562 UUIDv5 (SHA-1). Public for the determinism test.
  @spec uuid_v5(String.t(), String.t()) :: String.t()
  def uuid_v5(namespace, name) do
    {:ok, ns_bytes} = Ecto.UUID.dump(namespace)
    <<a::48, _v::4, b::12, _var::2, c::62, _rest::binary>> = :crypto.hash(:sha, ns_bytes <> name)
    Ecto.UUID.cast!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  defp rand_seed(%{instance_id: i, node_id: n, token_id: t}) do
    <<a::32, b::32, c::32, _rest::binary>> =
      :crypto.hash(:sha256, i <> ":" <> n <> ":" <> t <> ":rand")

    {a, b, c}
  end

  defp random(run, args) do
    state = get(run, :rand)

    {value, state} =
      case args do
        [] ->
          :rand.uniform_real_s(state)

        [m] when is_integer(m) and m >= 1 ->
          :rand.uniform_s(m, state)

        [m, n] when is_integer(m) and is_integer(n) and m <= n ->
          {x, s} = :rand.uniform_s(n - m + 1, state)
          {m + x - 1, s}
      end

    put(run, :rand, state)
    [value]
  end

  # ── print (never logged, D11 stricter) ─────────────────────────────────────

  defp print(run, args, _lua) do
    {lines, dropped} = get(run, :print)

    if length(lines) >= @print_max_lines do
      put(run, :print, {lines, dropped + 1})
    else
      line =
        args
        |> Enum.map(&scalar_text/1)
        |> Enum.join("\t")
        |> binary_part_utf8(@print_max_line_bytes)

      put(run, :print, {[line | lines], dropped})
    end

    []
  end

  defp scalar_text(value) when is_binary(value), do: value
  defp scalar_text(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_text(value) when is_float(value), do: Float.to_string(value)
  defp scalar_text(true), do: "true"
  defp scalar_text(false), do: "false"
  defp scalar_text(nil), do: "nil"
  defp scalar_text({:tref, _}), do: "table"
  defp scalar_text(_other), do: "function"

  # ── fail (0053 D5; SEC B3) ─────────────────────────────────────────────────

  # Validated, stored host-side, then thrown with the run's own ref. `pcall` rescues
  # exceptions only, so the throw reaches the worker; the worker matches the ref, never text.
  defp fail(run, args, lua) do
    case validate_fail(run, args, lua) do
      {:ok, payload} ->
        put(run, :fail, payload)
        throw({:script_fail, run.run_ref, payload})

      :error ->
        {:error, "invalid argument to fail", lua}
    end
  end

  defp validate_fail(run, [code | rest], lua) when is_binary(code) do
    with true <- Regex.match?(@fail_code_pattern, code),
         true <- run.fail_codes == nil or code in run.fail_codes,
         {:ok, details} <- fail_details(rest, lua) do
      {:ok, %{code: code, details: details}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate_fail(_run, _args, _lua), do: :error

  defp fail_details([], _lua), do: {:ok, %{}}
  defp fail_details([nil | _], _lua), do: {:ok, %{}}

  defp fail_details([{:tref, _} = ref | _], lua) do
    map = lua.state |> State.get_table(ref) |> Table.to_map()

    if map_size(map) <= @fail_details_max_keys and Enum.all?(map, &fail_detail_pair?/1),
      do: {:ok, map},
      else: :error
  end

  defp fail_details(_other, _lua), do: :error

  defp fail_detail_pair?({key, value}) when is_binary(key) do
    String.valid?(key) and
      ((is_binary(value) and byte_size(value) <= @fail_details_max_string and String.valid?(value)) or
         is_integer(value) or is_float(value) or is_boolean(value))
  end

  defp fail_detail_pair?(_pair), do: false

  # ── size-checked library members (SEC B1) ──────────────────────────────────

  # table.concat: each element read ONCE from raw storage (no __index), measured, and the
  # result built from exactly those values.
  defp concat([{:tref, _} = ref | rest], lua) do
    table = State.get_table(lua.state, ref)
    sep = Enum.at(rest, 0) || ""
    sep = if is_binary(sep), do: sep, else: raise(ArgumentError)
    first = Enum.at(rest, 1) || 1
    last = Enum.at(rest, 2) || table.arr_n

    parts =
      if last < first do
        []
      else
        Enum.map(first..last, fn i ->
          case Table.get(table, i) do
            v when is_binary(v) -> v
            v when is_integer(v) -> Integer.to_string(v)
            v when is_float(v) -> Float.to_string(v)
            _ -> raise ArgumentError
          end
        end)
      end

    size =
      Enum.reduce(parts, 0, &(byte_size(&1) + &2)) + byte_size(sep) * max(length(parts) - 1, 0)

    if size > Sandbox.script_max_string_bytes(), do: too_large!("table.concat")
    {[Enum.join(parts, sep)], lua}
  end

  defp concat(_args, _lua), do: raise(ArgumentError)

  # string.format: an upper bound on the result, before delegating to the library.
  defp format([fmt | args], lua, original) when is_binary(fmt) do
    specs = Regex.scan(~r/%[-+ #0]*(\d*)(?:\.(\d*))?([a-zA-Z%])/, fmt)

    {bound, _rest} =
      Enum.reduce(specs, {byte_size(fmt), args}, fn [_all, width, precision, conv],
                                                    {acc, remaining} ->
        padding = digits(width) + digits(precision)

        case {conv, remaining} do
          {"%", _} -> {acc + padding, remaining}
          {_conv, []} -> {acc + padding, []}
          {"q", [arg | tail]} -> {acc + padding + arg_size(arg) * 4 + 2, tail}
          {_conv, [arg | tail]} -> {acc + padding + arg_size(arg), tail}
        end
      end)

    if bound > Sandbox.script_max_string_bytes(), do: too_large!("string.format")
    call_original(original, [fmt | args], lua)
  end

  defp format(_args, _lua, _original), do: raise(ArgumentError)

  defp arg_size(arg) when is_binary(arg), do: byte_size(arg)
  defp arg_size(_arg), do: 64

  defp digits(""), do: 0
  defp digits(text), do: String.to_integer(text)

  # string.gsub: ONLY a string replacement (no host re-entry); bound before delegating.
  defp gsub([s, pattern, repl | rest], lua, original)
       when is_binary(s) and is_binary(pattern) and is_binary(repl) do
    max_matches =
      case rest do
        [n | _] when is_integer(n) and n >= 0 -> min(n, byte_size(s) + 1)
        _ -> byte_size(s) + 1
      end

    if byte_size(s) + max_matches * byte_size(repl) > Sandbox.script_max_string_bytes(),
      do: too_large!("string.gsub")

    call_original(original, [s, pattern, repl | rest], lua)
  end

  defp gsub(_args, _lua, _original), do: raise(ArgumentError)

  defp char(args, lua, original) do
    if length(args) > Sandbox.script_max_string_bytes(), do: too_large!("string.char")
    call_original(original, args, lua)
  end

  defp call_original({:native_func, fun}, args, lua) do
    {values, state} = fun.(args, lua.state)
    {values, %{lua | state: state}}
  end

  defp library_function(lua, library, name) do
    globals = State.globals(lua.state)
    lua.state |> State.get_table(Map.fetch!(globals, library)) |> Table.get(name)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp binary_part_utf8(text, max) when byte_size(text) <= max, do: text

  defp binary_part_utf8(text, max) do
    text
    |> binary_part(0, max)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  defp put(run, key, value), do: Process.put({__MODULE__, run.run_ref, key}, value)
  defp get(run, key), do: Process.get({__MODULE__, run.run_ref, key})
end
