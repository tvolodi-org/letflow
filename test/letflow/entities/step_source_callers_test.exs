defmodule Letflow.Entities.StepSourceCallersTest do
  @moduledoc """
  GH #2627: no literal process-step source is built outside
  `lib/letflow/entities/step_source.ex`.

  Scope: PRODUCERS in `lib/**/*.ex` and `test/support/**/*.ex` (AST scan, so a comment or
  doc naming a string is not a literal). Test files under `test/**/*_test.exs` are out of
  scope on purpose: they build invalid structs to exercise the refusals. Accepted limits:
  computed module names (`struct!(mod, ...)` with a variable), `Code.eval_*`, macro-generated
  code, `.exs` files, dependencies, and `cond` clause heads (read as patterns).

  Rules, per file (a `StepSource` name is `StepSource` or any `alias ..., as: Name`):

    * S1: a `{:kind, "process_step"}` / `{"kind", "process_step"}` pair (a map or keyword
      literal) or a call-argument run `..., :kind, "process_step"`;
    * S2: a `%StepSource{}` / `%Letflow.Entities.StepSource{}` / `%Alias{}` struct literal
      in EXPRESSION position. A literal in PATTERN position (function head, `<-`, `=` left
      side, `case`/`fn` clause head) is allowed only in `@struct_pattern_files`
      (`records.ex` matches the struct it was handed);
    * S3: a `struct/2`, `struct!/2` or `Kernel.struct/2,3` call naming a `StepSource`;
    * S4: a module attribute whose value is a `StepSource` name (indirection).

  Producers build through `StepSource.new/1`; the exact set of callers is pinned in
  `@new_callers` and a new producer (PR C's SERVICE_TASK path) is a reviewed edit to that
  list. Every rule is a pure function over `[{path, ast}]`; synthetic cases go through the
  same functions as the real tree. Pure file reads, `async: true`.
  """

  use ExUnit.Case, async: true

  @definer "lib/letflow/entities/step_source.ex"
  @records "lib/letflow/entities/records.ex"
  @step_writes "lib/letflow/entities/step_writes.ex"
  @fake "lib/letflow/fake.ex"

  # Allow-lists: adding a file is a reviewed diff. records.ex re-runs the constructor on the
  # command's struct and pattern-matches it; step_writes.ex is the only producer.
  @new_callers [@records, @step_writes]
  @struct_pattern_files [@records]

  @full_module [:Letflow, :Entities, :StepSource]

  setup_all do
    files =
      for path <- Enum.sort(Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")) do
        {path, parse(File.read!(path), path)}
      end

    {:ok, files: files}
  end

  defp parse(source, path), do: Code.string_to_quoted!(source, file: path, columns: true)

  defp synthetic(sources), do: for({path, source} <- sources, do: {path, parse(source, path)})

  # ── names ───────────────────────────────────────────────────────────────────────────────────

  # `StepSource` plus every `alias Some.StepSource, as: Name` of this file.
  defp step_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [:StepSource], fn
        {:alias, _, [{:__aliases__, _, segments}, opts]} = node, acc when is_list(opts) ->
          with true <- List.last(segments) == :StepSource,
               {:__aliases__, _, [as]} <- Keyword.get(opts, :as) do
            {node, [as | acc]}
          else
            _other -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp step_alias?({:__aliases__, _, segments}, names) when is_list(segments),
    do: List.last(segments) in names

  defp step_alias?(atom, _names) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom) == "Elixir." <> Enum.map_join(@full_module, ".", &Atom.to_string/1)

  defp step_alias?(_other, _names), do: false

  # ── S1 ──────────────────────────────────────────────────────────────────────────────────────

  defp kind_literal?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {key, "process_step"} = node, _acc when key in [:kind, "kind"] ->
          {node, true}

        {_name, _meta, args} = node, acc when is_list(args) ->
          {node, acc or kind_run?(args)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp kind_run?(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 in [[:kind, "process_step"], ["kind", "process_step"]]))
  end

  # ── S2: struct literals, split by position ──────────────────────────────────────────────────

  defp struct_literals(ast, names) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:%, meta, [alias_ast, _map]} = node, acc ->
          if step_alias?(alias_ast, names), do: {node, [position(meta) | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp position(meta), do: {Keyword.get(meta, :line), Keyword.get(meta, :column)}

  # The literal positions that sit inside a pattern.
  defp pattern_positions(ast, names) do
    {_ast, roots} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head | _]} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {node, [function_head_args(head) | acc]}

        {:<-, _, [pattern, _rhs]} = node, acc ->
          {node, [pattern | acc]}

        {:=, _, [pattern, _rhs]} = node, acc ->
          {node, [pattern | acc]}

        {:->, _, [patterns, _body]} = node, acc when is_list(patterns) ->
          {node, [patterns | acc]}

        node, acc ->
          {node, acc}
      end)

    roots |> Enum.flat_map(&struct_literals(&1, names)) |> MapSet.new()
  end

  defp function_head_args({:when, _, [call | _guards]}), do: function_head_args(call)
  defp function_head_args({_name, _, args}) when is_list(args), do: args
  defp function_head_args(_other), do: []

  defp expression_struct_literal?(ast, names),
    do: struct_literals(ast, names) -- MapSet.to_list(pattern_positions(ast, names)) != []

  defp any_struct_literal?(ast, names), do: struct_literals(ast, names) != []

  # ── S3 / S4 ─────────────────────────────────────────────────────────────────────────────────

  defp struct_call?(ast, names) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [receiver, fun]}, _, args} = node, acc
        when fun in [:struct, :struct!] and is_list(args) ->
          {node, acc or (kernel?(receiver) and Enum.any?(args, &step_alias?(&1, names)))}

        {fun, _, args} = node, acc when fun in [:struct, :struct!] and is_list(args) ->
          {node, acc or Enum.any?(args, &step_alias?(&1, names))}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp kernel?({:__aliases__, _, [:Kernel]}), do: true
  defp kernel?(Kernel), do: true
  defp kernel?(_other), do: false

  defp attribute_indirection?(ast, names) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, acc or step_alias?(value, names)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # ── verdict ─────────────────────────────────────────────────────────────────────────────────

  defp reasons(path, ast) do
    names = step_names(ast)

    struct_reason? =
      if path in @struct_pattern_files,
        do: expression_struct_literal?(ast, names),
        else: any_struct_literal?(ast, names)

    [
      {kind_literal?(ast), :kind_literal},
      {struct_reason?, :struct_literal},
      {struct_call?(ast, names), :struct_call},
      {attribute_indirection?(ast, names), :attribute_indirection}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp violations(files) do
    for {path, ast} <- files, path != @definer, reasons = reasons(path, ast), reasons != [] do
      {path, reasons}
    end
  end

  defp new_caller?(ast) do
    names = step_names(ast)

    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, segments}, :new]}, _, [_]} = node, acc ->
          {node, acc or List.last(segments) in names}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # ── real tree ───────────────────────────────────────────────────────────────────────────────

  describe "real tree" do
    test "no literal source map or struct outside step_source.ex", %{files: files} do
      assert violations(files) == []
      assert length(files) > 100
      assert @definer in Enum.map(files, &elem(&1, 0))
    end

    test "the definer is the one place holding the kind literal", %{files: files} do
      {_path, ast} = Enum.find(files, &(elem(&1, 0) == @definer))
      assert Macro.to_string(ast) =~ ~s|"process_step"|
    end

    test "exactly the known callers build through StepSource.new/1", %{files: files} do
      callers = for {path, ast} <- files, path != @definer, new_caller?(ast), do: path

      assert callers == @new_callers,
             "StepSource.new/1 callers changed. Update @new_callers (and @struct_pattern_files) " <>
               "deliberately in a reviewed diff; got #{inspect(callers)}"
    end
  end

  # ── synthetic positives and negatives ───────────────────────────────────────────────────────

  describe "synthetic sources" do
    test "every literal form is a violation under a fake path" do
      for source <- [
            ~s|%{kind: "process_step", node_id: "n"}|,
            ~s|[kind: "process_step"]|,
            ~s|%{"kind" => "process_step"}|,
            ~s|Map.put(m, :kind, "process_step")|,
            ~s|%Letflow.Entities.StepSource{kind: k}|,
            ~s|%StepSource{}|,
            ~s|def f(%StepSource{} = s), do: s|
          ] do
        assert [{@fake, _}] = violations(synthetic([{@fake, source}])), source
      end
    end

    test "struct/struct!/Kernel.struct calls and aliases naming StepSource are violations" do
      for source <- [
            "struct!(StepSource, attrs)",
            "struct(Letflow.Entities.StepSource, attrs)",
            "Kernel.struct!(StepSource, attrs)",
            "attrs |> struct!(StepSource)",
            "struct!(:\"Elixir.Letflow.Entities.StepSource\", a)",
            "alias Letflow.Entities.StepSource, as: SS\n%SS{line_index: 1}",
            "alias Letflow.Entities.StepSource, as: SS\nstruct!(SS, attrs)"
          ] do
        assert [{@fake, _}] = violations(synthetic([{@fake, source}])), source
      end
    end

    test "a module-attribute indirection is a violation" do
      for source <- [
            "@source_module StepSource",
            "@source_module Letflow.Entities.StepSource\ndef build(a), do: struct!(@source_module, a)"
          ] do
        assert [{@fake, [_ | _]}] = violations(synthetic([{@fake, source}])), source
      end
    end

    test "records.ex: a pattern is exempt, a literal in expression position is not" do
      exempt = [
        "def f(%StepSource{line_index: i} = s) when is_integer(i), do: s",
        "with %StepSource{} = s <- x, do: s",
        "case x do\n  %StepSource{} -> :ok\nend",
        "g = fn %StepSource{} -> :ok end",
        "%StepSource{} = s = x"
      ]

      for source <- exempt do
        assert violations(synthetic([{@records, source}])) == [], source
      end

      for source <- [
            ~s|def f(a), do: %StepSource{kind: "client"}|,
            "def f(a) do\n  s = %StepSource{line_index: 0}\n  s\nend",
            "def f(%StepSource{}), do: %StepSource{line_index: 0}",
            "[%StepSource{}]",
            "struct!(StepSource, a)"
          ] do
        assert [{@records, _}] = violations(synthetic([{@records, source}])), source
      end
    end

    test "controls: the definer, a doc, a builder call and other kinds are not" do
      assert violations(synthetic([{@definer, ~s|%{kind: "process_step"}|}])) == []

      for source <- [
            ~s|@moduledoc "kind: process_step"|,
            ~s|StepSource.new(attrs)|,
            ~s|%{kind: "client"}|,
            ~s|action = "entity_write.process_step"|,
            "struct!(Other, attrs)",
            "alias Letflow.Entities.Other, as: SS\n%SS{}",
            "@mod Other"
          ] do
        assert violations(synthetic([{@fake, source}])) == [], source
      end
    end

    test "StepSource.new/1 caller detection follows alias ... as:" do
      ast = parse("alias Letflow.Entities.StepSource, as: SS\nSS.new(a)", @fake)
      assert new_caller?(ast)
      refute new_caller?(parse("Other.new(a)", @fake))
    end
  end
end
