defmodule Letflow.Engine.PutSysCallersTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2.5, 2.6, D-A1.8, D-A1.9, invariants I-1 and I-3): static allow-lists over the AST of every
  `lib/**/*.ex` file (not grep: AST nodes, so a function name inside a doc string is not a
  call, while a binary literal inside a doc string IS a literal).

    * R1: the identifiers `put_sys` and `put_sys_replayed` (GH #2621; a local or remote call with any receiver, piped, a capture
      `&put_sys/3` / `&X.put_sys/3`, or the atom `:put_sys` handed to `Function.capture/3` or
      `apply/3`) occurs only in `@put_sys_callers`. PR B adds `lib/letflow/engine.ex` in a
      reviewed diff.
    * R2: a binary literal CONTAINING `"INSTANCE_SYS_VARIABLES_SET"` or
      `"TASK_ENTITY_WRITES_APPLIED"` occurs only in `@event_literal_files` (A3 adds
      `lib/letflow/engine/entity_port.ex`; `lib/letflow/engine/lua/platform.ex` is never on it).
    * R3 (SEC F5, hardened for SECURITY F1): a binary literal (doc strings and interpolation
      segments included) STARTING with the reserved prefix, an atom literal whose name starts
      with it, or a `<>` chain whose leading literal operands start with it or are a non-empty
      prefix of it, occurs only in `lib/letflow/engine/variable_merge.ex`.
    * R4 (CDV-1): `Reconstruction.folded_event_types/0` equals the set of string literals in the
      `event_type:` patterns of the `apply_event/4` clause heads (`def` or `defp`) of
      `reconstruction.ex`, so a new
      fold clause cannot be added without the Lua `emit_event` refusal following it.

  Every rule's real-tree assertion is an EXACT file-set equality (non-vacuous: each set is
  non-empty, and a removed allow-listed use fails too). Synthetic snippets under a fake
  `lib/letflow/fake.ex` path go through the same functions. Accepted limits: computed names
  (`String.to_atom/1`, `apply(mod, fun_var, args)`), macro-generated code, `.exs` files.
  Pure file reads, so `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Reconstruction

  @variable_merge "lib/letflow/engine/variable_merge.ex"
  @reconstruction "lib/letflow/engine/reconstruction.ex"
  @tenant_provisioning "lib/letflow/tenant_provisioning.ex"
  @fake "lib/letflow/fake.ex"

  # Reviewed allow-lists (adding a file is a reviewed diff).
  @put_sys_callers [@variable_merge, @reconstruction]
  @put_sys_names [:put_sys, :put_sys_replayed]
  @entity_port "lib/letflow/engine/entity_port.ex"
  @event_literal_files [@variable_merge, @reconstruction, @tenant_provisioning, @entity_port]
  @reserved_literal_files [@variable_merge]

  @event_literals ["INSTANCE_SYS_VARIABLES_SET", "TASK_ENTITY_WRITES_APPLIED"]
  # Built so this file's own literal does not matter (it is .exs, never scanned anyway).
  @reserved_prefix "_" <> "sys"

  setup_all do
    files =
      for path <- Enum.sort(Path.wildcard("lib/**/*.ex")) do
        {path, path |> File.read!() |> Code.string_to_quoted!(file: path)}
      end

    {:ok, files: files}
  end

  defp synthetic(source), do: [{@fake, Code.string_to_quoted!(source, file: @fake)}]

  # ── rule functions (pure over [{path, ast}]) ────────────────────────────────────────────────

  # R1: every file holding the identifier put_sys in any call / capture / atom position.
  def put_sys_files(files) do
    for {path, ast} <- files, mentions_put_sys?(ast), uniq: true, do: path
  end

  defp mentions_put_sys?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {name, _meta, _args} = node, _acc when name in @put_sys_names -> {node, true}
        name = node, _acc when name in @put_sys_names -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # R2 / R3: every file holding a binary literal matching `pred`.
  def literal_files(files, pred) do
    for {path, ast} <- files, has_literal?(ast, pred), uniq: true, do: path
  end

  defp has_literal?(ast, pred) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        binary = node, acc when is_binary(binary) -> {node, acc or pred.(binary)}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp event_literal?(binary), do: Enum.any?(@event_literals, &String.contains?(binary, &1))
  defp reserved_literal?(binary), do: String.starts_with?(binary, @reserved_prefix)

  # R3 (hardened, SECURITY F1): a binary literal starting with the prefix, an atom literal whose
  # name starts with it (`:"_sys.x"`, keyword key `_sys:`), or a `<>` chain whose leading
  # literal operands join to a string that starts with the prefix or is a non-empty prefix of
  # it (`"_" <> "sys.x"`, `"_s" <> rest`).
  def reserved_files(files) do
    for {path, ast} <- files, reserved_mention?(ast), uniq: true, do: path
  end

  defp reserved_mention?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        binary = node, acc when is_binary(binary) ->
          {node, acc or reserved_literal?(binary)}

        atom = node, acc when is_atom(atom) ->
          {node, acc or reserved_literal?(Atom.to_string(atom))}

        {:<>, _, [_, _]} = node, acc ->
          {node, acc or reserved_concat?(node)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp reserved_concat?(node) do
    head = node |> concat_operands() |> Enum.take_while(&is_binary/1) |> Enum.join()

    head != "" and
      (String.starts_with?(head, @reserved_prefix) or String.starts_with?(@reserved_prefix, head))
  end

  defp concat_operands({:<>, _, [left, right]}),
    do: concat_operands(left) ++ concat_operands(right)

  defp concat_operands(other), do: [other]

  # R4: the event_type: literals of every apply_event clause head.
  def apply_event_head_literals(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head | _]} = node, acc when kind in [:def, :defp] ->
          {node, head_literals(head) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.uniq() |> Enum.sort()
  end

  defp head_literals({:when, _, [head | _]}), do: head_literals(head)

  defp head_literals({:apply_event, _, args}) when is_list(args) do
    {_args, acc} =
      Macro.prewalk(args, [], fn
        {:event_type, literal} = node, acc when is_binary(literal) -> {node, [literal | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp head_literals(_other), do: []

  # ── real tree ───────────────────────────────────────────────────────────────────────────────

  describe "real lib/ tree" do
    test "R1: put_sys occurs exactly in the allow-listed files", %{files: files} do
      assert put_sys_files(files) == Enum.sort(@put_sys_callers)
    end

    test "R2: the two event-type literals occur exactly in the allow-listed files", %{
      files: files
    } do
      assert literal_files(files, &event_literal?/1) == Enum.sort(@event_literal_files)
      refute "lib/letflow/engine/lua/platform.ex" in @event_literal_files
    end

    test "R3: binary literals starting with the reserved prefix occur only in variable_merge.ex",
         %{files: files} do
      assert reserved_files(files) == @reserved_literal_files
    end

    test "R4: folded_event_types/0 equals the apply_event/4 clause-head literals", %{
      files: files
    } do
      {@reconstruction, ast} = List.keyfind(files, @reconstruction, 0)
      literals = apply_event_head_literals(ast)

      assert literals != []
      assert literals == Reconstruction.folded_event_types()
      assert Reconstruction.folded_event_types() == Enum.sort(Reconstruction.folded_event_types())
      assert "INSTANCE_SYS_VARIABLES_SET" in literals
      assert "TASK_ENTITY_WRITES_APPLIED" in literals
    end
  end

  # ── synthetic negatives (same functions) ────────────────────────────────────────────────────

  describe "synthetic negatives under #{@fake}" do
    @put_sys_shapes [
      "def f(v), do: put_sys(v, k(), 1)",
      "def f(v), do: VariableMerge.put_sys(v, k(), 1)",
      "def f(v), do: Letflow.Engine.VariableMerge.put_sys(v, k(), 1)",
      "def f(v), do: :\"Elixir.Letflow.Engine.VariableMerge\".put_sys(v, k(), 1)",
      "def f(v), do: v |> VariableMerge.put_sys(k(), 1)",
      "def f, do: &put_sys/3",
      "def f, do: &VariableMerge.put_sys/3",
      "def f, do: Function.capture(VariableMerge, :put_sys, 3)",
      "def f(v), do: apply(VariableMerge, :put_sys, [v, k(), 1])",
      "def f(v), do: put_sys_replayed(v, k(), 1)",
      "def f(v), do: VariableMerge.put_sys_replayed(v, k(), 1)",
      "def f(v), do: v |> VariableMerge.put_sys_replayed(k(), 1)",
      "def f, do: &VariableMerge.put_sys_replayed/3",
      "def f, do: Function.capture(VariableMerge, :put_sys_replayed, 3)",
      "def f(v), do: apply(VariableMerge, :put_sys_replayed, [v, k(), 1])"
    ]

    test "R1: every call / capture / apply shape of put_sys is flagged" do
      for shape <- @put_sys_shapes do
        source = "defmodule Fake do\n  #{shape}\nend\n"
        assert put_sys_files(synthetic(source)) == [@fake], "not flagged: #{shape}"
      end
    end

    test "R1: a doc mentioning put_sys/3 is not a call" do
      source = ~s|defmodule Fake do\n  @moduledoc "uses put_sys/3"\n  def f, do: :ok\nend\n|
      assert put_sys_files(synthetic(source)) == []
    end

    test "R2: the event literals are flagged in code and in a doc string" do
      for literal <- @event_literals do
        code = ~s|defmodule Fake do\n  def t, do: "#{literal}"\nend\n|
        doc = ~s|defmodule Fake do\n  @moduledoc "emits #{literal} once"\nend\n|
        assert literal_files(synthetic(code), &event_literal?/1) == [@fake]
        assert literal_files(synthetic(doc), &event_literal?/1) == [@fake]
      end

      clean = ~s|defmodule Fake do\n  def t, do: "TASK_COMPLETED"\nend\n|
      assert literal_files(synthetic(clean), &event_literal?/1) == []
    end

    test "R3: a reserved-prefix literal is flagged in code, a doc, a sigil and an interpolation segment" do
      p = @reserved_prefix

      sources = [
        ~s|defmodule Fake do\n  def k, do: "#{p}.x"\nend\n|,
        ~s|defmodule Fake do\n  @doc "#{p}.x is set here"\n  def k, do: 1\nend\n|,
        ~s|defmodule Fake do\n  def k, do: ~s(#{p}.x)\nend\n|,
        ~s|defmodule Fake do\n  def k(n), do: "#{p}.\#{n}"\nend\n|,
        ~s|defmodule Fake do\n  def k(n), do: "a\#{n}#{p}"\nend\n|,
        # SECURITY F1 hardening: atom literals and `<>` chains with a literal prefix head
        ~s|defmodule Fake do\n  def k, do: :"#{p}.x"\nend\n|,
        ~s|defmodule Fake do\n  def k, do: [#{p}: 1]\nend\n|,
        ~s|defmodule Fake do\n  def k, do: "_" <> "sys.x"\nend\n|,
        ~s|defmodule Fake do\n  def k(rest), do: "_s" <> rest\nend\n|,
        ~s|defmodule Fake do\n  def k(n), do: ("_" <> "sy") <> n\nend\n|,
        ~s|defmodule Fake do\n  def k(n), do: "a" <> "_" <> n\nend\n|
      ]

      for source <- sources do
        assert reserved_files(synthetic(source)) == [@fake],
               "not flagged: #{source}"
      end

      clean = [
        ~s|defmodule Fake do\n  def k, do: "x#{p}.y"\nend\n|,
        ~s|defmodule Fake do\n  def k, do: :system_x\nend\n|,
        ~s|defmodule Fake do\n  def k(n), do: "_x" <> n\nend\n|,
        ~s|defmodule Fake do\n  def k(n), do: n <> "sys"\nend\n|
      ]

      for source <- clean do
        assert reserved_files(synthetic(source)) == [], "false positive: #{source}"
      end
    end

    test "R4: a new apply_event clause literal is seen by the head scan" do
      source = """
      defmodule Fake do
        defp apply_event(_g, s, %{event_type: "A_NEW_TYPE"} = _e, _p), do: {:ok, s}
        defp apply_event(_g, s, %{event_type: "B_TYPE"}, _p) when is_map(s), do: {:ok, s}
        defp apply_event(_g, _s, %{event_type: t}, _p), do: {:error, t}
        def apply_event(_g, s, %{event_type: "C_PUBLIC_TYPE"}, _p), do: {:ok, s}
        defp other(%{event_type: "NOT_A_FOLD"}), do: :ok
      end
      """

      [{@fake, ast}] = synthetic(source)
      assert apply_event_head_literals(ast) == ["A_NEW_TYPE", "B_TYPE", "C_PUBLIC_TYPE"]
    end
  end
end
