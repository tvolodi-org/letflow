defmodule Letflow.Engine.LuaHostNoHandlerAccessTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R5, D-R.18 (advisor condition 3): module write handlers are never
  callable from Lua. No module of the Lua host (`lib/letflow/engine/lua/**`) or of the script
  runtime (`lib/letflow/scripts/**`) may name `HandlerWrites`, `HandlerContext`, the Catalog's
  `write_handler` / `write_handler_in` resolver or `call_write_handler`. A script-bound
  SERVICE_TASK node writes module data only AFTER the script returned, in engine code
  (`Engine.apply_script_task_result/3` -> `EntityPort.multi/3` -> `StepWrites` -> `HandlerWrites`),
  outside the sandbox process. Pure AST over the source text; the real-tree test and the
  synthetic non-vacuity tests run the SAME function (same accepted limits as the sibling scans:
  computed names and macros are not seen).
  """

  use ExUnit.Case, async: true

  @forbidden_aliases [:HandlerWrites, :HandlerContext]
  @forbidden_calls [:write_handler, :write_handler_in, :call_write_handler]

  @doc false
  def violations(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, parts} = node, acc when is_list(parts) ->
          hit = Enum.filter(parts, &(&1 in @forbidden_aliases))
          {node, hit ++ acc}

        {name, _meta, args} = node, acc when name in @forbidden_calls and is_list(args) ->
          {node, [name | acc]}

        {{:., _, [_receiver, name]}, _meta, _args} = node, acc when name in @forbidden_calls ->
          {node, [name | acc]}

        {:&, _, [{:/, _, [{{:., _, [_receiver, name]}, _, _}, _arity]}]} = node, acc
        when name in @forbidden_calls ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(found)
  end

  defp host_files do
    (Path.wildcard("lib/letflow/engine/lua/**/*.ex") ++
       Path.wildcard("lib/letflow/scripts/**/*.ex"))
    |> Enum.sort()
  end

  test "the Lua host and the script runtime reference no handler machinery" do
    files = host_files()
    assert length(files) >= 10, "the scan must see the Lua host files: #{inspect(files)}"

    offenders =
      for file <- files, hits = violations(File.read!(file)), hits != [], do: {file, hits}

    assert offenders == []
  end

  describe "non-vacuity (the same function flags each form)" do
    test "an alias" do
      assert [:HandlerWrites] ==
               violations("defmodule X do\n  alias Letflow.Entities.HandlerWrites\nend")

      assert :HandlerContext in violations(
               "defmodule X do\n  def f, do: %Letflow.Entities.HandlerContext{}\nend"
             )
    end

    test "a remote call, a capture and a local call of the resolver or the caller" do
      assert [:write_handler] ==
               violations(
                 "defmodule X do\n  def f, do: Letflow.Modules.Catalog.write_handler(1, 2)\nend"
               )

      assert [:call_write_handler] ==
               violations("defmodule X do\n  def f, do: &Catalog.call_write_handler/4\nend")

      assert [:write_handler_in] ==
               violations("defmodule X do\n  def f, do: write_handler_in(1, 2, 3)\nend")
    end

    test "clean code is not flagged" do
      assert [] == violations("defmodule X do\n  def f, do: Enum.map([1], & &1)\nend")
    end
  end
end
