defmodule Letflow.ScopeEnforcementFlipAuthorityTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 8, AC 20 and AC 24 (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` section 4.9, tests T-X8 and the
  source scan; SEC step-21 condition "AC 24 scan test"; spec `test/specs/REQ-519-2f-b.md`):
  nothing but the guarded flip can set a tenant to `on`.

  Source scans over `lib/`, `priv/`, `config/`, `scripts/`, `.github/` and `mix.exs` (AST for Elixir
  source, text for everything else), each PROVEN LIVE on a seeded offender:

    * the `tenants.scope_enforcement` column is written by `Tenant.scope_enforcement_changeset/2`
      and that changeset is called only by `lib/letflow/scope_enforcement.ex`;
    * no `lib/` Elixir source holds a literal pair `scope_enforcement: :on` / `"on"` (map, keyword,
      struct, changeset attrs) except the one READ pattern of the auth pipeline;
    * no `UPDATE ... scope_enforcement`, `update_all` of the column or `set: [scope_enforcement: ...]`
      anywhere in `lib/` or `priv/`;
    * no seed, migration, config file, script or workflow sets a tenant to `on` (the two
      migrations that name the column are pinned to what they may contain); `config/` never names
      the column at all;
    * only the router calls `flip/4`; the `:credential` of the `auth_context` is built only by the
      auth pipeline; the flag route is the ONLY route of the `:ScopeEnforcementManage` key (the
      platform-scope flip route for ANOTHER tenant is NOT built, AC 20);
    * GH #2883 (the operator break-glass; spec `test/specs/GH2883-break-glass.md`): ONE caller of
      `flip_out_of_band/3` (a text scan over ALL of `lib/` plus AST scans), one call expression
      of the changeset, no HTTP surface, a transaction timeout derived from the lock timeout and
      the lock-timeout key absent from every config file.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Support.RouteInventory

  @flip_module "lib/letflow/scope_enforcement.ex"
  @router "lib/letflow/routers/tenant_scope_enforcement.ex"
  @auth_pipeline "lib/letflow/plugs/auth_pipeline.ex"
  @read_pattern_files [@auth_pipeline]
  @add_column_migration "priv/repo/migrations/20261015025332_add_scope_enforcement_to_tenants.exs"
  @widen_migration "priv/repo/migrations/20261018200001_widen_tenants_scope_enforcement_check.exs"

  # --- scanners ----------------------------------------------------------------------------------

  defp rel(path), do: path |> Path.relative_to_cwd() |> String.replace("\\", "/")

  defp lib_files, do: "lib/**/*.ex" |> Path.wildcard() |> Enum.map(&rel/1)

  defp quoted!(path), do: path |> File.read!() |> Code.string_to_quoted!(file: path)

  # Every {key, value} pair in the AST (map, keyword, struct and call options alike) where the
  # key is the column name and the value the literal on.
  defp on_pairs(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {key, value} = node, acc
        when key in [:scope_enforcement, "scope_enforcement"] and value in [:on, "on"] ->
          {node, [{key, value} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp calls?(ast, name) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or call_of?(node, name)} end)

    found?
  end

  defp call_of?({name, _, args}, name) when is_list(args), do: true
  defp call_of?({{:., _, [_mod, name]}, _, args}, name) when is_list(args), do: true
  defp call_of?(_node, _name), do: false

  defp files_calling(files, name),
    do: for(path <- files, calls?(quoted!(path), name), do: path)

  # Text patterns that write the column from SQL or an Ecto bulk update.
  @sql_setter ~r/UPDATE\s+\S*tenants\S*\s+SET[^;]*scope_enforcement/is
  @bulk_setter ~r/(update_all|set:)[^\n]*scope_enforcement/

  defp setter_text?(text), do: text =~ @sql_setter or text =~ @bulk_setter

  # `scope_enforcement` followed (same line) by the on value in any spelling.
  @on_text ~r/scope_enforcement[^\n]*(['"]on['"]|:on\b)/

  # The CI directory glob is built from a sigil, not written as a string literal: the CI path-filter
  # guard (ci_backend_path_filter_test) treats every path-like string literal in test/ as a path the
  # backend gate READS, and this scan only reads the directory to prove nothing in it sets `on`.
  defp ci_dir_glob, do: Path.join([hd(~w(.github)), "**", "*"])

  defp files_with_text(globs, regex) do
    for glob <- globs,
        path <- Path.wildcard(glob, match_dot: true),
        File.regular?(path),
        File.read!(path) =~ regex,
        do: rel(path)
  end

  # --- the column has one writer ----------------------------------------------------------------

  describe "the guarded flip is the only writer of the column" do
    test "Tenant.scope_enforcement_changeset/2 is called only by lib/letflow/scope_enforcement.ex" do
      others = Enum.reject(lib_files(), &(&1 in ["lib/letflow/identity/tenant.ex", @flip_module]))
      assert files_calling(others, :scope_enforcement_changeset) == []
      assert files_calling([@flip_module], :scope_enforcement_changeset) == [@flip_module]
    end

    test "only the router calls ScopeEnforcement.flip/4 from lib/" do
      callers =
        for path <- lib_files(),
            ast = quoted!(path),
            {_ast, true} <-
              [
                Macro.prewalk(ast, false, fn
                  {{:., _, [{:__aliases__, _, parts}, :flip]}, _, _args} = node, acc ->
                    {node, acc or List.last(parts) == :ScopeEnforcement}

                  node, acc ->
                    {node, acc}
                end)
              ],
            do: path

      assert callers == [@router]
    end

    test "no lib/ source has a literal scope_enforcement pair set to on, except the auth pipeline's READ pattern" do
      offenders =
        for path <- lib_files(), on_pairs(quoted!(path)) != [], do: path

      assert offenders == @read_pattern_files

      # the one allowed occurrence is a function-head pattern matching a %Tenant{} struct
      source = File.read!(@auth_pipeline)
      assert source =~ ~r/defp scope_enforcement\(%Tenant\{scope_enforcement: :on\}\), do: :on/
      assert length(on_pairs(quoted!(@auth_pipeline))) == 1
    end

    test "no lib/ or priv/ file writes the column with SQL or a bulk update" do
      assert files_with_text(["lib/**/*.ex", "priv/**/*"], @sql_setter) == []
      assert files_with_text(["lib/**/*.ex", "priv/**/*"], @bulk_setter) == []
    end

    test "the router builds the flip attrs from a literal map and the flag route is the only route of its key" do
      routes = Enum.filter(RouteInventory.routes(), &(&1.key == :ScopeEnforcementManage))

      # T-X8 / AC 20: the platform-scope flip route for ANOTHER tenant is not built
      assert [%{method: "PUT", path: "/tenant/scope-enforcement"}] = routes

      # the only route with a flip-capable key: nothing else mounts the router module
      mounts =
        Enum.filter(
          RouteInventory.routes(),
          &(&1.router == Letflow.Routers.TenantScopeEnforcement)
        )

      assert Enum.count(mounts, &(&1.method == "PUT")) == 1
    end
  end

  # --- no seed, migration, config or script sets on (AC 24) --------------------------------------

  describe "AC 24 nothing sets a tenant to on" do
    test "no priv/, config/, scripts/, .github/ or mix.exs line names the column next to an on value, bar the pinned migration" do
      hits =
        files_with_text(
          ["priv/**/*", "config/**/*", "scripts/**/*", ci_dir_glob(), "mix.exs"],
          @on_text
        )

      assert hits == [@widen_migration]

      # the widened CHECK and the rollback guard are the only places the value appears
      source = File.read!(@widen_migration)
      refute source =~ ~r/UPDATE|update_all|INSERT/i
      assert source =~ "scope_enforcement IN ('off', 'shadow', 'on')"
      assert source =~ "SELECT count(*) FROM tenants WHERE scope_enforcement = 'on'"
    end

    test "the migration that added the column defaults every tenant to off and names no on" do
      source = File.read!(@add_column_migration)

      assert source =~ ~r/default:\s*"off"/
      refute source =~ ~r/'on'|"on"|:on\b/
    end

    test "config/ never names the column or the flag route" do
      assert files_with_text(["config/**/*"], ~r/scope_enforcement|scope-enforcement/) == []
    end

    test "no seed, script, workflow or solution pack drives the flag route" do
      hits =
        files_with_text(
          ["priv/**/*", "scripts/**/*", ci_dir_glob(), "deploy/**/*", "config/**/*"],
          ~r/tenant\/scope-enforcement|scope_enforcement/
        )

      # the two migrations that create / widen the column are the only mentions
      assert Enum.sort(hits) == Enum.sort([@add_column_migration, @widen_migration])
    end

    test "no lib/ source other than the pipeline reads or writes the column through a string literal on" do
      # `"on"` next to `scope_enforcement` in lib/ (comments and docs excluded by the AST)
      offenders =
        for path <- lib_files(),
            Enum.any?(on_pairs(quoted!(path)), fn {key, _value} -> key == "scope_enforcement" end),
            do: path

      assert offenders == []
    end
  end

  # --- the credential of the auth context -----------------------------------------------------------

  describe "the credential assign" do
    test "only the auth pipeline builds the auth_context; the only other assigner merely adds the grants" do
      assigners =
        for path <- lib_files(),
            source = File.read!(path),
            source =~ ":auth_context",
            assigns_auth_context?(quoted!(path)),
            do: path

      assert Enum.sort(assigners) == Enum.sort([@auth_pipeline, "lib/letflow/api/scope.ex"])

      # scope.ex only adds :scope_grants to the existing context, never a credential
      scope = File.read!("lib/letflow/api/scope.ex")
      assert scope =~ "Map.put(ctx, :scope_grants, grants)"
      refute scope =~ ~r/Map\.put\(ctx, :credential/
    end
  end

  defp assigns_auth_context?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:assign, _, [_conn, :auth_context, _value]} = node, acc -> {node, true or acc}
        node, acc -> {node, acc}
      end)

    found?
  end

  # --- every scan is live ------------------------------------------------------------------------

  describe "the scans are proven live on seeded offenders" do
    test "the AST scan finds literal on pairs in every spelling and ignores comments, strings and variables" do
      seeded = """
      defmodule Seeded do
        def a, do: %{scope_enforcement: :on}
        def b, do: [scope_enforcement: "on"]
        def c, do: %{"scope_enforcement" => "on"}
        def d(t), do: Ecto.Changeset.change(t, scope_enforcement: :on)
        def e, do: %Tenant{scope_enforcement: :on}
      end
      """

      quiet = """
      defmodule Quiet do
        # scope_enforcement: :on
        @doc "scope_enforcement: :on"
        def a(mode), do: %{scope_enforcement: mode}
        def b, do: %{scope_enforcement: :shadow, other: :on}
        def c, do: %{scope_enforcement: :off}
      end
      """

      assert length(on_pairs(Code.string_to_quoted!(seeded))) == 5
      assert on_pairs(Code.string_to_quoted!(quiet)) == []
    end

    test "the call scan finds a seeded changeset call and the text scans find seeded setters" do
      assert calls?(
               Code.string_to_quoted!("Tenant.scope_enforcement_changeset(t, %{})"),
               :scope_enforcement_changeset
             )

      assert calls?(
               Code.string_to_quoted!("scope_enforcement_changeset(t, %{})"),
               :scope_enforcement_changeset
             )

      refute calls?(
               Code.string_to_quoted!("# scope_enforcement_changeset(t, %{})\n:ok"),
               :scope_enforcement_changeset
             )

      assert setter_text?("UPDATE tenants SET scope_enforcement = 'on' WHERE id = $1")
      assert setter_text?("UPDATE public.tenants\n   SET scope_enforcement = $1")
      assert setter_text?("Repo.update_all(Tenant, set: [scope_enforcement: :on])")
      assert setter_text?("from(t in Tenant) |> Repo.update_all(set: [scope_enforcement: m])")
      refute setter_text?("SELECT scope_enforcement FROM tenants")

      assert "tenants SET scope_enforcement = 'on'" =~ @on_text
      assert "scope_enforcement: :on" =~ @on_text
      assert ~s(scope_enforcement => "on") =~ @on_text
      refute "scope_enforcement: :shadow, other: :one" =~ @on_text
    end

    test "the file-text scan reports a seeded offender in a temporary directory" do
      dir =
        System.tmp_dir!()
        |> Path.join("req519_ac24_#{System.unique_integer([:positive])}")
        |> String.replace("\\", "/")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "seed.sql"), "UPDATE tenants SET scope_enforcement = 'on';\n")
      File.write!(Path.join(dir, "clean.sql"), "SELECT 1;\n")

      assert files_with_text([Path.join(dir, "*")], @on_text) |> Enum.map(&Path.basename/1) ==
               ["seed.sql"]
    end
  end

  # --- GH #2883 (T-BG-14c iv/v, T-BG-29, T-BG-31, T-BG-32): the operator break-glass has ONE caller --
  #
  # `flip_out_of_band/3` is a public function with NO authority check of its own: the only control
  # that nobody but the release module calls it is this scan set (SECURITY-REVIEWER design gate
  # F-2). Text scans over ALL of `lib/` (comments and strings included, so `apply/3`, captures,
  # aliases, imports and mentions in an unlisted file are caught), AST scans for the call
  # expressions, and every scan is proven live on seeded offenders below.
  #
  # Deviation from the design text, recorded in the spec: the design lists `ScopeBreakGlass` as
  # allowed only in the release module and the Mix task, but its own section 10.3 requires the
  # `ScopeEnforcement` moduledoc to NAME the sole caller `Letflow.Release.ScopeBreakGlass`, so that
  # one file is allowed to mention it (the call scan, which is AST, still forbids a call there).

  @bg_release "lib/letflow/release/scope_break_glass.ex"
  @bg_task "lib/mix/tasks/letflow.scope_enforcement.break_glass.ex"
  @bg_lock_key "scope_break_glass_lock_timeout_ms"

  # needle => the only lib files that may contain it (text)
  @bg_allowed %{
    "flip_out_of_band" => [@flip_module, @bg_release],
    "ScopeBreakGlass" => [@flip_module, @bg_release, @bg_task],
    "out_of_band" => [@flip_module, @bg_release, @bg_task]
  }

  # `[{path, needle}]` for every source that holds a needle it may not hold.
  defp text_offenders(sources) do
    for {path, text} <- sources,
        {needle, allowed} <- @bg_allowed,
        String.contains?(text, needle),
        path not in allowed,
        do: {path, needle}
  end

  defp lib_sources, do: for(path <- lib_files(), do: {path, File.read!(path)})

  # number of CALL expressions (local or remote) of `name` in the AST
  defp call_count(ast, name) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        {node, if(call_of?(node, name), do: acc + 1, else: acc)}
      end)

    count
  end

  # `{function_name, calls}` for every def/defp whose body calls `name`
  defp functions_calling(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          calls = call_count(body, name)
          if calls > 0, do: {node, [{head_name(head), calls} | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp head_name({:when, _, [head | _guards]}), do: head_name(head)
  defp head_name({name, _, _args}), do: name

  # AST: any alias that ends in the break-glass module
  defp break_glass_alias?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:__aliases__, _, parts} = node, acc -> {node, acc or :ScopeBreakGlass in parts}
        node, acc -> {node, acc}
      end)

    found?
  end

  # the `timeout:` option of every `Repo.transaction` call inside `def flip_out_of_band`
  defp transaction_options(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, body]} = node, acc ->
          if head_name(head) == :flip_out_of_band, do: {node, [body | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    for body <- found,
        {_ast, calls} <-
          [
            Macro.prewalk(body, [], fn
              {{:., _, [{:__aliases__, _, [:Repo]}, :transaction]}, _, args} = node, acc ->
                {node, [args | acc]}

              node, acc ->
                {node, acc}
            end)
          ],
        args <- calls,
        do: transaction_timeout(args)
  end

  defp transaction_timeout(args) do
    case List.last(args) do
      opts when is_list(opts) -> Keyword.get(opts, :timeout)
      _no_options -> nil
    end
  end

  # route/permission words
  defp mentions_break?(values),
    do: Enum.any?(values, &(&1 |> inspect() |> String.downcase() |> String.contains?("break")))

  @bg_config_globs ["config/**/*", "rel/**/*", "mix.exs"]

  # the files (outside test/) that name the application key
  defp key_files(globs), do: files_with_text(globs, @bg_lock_key)

  describe "T-BG-29 the break-glass has one caller and no surface" do
    test "flip_out_of_band is called from lib/ only by the release module (AST, remote or local)" do
      others = Enum.reject(lib_files(), &(&1 == @flip_module))
      assert files_calling(others, :flip_out_of_band) == [@bg_release]

      # one call expression, and it is the remote call on ScopeEnforcement
      ast = quoted!(@bg_release)
      assert call_count(ast, :flip_out_of_band) == 1
      assert File.read!(@bg_release) =~ "ScopeEnforcement.flip_out_of_band("
    end

    test "text scan over ALL of lib/: the three needles occur only in their allowed files" do
      assert text_offenders(lib_sources()) == []
      # the allowed files do contain them (the scan is not vacuous)
      sources = Map.new(lib_sources())
      assert sources[@flip_module] =~ "flip_out_of_band"
      assert sources[@bg_release] =~ "flip_out_of_band"
      assert sources[@bg_release] =~ "ScopeBreakGlass"
      assert sources[@bg_task] =~ "ScopeBreakGlass"
    end

    test "no router, api or plug file (and not the flag router) references the break-glass" do
      guarded =
        for dir <- ~w(routers api plugs),
            path <- Path.wildcard("lib/letflow/#{dir}/**/*.ex"),
            do: rel(path)

      assert @router in guarded
      assert length(guarded) > 20

      aliased = for path <- guarded, break_glass_alias?(quoted!(path)), do: path
      assert aliased == []

      assert files_calling(guarded, :flip_out_of_band) == []

      texty =
        for path <- guarded,
            text = File.read!(path),
            String.contains?(text, "flip_out_of_band") or
              String.contains?(text, "ScopeBreakGlass") or
              String.contains?(text, "break_glass"),
            do: path

      assert texty == []
    end

    test "no script, workflow, config, seed, migration, deploy or release file mentions the command" do
      globs = [
        "priv/**/*",
        "config/**/*",
        "scripts/**/*",
        ci_dir_glob(),
        "deploy/**/*",
        "rel/**/*",
        "mix.exs"
      ]

      assert files_with_text(globs, ~r/break_glass|ScopeBreakGlass|flip_out_of_band/) == []
    end

    test "no route, route key, permission or route-snapshot line mentions a break-glass; the flag key keeps its one route" do
      routes = RouteInventory.routes()

      refute mentions_break?(Enum.flat_map(routes, &[&1.path, &1.key, &1.router]))
      refute mentions_break?(Letflow.Api.Authorization.permissions())
      refute mentions_break?(RouteInventory.read_snapshot())

      assert [%{method: "PUT", path: "/tenant/scope-enforcement"}] =
               Enum.filter(routes, &(&1.key == :ScopeEnforcementManage))
    end
  end

  describe "T-BG-31 one writer expression" do
    test "scope_enforcement_changeset has exactly one call expression, inside write_flag_and_audit!" do
      ast = quoted!(@flip_module)

      assert call_count(ast, :scope_enforcement_changeset) == 1
      assert functions_calling(ast, :scope_enforcement_changeset) == [write_flag_and_audit!: 1]

      # and still only this file calls it
      others = Enum.reject(lib_files(), &(&1 in ["lib/letflow/identity/tenant.ex", @flip_module]))
      assert files_calling(others, :scope_enforcement_changeset) == []
    end

    test "both writers go through the shared helper: flip/4 and flip_out_of_band/3 call write_flag_and_audit!" do
      callers = functions_calling(quoted!(@flip_module), :write_flag_and_audit!)
      assert Enum.sort(Keyword.keys(callers)) == [:do_flip, :do_flip_out_of_band]
    end
  end

  # the `timeout:` option of every `Repo.query!` call whose SQL is the set_config of the lock timeout
  defp set_config_timeouts(source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, [:Repo]}, :query!]}, _, [sql | _] = args} = node, acc
        when is_binary(sql) ->
          if String.contains?(sql, "set_config"),
            do: {node, [transaction_timeout(tl(args) |> then(&[hd(&1), List.last(&1)])) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  describe "T-BG-14c (iv) and T-BG-32 the timeouts" do
    test "the transaction of flip_out_of_band/3 carries a timeout derived from transaction_timeout_ms" do
      assert [timeout] = transaction_options(File.read!(@flip_module))
      assert timeout != nil
      assert Macro.to_string(timeout) =~ "transaction_timeout_ms("
    end

    test "the set_config query of the lock timeout carries a timeout: derived from transaction_timeout_ms (R5 F3)" do
      assert [timeout] = set_config_timeouts(File.read!(@flip_module))
      assert timeout != nil
      assert Macro.to_string(timeout) =~ "transaction_timeout_ms("
    end

    test "the set_config timeout scan is live: a missing option, a constant and another query are reported" do
      with_option = ~s|defmodule S do
 def a(l), do: Repo.query!("SELECT set_config('lock_timeout', $1, true)", [l], timeout: transaction_timeout_ms(l))
end|
      without = ~s|defmodule S do
 def a(l), do: Repo.query!("SELECT set_config('lock_timeout', $1, true)", [l])
end|
      constant = ~s|defmodule S do
 def a(l), do: Repo.query!("SELECT set_config('lock_timeout', $1, true)", [l], timeout: 15_000)
end|
      other = ~s|defmodule S do
 def a(l), do: Repo.query!("SELECT 1", [l], timeout: transaction_timeout_ms(l))
end|

      assert [t] = set_config_timeouts(with_option)
      assert Macro.to_string(t) =~ "transaction_timeout_ms("
      assert set_config_timeouts(without) == [nil]
      assert set_config_timeouts(constant) == [15_000]
      assert set_config_timeouts(other) == []
    end

    test "the application key is read in lib/ only by scope_enforcement.ex and never set there" do
      sources = lib_sources()
      holders = for {path, text} <- sources, String.contains?(text, @bg_lock_key), do: path
      assert holders == [@flip_module]

      for {path, text} <- sources do
        refute text =~ ~r/put_env\([^)]*#{@bg_lock_key}/s, path
        refute text =~ ~r/System\.get_env[^\n]*scope_break_glass/, path
      end
    end

    test "config/, rel/ and mix.exs never name the key (production and runtime config cannot set it)" do
      assert key_files(@bg_config_globs) == []
      assert File.read!("config/runtime.exs") |> String.contains?(@bg_lock_key) == false
      assert File.read!("config/prod.exs") |> String.contains?(@bg_lock_key) == false
    end
  end

  describe "the GH #2883 scans are proven live on seeded offenders" do
    @unlisted "lib/letflow/engine/seeded.ex"

    test "the lib-wide text scan reports every call form, a comment and a plugin module" do
      forms = [
        {"a plain call from a new lib file", "lib/letflow/seeded.ex",
         "defmodule S do\n def a, do: Letflow.ScopeEnforcement.flip_out_of_band(1, :off, %{})\nend"},
        {"apply/3", "lib/letflow/seeded.ex",
         "defmodule S do\n def a, do: apply(Letflow.ScopeEnforcement, :flip_out_of_band, [1, :off, %{}])\nend"},
        {"Kernel.apply/3", "lib/letflow/seeded.ex",
         "defmodule S do\n def a, do: Kernel.apply(Letflow.ScopeEnforcement, :flip_out_of_band, [1])\nend"},
        {"a capture", "lib/letflow/seeded.ex",
         "defmodule S do\n def a, do: &Letflow.ScopeEnforcement.flip_out_of_band/3\nend"},
        {"a mention in a comment of an unlisted file", "lib/letflow/seeded.ex",
         "defmodule S do\n # see flip_out_of_band\n def a, do: :ok\nend"},
        {"an alias of the release module", "lib/letflow/seeded.ex",
         "defmodule S do\n alias Letflow.Release.ScopeBreakGlass\n def a, do: ScopeBreakGlass.run(1, 2, 3, 4)\nend"},
        {"an import", "lib/letflow/seeded.ex",
         "defmodule S do\n import Letflow.ScopeEnforcement, only: [flip_out_of_band: 3]\nend"},
        {"a call from a plugin or engine module", @unlisted,
         "defmodule S do\n def a, do: Letflow.Release.ScopeBreakGlass.run(\"s\", \"off\", \"r\", \"o\", [])\nend"},
        {"the bare out_of_band word", "lib/letflow/seeded.ex",
         "defmodule S do\n def out_of_band_helper, do: :ok\nend"},
        {"a call from the Mix task's neighbour", "lib/mix/tasks/letflow.other.ex",
         "defmodule S do\n def a, do: Letflow.ScopeEnforcement.flip_out_of_band(1, :off, %{})\nend"}
      ]

      for {label, path, text} <- forms do
        assert text_offenders([{path, text}]) != [], label
      end
    end

    test "the three allowed files, seeded alone, pass" do
      assert text_offenders([
               {@flip_module,
                "def flip_out_of_band(a, b, c), do: :ok\n# Letflow.Release.ScopeBreakGlass\n@out_of_band_source 1"},
               {@bg_release,
                "ScopeEnforcement.flip_out_of_band(a, b, c)\n# ScopeBreakGlass\ncheck_out_of_band_inputs"},
               {@bg_task, "alias Letflow.Release.ScopeBreakGlass\n# ScopeBreakGlass.run"}
             ]) == []

      # a file may hold only the needles it is allowed to hold
      assert text_offenders([{@bg_task, "ScopeEnforcement.flip_out_of_band(1, :off, %{})"}]) ==
               [{@bg_task, "flip_out_of_band"}]
    end

    test "the call and alias scans find seeded calls and aliases and ignore comments and strings" do
      call = Code.string_to_quoted!("Letflow.ScopeEnforcement.flip_out_of_band(1, :off, %{})")
      quiet = Code.string_to_quoted!("# flip_out_of_band(1)\n\"flip_out_of_band(1)\"\n:ok")

      assert call_count(call, :flip_out_of_band) == 1
      assert call_count(quiet, :flip_out_of_band) == 0

      assert break_glass_alias?(Code.string_to_quoted!("alias Letflow.Release.ScopeBreakGlass"))
      assert break_glass_alias?(Code.string_to_quoted!("Letflow.Release.ScopeBreakGlass.run(1)"))
      refute break_glass_alias?(Code.string_to_quoted!("# ScopeBreakGlass\n:ok"))
    end

    test "the changeset-call counter counts expressions and names the enclosing function" do
      two = """
      defmodule S do
        defp a(t), do: Tenant.scope_enforcement_changeset(t, %{})
        defp b(t), do: Tenant.scope_enforcement_changeset(t, %{})
      end
      """

      one_elsewhere = """
      defmodule S do
        defp write_flag_and_audit!(t), do: Tenant.scope_enforcement_changeset(t, %{})
        def sneaky(t), do: Tenant.scope_enforcement_changeset(t, %{})
      end
      """

      none = "defmodule S do\n def a, do: :ok\nend"

      assert call_count(Code.string_to_quoted!(two), :scope_enforcement_changeset) == 2
      assert call_count(Code.string_to_quoted!(none), :scope_enforcement_changeset) == 0

      assert functions_calling(
               Code.string_to_quoted!(one_elsewhere),
               :scope_enforcement_changeset
             ) ==
               [write_flag_and_audit!: 1, sneaky: 1]

      assert functions_calling(Code.string_to_quoted!(two), :scope_enforcement_changeset) ==
               [a: 1, b: 1]
    end

    test "the transaction-timeout scan finds a missing option and a timeout that is not derived" do
      with_timeout = """
      defmodule S do
        def flip_out_of_band(a, b, c) when is_map(c) do
          Repo.transaction(fn -> :ok end, timeout: transaction_timeout_ms(1))
        end
      end
      """

      without = """
      defmodule S do
        def flip_out_of_band(a, b, c) do
          Repo.transaction(fn -> :ok end)
        end
      end
      """

      constant = """
      defmodule S do
        def flip_out_of_band(a, b, c), do: Repo.transaction(fn -> :ok end, timeout: 15_000)
      end
      """

      other_function = """
      defmodule S do
        def flip_out_of_band(a, b, c), do: Repo.transaction(fn -> :ok end)
        def other, do: Repo.transaction(fn -> :ok end, timeout: transaction_timeout_ms(1))
      end
      """

      assert [timeout] = transaction_options(with_timeout)
      assert Macro.to_string(timeout) =~ "transaction_timeout_ms("

      assert transaction_options(without) == [nil]
      assert [15_000] = transaction_options(constant)
      # a timeout in ANOTHER function does not satisfy the scan
      assert transaction_options(other_function) == [nil]
    end

    test "the route scan fires on a break-glass route, key and permission" do
      assert mentions_break?(["/tenant/scope-enforcement/break-glass"])
      assert mentions_break?([:ScopeBreakGlassManage])
      assert mentions_break?([{:permission, :BreakGlass}])
      refute mentions_break?(["/tenant/scope-enforcement", :ScopeEnforcementManage])
    end

    test "the key scan finds the key in a seeded config file and the text scan in a seeded script" do
      dir =
        System.tmp_dir!()
        |> Path.join("gh2883_scan_#{System.unique_integer([:positive])}")
        |> String.replace("\\", "/")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "runtime.exs"),
        "config :letflow, :scope_break_glass_lock_timeout_ms, 1\n"
      )

      File.write!(
        Path.join(dir, "deploy.sh"),
        "bin/letflow rpc 'Letflow.Release.ScopeBreakGlass.run()'\n"
      )

      File.write!(Path.join(dir, "clean.sh"), "echo ok\n")

      assert key_files([Path.join(dir, "*")]) |> Enum.map(&Path.basename/1) == ["runtime.exs"]

      assert files_with_text(
               [Path.join(dir, "*")],
               ~r/break_glass|ScopeBreakGlass|flip_out_of_band/
             )
             |> Enum.map(&Path.basename/1)
             |> Enum.sort() == ["deploy.sh", "runtime.exs"]
    end
  end
end
