defmodule Letflow.Engine.EntityPortBoundaryTest do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (design sections 4.1-4.4, 11 A3): the ONE engine-defined entity port.
  Pure file and module reads.

    * the engine names no `Letflow.Entities` module;
    * `EntityPort.impl/0` is the only reader of `:entity_port` in `lib/`;
    * `EntityPortImpl` implements every callback; `ScriptReadPort` is gone;
    * (SEC F8) the script paths (dispatcher and `Letflow.Scripts.*`) call only `prefetch/3` on
      the port.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.EntityPort

  @root Path.expand("../../..", __DIR__)
  @dispatcher "lib/letflow/engine/script_task_dispatcher.ex"
  # Derived, not listed: every port callback but the read `prefetch` is a write-side name, so a new
  # callback is covered at once (T-F8-9 pins the current six and forces a decision on a change).
  @write_names for {name, _arity} <- EntityPort.behaviour_info(:callbacks),
                   name != :prefetch,
                   do: name
  @forbidden_aliases [:StepWrites, :EntityPortImpl, :HandlerWrites]
  # Calls that take a runtime module and function (MFA), or build/evaluate one.
  @mfa_names [:apply, :spawn, :spawn_link, :spawn_monitor, :spawn_opt]
  @code_eval_names [
    :eval_string,
    :eval_quoted,
    :eval_file,
    :compile_string,
    :compile_quoted,
    :compile_file,
    :require_file
  ]
  @macro_names [:unquote, :unquote_splicing, :defmacro, :defmacrop]

  defp lib_files(pattern), do: Path.wildcard(Path.join(@root, pattern))

  test "no engine file names a Letflow.Entities module (docs included)" do
    files = [Path.join(@root, "lib/letflow/engine.ex")] ++ lib_files("lib/letflow/engine/**/*.ex")
    assert length(files) > 10
    assert Enum.filter(files, &(File.read!(&1) =~ ~r/Letflow\.Entities\b/)) == []
  end

  test "EntityPort.impl/0 is the only :entity_port reader in lib/" do
    readers =
      lib_files("lib/**/*.ex")
      |> Enum.filter(&(env_readers(File.read!(&1)) > 0))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert readers == ["lib/letflow/engine/entity_port.ex"]
    assert EntityPort.impl() == Letflow.Entities.EntityPortImpl
  end

  test "the reader scan is AST-based: a multi-line fetch_env! is found" do
    assert env_readers("Application.fetch_env!(
  :letflow,
  :entity_port
)") == 1
    assert env_readers("Application.get_env(:letflow, :entity_port, nil)") == 1
    assert env_readers("Application.fetch_env!(:letflow, :other)") == 0
  end

  test "the adapter implements the behaviour and ScriptReadPort is gone" do
    assert Code.ensure_loaded?(Letflow.Entities.EntityPortImpl)

    behaviours =
      Letflow.Entities.EntityPortImpl.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert EntityPort in behaviours

    callbacks = EntityPort.behaviour_info(:callbacks)
    # prefetch, prepare, validate_lines, multi, interpret_failure + (GH #2590 R4b)
    # authorize_module_writes + (GH #2704) the OPTIONAL pre-lock lock_types/4, which the
    # production adapter must still export (EntityPort.verify_adapter!/0)
    assert length(callbacks) == 7

    for {name, arity} <- callbacks do
      assert function_exported?(Letflow.Entities.EntityPortImpl, name, arity), "#{name}/#{arity}"
    end

    refute Code.ensure_loaded?(Letflow.Engine.ScriptReadPort)
    assert EntityPort.applied_event_type() == "TASK_ENTITY_WRITES_APPLIED"
  end

  # SEC F8 (GH 2632), forms 5 and 7: a delegation helper or a new file outside the scanned globs.
  # The AST inventory runs over ALL of lib/**; docs and comments are not AST nodes.
  describe "port inventory over lib/** (SEC F8)" do
    test "T-F8-5a only the pinned files name a holder or reach the port's accessors" do
      inventory =
        for file <- lib_files("lib/**/*.ex"), into: %{} do
          {Path.relative_to(file, @root), port_users(File.read!(file))}
        end

      holders =
        for {file, %{holders: [_ | _]}} <- inventory,
            not String.starts_with?(file, "lib/letflow/entities/"),
            do: file

      accessors = for {file, %{accessors: [_ | _]}} <- inventory, do: file

      assert holders == []

      assert Enum.sort(accessors) == [
               "lib/letflow/definitions.ex",
               "lib/letflow/engine.ex",
               "lib/letflow/engine/script_task_dispatcher.ex"
             ]
    end

    test "T-F8-5b a delegation helper is reported by port_users/1" do
      by_alias =
        "defmodule H do\n  def f(m, l, c), do: Letflow.Entities.StepWrites.multi(m, l, c)\nend"

      assert %{holders: [:StepWrites]} = port_users(by_alias)

      aliased =
        "defmodule H do\n  alias Letflow.Entities.{HandlerWrites, EntityPortImpl}\n  def f, do: {HandlerWrites, EntityPortImpl}\nend"

      assert %{holders: [:EntityPortImpl, :HandlerWrites]} = port_users(aliased)

      via_port = "defmodule H do\n  def f(m, l, c), do: EntityPort.impl().multi(m, l, c)\nend"
      assert %{accessors: [_ | _]} = port_users(via_port)

      lock = "defmodule H do\n  def f(a, b, c, d), do: EntityPort.lock_types(a, b, c, d)\nend"
      assert %{accessors: [_ | _]} = port_users(lock)

      assert port_users("defmodule H do\n  def f, do: Ecto.Multi.new()\nend") ==
               %{holders: [], accessors: []}
    end
  end

  describe "script paths call only prefetch/3 on the port (SEC F8)" do
    test "the dispatcher and lib/letflow/scripts/** are clean" do
      files =
        [
          @dispatcher,
          "lib/letflow/scripts.ex"
          | Enum.map(lib_files("lib/letflow/scripts/**/*.ex"), &Path.relative_to(&1, @root))
        ]

      assert length(files) > 2

      for file <- files do
        found = violations(File.read!(Path.join(@root, file)))
        assert found == [], "#{file}: #{inspect(found)}"
      end
    end

    test "the dispatcher does call prefetch (non-vacuous)" do
      assert File.read!(Path.join(@root, @dispatcher)) =~ "EntityPort.impl().prefetch("
    end

    # SEC F8 (GH 2632): the false negatives of the lexical rule. Each fixture is a call form
    # that reaches a write callback without the `port.multi(...)` shape.
    test "T-F8-1a/1b/1c apply and MFA-taking calls are violations" do
      for body <- [
            "apply(port, :multi, [m, l, c])",
            "Kernel.apply(port, :multi, [m, l, c])",
            ":erlang.apply(port, :multi, [m, l, c])",
            "apply(&port.multi/3, [m, l, c])",
            "Task.async(port, :multi, [m, l, c])",
            "Task.Supervisor.async_nolink(sup, port, :multi, [m, l, c])",
            "spawn(port, :multi, [m, l, c])",
            "spawn_link(port, :multi, [m, l, c])",
            ":erlang.spawn(port, :multi, [m, l, c])",
            ":timer.apply_after(1, port, :multi, [m, l, c])",
            ":rpc.call(node(), port, :multi, [m, l, c])",
            ":erpc.call(node(), port, :multi, [m, l, c])"
          ] do
        assert violations(wrap(body)) != [], body
      end
    end

    test "T-F8-2 remote captures" do
      # 2a: the capture of a non-alias receiver is a remote-call node: caught on main already
      assert violations(wrap("&port.multi/3")) != []
      assert violations(wrap("Function.capture(port, :multi, 3)")) != []
    end

    test "T-F8-3 dynamic names and port-held write callbacks" do
      for body <- [
            ~S|apply(port, String.to_existing_atom("mu" <> "lti"), [m, l, c])|,
            "apply(port, @callback_name, [m, l, c])",
            "port.authorize_module_writes(a, b, c)",
            "port.lock_types(a, b, c, d)"
          ] do
        assert violations(wrap(body)) != [], body
      end
    end

    test "T-F8-4 dynamic modules and eval" do
      for body <- [
            "Module.concat([Letflow, Entities, StepWrites]).multi(m, l, c)",
            "Module.safe_concat([Letflow, Entities, StepWrites])",
            ~S|Code.eval_string("Letflow.Entities.StepWrites.multi(1, 2, 3)")|,
            "Code.eval_quoted(ast)",
            "Code.compile_string(src)",
            ~S|:"Elixir.Letflow.Entities.EntityPortImpl".lock_types(a, b, c, d)|,
            ~S|:"Elixir.Letflow.Entities.EntityPortImpl"|
          ] do
        assert violations(wrap(body)) != [], body
      end

      # the Code ban is not wider than stated: parsing executes nothing
      assert violations(wrap(~S|Code.string_to_quoted("1 + 1")|)) == []
      assert violations(wrap(~S|String.to_existing_atom("status")|)) == []
    end

    test "T-F8-6 module attributes and macro injection" do
      assert violations(
               "defmodule F do\n  @port EntityPort.impl()\n  def f(m, l, c), do: @port.multi(m, l, c)\nend"
             ) != []

      assert violations("defmodule F do\n  defmacro m(x), do: quote(do: unquote(x))\nend") != []
      assert violations("defmodule F do\n  defmacrop m(x), do: x\nend") != []
      assert violations(wrap("quote(do: port.unquote(name)(1))")) != []
    end

    test "T-F8-9 the write names are derived from the behaviour (a new callback forces a decision)" do
      assert Enum.sort(@write_names) ==
               [
                 :authorize_module_writes,
                 :interpret_failure,
                 :lock_types,
                 :multi,
                 :prepare,
                 :validate_lines
               ]

      refute :prefetch in @write_names
    end

    test "synthetic negatives are violations, positives are not" do
      assert violations("defmodule F do\n  def f(port, m, l, c), do: port.multi(m, l, c)\nend") !=
               []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl().prepare([], %{})\nend") !=
               []

      assert violations(
               "defmodule F do\n  def f(port, s, r), do: port.interpret_failure(s, r)\nend"
             ) != []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl()\nend") != []
      assert violations("defmodule F do\n  def f, do: Ecto.Multi.new()\nend") == []

      assert violations("defmodule F do\n  def f, do: EntityPort.impl().prefetch(1, 2, 3)\nend") ==
               []
    end
  end

  # Violations (SEC F8 / TDV F3):
  #   * a remote call named prepare/validate_lines/multi whose receiver is NOT a bare alias;
  #   * any alias whose last segment is `StepWrites` or `EntityPortImpl`, however it is spelled
  #     (direct, `alias ..., as: P`, multi-alias);
  #   * any `EntityPort` alias reference beyond the single allowed shape
  #     `EntityPort.impl().prefetch(...)` (one per call) and a plain `alias Letflow.Engine.EntityPort`.
  defp violations(source) do
    ast = Code.string_to_quoted!(source)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:alias, _, [{:__aliases__, _, segs} | rest]}, acc when segs != [] ->
          last = List.last(segs)

          cond do
            last in @forbidden_aliases ->
              {{:alias_seen, [], []}, [{:alias, last} | acc]}

            last == :EntityPort and rest != [] ->
              {{:alias_seen, [], []}, [{:alias_as, last} | acc]}

            true ->
              {{:alias_seen, [], []}, acc}
          end

        {{:., _, [recv, name]}, _, _args} = node, acc when name in @write_names ->
          if match?({:__aliases__, _, _}, recv),
            do: {node, acc},
            else: {node, [{:write, name} | acc]}

        {{:., _, [recv, name]}, _, _args} = node, acc ->
          if banned_remote?(recv, name), do: {node, [{:banned, name} | acc]}, else: {node, acc}

        {:__aliases__, _, segs} = node, acc when is_list(segs) and segs != [] ->
          last = List.last(segs)

          cond do
            last in @forbidden_aliases -> {node, [{:alias, last} | acc]}
            last == :EntityPort -> {node, [:entity_port_ref | acc]}
            true -> {node, acc}
          end

        {name, _, args} = node, acc
        when (name in @mfa_names or name in @macro_names) and is_list(args) ->
          {node, [{:banned, name} | acc]}

        # a `:"Elixir.…"` module atom literal; the parser itself emits `Access` (`map[key]`) and `Kernel`
        atom, acc when is_atom(atom) and atom not in [Access, Kernel] ->
          if String.starts_with?(Atom.to_string(atom), "Elixir."),
            do: {atom, [{:module_atom, atom} | acc]},
            else: {atom, acc}

        node, acc ->
          {node, acc}
      end)

    refs = Enum.count(found, &(&1 == :entity_port_ref))
    others = Enum.reject(found, &(&1 == :entity_port_ref))

    if refs > count_prefetch_receivers(ast), do: [:entity_port_ref | others], else: others
  end

  defp count_prefetch_receivers(ast) do
    {_, n} =
      Macro.prewalk(ast, 0, fn
        {{:., _, [{{:., _, [{:__aliases__, _, _}, :impl]}, _, []}, :prefetch]}, _, _} = node, n ->
          {node, n + 1}

        node, n ->
          {node, n}
      end)

    n
  end

  # Remote calls that take or build a runtime module/function (SEC F8 forms 1-4): MFA dispatch,
  # captures from values, module construction and code evaluation. `Code.string_to_quoted` only
  # parses and `String.to_existing_atom` yields data, so neither is banned.
  defp banned_remote?(recv, name) do
    case recv do
      _ when name in @macro_names -> true
      {:__aliases__, _, [:Kernel]} -> name in @mfa_names
      :erlang -> name in @mfa_names
      {:__aliases__, _, [:Task]} -> true
      {:__aliases__, _, [:Task, :Supervisor]} -> true
      recv when recv in [:rpc, :erpc, :timer] -> true
      {:__aliases__, _, [:Function]} -> name == :capture
      {:__aliases__, _, [:Module]} -> name in [:concat, :safe_concat]
      {:__aliases__, _, [:Code]} -> name in @code_eval_names
      _ -> false
    end
  end

  # Who touches the port or its write-callback holders (forms 5 and 7), for the lib/** inventory:
  #   * holders: alias references to StepWrites / EntityPortImpl / HandlerWrites;
  #   * accessors: `EntityPort.impl|lock_types|<write callback>` calls through the alias.
  defp port_users(source) do
    {_, {holders, accessors}} =
      Macro.prewalk(Code.string_to_quoted!(source), {[], []}, fn
        {{:., _, [{:__aliases__, _, segs}, fun]}, _, _} = node, {h, a}
        when is_list(segs) and segs != [] ->
          if List.last(segs) == :EntityPort and fun in [:impl, :lock_types | @write_names],
            do: {node, {h, [fun | a]}},
            else: {node, {h, a}}

        {:__aliases__, _, segs} = node, {h, a} when is_list(segs) and segs != [] ->
          if List.last(segs) in @forbidden_aliases,
            do: {node, {[List.last(segs) | h], a}},
            else: {node, {h, a}}

        node, acc ->
          {node, acc}
      end)

    %{
      holders: holders |> Enum.uniq() |> Enum.sort(),
      accessors: accessors |> Enum.uniq() |> Enum.sort()
    }
  end

  defp wrap(body), do: "defmodule F do\n  def f(port, m, l, c), do: #{body}\nend"

  defp env_readers(source) do
    {_, n} =
      Macro.prewalk(Code.string_to_quoted!(source), 0, fn
        {{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, [:letflow, :entity_port | _]} =
            node,
        n
        when fun in [:get_env, :fetch_env, :fetch_env!] ->
          {node, n + 1}

        node, n ->
          {node, n}
      end)

    n
  end
end
