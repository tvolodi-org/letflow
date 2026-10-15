defmodule Letflow.Entities.StepSourceCallersTest do
  @moduledoc """
  GH #2627: no literal process-step source is built outside
  `lib/letflow/entities/step_source.ex`. AST scan (a comment or doc naming the
  string is not a literal) of every `lib/**/*.ex` and `test/support/**/*.ex`:

    * S1: a `{:kind, "process_step"}` / `{"kind", "process_step"}` pair (a map or
      keyword literal) or a call-argument run `..., :kind, "process_step"`;
    * S2: a `%StepSource{}` / `%Letflow.Entities.StepSource{}` struct literal
      (producers build through `StepSource.new/1` so the invariants run).

  Non-vacuity: synthetic positives and negatives go through the same functions,
  and the real tree must contain exactly the known `StepSource.new/1` callers.
  Pure file reads, `async: true`.
  """

  use ExUnit.Case, async: true

  @definer "lib/letflow/entities/step_source.ex"
  # records.ex re-runs the constructor on the command's struct and pattern-matches it
  # (the single line_index == line_key check); step_writes.ex is the only producer.
  @producers ["lib/letflow/entities/records.ex", "lib/letflow/entities/step_writes.ex"]
  @struct_pattern_files ["lib/letflow/entities/records.ex"]
  @fake "lib/letflow/fake.ex"

  setup_all do
    files =
      for path <- Enum.sort(Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")) do
        {path, path |> File.read!() |> Code.string_to_quoted!(file: path)}
      end

    {:ok, files: files}
  end

  defp synthetic(sources) do
    for {path, source} <- sources, do: {path, Code.string_to_quoted!(source, file: path)}
  end

  defp kind_literal?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {key, "process_step"} = node, _acc when key in [:kind, "kind"] ->
          {node, true}

        {_name, _meta, args} = node, acc when is_list(args) ->
          {node, acc or run?(args)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp run?(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 in [[:kind, "process_step"], ["kind", "process_step"]]))
  end

  defp struct_literal?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:%, _, [{:__aliases__, _, segments}, _map]} = node, acc ->
          {node, acc or List.last(segments) == :StepSource}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp violations(files) do
    for {path, ast} <- files,
        path != @definer,
        kind_literal?(ast) or (struct_literal?(ast) and path not in @struct_pattern_files),
        do: path
  end

  defp producer_call?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:StepSource]}, :new]}, _, [_]} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

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
      producers = for {path, ast} <- files, path != @definer, producer_call?(ast), do: path
      assert producers == @producers
    end
  end

  describe "synthetic sources" do
    test "every literal form is a violation under a fake path" do
      for source <- [
            ~s|%{kind: "process_step", node_id: "n"}|,
            ~s|[kind: "process_step"]|,
            ~s|%{"kind" => "process_step"}|,
            ~s|Map.put(m, :kind, "process_step")|,
            ~s|%Letflow.Entities.StepSource{kind: k}|,
            ~s|%StepSource{}|
          ] do
        assert violations(synthetic([{@fake, source}])) == [@fake], source
      end
    end

    test "controls: the definer, a doc, a builder call and other kinds are not" do
      assert violations(synthetic([{@definer, ~s|%{kind: "process_step"}|}])) == []

      for source <- [
            ~s|@moduledoc "kind: process_step"|,
            ~s|StepSource.new(attrs)|,
            ~s|%{kind: "client"}|,
            ~s|action = "entity_write.process_step"|
          ] do
        assert violations(synthetic([{@fake, source}])) == [], source
      end
    end
  end
end
