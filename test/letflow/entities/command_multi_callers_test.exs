defmodule Letflow.Entities.CommandMultiCallersTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A2 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  section 3.4, D-A2.1, D-A2.16, invariant I-5; revision 1 SEC F3 and SECURITY's design re-gate
  note 1). Two static rules over the AST (not grep: a comment or doc naming a function is not a
  call) of every `lib/**/*.ex` and `test/support/**/*.ex` file, pipe-normalised:

    * C1: any call, capture, `Function.capture/3` or `apply/3` (`apply`, `Kernel.apply`,
      `:erlang.apply`) of `command_multi` with a Records receiver (`Records`, `Entities.Records`,
      `Letflow.Entities.Records` or the atom) occurs only in `@command_multi_callers` (and the
      definer `records.ex`). Expected set in PR A: EMPTY (StepWrites calls it from PR B), so
      non-vacuity is proven on synthetic sources.
    * C2: the atom `:step_namespace` (which is also what a `step_namespace:` keyword key is in
      the AST, wherever the keyword list is built: a call site, `Keyword.put/3`, `Keyword.merge/2`,
      a `{:step_namespace, ns}` tuple, a map key) and the binary `"step_namespace"` (a
      `String.to_atom/1` route) occur only in `event_store.ex` (the definer) and `records.ex`.
      With D-A2.16 (every un-namespaced EventStore append refuses a `sys:step:` key) this makes
      I-5 structural: only Records can write the step-key family.

  Deliberately a separate file from `managed_types_callers_test.exs` (which #2596 owns); its
  R1 still covers `command_multi/3`'s authority argument. Accepted limits as there: computed
  module/function names, `Code.eval_*`, macro-generated code, `.exs` files, dependencies.

  Every rule is a pure function over `[{path, ast}]`; the synthetic cases feed snippets through
  the SAME functions the real-tree tests use. Pure file reads, so `async: true`.
  """

  use ExUnit.Case, async: true

  @records "lib/letflow/entities/records.ex"
  @event_store "lib/letflow/event_store.ex"
  @step_writes "lib/letflow/entities/step_writes.ex"
  @handler_writes "lib/letflow/entities/handler_writes.ex"
  @fake "lib/letflow/fake.ex"

  # Static allow-lists: adding a file is a reviewed diff (design 3.4).
  @command_multi_callers [@step_writes, @handler_writes]
  @step_namespace_files [@event_store, @records]

  @records_receivers [[:Records], [:Entities, :Records], [:Letflow, :Entities, :Records]]
  @apply_receivers [nil, [:Kernel], [:erlang]]

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

  # ── AST helpers (same shapes as managed_types_callers_test.exs) ─────────────────────────────

  defp normalize_pipes(ast) do
    Macro.postwalk(ast, fn
      {:|>, _, [lhs, {fun, meta, args}]} when is_list(args) -> {fun, meta, [lhs | args]}
      node -> node
    end)
  end

  defp calls(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [receiver, name]}, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{name, receiver_segments(receiver), args} | acc]}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{name, nil, args} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp captures(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:&, _, [{:/, _, [{{:., _, [receiver, name]}, _, []}, arity]}]} = node, acc
        when is_atom(name) ->
          {node, [{name, receiver_segments(receiver), arity} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp receiver_segments({:__aliases__, _, segments}), do: segments
  defp receiver_segments(atom) when is_atom(atom), do: atom_segments(atom)
  defp receiver_segments(_computed), do: [:__dynamic__]

  defp atom_segments(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest |> String.split(".") |> Enum.map(&String.to_atom/1)
      _erlang -> [atom]
    end
  end

  defp literal_module({:__aliases__, _, segments}), do: segments

  defp literal_module(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: atom_segments(atom)

  defp literal_module(_other), do: nil

  defp records_receiver?(receiver), do: receiver in @records_receivers

  # ── C1: command_multi sites ─────────────────────────────────────────────────────────────────

  defp command_multi_sites(ast) do
    normalised = normalize_pipes(ast)
    all_calls = calls(normalised)

    direct =
      for {:command_multi, receiver, _args} <- all_calls,
          records_receiver?(receiver),
          do: :call

    captured =
      for {:command_multi, receiver, _arity} <- captures(normalised),
          records_receiver?(receiver),
          do: :capture

    function_captured =
      for {:capture, [:Function], [module, :command_multi, _arity]} <- all_calls,
          records_receiver?(literal_module(module)),
          do: :function_capture

    applied =
      for {:apply, receiver, [module, :command_multi, _args]} <- all_calls,
          receiver in @apply_receivers,
          records_receiver?(literal_module(module)),
          do: :apply

    direct ++ captured ++ function_captured ++ applied
  end

  defp c1_violations(files) do
    for {path, ast} <- files,
        path != @records,
        path not in @command_multi_callers,
        site <- command_multi_sites(ast),
        do: {path, site}
  end

  defp c1_files(files), do: files |> c1_violations() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  # ── C2: :step_namespace anywhere ────────────────────────────────────────────────────────────

  defp names_step_namespace?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        :step_namespace = node, _acc ->
          {node, true}

        node, acc when is_binary(node) ->
          {node, acc or String.contains?(node, "step_namespace")}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp step_namespace_files(files),
    do: for({path, ast} <- files, names_step_namespace?(ast), do: path)

  defp c2_violations(files), do: step_namespace_files(files) -- @step_namespace_files

  # ── real tree ───────────────────────────────────────────────────────────────────────────────

  describe "real tree" do
    test "the scan set is non-trivial and includes the definers", %{files: files} do
      paths = Enum.map(files, &elem(&1, 0))
      assert @records in paths
      assert @event_store in paths
      assert length(paths) > 100
    end

    test "C1: no command_multi caller outside @command_multi_callers (none in PR A)", %{
      files: files
    } do
      assert c1_violations(files) == [],
             "command_multi called outside #{inspect(@command_multi_callers)}: " <>
               inspect(c1_violations(files))

      # The definer is scanned and does define it (the rule is not looking at the wrong name).
      {_path, records_ast} = Enum.find(files, &(elem(&1, 0) == @records))
      assert Macro.to_string(records_ast) =~ "def command_multi("
    end

    test "C2: :step_namespace occurs exactly in event_store.ex and records.ex", %{files: files} do
      assert Enum.sort(step_namespace_files(files)) == Enum.sort(@step_namespace_files),
             "step_namespace outside the allow-list: " <> inspect(c2_violations(files))
    end
  end

  # ── synthetic negatives and controls ────────────────────────────────────────────────────────

  describe "C1 on synthetic sources" do
    @c1_violating [
      "Records.command_multi(c, p, :tenant)",
      "c |> Letflow.Entities.Records.command_multi(p, owner)",
      "Entities.Records.command_multi(c, p, :tenant)",
      ~s|:"Elixir.Letflow.Entities.Records".command_multi(c, p, :tenant)|,
      "f = &Records.command_multi/3",
      "f = Function.capture(Records, :command_multi, 3)",
      "apply(Records, :command_multi, [c, p, :tenant])",
      "Kernel.apply(Letflow.Entities.Records, :command_multi, args)",
      ":erlang.apply(Letflow.Entities.Records, :command_multi, [c, p, o])",
      "Records |> apply(:command_multi, [c, p, :tenant])"
    ]

    test "every call form under a fake lib path is a violation" do
      for source <- @c1_violating do
        assert c1_files(synthetic([{@fake, source}])) == [@fake], source
      end
    end

    test "the same forms in step_writes.ex or records.ex are not" do
      for source <- @c1_violating, path <- [@step_writes, @records] do
        assert c1_violations(synthetic([{path, source}])) == [], "#{path}: #{source}"
      end
    end

    test "other receivers and local calls are not Records calls" do
      for source <- [
            "Other.command_multi(c, p, :tenant)",
            "command_multi(c, p, :tenant)",
            "Records.create_record(a, p)",
            "apply(Other, :command_multi, [c, p, :tenant])"
          ] do
        assert c1_violations(synthetic([{@fake, source}])) == [], source
      end
    end
  end

  describe "C2 on synthetic sources" do
    @c2_violating [
      "EventStore.append_multi(m, a, prefix: p, step_namespace: {:line, 0})",
      "m |> Letflow.EventStore.append_multi(a, prefix: p, step_namespace: ns)",
      "opts = Keyword.put(opts, :step_namespace, {:line, 0})",
      "opts |> Keyword.merge(step_namespace: ns)",
      "opts = [{:prefix, p}, {:step_namespace, ns}]",
      "opts = [prefix: p] ++ [step_namespace: ns]",
      "%{step_namespace: ns}",
      ~s|key = String.to_existing_atom("step_namespace")|,
      ~s|key = String.to_atom("my_step_namespace_key")|,
      ~s|key = ~s(step_namespace)|,
      ~s|key = "x_" <> y <> "_step_namespace"|,
      "Keyword.fetch(opts, :step_namespace)"
    ]

    test "the atom, the keyword and the string are violations anywhere under a fake lib path" do
      for source <- @c2_violating do
        assert c2_violations(synthetic([{@fake, source}])) == [@fake], source
      end
    end

    test "the same sources in event_store.ex or records.ex are allowed" do
      for source <- @c2_violating, path <- @step_namespace_files do
        assert c2_violations(synthetic([{path, source}])) == [], "#{path}: #{source}"
      end
    end

    test "controls: an un-namespaced append and a variable named step_namespace are not" do
      for source <- [
            "EventStore.append_multi(m, a, prefix: p)",
            "step_namespace = {:line, 0}",
            ~s|doc = "the step namespace option"|,
            ~s|key = "step_" <> "x"|,
            "fetch_step_namespace(opts)"
          ] do
        assert c2_violations(synthetic([{@fake, source}])) == [], source
      end
    end
  end
end
