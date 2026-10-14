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
          prints_dropped: non_neg_integer()
        }
  def run_state(run_ref) do
    {lines, dropped} = Process.get({__MODULE__, run_ref, :print}, {[], 0})

    %{
      input_dropped: Process.get({__MODULE__, run_ref, :input_dropped}, 0),
      prints: Enum.reverse(lines),
      prints_dropped: dropped
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
      put(run, :print, {[print_line(args) | lines], dropped})
    end

    []
  end

  # SEC (code review) B1: never join the full arguments; collect at most the line cap, so a
  # print of many 1 MiB strings never allocates more than @print_max_line_bytes.
  defp print_line(args) do
    args
    |> Enum.reduce_while({[], @print_max_line_bytes, true}, fn arg, {acc, remaining, first?} ->
      sep = if first?, do: "", else: "\t"
      sep_part = binary_part(sep, 0, min(byte_size(sep), remaining))
      remaining = remaining - byte_size(sep_part)
      piece = scalar_text(arg)
      piece_part = binary_part(piece, 0, min(byte_size(piece), remaining))
      remaining = remaining - byte_size(piece_part)
      acc = [piece_part, sep_part | acc]

      if remaining <= 0, do: {:halt, {acc, 0, false}}, else: {:cont, {acc, remaining, false}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> valid_utf8_prefix()
  end

  defp scalar_text(value) when is_binary(value), do: value
  defp scalar_text(value) when is_number(value), do: Lua.VM.Value.to_string(value)
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
    # Lua's default end is #t (the border), not only the array part.
    last = Enum.at(rest, 2) || Table.length(table)

    parts =
      if last < first do
        []
      else
        Enum.map(first..last, fn i ->
          case Table.get(table, i) do
            v when is_binary(v) -> v
            # Lua's own number formatting (%.14g for floats), as the library would print it
            v when is_number(v) -> Lua.VM.Value.to_string(v)
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
          {"%", _} ->
            {acc + padding, remaining}

          {_conv, []} ->
            {acc + padding, []}

          {"q", [arg | tail]} ->
            {acc + padding + arg_size(arg) * 4 + 2, tail}

          # %f of 1e308 renders ~316 bytes, %.99f ~410 (SEC code review nb 1)
          {c, [arg | tail]} when c in ["f", "F"] ->
            {acc + padding + max(arg_size(arg), 420), tail}

          {_conv, [arg | tail]} ->
            {acc + padding + arg_size(arg), tail}
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

    # SEC (code review) B2: each %0-%9 in the replacement expands to a whole match or a
    # capture (at most byte_size(s)), not to its own 2 bytes.
    capture_refs = count_capture_refs(repl, 0)
    per_match = byte_size(repl) + capture_refs * byte_size(s)

    if byte_size(s) + max_matches * per_match > Sandbox.script_max_string_bytes(),
      do: too_large!("string.gsub")

    call_original(original, [s, pattern, repl | rest], lua)
  end

  defp gsub(_args, _lua, _original), do: raise(ArgumentError)

  # Counts `%<digit>` without allocating (a Regex.scan over a 512 KiB replacement of
  # `%0`s would itself build a match list larger than the heap limit).
  defp count_capture_refs(<<?%, digit, rest::binary>>, acc) when digit in ?0..?9,
    do: count_capture_refs(rest, acc + 1)

  defp count_capture_refs(<<?%, ?%, rest::binary>>, acc), do: count_capture_refs(rest, acc)
  defp count_capture_refs(<<_byte, rest::binary>>, acc), do: count_capture_refs(rest, acc)
  defp count_capture_refs(<<>>, acc), do: acc

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

  defp valid_utf8_prefix(text) do
    if String.valid?(text),
      do: text,
      else: text |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
  end

  defp put(run, key, value), do: Process.put({__MODULE__, run.run_ref, key}, value)
  defp get(run, key), do: Process.get({__MODULE__, run.run_ref, key})
end
