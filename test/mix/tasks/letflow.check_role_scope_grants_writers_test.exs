defmodule Mix.Tasks.Letflow.CheckRoleScopeGrantsWritersTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 14 (design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  section 3.13; spec `test/specs/REQ-517-2a.md`, T-X1..T-X7): `mix letflow.check_role_scope_grants_writers`,
  the static scan `mix letflow.check` runs, fails when code outside the allowlist writes the
  `role_scope_grants` table or builds the schema struct, and passes otherwise.

    * T-X1 the real tree scans clean and `run/1` returns `:ok`;
    * T-X2 four violating fixtures each fail with the expected rule (`Repo.insert_all` of the schema,
      `Multi.delete_all` of it, raw `DELETE FROM`, a struct literal);
    * T-X3 must-pass fixtures: two read-only queries and the two sites on `main` a substring match
      would flag, taken VERBATIM from the real files at test time
      (`Letflow.Identity.delete_group/2`'s `delete_group_principal_rows!` pair and
      `TenantAdminMigration.remove_legacy_binding/2`'s `reconcile_binding!` pair);
    * T-X4 the whole-word rule: the first verbatim fixture with `RoleScopeGrants` replaced by the
      singular schema word fails (mutant M11);
    * T-X5 an allowlisted file with a violation passes, the task's own file is exempt;
    * T-X6 `run/1` raises `Mix.Error` listing `path:line [rule]` for a violation;
    * T-X7 the task is wired into `@check_static_steps`, before `format --check-formatted`.

  `async: false`: one test changes the working directory (restored in an `after`).
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Letflow.CheckRoleScopeGrantsWriters, as: Scan

  @identity_anchor ~r/Repo\.delete_all\(query, prefix: prefix\)/
  @migration_anchor ~r/Repo\.delete_all\(from\(t in TenantRole, where: t\.id == \^id\), prefix: schema\)/

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    dir = Path.join(System.tmp_dir!(), "req517_writer_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp put_file!(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  # `count` lines of `path` starting at the first line matching `anchor`, VERBATIM.
  defp verbatim!(path, anchor, count) do
    lines = path |> File.read!() |> String.split("\n")
    index = Enum.find_index(lines, &Regex.match?(anchor, &1))
    assert index, "anchor #{inspect(anchor)} not found in #{path}: the verbatim fixture drifted"
    lines |> Enum.slice(index, count) |> Enum.join("\n")
  end

  defp identity_snippet, do: verbatim!("lib/letflow/identity.ex", @identity_anchor, 3)

  defp migration_snippet,
    do: verbatim!("lib/letflow/identity/tenant_admin_migration.ex", @migration_anchor, 4)

  defp rules(violations), do: violations |> Enum.map(& &1.rule) |> Enum.uniq() |> Enum.sort()

  # --- T-X1 --------------------------------------------------------------------------------------

  test "T-X1 the real tree scans clean and run/1 returns :ok" do
    assert Scan.scan(["lib", "priv/modules"]) == []
    assert Scan.run([]) == :ok
    assert_received {:mix_shell, :info, ["role_scope_grants writer scan: no violations"]}
  end

  test "the allowlist is exactly the writer, the backfill, the schema and the task's own file" do
    assert Scan.allowlist() == [
             "lib/letflow/identity/role_scope_grants.ex",
             "lib/letflow/identity/role_scope_grants/backfill.ex",
             "lib/letflow/identity/role_scope_grant.ex",
             "lib/mix/tasks/letflow.check_role_scope_grants_writers.ex"
           ]

    for path <- Scan.allowlist(), do: assert(File.regular?(path), path)
  end

  # --- T-X2 --------------------------------------------------------------------------------------

  describe "T-X2 violating fixtures" do
    test "Repo.insert_all of the schema is :repo_write (same line and the next two lines)" do
      content = """
      defmodule Bad.One do
        def go(rows) do
          Repo.insert_all(
            Letflow.Identity.RoleScopeGrant,
            rows
          )
        end
      end
      """

      assert [%{rule: :repo_write, line: 3}] = Scan.audit(content, "lib/bad/one.ex")
    end

    test "Multi.delete_all of the schema is :multi_write" do
      content = """
      defmodule Bad.Two do
        def go(multi) do
          multi |> Ecto.Multi.delete_all(:rows, from(g in RoleScopeGrant))
        end
      end
      """

      assert :multi_write in rules(Scan.audit(content, "lib/bad/two.ex"))
    end

    test "raw DELETE FROM, INSERT INTO and UPDATE of the table are :raw_sql, with and without a schema qualifier" do
      for sql <- [
            ~S|Repo.query!("DELETE FROM role_scope_grants WHERE true")|,
            ~S'Repo.query!(~s|DELETE FROM "#{prefix}".role_scope_grants WHERE true|)',
            ~S|Repo.query!("insert into role_scope_grants (id) values (1)")|,
            ~S|Repo.query!("UPDATE public.role_scope_grants SET role = 'x'")|
          ] do
        assert :raw_sql in rules(Scan.audit(sql <> "\n", "lib/bad/three.ex")), sql
      end
    end

    test "KNOWN LIMIT (pinned): a raw write with ESCAPED quotes around the schema qualifier is NOT caught; the codebase's sigil style is" do
      escaped = ~S|Repo.query!("UPDATE \"#{prefix}\".role_scope_grants SET role = 1")|
      sigil = ~S'Repo.query!(~s|UPDATE "#{prefix}".role_scope_grants SET role = 1|)'

      # If the first assertion starts failing the scan got stricter: delete the limit.
      assert Scan.audit(escaped <> "\n", "lib/bad/escaped.ex") == []
      assert :raw_sql in rules(Scan.audit(sigil <> "\n", "lib/bad/sigil.ex"))
    end

    test "a struct literal of the schema (with or without a module prefix) and RoleScopeGrant.changeset( are :struct_literal" do
      for text <- [
            "x = %RoleScopeGrant{principal_type: :user}",
            "x = %Letflow.Identity.RoleScopeGrant{principal_type: :user}",
            "cs = RoleScopeGrant.changeset(%{}, %{})"
          ] do
        assert :struct_literal in rules(Scan.audit(text <> "\n", "lib/bad/four.ex")), text
      end
    end

    test "a violation is reported against the file, the line and the trimmed text" do
      content = "defmodule A do\n  def go, do: Repo.delete_all(RoleScopeGrant)\nend\n"

      assert [%{path: "lib/a.ex", line: 2, rule: :repo_write, text: text}] =
               Scan.audit(content, "lib/a.ex")

      assert text == "def go, do: Repo.delete_all(RoleScopeGrant)"
    end
  end

  # --- T-X3 / T-X4 -------------------------------------------------------------------------------

  describe "T-X3 must-pass fixtures" do
    test "reads of the schema (Repo.all, Repo.exists?) and the plural context module pass" do
      content = """
      defmodule Good.Reads do
        import Ecto.Query

        def a(prefix), do: Repo.all(from(g in RoleScopeGrant, where: g.role == "X"), prefix: prefix)
        def b(prefix), do: Repo.exists?(from(g in RoleScopeGrant), prefix: prefix)
        def c(prefix), do: Letflow.Identity.RoleScopeGrants.user_row_count(prefix)
      end
      """

      assert Scan.audit(content, "lib/good/reads.ex") == []
    end

    test "comment lines naming the table and a manifest file name are not violations" do
      content = """
      # Repo.delete_all of role_scope_grants is only allowed in the writer
      defmodule Good.Docs do
        @file_name "20261015025331_create_role_scope_grants.exs"
        def index, do: "role_scope_grants_scoped_uniq"
      end
      """

      assert Scan.audit(content, "lib/good/docs.ex") == []
    end

    test "verbatim: Letflow.Identity.delete_group/2's Repo.delete_all followed by RoleScopeGrants.delete_group_principal_rows! passes" do
      snippet = identity_snippet()
      assert snippet =~ "RoleScopeGrants.delete_group_principal_rows!"
      assert Scan.audit(snippet <> "\n", "lib/letflow/identity.ex") == []
    end

    test "verbatim: TenantAdminMigration's Repo.delete_all of a TenantRole query followed by RoleScopeGrants.reconcile_binding! passes" do
      snippet = migration_snippet()
      assert snippet =~ "RoleScopeGrants.reconcile_binding!"
      assert Scan.audit(snippet <> "\n", "lib/letflow/identity/tenant_admin_migration.ex") == []
    end
  end

  describe "T-X4 the whole-word rule (mutant M11)" do
    test "the verbatim Identity fixture with RoleScopeGrants replaced by the singular schema word is a violation" do
      mutated = String.replace(identity_snippet(), "RoleScopeGrants", "RoleScopeGrant")

      assert :repo_write in rules(Scan.audit(mutated <> "\n", "lib/letflow/identity.ex"))
    end

    test "the verbatim migration fixture, mutated the same way, is a violation too" do
      mutated = String.replace(migration_snippet(), "RoleScopeGrants", "RoleScopeGrant")

      assert :repo_write in rules(Scan.audit(mutated <> "\n", "lib/x.ex"))
    end

    test "index and constraint names that merely start with the table name never match" do
      content = """
      defmodule Good.Names do
        def names, do: ["role_scope_grants_scoped_uniq", "role_scope_grants_scope_node_id_fkey"]
        def go(prefix), do: Repo.delete_all(from(i in "role_scope_grants_scoped_uniq"), prefix: prefix)
      end
      """

      assert Scan.audit(content, "lib/good/names.ex") == []
    end
  end

  # --- T-X5 / T-X6 -------------------------------------------------------------------------------

  describe "T-X5 the allowlist" do
    test "an allowlisted file with a violation passes; the same text in another file fails", %{
      dir: dir
    } do
      violation = "defmodule W do\n  def go, do: Repo.delete_all(RoleScopeGrant)\nend\n"

      put_file!(dir, "lib/letflow/identity/role_scope_grants.ex", violation)
      put_file!(dir, "lib/letflow/identity/role_scope_grants/backfill.ex", violation)
      put_file!(dir, "lib/letflow/identity/role_scope_grant.ex", violation)
      put_file!(dir, "lib/mix/tasks/letflow.check_role_scope_grants_writers.ex", violation)
      put_file!(dir, "lib/letflow/identity/scoped_grants.ex", violation)

      violations = File.cd!(dir, fn -> Scan.scan(["lib"]) end)

      assert Enum.map(violations, & &1.path) == ["lib/letflow/identity/scoped_grants.ex"]
    end

    test "a missing root is skipped and only .ex files under lib / every file under priv/modules are scanned",
         %{dir: dir} do
      violation = "x = %RoleScopeGrant{}\n"
      put_file!(dir, "lib/a.txt", violation)
      put_file!(dir, "priv/modules/exam/hook.lua", "-- " <> violation)
      put_file!(dir, "priv/repo/migrations/20260101000000_x.exs", violation)

      violations = File.cd!(dir, fn -> Scan.scan(["lib", "priv/modules", "no/such/root"]) end)

      assert Enum.map(violations, & &1.path) == ["priv/modules/exam/hook.lua"]
    end
  end

  describe "T-X6 run/1" do
    test "raises Mix.Error listing path:line [rule] and the count when the tree carries a violation",
         %{dir: dir} do
      put_file!(
        dir,
        "lib/letflow/bad.ex",
        "defmodule B do\n  def go, do: Repo.insert_all(RoleScopeGrant, [])\nend\n"
      )

      error =
        assert_raise Mix.Error, fn ->
          File.cd!(dir, fn -> Scan.run([]) end)
        end

      assert error.message =~ "1 violation(s)"
      assert error.message =~ "lib/letflow/bad.ex:2 [repo_write]"
      assert error.message =~ "Letflow.Identity.RoleScopeGrants"
    end
  end

  # --- T-X7 --------------------------------------------------------------------------------------

  test "T-X7 the task is wired into @check_static_steps, next to the scope_node_paths scan and before format" do
    source = File.read!("mix.exs")
    [steps] = Regex.run(~r/@check_static_steps \[(.*?)\n  \]/s, source, capture: :all_but_first)

    names =
      Regex.scan(~r/^\s*"([a-z_. -]+)",?$/m, steps, capture: :all_but_first) |> List.flatten()

    index = fn name -> Enum.find_index(names, &(&1 == name)) end

    assert index.("letflow.check_role_scope_grants_writers")

    assert index.("letflow.check_scope_node_paths_writers") <
             index.("letflow.check_role_scope_grants_writers")

    assert index.("letflow.check_role_scope_grants_writers") < index.("format --check-formatted")
  end
end
