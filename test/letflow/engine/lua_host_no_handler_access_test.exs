defmodule Letflow.Engine.LuaHostNoHandlerAccessTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R5, D-R.18 (advisor condition 3): module write handlers are never
  callable from Lua (or from any other script surface). The scan is INVERTED: over ALL of
  `lib/**/*.ex`, only an explicit allowlist of files may name `HandlerWrites`, `HandlerContext`,
  the Catalog's `write_handler` / `write_handler_in` resolver or `call_write_handler`. Every
  Lua-touching file (`engine/lua/**`, `scripts/**`, `scripts.ex`, `engine/script_task_dispatcher.ex`,
  `engine/script_input.ex`, `engine/wasm/**`, `modules/exam/scoring.ex`, `admission.ex`, and any file added
  later) is therefore covered, and a new file that names them fails here until it is reviewed and
  added. A script-bound SERVICE_TASK node writes module data only AFTER the script returned, in
  engine code (`Engine.apply_script_task_result/3` -> `EntityPort.multi/3` -> `StepWrites` ->
  `HandlerWrites`), outside the sandbox process.

  This list is a SUPERSET of the sibling scan's (`handler_writes_callers_test.exs` H1-H3 pin who may
  CALL the resolver/caller; this one pins who may even NAME them, aliases and docs-free AST
  included, so the engine, the port impl, `StepWrites`, `Module`, `ManifestHash` and the
  `HandlerContext` definer appear here and not there). The two lists do not contradict: every H-scan
  allowlist file is in this one. Pure AST over the source text; the real-tree test and the
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

  # Every file of lib/ that may name the handler machinery (verified by grep and by this scan).
  @allowed ~w(
    lib/letflow/definitions/module_writes.ex
    lib/letflow/engine.ex
    lib/letflow/entities/entity_port_impl.ex
    lib/letflow/entities/handler_context.ex
    lib/letflow/entities/handler_writes.ex
    lib/letflow/entities/managed_types.ex
    lib/letflow/entities/step_writes.ex
    lib/letflow/modules/catalog.ex
    lib/letflow/modules/manifest_hash.ex
    lib/letflow/modules/module.ex
  )

  defp lib_files, do: "lib/**/*.ex" |> Path.wildcard() |> Enum.sort()

  test "only the allowlisted files of lib/ name the handler machinery" do
    files = lib_files()
    assert length(files) > 300, "the scan must see the whole tree: #{length(files)} files"

    offenders =
      for file <- files, hits = violations(File.read!(file)), hits != [], do: file

    # non-vacuous on the real tree: the scan does see the definer and a known caller
    assert "lib/letflow/entities/handler_writes.ex" in offenders
    assert "lib/letflow/entities/step_writes.ex" in offenders

    assert offenders -- @allowed == [], "files outside the allowlist name handler machinery"
  end

  test "the allowlist names real files, and none of them is a Lua, script or wasm file" do
    for file <- @allowed, do: assert(File.regular?(file), "stale allowlist entry #{file}")

    script_surface =
      ~r{/(lua|scripts|wasm)/|/scripts\.ex$|script_task_dispatcher|script_input|exam/scoring|/admission\.ex$}

    assert Enum.filter(@allowed, &Regex.match?(script_surface, &1)) == []

    # non-vacuity of the pattern itself: it matches the files it is meant to keep out
    for file <- [
          "lib/letflow/engine/lua/sandbox.ex",
          "lib/letflow/scripts/runtime.ex",
          "lib/letflow/scripts.ex",
          "lib/letflow/engine/script_task_dispatcher.ex",
          "lib/letflow/engine/script_input.ex",
          "lib/letflow/engine/wasm/x.ex",
          "lib/letflow/modules/exam/scoring.ex",
          "lib/letflow/admission.ex"
        ] do
      assert Regex.match?(script_surface, file), file
    end
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
