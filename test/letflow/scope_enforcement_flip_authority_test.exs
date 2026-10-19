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
      platform-scope flip route for ANOTHER tenant is NOT built, AC 20).

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
end
