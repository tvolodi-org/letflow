defmodule Letflow.Entities.RecordsScopeAllScanTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii, T-W17 (design `lib/letflow/design/req518-compiler-scope-filter.md`
  3.7 last paragraph and 5.7; spec `test/specs/REQ-518-2c-ii.md`; SEC code-gate step-17): the
  `scope-all:` scan extended to the `Letflow.Entities.Records` write functions.

  `Records.create_record/2`, `update_record/2`, `delete_record/2` and
  `upsert_record_by_external_ref/2` default to `scope: :all` (no check at all). The default
  exists only for system callers, so every call site in `lib/` OUTSIDE `Letflow.Routers.Entities`
  and `Records` itself must either pass an explicit `scope:` key in its attribute literal or carry
  a `# scope-all: <rule or ruling id>` comment on the call line or the lines just above it.

  The scan PARSES (anti-pattern "a grep-shaped acceptance criterion can be tripped by the
  module's own moduledoc": the words `Records.create_record/2` appear in many moduledocs): it
  finds real CALL nodes in the AST (alias-aware: `alias`, `alias ... as:`, `alias ...{A, B}`, a
  fully qualified name), reads the justification from the comments the tokenizer returns, never
  from strings or docs.

    * the justified non-router sites are PINNED to a ledger (a new unannotated or unlisted site
      fails until it is added here with its rule);
    * the router builds its attribute map in four literals (create, update, delete, import entry)
      and EVERY one of them carries `scope:` (a handler that forgets it would silently take the
      `:all` default for a scoped caller);
    * the scan itself is proven live: a seeded source with a bare call fails, one with a comment
      or a `scope:` key passes.

  No database and no global state, so `async: true`.
  """

  use ExUnit.Case, async: true

  @records_parts [:Letflow, :Entities, :Records]
  @functions [:create_record, :update_record, :delete_record, :upsert_record_by_external_ref]
  # The router and the handler modules it delegates to (GH #2833): the record write, import and
  # attachment handlers hold the Records call sites the router used to hold.
  @router_files [
    "lib/letflow/routers/entities.ex",
    "lib/letflow/routers/entities/record_writes.ex",
    "lib/letflow/routers/entities/record_import.ex",
    "lib/letflow/routers/entities/record_attachments.ex",
    "lib/letflow/routers/entities/support.ex"
  ]
  @records_file "lib/letflow/entities/records.ex"
  @justification ~r/\Ascope-all:\s*\S/
  @lines_above 4

  # file => number of justified call sites, outside the router and Records itself
  @ledger %{
    "lib/letflow/entities/import_upsert.ex" => 1,
    "lib/letflow/modules/exam/anti_cheat.ex" => 1,
    # REQ-582 part B: create_assignment/2 is the exam module's own surface for the seed task
    "lib/letflow/modules/exam/authoring.ex" => 4,
    "lib/letflow/modules/exam/certificate.ex" => 1,
    "lib/letflow/modules/exam/session.ex" => 5,
    "lib/letflow/modules/exam/snapshot.ex" => 1,
    "lib/letflow/scheduler/record_deadline_sweep.ex" => 1,
    "lib/mix/tasks/letflow.seed.exam_fixtures.ex" => 1
  }

  # ---- the scanner ---------------------------------------------------------------------------

  # [%{file:, function:, line:, has_scope_key?:, justification:}] for every call of a Records
  # write function in `source`
  defp call_sites(source, file) do
    {ast, comments} =
      Code.string_to_quoted_with_comments!(source, columns: false, token_metadata: true)

    comment_by_line =
      Map.new(comments, fn %{line: line, text: text} ->
        {line, text |> String.trim_leading("#") |> String.trim()}
      end)

    aliases = collect_aliases(ast)

    {_, sites} =
      Macro.prewalk(ast, [], fn
        {{:., _meta, [target, fun]}, call_meta, args} = node, acc
        when fun in @functions and is_list(args) ->
          if records?(target, aliases) do
            first = call_meta[:line]
            last = call_meta[:closing][:line] || first

            justification =
              Enum.find_value((first - @lines_above)..last, fn l ->
                text = Map.get(comment_by_line, l)
                if text && Regex.match?(@justification, text), do: text
              end)

            site = %{
              file: file,
              function: fun,
              line: first,
              has_scope_key?: scope_key?(args),
              justification: justification
            }

            {node, [site | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  defp records?({:__aliases__, _, parts}, aliases),
    do: Map.get(aliases, parts, parts) == @records_parts

  defp records?(_other, _aliases), do: false

  # a `scope:` key anywhere inside the literal first argument (map or keyword)
  defp scope_key?([first | _rest]) do
    {_, found?} =
      Macro.prewalk(first, false, fn
        {:scope, _value} = node, _acc -> {node, true}
        {{:__block__, _, [:scope]}, _value} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp scope_key?([]), do: false

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

  defp lib_files do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&(&1 in [@records_file | @router_files]))
    |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
  end

  defp router_asts do
    Enum.map(@router_files, fn file ->
      {ast, _} = Code.string_to_quoted_with_comments!(File.read!(file), columns: false)
      ast
    end)
  end

  defp all_sites do
    Enum.flat_map(lib_files(), fn file -> call_sites(File.read!(file), file) end)
  end

  defp unjustified(sites),
    do: Enum.reject(sites, &(&1.has_scope_key? or &1.justification != nil))

  # ===========================================================================================
  describe "the scanner is live (seeded sources)" do
    @bare """
    defmodule Seed do
      alias Letflow.Entities.Records
      def go(attrs, prefix), do: Records.create_record(attrs_literal(), prefix)
      defp attrs_literal, do: %{entity_type: "x"}
    end
    """

    test "a bare call (no scope key, no comment) is reported, in each alias form" do
      forms = [
        @bare,
        String.replace(
          @bare,
          "alias Letflow.Entities.Records",
          "alias Letflow.Entities.Records, as: R"
        )
        |> String.replace("Records.create_record", "R.create_record"),
        String.replace(
          @bare,
          "alias Letflow.Entities.Records",
          "alias Letflow.Entities.{Records, Other}"
        ),
        String.replace(@bare, "alias Letflow.Entities.Records\n", "")
        |> String.replace("Records.create_record", "Letflow.Entities.Records.create_record")
      ]

      for source <- forms do
        assert [site] = call_sites(source, "seed.ex")
        assert [^site] = unjustified([site])
      end
    end

    test "each of the four functions is recognised" do
      for fun <- @functions do
        source = String.replace(@bare, "create_record", Atom.to_string(fun))
        assert [%{function: ^fun}] = call_sites(source, "seed.ex")
      end
    end

    test "a `# scope-all: <rule>` comment on the line above, or inside the call, justifies it; an empty rule or a bare `scope-all` does not" do
      above = String.replace(@bare, "  def go", "  # scope-all: seeded rule\n  def go")
      assert [site] = call_sites(above, "seed.ex")
      assert unjustified([site]) == []

      inside =
        String.replace(
          @bare,
          "Records.create_record(attrs_literal(), prefix)",
          "Records.create_record(\n      # scope-all: seeded rule\n      attrs_literal(),\n      prefix\n    )"
        )

      assert [site] = call_sites(inside, "seed.ex")
      assert unjustified([site]) == []

      for bad <- ["# scope-all:", "# scope-all", "# scope all: x", "# not scope-all: x"] do
        source = String.replace(@bare, "  def go", "  #{bad}\n  def go")
        assert [site] = call_sites(source, "seed.ex")
        assert [^site] = unjustified([site]), bad
      end
    end

    test "a justification far above (outside the window) or only in a string/doc does not count" do
      far =
        String.replace(@bare, "  def go", "  # scope-all: too far\n\n\n\n\n\n  def go")

      assert [site] = call_sites(far, "seed.ex")
      assert [^site] = unjustified([site])

      in_string =
        String.replace(@bare, "  def go", ~s(  @doc "# scope-all: nope"\n  def go))

      assert [site] = call_sites(in_string, "seed.ex")
      assert [^site] = unjustified([site])
    end

    test "an explicit `scope:` key in the attribute literal justifies it (map and keyword forms)" do
      for literal <- ["%{entity_type: \"x\", scope: :all}", "[entity_type: \"x\", scope: scope]"] do
        source = String.replace(@bare, "attrs_literal()", literal)
        assert [site] = call_sites(source, "seed.ex")
        assert site.has_scope_key?
        assert unjustified([site]) == []
      end
    end

    test "a function of another module with the same name is not a Records call" do
      source = """
      defmodule Seed do
        alias Letflow.Other.Records
        def go(a, p), do: Records.create_record(a, p)
      end
      """

      assert call_sites(source, "seed.ex") == []
    end
  end

  # ===========================================================================================
  describe "T-W8 reference-check wiring (BUG-1) and the validator pin" do
    @validator "lib/letflow/entities/record/validator.ex"

    defp identifiers(file) do
      {ast, _} = Code.string_to_quoted_with_comments!(File.read!(file), columns: false)

      {_, found} =
        Macro.prewalk(ast, [], fn
          {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
            {node, [Atom.to_string(name) | acc]}

          {{:., _, [_target, fun]}, _, _} = node, acc when is_atom(fun) ->
            {node, [Atom.to_string(fun) | acc]}

          atom, acc when is_atom(atom) ->
            {atom, [Atom.to_string(atom) | acc]}

          bin, acc when is_binary(bin) ->
            {bin, [bin | acc]}

          node, acc ->
            {node, acc}
        end)

      found
    end

    test "the reference check is WIRED: Records calls check_references, the router calls check_references_of_type and check_batch_references (F7 withdrawn; BUG-1)" do
      assert "check_references" in identifiers(@records_file)
      router = Enum.flat_map(@router_files, &identifiers/1)
      assert "check_references_of_type" in router
      assert "check_batch_references" in router
    end

    test "the Validator still reads no reference declaration" do
      hits =
        @validator
        |> identifiers()
        |> Enum.filter(&(&1 =~ ~r/references_entity|foreign_key|reference_check|fk_/))

      assert hits == []
    end

    test "the Validator performs no database read at all (no Repo, Latest, Ecto.Query use)" do
      aliases = identifiers(@validator)
      refute "Repo" in aliases
      refute Enum.any?(aliases, &(&1 in ["get_for_update", "transaction", "query!"]))
    end
  end

  # ===========================================================================================
  describe "T-W17 the real tree" do
    test "every Records write call site outside the router carries a scope key or a `# scope-all:` justification" do
      bare = unjustified(all_sites())

      assert bare == [],
             "unjustified Records calls (pass `scope:` or add `# scope-all: <rule>`):\n" <>
               Enum.map_join(bare, "\n", &"  #{&1.file}:#{&1.line} #{&1.function}")
    end

    test "the justified sites are exactly the pinned ledger (a new caller must be added with its rule)" do
      counts = all_sites() |> Enum.frequencies_by(& &1.file)
      assert counts == @ledger
    end

    test "every ledger site names a rule the SEC rulings know (SEC-518-R1, a tenant-wide-only note, a no-HTTP-user note)" do
      for site <- all_sites() do
        assert site.justification =~ ~r/SEC-518-R1|tenant-wide|no HTTP user|system/, inspect(site)
      end
    end

    test "the router builds EVERY record command attribute literal with `scope:` (four literals: create, update, delete, import entry)" do
      literals =
        Enum.flat_map(router_asts(), fn ast ->
          {_, found} =
            Macro.prewalk(ast, [], fn
              {:%{}, _, pairs} = node, acc when is_list(pairs) ->
                keys = for {k, _v} <- pairs, is_atom(k), do: k

                if :idempotency_key in keys and :entity_type in keys and :actor_id in keys,
                  do: {node, [keys | acc]},
                  else: {node, acc}

              node, acc ->
                {node, acc}
            end)

          found
        end)

      assert length(literals) == 4, inspect(literals)
      assert Enum.all?(literals, &(:scope in &1)), inspect(literals)
    end

    test "the router passes only those literals (or `command_attrs` built from them) to Records" do
      args =
        Enum.flat_map(router_asts(), fn ast ->
          {_, found} =
            Macro.prewalk(ast, [], fn
              {{:., _, [{:__aliases__, _, [:Records]}, fun]}, _, [first | _]} = node, acc
              when fun in [:create_record, :update_record, :delete_record] ->
                {node, [first | acc]}

              node, acc ->
                {node, acc}
            end)

          found
        end)

      assert length(args) == 4
      assert Enum.all?(args, &match?({:command_attrs, _, _}, &1)), inspect(args)
    end
  end
end
