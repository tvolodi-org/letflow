defmodule Letflow.Entities.ScopeAllScanTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, AC 1 and the R-1 ruling SEC-518-R1 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.7; spec
  `test/specs/REQ-518-2c-i-a.md`, T-C2, T-C15 (scan half)): the source scan that fails a literal
  `:all` third argument of `Compiler.compile`, `compile_aggregate` or `run_aggregate` that is
  not justified.

  The scan PARSES (REVIEWER 2c-i-a F-5; anti-pattern "a grep-shaped acceptance criterion can
  be tripped by the module's own moduledoc"): `compile/3` and `scope-all:` appear in the
  moduledocs and comments of `compiler.ex`, `scope.ex` and `session.ex`, so it finds real CALL
  nodes in the AST (alias-aware: `alias`, `alias ... as:`, `alias ...{A, B}`, a fully qualified
  name, a piped call) and reads justification from the COMMENTS the tokenizer returns, never from
  strings or docs.

    * a literal `:all` argument outside `lib/letflow/routers/entities.ex` needs a comment
      `# scope-all: <rule or ruling id>` on the call line, the line above it, or the line of the
      literal or the line above that;
    * the non-router literal sites are PINNED to the nine-site ledger (a new one fails until it
      is added here with its rule): script reads, the mix task, and the three exam helpers under
      ruling `SEC-518-R1`;
    * the three router sites may carry a literal only while their three routes are still
      `:tenant_wide` (a literal `:all` behind a `:filter` route would hand every scoped caller
      the whole tenant: the check survives 2c-i-b);
    * R-1 guard (scan half): an exam manifest that gains `:scope_declarations` while a
      `SEC-518-R1` literal remains fails (the ruling lapses), and `list_available_exams/2` keeps
      its required `:scope` option.

  No database and no mutation of global state, so `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Support.RouteInventory

  @compiler_parts [:Letflow, :Entities, :Query, :Compiler]
  @functions [:compile, :compile_aggregate, :run_aggregate]
  @router_file "lib/letflow/routers/entities.ex"
  @justification ~r/\Ascope-all:\s*\S/
  @lines_above 3

  # ---- the scanner ---------------------------------------------------------------------------

  # [%{file:, function:, line:, literal_line:, justification: String.t() | nil}] for every
  # call whose scope argument is the literal :all
  defp literal_all_sites(source, file) do
    {ast, comments} =
      Code.string_to_quoted_with_comments!(source, columns: false, token_metadata: true)

    comment_by_line =
      Map.new(comments, fn %{line: line, text: text} ->
        {line, text |> String.trim_leading("#") |> String.trim()}
      end)

    aliases = collect_aliases(ast)
    piped = collect_piped(ast)

    {_, sites} =
      Macro.prewalk(ast, [], fn
        {{:., _meta, [target, fun]}, call_meta, args} = node, acc
        when fun in @functions and is_list(args) ->
          arity =
            length(args) + if(MapSet.member?(piped, {fun, call_meta[:line]}), do: 1, else: 0)

          if arity == 3 and compiler?(target, aliases) do
            scope_arg =
              if MapSet.member?(piped, {fun, call_meta[:line]}),
                do: Enum.at(args, 1),
                else: Enum.at(args, 2)

            if scope_arg == :all do
              lines = justification_lines(call_meta)
              {node, [site(file, fun, call_meta[:line], lines, comment_by_line) | acc]}
            else
              {node, acc}
            end
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  defp site(file, fun, line, lines, comment_by_line) do
    justification =
      Enum.find_value(lines, fn l ->
        text = Map.get(comment_by_line, l)
        if text && Regex.match?(@justification, text), do: text
      end)

    %{file: file, function: fun, line: line, justification: justification}
  end

  # A justification is a comment inside the call (its first line to its closing line) or in the
  # three lines above the call: the real sites put it above the `with` / `{:ok, q} =` statement
  # that holds the call, which can be one or two lines above `Compiler.compile(`.
  defp justification_lines(call_meta) do
    first = call_meta[:line]
    last = call_meta[:closing][:line] || first
    Enum.to_list((first - @lines_above)..last)
  end

  defp compiler?({:__aliases__, _, parts}, aliases),
    do: Map.get(aliases, parts, parts) == @compiler_parts

  defp compiler?(_other, _aliases), do: false

  # alias map: [:Compiler] => full parts, handling alias A.B.C, alias A.B.C, as: X, alias A.B.{C, D}
  defp collect_aliases(ast) do
    {_, found} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, [List.last(parts)], parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, as_parts} -> {node, Map.put(acc, as_parts, parts)}
            _ -> {node, acc}
          end

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}]} = node, acc ->
          added =
            for {:__aliases__, _, member} <- members, into: %{} do
              {[List.last(member)], base ++ member}
            end

          {node, Map.merge(acc, added)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # {function, line} of every call that is the right-hand side of a |> (its first argument is
  # supplied by the pipe)
  defp collect_piped(ast) do
    {_, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:|>, _, [_left, {{:., _, [_, fun]}, meta, _args}]} = node, acc when fun in @functions ->
          {node, MapSet.put(acc, {fun, meta[:line]})}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")

  defp real_sites do
    Enum.flat_map(lib_files(), fn file ->
      source = File.read!(file)

      if source =~ ~r/compile|run_aggregate/,
        do: literal_all_sites(source, Path.relative_to_cwd(file) |> String.replace("\\", "/")),
        else: []
    end)
  end

  defp violations(source, file) do
    for site <- literal_all_sites(source, file),
        file != @router_file,
        site.justification == nil,
        do: site
  end

  # ===========================================================================================
  describe "T-C2 the scanner itself (seeded sources)" do
    @head "defmodule Seed do\n  alias Letflow.Entities.Query.Compiler\n"

    test "a bare literal :all with no comment is a violation, for each of the three functions" do
      for fun <- @functions do
        source = @head <> "  def f(r, p), do: Compiler.#{fun}(r, p, :all)\nend\n"

        assert [%{function: ^fun, justification: nil}] = violations(source, "lib/x.ex")
      end
    end

    test "a `# scope-all: <rule>` comment on the call line, above it, or inside a multi-line call passes" do
      same_line =
        @head <> "  def f(r, p), do: Compiler.compile(r, p, :all) # scope-all: rule x\nend\n"

      above =
        @head <>
          "  # scope-all: SEC-518-R1\n  def f(r, p), do: Compiler.compile(r, p, :all)\nend\n"

      multiline =
        @head <>
          "  def f(r, p) do\n    Compiler.compile(\n      r,\n      p,\n      # scope-all: mix task, no HTTP user\n      :all\n    )\n  end\nend\n"

      for source <- [same_line, above, multiline] do
        assert violations(source, "lib/x.ex") == [], source
      end
    end

    test "a comment that names no rule does not justify: `# scope-all:`, `# scope-all`, `# scope all: x`, a TODO" do
      for comment <- [
            "# scope-all:",
            "# scope-all",
            "# scope all: x",
            "# TODO scope-all: x later?"
          ] do
        source = @head <> "  #{comment}\n  def f(r, p), do: Compiler.compile(r, p, :all)\nend\n"

        # the last one starts with TODO, so it is not a justification either
        assert [_one] = violations(source, "lib/x.ex"), comment
      end
    end

    test "a comment more than three lines above the call does not justify; the statement-above form of the real sites does" do
      far =
        @head <>
          "  # scope-all: too far\n  def a, do: 1\n  def b, do: 2\n  def c, do: 3\n  def f(r, p), do: Compiler.compile(r, p, :all)\nend\n"

      assert [_one] = violations(far, "lib/x.ex")

      real_shape =
        @head <>
          "  def f(r, p) do\n    # scope-all: SEC-518-R1\n    with {:ok, q} <-\n           Compiler.compile(r, p, :all) do\n      q\n    end\n  end\nend\n"

      assert violations(real_shape, "lib/x.ex") == []
    end

    test "moduledoc text, strings and unrelated comments cannot justify or trip the scan (REVIEWER F-5)" do
      source = """
      defmodule Seed do
        @moduledoc "scope-all: SEC-518-R1 Compiler.compile(r, p, :all)"
        alias Letflow.Entities.Query.Compiler
        @doc \"\"\"
        # scope-all: not a comment, a heredoc; calls compile/3 with :all
        \"\"\"
        def f(r, p), do: Compiler.compile(r, p, :all)
        def g, do: "# scope-all: in a string"
      end
      """

      assert [%{function: :compile}] = violations(source, "lib/x.ex")

      docs_only = """
      defmodule Seed do
        @moduledoc "Compiler.compile(r, p, :all) is the tenant-wide form; scope-all: fine"
        # compile/3 with :all, see scope-all: elsewhere
        def f, do: :ok
      end
      """

      assert violations(docs_only, "lib/x.ex") == []
    end

    test "alias forms: as:, multi-alias, fully qualified, piped" do
      as_alias =
        "defmodule S do\n  alias Letflow.Entities.Query.Compiler, as: Q\n  def f(r, p), do: Q.compile(r, p, :all)\nend\n"

      multi =
        "defmodule S do\n  alias Letflow.Entities.Query.{Allowlist, Compiler}\n  def f(r, p), do: Compiler.run_aggregate(r, p, :all)\nend\n"

      full =
        "defmodule S do\n  def f(r, p), do: Letflow.Entities.Query.Compiler.compile_aggregate(r, p, :all)\nend\n"

      piped = @head <> "  def f(r, p), do: r |> Compiler.compile(p, :all)\nend\n"

      for source <- [as_alias, multi, full, piped] do
        assert [_one] = violations(source, "lib/x.ex"), source
      end
    end

    test "not flagged: another module's compile/3, a non-literal scope, a scoped tuple, :none, two-argument calls" do
      for call <- [
            "Other.compile(r, p, :all)",
            "Compiler.compile(r, p, scope)",
            "Compiler.compile(r, p, {:nodes, ids})",
            "Compiler.compile(r, p, :none)",
            "Compiler.compile(r, p, opts[:scope])"
          ] do
        source =
          "defmodule S do\n  alias Letflow.Entities.Query.Compiler\n  alias Other.Thing, as: Other\n  def f(r, p, scope, ids, opts), do: #{call}\nend\n"

        assert violations(source, "lib/x.ex") == [], call
      end
    end

    test "the router file itself is exempt from the comment rule (its value is derived or ruled by the route class)" do
      source = @head <> "  def f(r, p), do: Compiler.compile(r, p, :all)\nend\n"

      assert violations(source, @router_file) == []
      assert [_one] = violations(source, "lib/letflow/routers/other.ex")
    end
  end

  # ===========================================================================================
  describe "T-C2 the real tree" do
    test "no unjustified literal :all argument exists under lib/ (outside the entities router)" do
      offenders =
        for file <- lib_files(),
            source = File.read!(file),
            source =~ ~r/compile|run_aggregate/,
            site <-
              violations(source, file |> Path.relative_to_cwd() |> String.replace("\\", "/")),
            do: {site.file, site.function, site.line}

      assert offenders == []
    end

    test "the ledger of non-router literal sites is exactly the five reviewed ones, each with its rule" do
      ledger =
        real_sites()
        |> Enum.reject(&(&1.file == @router_file))
        |> Enum.map(&{&1.file, &1.function, &1.justification})
        |> Enum.sort()

      assert ledger == [
               {"lib/letflow/entities/script_reads.ex", :compile,
                "scope-all: script principal is tenant-wide, 0051 D1/F6"},
               {"lib/letflow/modules/exam/anti_cheat.ex", :compile, "scope-all: SEC-518-R1"},
               {"lib/letflow/modules/exam/session.ex", :compile, "scope-all: SEC-518-R1"},
               {"lib/letflow/modules/exam/snapshot.ex", :compile, "scope-all: SEC-518-R1"},
               {"lib/mix/tasks/letflow.seed.exam_fixtures.ex", :compile,
                "scope-all: mix task, no HTTP user"}
             ]
    end

    test "every Compiler call under lib/ passes three arguments (no two-argument form survives)" do
      two_arg =
        for file <- lib_files(),
            source = File.read!(file),
            source =~ ~r/compile|run_aggregate/,
            call <- two_argument_calls(source),
            do: {file, call}

      assert two_arg == []
    end

    defp two_argument_calls(source) do
      ast = Code.string_to_quoted!(source)
      aliases = collect_aliases(ast)
      piped = collect_piped(ast)

      {_, found} =
        Macro.prewalk(ast, [], fn
          {{:., _, [target, fun]}, meta, args} = node, acc
          when fun in @functions and is_list(args) ->
            extra = if MapSet.member?(piped, {fun, meta[:line]}), do: 1, else: 0

            if compiler?(target, aliases) and length(args) + extra == 2,
              do: {node, [{fun, meta[:line]} | acc]},
              else: {node, acc}

          node, acc ->
            {node, acc}
        end)

      found
    end

    test "the scan sees the sites at all: the three router sites and the five ledger sites exist" do
      sites = real_sites()

      assert Enum.count(sites, &(&1.file == @router_file)) == 3
      assert length(sites) == 8
    end
  end

  # ===========================================================================================
  describe "the router literals are safe only while their routes are :tenant_wide" do
    @filter_routes [
      {"POST", "/entities/query"},
      {"POST", "/entities/query/aggregate"},
      {"POST", "/entities/records/:entity_type/export"}
    ]

    test "a literal :all in routers/entities.ex implies the query, aggregate and export routes are all :tenant_wide" do
      routes = RouteInventory.routes()

      classes =
        for {method, path} <- @filter_routes do
          row = Enum.find(routes, &(&1.method == method and &1.path == path))
          assert row, "route #{method} #{path} not found"
          {{method, path}, row.class}
        end

      literals = real_sites() |> Enum.filter(&(&1.file == @router_file))

      if literals != [] do
        not_tenant_wide = for {route, class} <- classes, class != :tenant_wide, do: {route, class}

        assert not_tenant_wide == [],
               "routers/entities.ex still passes a literal :all, but #{inspect(not_tenant_wide)} " <>
                 "is no longer :tenant_wide: a scoped caller would receive the whole tenant"
      end
    end
  end

  # ===========================================================================================
  describe "T-C15 (scan half) R-1: the exam literals and the exam manifest" do
    # the guard as a pure function: the ruling lapses when the exam manifest declares scopes
    # while a SEC-518-R1 literal remains
    defp r1_lapsed?(exam_manifest, sites) do
      declares? = exam_manifest |> Map.get(:scope_declarations, %{}) |> map_size() > 0
      literal? = Enum.any?(sites, &(&1.justification =~ "SEC-518-R1"))
      declares? and literal?
    end

    test "the real exam manifest declares no scope while the SEC-518-R1 literals remain" do
      exam = Enum.find(Letflow.Modules.Catalog.all_manifests(), &(&1.id == "exam"))
      assert exam

      sites = real_sites() |> Enum.filter(&(&1.justification && &1.justification =~ "SEC-518-R1"))
      assert length(sites) == 3

      refute r1_lapsed?(exam, sites)
      refute Map.has_key?(exam, :scope_declarations)
    end

    test "the guard fires for a seeded exam manifest that gains :scope_declarations" do
      sites = [%{justification: "scope-all: SEC-518-R1"}]
      exam = %{id: "exam", scope_declarations: %{"exam" => {:column, "scope_node"}}}

      assert r1_lapsed?(exam, sites)
      refute r1_lapsed?(%{id: "exam", scope_declarations: %{}}, sites)
      refute r1_lapsed?(exam, [])
    end

    test "list_available_exams/2 keeps its REQUIRED :scope option: absent raises, a bad value raises, before any query" do
      Code.ensure_loaded!(Letflow.Modules.Exam.Session)
      assert function_exported?(Letflow.Modules.Exam.Session, :list_available_exams, 2)
      refute function_exported?(Letflow.Modules.Exam.Session, :list_available_exams, 1)

      prefix = "tenant_" <> String.duplicate("0", 32)

      assert_raise KeyError, fn ->
        Letflow.Modules.Exam.Session.list_available_exams(prefix, page_size: 5)
      end

      assert_raise ArgumentError, fn ->
        Letflow.Modules.Exam.Session.list_available_exams(prefix, scope: nil)
      end

      assert_raise ArgumentError, fn ->
        Letflow.Modules.Exam.Session.list_available_exams(prefix, scope: {:nodes, [1]})
      end
    end

    test "the exam router passes its scope literal with the walk-guard comment (the only exam router literal)" do
      source = File.read!("lib/letflow/modules/exam/router.ex")
      {_ast, comments} = Code.string_to_quoted_with_comments!(source)

      assert Enum.any?(comments, &(&1.text =~ ~r/scope-all:.*:exam_route_reclassified/))
      assert source =~ "scope: :all"
    end
  end
end
