defmodule Letflow.Entities.ManagedTypes.StampOpenerScanTest do
  @moduledoc """
  GH #2596 T-11, design `lib/letflow/design/gh2596-exam-managed-types.md` section 4.3 (spec
  `test/specs/GH2596-exam-managed.md`): the AST scan that pins WHO may open the database stamp
  exception (`current_setting('letflow.managed_by_stamp', true)` in the trigger function).

  **This is a tripwire, not a security boundary (SECURITY F-2).** It makes a NEW opener a reviewed
  test change. Any raw-SQL code running as the application DB role can still call `set_config` (a
  custom setting needs no privilege) or `DISABLE TRIGGER`, exactly as before GH #2596; no test here
  can prevent that.

  Five assertions over `lib/`, `priv/` (migrations, seeds), `scripts/` and `config/` (AST, via
  `Code.string_to_quoted/2`, not a text grep: a comment naming a function is not a call), each a
  pure function over `[{path, ast}]` so the synthetic negatives feed the SAME detector as the
  real-tree tests:

    1. the fragment `managed_by_stamp`, or a string literal ending in `letflow.` (the start of a
       concatenated or interpolated setting name), appears only in `stamp.ex` and the new
       migration. The walk covers string literals of EVERY form: plain strings, heredocs, sigils
       (`~s`, `~S`, `~r`...), charlists and `fragment/1` literals. (The migration's FILE NAME
       `..._allow_exam_managed_by_stamp.exs` in `TenantProvisioning`'s manifest is the one
       permitted other occurrence and is stripped before the check.)
    2. every `Repo.query`/`Repo.query!`/`Ecto.Adapters.SQL.query`/`query!` call whose SQL argument
       is not a compile-time string literal sits in a file of `@dynamic_sql_files`.
    3. `set_config` occurs in `lib/` string literals only in `step_writes.ex`, `stamp.ex` and the exam snapshot `rollout.ex` and `engine.ex` (timeouts), and
       there only with a LITERAL setting name (`set_config('name', ...)`, never `set_config($1, ...)`).
    4. `Stamp.run/1` and `Stamp.run_tenant/2` are referenced (call, capture, `apply`) only from
       `lib/letflow/release/managed_types.ex` and the two Mix tasks.
    5. no `update_all`/`update` touching `:managed_by`, and no SQL literal updating it, outside
       `stamp.ex` and the insert-time stamping files.

  and `DISABLE TRIGGER`, `session_replication_role` and `ALTER TABLE ... DISABLE` appear in no
  scanned string literal and no `.sql`/`.sh` file.

  Pure file reads, so `async: true`.
  """

  use ExUnit.Case, async: true

  @stamp "lib/letflow/entities/managed_types/stamp.ex"
  @migration "priv/repo/migrations/20261016120001_allow_exam_managed_by_stamp.exs"
  @step_writes "lib/letflow/entities/step_writes.ex"
  # GH #2682 PR a: the exam snapshot rollout bounds its definition writes with the same
  # literal `lock_timeout` / `statement_timeout` settings (never the stamp setting).
  @snapshot_rollout "lib/letflow/modules/exam/snapshot/rollout.ex"
  # GH #2706 PR-2: the cancel transaction bounds its lock waits with the literal `lock_timeout`
  # setting (value bound as a parameter, never the stamp setting).
  @engine "lib/letflow/engine.ex"
  # GH #2883: the operator break-glass sets a transaction-local `lock_timeout` with a bound parameter and
  # a literal setting name (reviewed by SECURITY-REVIEWER, fresh-packet code gate).
  @scope_enforcement "lib/letflow/scope_enforcement.ex"
  @release "lib/letflow/release/managed_types.ex"
  @mix_stamp "lib/mix/tasks/letflow.stamp_managed_types.ex"
  @mix_inventory "lib/mix/tasks/letflow.managed_types_tamper_inventory.ex"

  # Assertion 1: the only files whose string literals may carry the setting name.
  @opener_files [@stamp, @migration]
  # Assertion 2: the files that build SQL text at runtime today. Regenerated from the tree by
  # TEST-DESIGNER for GH #2596 (the first run of this assertion printed exactly these sixteen);
  # adding a file here is a reviewed diff. `stamp.ex` is listed because the design names it; its
  # own queries are literals, so it is not currently found.
  @dynamic_sql_files [
    @stamp,
    "lib/letflow/engine.ex",
    "lib/letflow/entities/record/projector.ex",
    "lib/letflow/entities/records.ex",
    "lib/letflow/entities/step_writes.ex",
    "lib/letflow/event_store/partition_maintenance.ex",
    "lib/letflow/event_store/retention_operations.ex",
    "lib/letflow/identity.ex",
    "lib/letflow/identity/pending_admin_grants.ex",
    "lib/letflow/ordering/metrics.ex",
    "lib/letflow/ordering/sweeper.ex",
    "lib/letflow/sandbox_pool.ex",
    "lib/letflow/sandbox_pool/fixture_loader.ex",
    "lib/letflow/scope_node_paths.ex",
    "lib/letflow/tenant_provisioning.ex",
    "priv/repo/migrations/20260926010001_backfill_exam_tenant_modules.exs",
    "priv/repo/migrations/20261015025331_create_role_scope_grants.exs",
    # REQ-517 2a: the FK migration interpolates only the schema name from `prefix()` (same shape as
    # the 20261015025331 migration above); reviewed by SECURITY-REVIEWER (code gate step-07).
    "priv/repo/migrations/20261018100001_add_scope_node_fkey_to_role_scope_grants.exs"
  ]
  # Assertion 3
  @set_config_files [@step_writes, @stamp, @snapshot_rollout, @engine, @scope_enforcement]
  # Assertion 4
  @stamp_callers [@release, @mix_stamp, @mix_inventory]
  # Assertion 5: the insert-time stamping path (as it stands) plus the platform stamp.
  @managed_by_writers [
    @stamp,
    "lib/letflow/entities/entity_definition.ex",
    "lib/letflow/entities/definitions.ex",
    "lib/letflow/definitions/solution_pack.ex",
    "lib/letflow/modules/installs.ex"
  ]

  @forbidden_ddl [
    ~r/DISABLE\s+TRIGGER/i,
    ~r/session_replication_role/i,
    ~r/ALTER\s+TABLE[^;]*\bDISABLE\b/i
  ]

  setup_all do
    {:ok, files: real_files(), plain_files: plain_files()}
  end

  # ── scan set ────────────────────────────────────────────────────────────────────────────────

  defp real_files do
    paths =
      Path.wildcard("lib/**/*.ex") ++
        Path.wildcard("priv/**/*.{ex,exs}") ++
        Path.wildcard("scripts/**/*.{ex,exs}") ++ Path.wildcard("config/**/*.{ex,exs}")

    for path <- Enum.sort(paths) do
      {path, path |> File.read!() |> Code.string_to_quoted!(file: path)}
    end
  end

  defp plain_files do
    for path <-
          Enum.sort(
            Path.wildcard("priv/**/*.{sql,sh}") ++
              Path.wildcard("scripts/**/*.{sql,sh,ps1}") ++ Path.wildcard("config/**/*.{sql,sh}")
          ),
        do: {path, File.read!(path)}
  end

  defp synthetic(sources) do
    for {path, source} <- sources,
        do: {path, Code.string_to_quoted!(source, file: path, emit_warnings: false)}
  end

  # ── AST helpers ─────────────────────────────────────────────────────────────────────────────

  # Every string literal of every form: plain strings, heredocs and the binary parts of
  # interpolations and sigils are all binaries in the AST; charlists are lists of integers.
  defp literals(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        node, acc when is_binary(node) ->
          {node, [node | acc]}

        [_ | _] = node, acc ->
          if Enum.all?(node, &is_integer/1) and List.ascii_printable?(node),
            do: {node, [List.to_string(node) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # The migration's file name inside TenantProvisioning's manifest is not the setting.
  defp strip_known(literal), do: String.replace(literal, "allow_exam_managed_by_stamp", "")

  defp opener_literal?(literal) do
    stripped = strip_known(literal)
    String.contains?(stripped, "managed_by_stamp") or String.ends_with?(stripped, "letflow.")
  end

  # Assertion 1: paths with an opener literal, minus the allowed ones.
  defp opener_files(files),
    do: for({path, ast} <- files, Enum.any?(literals(ast), &opener_literal?/1), do: path)

  defp opener_violations(files), do: opener_files(files) -- @opener_files

  # Calls as {name, receiver_segments | nil, args}.
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

  defp receiver_segments({:__aliases__, _, segments}), do: segments
  defp receiver_segments({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [{:var, name}]
  defp receiver_segments(atom) when is_atom(atom), do: [atom]
  defp receiver_segments(_computed), do: [:__dynamic__]

  # Piped calls: `a |> f(b)` is `f(a, b)`.
  defp normalize_pipes(ast) do
    Macro.postwalk(ast, fn
      {:|>, _, [lhs, {fun, meta, args}]} when is_list(args) -> {fun, meta, [lhs | args]}
      node -> node
    end)
  end

  defp literal_sql?(node) when is_binary(node), do: true
  defp literal_sql?({:<<>>, _, parts}), do: Enum.all?(parts, &is_binary/1)

  defp literal_sql?({sigil, _, [{:<<>>, _, parts}, _mods]}) when is_atom(sigil),
    do: String.starts_with?(Atom.to_string(sigil), "sigil_") and Enum.all?(parts, &is_binary/1)

  defp literal_sql?(_other), do: false

  defp repo_receiver?(receiver),
    do: receiver in [[:Repo], [:Letflow, :Repo], [{:var, :repo}], [{:var, :repo_module}]]

  defp sql_receiver?(receiver),
    do: receiver in [[:Ecto, :Adapters, :SQL], [:SQL], [:Letflow, :Ecto, :Adapters, :SQL]]

  # Assertion 2: files with a query call whose SQL text is not a literal. `Repo.query(sql, ...)`
  # carries the SQL first; `Ecto.Adapters.SQL.query(repo, sql, ...)` second.
  defp sql_text_argument(receiver, args) do
    cond do
      repo_receiver?(receiver) -> List.first(args)
      sql_receiver?(receiver) -> Enum.at(args, 1)
      true -> nil
    end
  end

  defp dynamic_sql_files(files) do
    for {path, ast} <- files,
        {name, receiver, args} <- calls(normalize_pipes(ast)),
        name in [:query, :query!],
        sql = sql_text_argument(receiver, args),
        not literal_sql?(sql),
        uniq: true,
        do: path
  end

  defp dynamic_sql_violations(files), do: dynamic_sql_files(files) -- @dynamic_sql_files

  # Assertion 3
  defp set_config_files(files),
    do: for({path, ast} <- files, Enum.any?(literals(ast), &set_config?/1), do: path)

  defp set_config?(literal), do: String.contains?(literal, "set_config")

  defp set_config_violations(files) do
    outside = Enum.reject(set_config_files(files), &(&1 in @set_config_files))

    non_literal_name =
      for {path, ast} <- files,
          path in @set_config_files,
          literal <- literals(ast),
          set_config?(literal),
          opens = length(Regex.scan(~r/set_config\(/, literal)),
          literal_names = length(Regex.scan(~r/set_config\(\s*'[A-Za-z_.]+'/, literal)),
          opens != literal_names,
          uniq: true,
          do: path

    outside ++ non_literal_name
  end

  # Assertion 4: references to Stamp.run / Stamp.run_tenant (call, capture, apply).
  defp stamp_receiver?(receiver),
    do: is_list(receiver) and receiver != [] and List.last(receiver) == :Stamp

  defp stamp_reference_files(files) do
    for {path, ast} <- files,
        path != @stamp,
        stamp_reference?(normalize_pipes(ast)),
        do: path
  end

  defp stamp_reference?(ast) do
    direct =
      Enum.any?(calls(ast), fn
        {fun, receiver, _args} when fun in [:run, :run_tenant] ->
          stamp_receiver?(receiver)

        {:apply, _recv, [module, fun, _args]} ->
          stamp_alias?(module) and fun in [:run, :run_tenant]

        _other ->
          false
      end)

    {_ast, captured?} =
      Macro.prewalk(ast, false, fn
        {:&, _, [{:/, _, [{{:., _, [receiver, fun]}, _, []}, _arity]}]} = node, acc
        when fun in [:run, :run_tenant] ->
          {node, acc or stamp_receiver?(receiver_segments(receiver))}

        node, acc ->
          {node, acc}
      end)

    direct or captured?
  end

  defp stamp_alias?({:__aliases__, _, segments}), do: stamp_receiver?(segments)

  defp stamp_alias?(atom) when is_atom(atom),
    do: String.ends_with?(Atom.to_string(atom), ".Stamp")

  defp stamp_alias?(_other), do: false

  defp stamp_caller_violations(files), do: stamp_reference_files(files) -- @stamp_callers

  # Assertion 5: update_all/update touching :managed_by, or an UPDATE ... managed_by SQL literal.
  defp touches_managed_by?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        :managed_by, _acc -> {:managed_by, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp managed_by_write_files(files) do
    for {path, ast} <- files, managed_by_write?(normalize_pipes(ast)), do: path
  end

  defp managed_by_write?(ast) do
    update_call? =
      Enum.any?(update_nodes(ast), &touches_managed_by?/1)

    sql_literal? =
      Enum.any?(literals(ast), &Regex.match?(~r/UPDATE[^;]*\bSET\b[^;]*\bmanaged_by\b/is, &1))

    update_call? or sql_literal?
  end

  # Subtrees rooted at an update/update_all call or at a `update:` / `set:` keyword value.
  defp update_nodes(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_receiver, fun]}, _, _args} = node, acc
        when fun in [:update_all, :update, :update!] ->
          {node, [node | acc]}

        {fun, _, [_ | _]} = node, acc when fun in [:update_all, :update_all!] ->
          {node, [node | acc]}

        {key, value} = node, acc when key in [:update, :set] and is_list(value) ->
          {node, [value | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp managed_by_write_violations(files),
    do: managed_by_write_files(files) -- @managed_by_writers

  # Forbidden DDL in any string literal.
  defp forbidden_ddl_files(files) do
    for {path, ast} <- files,
        Enum.any?(literals(ast), fn literal ->
          Enum.any?(@forbidden_ddl, &Regex.match?(&1, literal))
        end),
        do: path
  end

  # ── the real tree ───────────────────────────────────────────────────────────────────────────

  describe "T-11 real tree" do
    test "the scan set is non-vacuous", %{files: files} do
      paths = Enum.map(files, &elem(&1, 0))

      for required <- [@stamp, @migration, @step_writes, @release, @mix_stamp] do
        assert required in paths, required
      end

      assert length(paths) > 300
    end

    test "1: the setting name is spelled only in stamp.ex and the new migration (and the manifest's file name is not a spelling)",
         %{files: files} do
      assert Enum.sort(opener_files(files)) == Enum.sort(@opener_files)
      assert opener_violations(files) == []
    end

    test "2: dynamic SQL text is built only in the reviewed files", %{files: files} do
      assert dynamic_sql_violations(files) == [],
             "a new non-literal Repo.query/SQL.query site: add it to @dynamic_sql_files only after review. " <>
               "Found: #{inspect(dynamic_sql_files(files))}"
    end

    test "3: set_config appears in lib/ only in step_writes.ex, stamp.ex, the exam snapshot rollout.ex, engine.ex and scope_enforcement.ex (timeouts), with literal setting names",
         %{files: files} do
      lib_only = Enum.filter(files, fn {path, _} -> String.starts_with?(path, "lib/") end)

      assert Enum.sort(set_config_files(lib_only)) == Enum.sort(@set_config_files)
      assert set_config_violations(lib_only) == []
    end

    test "4: Stamp.run and Stamp.run_tenant are referenced only from the release wrapper (and the Mix tasks)",
         %{files: files} do
      assert stamp_reference_files(files) == [@release]
      assert stamp_caller_violations(files) == []
    end

    test "5: managed_by is updated only by Stamp and the insert-time stamping files", %{
      files: files
    } do
      assert managed_by_write_violations(files) == []
      # Non-vacuity: Stamp's own update_all IS seen by the detector.
      {_path, stamp_ast} = Enum.find(files, &(elem(&1, 0) == @stamp))
      assert managed_by_write?(normalize_pipes(stamp_ast))
    end

    test "no scanned string literal or SQL/shell file disables a trigger, changes session_replication_role or runs ALTER TABLE ... DISABLE",
         %{files: files, plain_files: plain} do
      assert forbidden_ddl_files(files) == []

      for {path, text} <- plain, regex <- @forbidden_ddl do
        refute Regex.match?(regex, text), path
      end
    end
  end

  # ── synthetic negatives (the same detectors) ────────────────────────────────────────────────

  describe "T-11 synthetic negatives: assertion 1 (string literals of every form)" do
    test "a plain string, a concatenated name, an interpolated name, a heredoc, sigils, a charlist and a fragment literal each violate" do
      sources = [
        {"lib/a1.ex", ~s|x = "letflow.managed_by_stamp"|},
        {"lib/a2.ex", ~s|x = "letflow." <> suffix|},
        {"lib/a3.ex", ~S|x = "letflow.#{suffix}"|},
        {"lib/a4.ex", ~s|x = """
SELECT set_config('letflow.managed_by_stamp', 'exam', true)
"""|},
        {"lib/a5.ex", ~s|x = ~s(letflow.managed_by_stamp)|},
        {"lib/a6.ex", ~s|x = ~S(letflow.managed_by_stamp)|},
        {"lib/a7.ex", ~s|x = ~r/managed_by_stamp/|},
        {"lib/a8.ex", ~s|x = 'letflow.managed_by_stamp'|},
        {"lib/a9.ex",
         ~s|from(d in "t", where: fragment("current_setting('letflow.managed_by_stamp')"))|},
        {"priv/repo/seeds_x.exs",
         ~s|Repo.query!("SELECT set_config('letflow.managed_by_stamp','exam',true)")|}
      ]

      violations = sources |> synthetic() |> opener_violations() |> Enum.sort()
      assert violations == sources |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "the allowed files are not flagged; the manifest file-name literal is not a spelling; clean code is not flagged" do
      files =
        synthetic([
          {@stamp, ~s|x = "letflow.managed_by_stamp"|},
          {@migration, ~s|x = "current_setting('letflow.managed_by_stamp')"|},
          {"lib/letflow/tenant_provisioning.ex",
           ~s|x = "20261016120001_allow_exam_managed_by_stamp.exs"|},
          {"lib/clean.ex", ~s|x = "letflow" <> "-tenant"|}
        ])

      assert opener_violations(files) == []
    end
  end

  describe "T-11 synthetic negatives: assertion 2 (dynamic SQL sites)" do
    test "a variable, an interpolated string and an adapter call with a variable SQL violate; literals do not" do
      files =
        synthetic([
          {"lib/d1.ex", "Repo.query!(sql, [])"},
          {"lib/d2.ex", ~S|Repo.query("SELECT #{x}", [])|},
          {"lib/d3.ex", "Ecto.Adapters.SQL.query!(Repo, sql, [])"},
          {"lib/d4.ex", "sql |> Repo.query([])"},
          {"lib/ok1.ex", ~s|Repo.query!("SELECT 1", [])|},
          {"lib/ok2.ex", ~s|Repo.query!(~s(SELECT 1))|},
          {"lib/ok3.ex", ~s|Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])|},
          {"lib/ok4.ex", "Repo.query!(\"\"\"\nSELECT 1\n\"\"\")"}
        ])

      assert Enum.sort(dynamic_sql_violations(files)) == [
               "lib/d1.ex",
               "lib/d2.ex",
               "lib/d3.ex",
               "lib/d4.ex"
             ]
    end
  end

  describe "T-11 synthetic negatives: assertion 3 (set_config)" do
    test "set_config in a new file (any literal form), and a bound setting name inside an allowed file, violate" do
      files =
        synthetic([
          {"lib/s1.ex", ~s|Repo.query!("SELECT set_config('x', 'y', true)")|},
          {"lib/s2.ex",
           ~s|from(d in "t", where: fragment("set_config('x', 'y', true) = ?", d.a))|},
          {"lib/s3.ex", "x = \"\"\"\nSELECT set_config('x', 'y', true)\n\"\"\""},
          {"lib/s4.ex", ~s|x = ~s[SELECT set_config('x','y',true)]|},
          {@stamp, ~s|Repo.query!("SELECT set_config($1, $2, true)", [name, value])|},
          {@step_writes, ~s|Repo.query!("SELECT set_config('lock_timeout', $1, true)", [v])|},
          {"lib/ok.ex", ~s|x = "no setting here"|}
        ])

      assert Enum.sort(set_config_violations(files)) == [
               "lib/letflow/entities/managed_types/stamp.ex",
               "lib/s1.ex",
               "lib/s2.ex",
               "lib/s3.ex",
               "lib/s4.ex"
             ]
    end
  end

  describe "T-11 synthetic negatives: assertion 4 (Stamp callers)" do
    test "a router calling Stamp.run, the qualified name, run_tenant, a capture and an apply each violate; the wrapper does not" do
      files =
        synthetic([
          {"lib/letflow/routers/r1.ex", "Stamp.run([])"},
          {"lib/letflow/routers/r2.ex",
           "Letflow.Entities.ManagedTypes.Stamp.run_tenant(schema, [])"},
          {"lib/letflow/routers/r3.ex", "f = &Stamp.run/1"},
          {"lib/letflow/routers/r4.ex", "apply(Stamp, :run, [[]])"},
          {"lib/letflow/routers/r5.ex", "[] |> ManagedTypes.Stamp.run()"},
          {@release, "Stamp.run(opts)"},
          {"lib/letflow/routers/ok.ex", "Other.run([]) && OwnerStamp.run_tenant(a, b)"}
        ])

      assert Enum.sort(stamp_caller_violations(files)) ==
               Enum.map(1..5, &"lib/letflow/routers/r#{&1}.ex")
    end
  end

  describe "T-11 synthetic negatives: assertion 5 (managed_by writes)" do
    test "update_all/update/Changeset forms touching :managed_by, and an UPDATE ... SET managed_by literal, violate; the allowed files and unrelated updates do not" do
      files =
        synthetic([
          {"lib/u1.ex", ~s|Repo.update_all(from(d in X), set: [managed_by: "exam"])|},
          {"lib/u2.ex",
           ~S'from(d in X, update: [set: [managed_by: "exam"]]) |> Repo.update_all([])'},
          {"lib/u3.ex", ~S'row |> Ecto.Changeset.change(managed_by: "exam") |> Repo.update()'},
          {"lib/u4.ex", ~s|Repo.query!("UPDATE t.entity_definitions SET managed_by = 'exam'")|},
          {@stamp, ~s|Repo.update_all(q, set: [managed_by: "exam"])|},
          {"lib/letflow/entities/definitions.ex", ~s|put_managed_by(changeset, module_id)|},
          {"lib/ok1.ex", ~s|Repo.update_all(q, set: [display_name: "x"])|}
        ])

      assert Enum.sort(managed_by_write_violations(files)) == [
               "lib/u1.ex",
               "lib/u2.ex",
               "lib/u3.ex",
               "lib/u4.ex"
             ]
    end
  end

  describe "T-11 synthetic negatives: forbidden DDL" do
    test "DISABLE TRIGGER, session_replication_role and ALTER TABLE ... DISABLE in any literal violate" do
      files =
        synthetic([
          {"lib/f1.ex", ~s|Repo.query!("ALTER TABLE x DISABLE TRIGGER y")|},
          {"lib/f2.ex", ~s|Repo.query!("SET session_replication_role = replica")|},
          {"lib/f3.ex", ~s|x = ~s(ALTER TABLE a DISABLE ROW LEVEL SECURITY)|},
          {"lib/ok.ex", ~s|Repo.query!("ALTER TABLE x ENABLE TRIGGER y")|}
        ])

      assert Enum.sort(forbidden_ddl_files(files)) == ["lib/f1.ex", "lib/f2.ex", "lib/f3.ex"]
    end
  end
end
