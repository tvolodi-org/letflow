defmodule Letflow.Tasks.ScopeNodeIdNoWriterScanTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2d, T-F2 (AC 12; design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.1, 10.3; spec `test/specs/REQ-518-2d.md`;
  SEC code-gate step-24 MERGE CONDITION: "T-F2 (lib/ source scan: no writer of scope_node_id incl.
  insert_all keyword forms and TaskActivation; absent from cast lists and response maps)"):
  the only function under `lib/` that writes `tasks.scope_node_id` is
  `Letflow.Engine.TaskActivation.insert_task_row/4` (REQ-532 / GH #3091, pinned exactly by name).
  `Letflow.Support.TaskScopeFixture` (test/support, compiled in :test only, NOT scanned) keeps its own
  raw-SQL writer for tests. `.md` history files under `lib/letflow/design/` are not scanned: they are
  records of past designs, not code.

  The scan parses every `lib/**/*.ex` file (comments are not in the AST; `@doc`, `@moduledoc` and
  `@typedoc` text is skipped) and finds every use of the name `scope_node_id`, as an atom or inside
  a string literal (raw SQL), together with the function it sits in. Those uses must equal a PINNED
  LEDGER: the task side holds exactly the three READERS (the schema field, the type and the audit
  exclusion in `Letflow.Engine.Task`; the two predicates in `Letflow.Tasks`; the resolver). A new
  write in any form (cast list, `put_change`, `change`, a struct literal, `insert_all`,
  `update_all`, raw `SET`, `Map.put(_, "scope_node_id", _)`) adds a use and fails the ledger.
  The scanner is proven LIVE on seeded writers of each form. The unrelated grants area
  (`role_scope_grants.scope_node_id`) is pinned as a set of files that never touch tasks.

  REQ-531 / GH #3092 adds the INSTANCE side: `instance_projections.scope_node_id` is written once at
  instance start. Its uses are a second exact ledger by enclosing function (`@instance_ledger`), and
  no function of it may name the Task schema or the tasks table. The task-side property above is
  unchanged: still nothing writes `tasks.scope_node_id` until the task scope writer (REQ-532).

  Behavioral half: no changeset function of `Letflow.Engine.Task` casts the column (every public
  `*_changeset/2` is discovered by reflection and fed a map that names it), and the audit exclusion
  has ONE owner, `Letflow.Engine.Task.audit_state/1`, used at exactly seven call sites in three
  files.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Task, as: EngineTask

  @doc_attrs [:doc, :moduledoc, :typedoc]
  @type_attrs [:type, :typep, :opaque, :spec, :callback]

  # file => the sorted list of enclosing labels of every use in CODE (docs and comments excluded)
  # REQ-532 / GH #3091: the task-side WRITER is `TaskActivation.insert_task_row/4`, the one place that
  # sets the column (from the instance's value). Its two callers carry the value in the same file.
  @task_ledger %{
    "lib/letflow/engine/task.ex" => ["@type", "def audit_state/1", "schema"],
    "lib/letflow/engine/task_activation.ex" => [
      "def append_multi/6",
      "def append_multi_from_existing_records/7",
      "def insert_task_row/4"
    ],
    "lib/letflow/tasks.ex" => ["def in_scope/3", "defp filter_by_scope/2"],
    "lib/letflow/tasks/scope_resolver.ex" => ["def task_scope/1"]
  }

  # REQ-531 / GH #3092: the INSTANCE side. `instance_projections.scope_node_id` is written once at start
  # (insert_changeset only), inherited by sub-process children, carried in `InstanceState`, replayed and
  # read back. An exact, closed list by enclosing function: any further use fails this test and has to be
  # added here on purpose, never by loosening the equality.
  @instance_ledger %{
    "lib/letflow/engine.ex" => [
      "@type",
      "defp append_instance_started_event/8",
      "defp build_instance_state/3",
      "defp build_instance_state/3",
      "defp insert_instance_projection/10",
      "defp persist/14",
      "defp persist/14",
      "defp put_scope_node/2",
      "defp same_start_request?/4",
      "defp same_start_request?/4 (string)",
      "defp start_instance/6",
      "defp start_instance/6",
      "defp validate_scope_node/2"
    ],
    "lib/letflow/engine/instance_state.ex" => ["@type", "module"],
    "lib/letflow/engine/reconstruction.ex" => [
      "defp apply_event/4",
      "defp replayed_scope_node/1 (string)",
      "defp upsert_projection/5",
      "defp upsert_projection/5"
    ],
    "lib/letflow/engine/snapshot_writer.ex" => [
      "defp deserialize_state/2",
      "defp deserialize_state/2 (string)",
      "defp serialize_state/1",
      "defp serialize_state/1 (string)"
    ],
    "lib/letflow/engine/sub_process.ex" => [
      "defp insert_child_instance_projection/10",
      "defp put_scope_node/2",
      "defp read_parent_scope_node/3",
      "defp read_parent_scope_node/3",
      "defp read_parent_scope_node/3",
      "defp with_scope_node/2",
      "defp with_scope_node/2"
    ],
    "lib/letflow/event_store/instance_projection.ex" => ["def insert_changeset/2", "schema"],
    "lib/letflow/routers/instances.ex" => [
      "defp create_attrs/3",
      "defp create_attrs/3 (string)",
      "defp handle_create/1 (string)",
      "defp instance_map/2",
      "defp instance_map/2 (string)",
      "defp list_item_map/1",
      "defp list_item_map/1 (string)",
      "defp render_create/2 (string)",
      "module (string)"
    ]
  }

  # the grants / node-path area: `role_scope_grants.scope_node_id` and its callers. None may touch tasks.
  @grants_area [
    "lib/letflow/api/scope.ex",
    "lib/letflow/identity/membership_scope.ex",
    "lib/letflow/identity/role_scope_grant.ex",
    "lib/letflow/identity/role_scope_grants.ex",
    "lib/letflow/identity/scoped_grants.ex",
    "lib/letflow/routers/tenant_role_scope_grants.ex"
  ]

  # GH #3194 / REQ-561: the tenant scheduled-job table has its own scope_node_id (the node an instance is
  # started in); the sweep hands it to Engine.create/2 as an INSTANCE attr; the router only reads and echoes it. No file writes tasks.
  @scheduled_jobs_ledger %{
    "lib/letflow/scheduled_jobs/job.ex" => [
      "defp validate_field/3",
      "defp validate_field/3",
      "defp validate_field/3",
      "module (string)",
      "module (string)",
      "schema"
    ],
    "lib/letflow/routers/scheduled_jobs.ex" => [
      "defp job_map/1",
      "defp job_map/1 (string)",
      "module",
      "module (string)"
    ],
    "lib/letflow/scheduler/scheduled_job_sweep.ex" => [
      "defp actor_allowed?/2",
      "defp put_scope_node/2",
      "defp start/4"
    ]
  }

  # strings only (a manifest comment); not a use of the column
  @strings_only ["lib/letflow/tenant_provisioning.ex"]

  # ---- the scanner (also run on seeded sources below) ----------------------------------------------

  defp walk({:@, _, [{attr, _, _}]}, _ctx, acc, _pred) when attr in @doc_attrs, do: acc

  defp walk({:@, _, [{attr, _, _}]} = node, _ctx, acc, pred) when attr in @type_attrs,
    do: children(node, "@" <> if(attr == :spec, do: "spec", else: "type"), acc, pred)

  defp walk({kind, _, [head | _]} = node, _ctx, acc, pred)
       when kind in [:def, :defp, :defmacro, :defmacrop],
       do: children(node, "#{kind} #{label(head)}", acc, pred)

  defp walk({:schema, _, _} = node, _ctx, acc, pred), do: children(node, "schema", acc, pred)

  defp walk(atom, ctx, acc, pred) when is_atom(atom), do: hit(pred.(atom), ctx, acc)
  defp walk(bin, ctx, acc, pred) when is_binary(bin), do: hit(pred.(bin), ctx <> " (string)", acc)

  defp walk({head, _, args} = node, ctx, acc, pred) when is_list(args) do
    acc = walk(head, ctx, acc, pred)
    children(node, ctx, acc, pred)
  end

  defp walk({l, r}, ctx, acc, pred), do: walk(r, ctx, walk(l, ctx, acc, pred), pred)

  defp walk(list, ctx, acc, pred) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, ctx, &2, pred))

  defp walk(_other, _ctx, acc, _pred), do: acc

  defp children({_, _, args}, ctx, acc, pred) when is_list(args),
    do: Enum.reduce(args, acc, &walk(&1, ctx, &2, pred))

  defp children(_node, _ctx, acc, _pred), do: acc

  defp hit(true, ctx, acc), do: [ctx | acc]
  defp hit(_no, _ctx, acc), do: acc

  defp label({:when, _, [head | _]}), do: label(head)

  defp label({name, _, args}) when is_atom(name),
    do: "#{name}/#{if is_list(args), do: length(args), else: 0}"

  defp label(_other), do: "?"

  defp names_column?(:scope_node_id), do: true
  defp names_column?(bin) when is_binary(bin), do: String.contains?(bin, "scope_node_id")
  defp names_column?(_other), do: false

  # every use of the column name in the CODE of `source`, as sorted enclosing labels
  defp uses(source) do
    source |> Code.string_to_quoted!() |> walk("module", [], &names_column?/1) |> Enum.sort()
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex") |> Enum.sort()

  # ===========================================================================================
  describe "AC 12 / T-F2: no lib/ writer of tasks.scope_node_id" do
    test "the uses of the name in lib/ code are exactly the pinned ledger: three task READERS and the unrelated grants area" do
      found =
        for file <- lib_files(),
            source = File.read!(file),
            String.contains?(source, "scope_node_id"),
            labels = uses(source),
            labels != [],
            into: %{} do
          {file, labels}
        end

      expected_files =
        Map.keys(@task_ledger) ++
          Map.keys(@instance_ledger) ++
          Map.keys(@scheduled_jobs_ledger) ++ @grants_area ++ @strings_only

      assert Enum.sort(Map.keys(found)) == Enum.sort(expected_files)

      for {file, labels} <-
            Map.merge(Map.merge(@task_ledger, @instance_ledger), @scheduled_jobs_ledger) do
        assert Map.fetch!(found, file) == labels, file
      end

      for file <- @strings_only do
        assert Enum.all?(found[file], &String.ends_with?(&1, "(string)")), file
      end
    end

    test "the grants-area files that name the column never touch tasks (no Engine.Task alias, no tasks table)" do
      for file <- @grants_area do
        ast = file |> File.read!() |> Code.string_to_quoted!()

        {_ast, refs} =
          Macro.prewalk(ast, [], fn
            {:__aliases__, _, parts} = node, acc ->
              if :Task in parts and :Engine in parts,
                do: {node, [:engine_task | acc]},
                else: {node, acc}

            bin, acc when is_binary(bin) ->
              if bin in ["tasks", "task"], do: {bin, [:tasks_table | acc]}, else: {bin, acc}

            node, acc ->
              {node, acc}
          end)

        assert refs == [], "#{file} touches tasks: #{inspect(refs)}"
      end
    end

    test "no instance-side function that names the column mentions the Task schema or the tasks table (REQ-531)" do
      for {file, labels} <- @instance_ledger do
        ast = file |> File.read!() |> Code.string_to_quoted!()
        names = labels |> Enum.map(&String.replace(&1, " (string)", "")) |> Enum.uniq()

        for def_node <- column_defs(ast), label_of(def_node) in names do
          {_n, refs} =
            Macro.prewalk(def_node, [], fn
              {:__aliases__, _, parts} = n, acc ->
                {n, if(List.last(parts) == :Task, do: [:task_alias | acc], else: acc)}

              bin, acc when is_binary(bin) ->
                {bin, if(bin in ["tasks", "task"], do: [:tasks_table | acc], else: acc)}

              n, acc ->
                {n, acc}
            end)

          assert refs == [], "#{file} #{label_of(def_node)} touches tasks: #{inspect(refs)}"
        end
      end
    end

    # every def / defp of an AST that names the column (the scanner's own predicate)
    defp column_defs(ast) do
      {_ast, acc} =
        Macro.prewalk(ast, [], fn
          {kind, _, [_head | _]} = node, acc when kind in [:def, :defp] ->
            {node, if(uses(Macro.to_string(node)) == [], do: acc, else: [node | acc])}

          node, acc ->
            {node, acc}
        end)

      acc
    end

    defp label_of({kind, _, [head | _]}), do: "#{kind} #{label(head)}"

    test "the only function that WRITES the tasks table and names the column is TaskActivation.insert_task_row/4 (REQ-532 pin)" do
      defs =
        for file <- lib_files(),
            ast = file |> File.read!() |> Code.string_to_quoted!(),
            def_node <- task_writing_defs(ast) do
          {file, def_node}
        end

      # the capture is live: the engine and the task context DO write tasks
      assert length(defs) >= 5

      writers =
        for {file, def_node} <- defs,
            Macro.to_string(def_node) =~ "scope_node_id",
            do: {file, label_of(def_node)}

      # exact pin: any other writer of a `tasks` row that names the column fails here
      assert writers == [{"lib/letflow/engine/task_activation.ex", "def insert_task_row/4"}]
    end

    test "REQ-532 AC 7: the scoped-approver refusal code appears nowhere in lib/*.ex code" do
      for file <- lib_files() do
        refute File.read!(file) =~ "scoped_approvers_without_task_scope", file
      end
    end

    test "the migrations that name the column on the tasks table are exactly the REQ-518 DDL and the REQ-532 backfill" do
      named =
        "priv/repo/migrations"
        |> File.ls!()
        |> Enum.sort()
        |> Enum.filter(fn file ->
          source = File.read!(Path.join("priv/repo/migrations", file))
          String.contains?(source, "scope_node_id") and String.contains?(source, "tasks")
        end)

      assert named == [
               "20261019200001_add_scope_node_id_to_tasks.exs",
               "20261024200001_backfill_tasks_scope_node_id.exs"
             ]
    end

    @write_funs [
      :insert_all,
      :update_all,
      :insert,
      :insert!,
      :update,
      :update!,
      :put_change,
      :change
    ]

    # every def whose body contains a write call AND mentions the Task schema alias or "tasks"
    defp task_writing_defs(ast) do
      {_ast, acc} =
        Macro.prewalk(ast, [], fn
          {kind, _, [_head, _body]} = node, acc when kind in [:def, :defp] ->
            if writes?(node) and task_target?(node), do: {node, [node | acc]}, else: {node, acc}

          node, acc ->
            {node, acc}
        end)

      acc
    end

    defp writes?(node) do
      {_n, found?} =
        Macro.prewalk(node, false, fn
          {{:., _, [_mod, fun]}, _, _args} = n, _acc when fun in @write_funs -> {n, true}
          n, acc -> {n, acc}
        end)

      found?
    end

    defp task_target?(node) do
      {_n, found?} =
        Macro.prewalk(node, false, fn
          {:__aliases__, _, parts} = n, acc -> {n, acc or List.last(parts) == :Task}
          "tasks", _acc -> {"tasks", true}
          n, acc -> {n, acc}
        end)

      found?
    end

    test "the scanner is LIVE: every writer form (cast, put_change, change, struct, insert_all, update_all, raw SQL) is found" do
      seeded = [
        ~S|defmodule A do def a(t, a), do: Ecto.Changeset.cast(t, a, [:node_id, :scope_node_id]) end|,
        ~S|defmodule A do def a(c), do: Ecto.Changeset.put_change(c, :scope_node_id, "x") end|,
        ~S|defmodule A do def a(t), do: Ecto.Changeset.change(t, %{scope_node_id: "x"}) end|,
        ~S|defmodule A do def a, do: %Letflow.Engine.Task{scope_node_id: "x"} end|,
        ~S|defmodule A do def a(r), do: r.insert_all(Task, [[node_id: "n", scope_node_id: "x"]]) end|,
        ~S|defmodule A do def a(r), do: r.insert_all("tasks", [%{scope_node_id: "x"}]) end|,
        ~S|defmodule A do def a(r, q), do: r.update_all(q, set: [scope_node_id: "x"]) end|,
        ~S|defmodule A do def a(r), do: r.query!("UPDATE tasks SET scope_node_id = $1", ["x"]) end|,
        ~S|defmodule A do def a(m), do: Map.put(m, "scope_node_id", "x") end|,
        ~S|defmodule A do def a(t), do: Map.put(t, :scope_node_id, "x") end|
      ]

      for source <- seeded do
        assert uses(source) != [], source
      end

      # the def-level check catches the insert_all / update_all / put_change forms that mention tasks
      flagged =
        for source <- seeded,
            ast = Code.string_to_quoted!(source),
            def_node <- task_writing_defs(ast),
            Macro.to_string(def_node) =~ "scope_node_id" do
          source
        end

      assert length(flagged) >= 2, "the def-level check flags the Task/tasks forms"
    end

    test "the scanner skips docs and comments (a doc string naming the column is not a use) but not code strings" do
      doc_only = ~S|defmodule A do
        @moduledoc "mentions scope_node_id"
        # scope_node_id in a comment
        @doc "scope_node_id"
        def a, do: 1
      end|

      assert uses(doc_only) == []

      assert uses(~S|defmodule A do def a, do: "scope_node_id" end|) == ["def a/0 (string)"]
    end
  end

  # ===========================================================================================
  describe "AC 12 / T-F2 behavioral: not castable, not in an audit payload, one owner" do
    test "every changeset function of Letflow.Engine.Task ignores a scope_node_id in its attrs" do
      changeset_fns =
        for {name, 2} <- EngineTask.__info__(:functions),
            String.ends_with?(Atom.to_string(name), "changeset"),
            do: name

      # the three known ones, discovered (a fourth added later is covered automatically)
      assert Enum.sort(changeset_fns) == [
               :assignment_changeset,
               :complete_changeset,
               :insert_changeset
             ]

      attrs = %{
        "instance_id" => Ecto.UUID.generate(),
        "token_id" => Ecto.UUID.generate(),
        "node_id" => "n",
        "node_name" => "N",
        "assignee_type" => "USER",
        "assignee_ref" => Ecto.UUID.generate(),
        "status" => "completed",
        "scope_node_id" => "sf-a"
      }

      for name <- changeset_fns,
          form <- [attrs, Map.new(attrs, fn {k, v} -> {String.to_atom(k), v} end)] do
        changeset = apply(EngineTask, name, [%EngineTask{}, form])
        refute Map.has_key?(changeset.changes, :scope_node_id), "#{name} casts scope_node_id"
        assert Ecto.Changeset.apply_changes(changeset).scope_node_id == nil, "#{name}"
      end

      # an existing node is not changed by a changeset either
      kept = %EngineTask{scope_node_id: "sf-b"}

      for name <- changeset_fns do
        changeset = apply(EngineTask, name, [kept, %{"scope_node_id" => "sf-a"}])
        assert Ecto.Changeset.apply_changes(changeset).scope_node_id == "sf-b", "#{name}"
      end
    end

    test "Task.audit_state/1 is the one owner: seven call sites in three files; no raw struct_state call takes a task" do
      owners =
        for file <- [
              "lib/letflow/engine.ex",
              "lib/letflow/tasks.ex",
              "lib/letflow/engine/task_activation.ex"
            ],
            into: %{} do
          ast = file |> File.read!() |> Code.string_to_quoted!()

          {_ast, count} =
            Macro.prewalk(ast, 0, fn
              {{:., _, [{:__aliases__, _, [:Task]}, :audit_state]}, _, _} = node, n ->
                {node, n + 1}

              node, n ->
                {node, n}
            end)

          {file, count}
        end

      assert owners == %{
               "lib/letflow/engine.ex" => 4,
               "lib/letflow/tasks.ex" => 2,
               "lib/letflow/engine/task_activation.ex" => 1
             }

      # the remaining raw struct_state calls of the engine are the INSTANCE audits (create, cancel)
      raw =
        "lib/letflow/engine.ex"
        |> File.read!()
        |> Code.string_to_quoted!()
        |> struct_state_sites()

      assert raw == [
               "defp record_instance_cancel_audit/4",
               "defp record_instance_cancel_audit/4",
               "defp record_instance_create_audit/4"
             ]

      for file <- ["lib/letflow/tasks.ex", "lib/letflow/engine/task_activation.ex"] do
        assert file |> File.read!() |> Code.string_to_quoted!() |> struct_state_sites() == [],
               file
      end
    end

    defp struct_state_sites(ast) do
      match = fn
        {{:., _, [{:__aliases__, _, [:Audit]}, :struct_state]}, _, _} -> true
        _ -> false
      end

      collect_sites(ast, "module", match) |> Enum.sort()
    end

    defp collect_sites({kind, _, [head | _]} = node, _ctx, match) when kind in [:def, :defp] do
      children_sites(node, "#{kind} #{label(head)}", match)
    end

    defp collect_sites(node, ctx, match) do
      here = if match.(node), do: [ctx], else: []
      here ++ children_sites(node, ctx, match)
    end

    defp children_sites({_, _, args}, ctx, match) when is_list(args),
      do: Enum.flat_map(args, &collect_sites(&1, ctx, match))

    defp children_sites({l, r}, ctx, match),
      do: collect_sites(l, ctx, match) ++ collect_sites(r, ctx, match)

    defp children_sites(list, ctx, match) when is_list(list),
      do: Enum.flat_map(list, &collect_sites(&1, ctx, match))

    defp children_sites(_other, _ctx, _match), do: []
  end
end
