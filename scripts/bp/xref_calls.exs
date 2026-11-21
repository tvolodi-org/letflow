# xref_calls.exs -- dumps the RUNTIME CALL GRAPH of the project as JSON on stdout (D-172).
#
# Run by scripts/bp/dead_code.py (never by hand):
#
#     MIX_ENV=dev mix run --no-start scripts/bp/xref_calls.exs > calls.json
#
# The dump is the authoritative source of "who calls what" for the compiled code:
# Mix.Tasks.Xref.calls/1 walks the debug info of every compiled module of the
# project and reports each REMOTE call with its callee {module, function, arity},
# the file and the line of the call site.
#
# Two things it does NOT see (scripts/bp/dead_code.py covers them from the source):
#   * a call to a function of the SAME module (a local call),
#   * a call through apply/3 with a variable, Module.concat/1 or a string.
#
# The JSON is written by hand (no dependency): the script must also run in a
# fixture project that has no deps at all.
#
# The values below are the shape of one call site:
#   {"callee": "Letflow.Engine.create", "arity": 2, "caller": "Letflow.Api.X",
#    "file": "lib/letflow/api/x.ex", "line": 12}

defmodule DcJson do
  @moduledoc "A minimal JSON writer (the script must run without any dependency)."

  def escape(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  def escape(value) when is_integer(value), do: Integer.to_string(value)

  def call(%{callee: callee, arity: arity, caller: caller, file: file, line: line}) do
    [
      "{\"callee\":",
      escape(callee),
      ",\"arity\":",
      Integer.to_string(arity),
      ",\"caller\":",
      escape(caller),
      ",\"file\":",
      escape(file),
      ",\"line\":",
      Integer.to_string(line),
      "}"
    ]
  end
end

calls =
  Mix.Tasks.Xref.calls()
  |> Enum.map(fn call ->
    {module, function, arity} = call.callee

    %{
      callee: "#{inspect(module)}.#{function}",
      arity: arity,
      caller: inspect(call.caller_module),
      file: to_string(call.file),
      line: call.line || 0
    }
  end)
  |> Enum.sort_by(&{&1.file, &1.line, &1.caller, &1.callee, &1.arity})

body =
  calls
  |> Enum.with_index()
  |> Enum.map(fn {call, index} ->
    entry = DcJson.call(call)
    if index == 0, do: entry, else: [",", entry]
  end)

json = "[\n" <> IO.iodata_to_binary(body) <> "\n]\n"

# `mix run` writes the output of the compile on stdout, so the dump goes to a file when
# the caller names one (LETFLOW_XREF_OUT); without it, to stdout.
case System.get_env("LETFLOW_XREF_OUT") do
  nil -> IO.write(json)
  path -> File.write!(path, json)
end
