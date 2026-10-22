defmodule Mix.Tasks.Letflow.CheckAsyncSandboxReachabilityTest do
  @moduledoc """
  Regression coverage for ISS-0481 (queue task 512, GH#1000 -- see
  `docs/issues/ISS-0481.yaml`'s own header note on the numbering collision
  with the GH issue's title) -- `mix letflow.check_async_sandbox_reachability`
  (`lib/mix/tasks/letflow.check_async_sandbox_reachability.ex`).

  Design authority: `lib/letflow/design/iss0481-async-sandbox-mode-check.md` §8,
  independently validated
  (`handoffs/WF03-ISS0512-20260905/step-02b-code-design-validator.json`).

  Three layers, matching the design's §8 split:

    * §8.1 -- pure classification functions (`async_true_file?/1`,
      `real_call_sites/1`) exercised against synthetic in-memory strings. No
      filesystem, no `Sandbox.mode` ever touched by these tests themselves.
    * §8.2 -- `--dir` against a `System.tmp_dir!/0`-rooted scratch fixture
      directory, never under the real `test/` tree (so `mix test` never
      discovers or executes the synthetic fixture files created here).
    * A real-tree smoke assertion -- the real, unscoped task, with no `--dir`,
      passes green today with exactly the two known permitted exceptions.

  ## Why fixtures below are built with `fixture/1`, not `\"\"\"` heredocs

  This file itself matches `test/**/*_test.exs` -- the very glob the checker
  under test scans. A literal heredoc physical line reading
  `  use Letflow.DataCase, async: true` (or a real, uncommented
  `provisioned_tenant!(`/`Sandbox.mode(` call line) sitting directly in this
  source file would make the checker classify THIS file as a genuine
  async:true violation when it scans the real tree -- self-referentially,
  since the checker's moduledoc-span exclusion (design §3) does not extend to
  arbitrary heredocs. `fixture/1` joins a list of line-strings at runtime
  with real `\\n` characters, so the classification functions under test see
  an identical multi-line string, but no single PHYSICAL line in this .exs
  file itself starts with the bare token `use` or contains an uncommented
  call -- each fixture line is one list element, so the character
  immediately preceding it on disk is always `"` or `,`, never leading
  whitespace-then-`use`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Letflow.CheckAsyncSandboxReachability, as: Checker

  defp fixture(lines), do: Enum.join(lines, "\n") <> "\n"

  # ==========================================================================
  # §8.1 -- pure classification, synthetic in-memory strings only
  # ==========================================================================

  describe "async_true_file?/1" do
    test "a genuine `use Letflow.DataCase, async: true` line is real" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  use Letflow.DataCase, async: true",
          "end"
        ])

      assert Checker.async_true_file?(content)
    end

    test "a moduledoc-only mention of async: true is NOT a real declaration" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  @moduledoc \"\"\"",
          "  This module uses `use ExUnit.Case, async: true` for isolation.",
          "  \"\"\"",
          "",
          "  use ExUnit.Case, async: false",
          "end"
        ])

      refute Checker.async_true_file?(content)
    end

    test "a `#`-comment mentioning async: true is NOT a real declaration" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  # use ExUnit.Case, async: true",
          "  use ExUnit.Case, async: false",
          "end"
        ])

      refute Checker.async_true_file?(content)
    end

    test "async: false is never a match" do
      content = fixture(["use Letflow.DataCase, async: false"])
      refute Checker.async_true_file?(content)
    end
  end

  describe "real_call_sites/1" do
    test "a genuine provisioned_tenant!( call outside any moduledoc is a real §3(a) match" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  defp tenant do",
          "    Letflow.TenantFixture.provisioned_tenant!(slug_prefix: \"foo\")",
          "  end",
          "end"
        ])

      assert [%{pattern: :provisioned_tenant}] = Checker.real_call_sites(content)
    end

    test "a bare Sandbox.mode( call is a real §3(b) match" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  setup do",
          "    Sandbox.mode(Letflow.Repo, :auto)",
          "  end",
          "end"
        ])

      assert [%{pattern: :sandbox_mode}] = Checker.real_call_sites(content)
    end

    test "a fully-qualified Ecto.Adapters.SQL.Sandbox.mode( call is a real §3(b) match" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  setup do",
          "    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)",
          "  end",
          "end"
        ])

      assert [%{pattern: :sandbox_mode}] = Checker.real_call_sites(content)
    end

    test "async:true with no call of either kind has no matches" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  test \"does nothing special\" do",
          "    assert 1 == 1",
          "  end",
          "end"
        ])

      assert Checker.real_call_sites(content) == []
    end

    test "a moduledoc mention of provisioned_tenant!/1 in prose is excluded" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  @moduledoc \"\"\"",
          "  Each test that needs a real tenant provisions one via",
          "  `Letflow.TenantFixture.provisioned_tenant!/1`.",
          "  \"\"\"",
          "",
          "  use Letflow.DataCase, async: true",
          "",
          "  test \"does nothing special\" do",
          "    assert 1 == 1",
          "  end",
          "end"
        ])

      assert Checker.real_call_sites(content) == []
    end

    test "a commented-out provisioned_tenant!( line is excluded" do
      content =
        fixture([
          "defmodule Letflow.FooTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  defp tenant do",
          "    # Letflow.TenantFixture.provisioned_tenant!(slug_prefix: \"foo\")",
          "    :ok",
          "  end",
          "end"
        ])

      assert Checker.real_call_sites(content) == []
    end
  end

  # ==========================================================================
  # §8.2 -- integration: --dir against a scratch fixture directory
  # ==========================================================================

  describe "run/1 against a scratch --dir fixture" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-check-async-sandbox-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{dir: dir}
    end

    test "a clean async:true fixture (no call site) reports zero violations", %{dir: dir} do
      File.write!(
        Path.join(dir, "clean_test.exs"),
        fixture([
          "defmodule Letflow.CleanTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  test \"does nothing special\" do",
          "    assert 1 == 1",
          "  end",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert Checker.run(["--dir", dir]) == :ok
        end)

      assert output =~ "OK --"
      assert output =~ "0 new violations"
    end

    test "a violating fixture (async:true + real provisioned_tenant!( call) fails the build", %{
      dir: dir
    } do
      fixture_path = Path.join(dir, "regression_test.exs")

      File.write!(
        fixture_path,
        fixture([
          "defmodule Letflow.RegressionTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  defp tenant do",
          "    Letflow.TenantFixture.provisioned_tenant!(slug_prefix: \"regression\")",
          "  end",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found 1 new violation/, fn ->
            Checker.run(["--dir", dir])
          end
        end)

      assert output =~ "NEW VIOLATIONS"
      assert output =~ fixture_path
      assert output =~ "provisioned_tenant"
    end

    test "an async:false file with a real provisioned_tenant!( call is never flagged", %{
      dir: dir
    } do
      File.write!(
        Path.join(dir, "async_false_test.exs"),
        fixture([
          "defmodule Letflow.AsyncFalseTest do",
          "  use Letflow.DataCase, async: false",
          "",
          "  defp tenant do",
          "    Letflow.TenantFixture.provisioned_tenant!(slug_prefix: \"foo\")",
          "  end",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert Checker.run(["--dir", dir]) == :ok
        end)

      assert output =~ "OK --"
    end

    test "an explicit --dir that discovers zero files is a hard usage error", %{dir: dir} do
      empty_dir = Path.join(dir, "empty")
      File.mkdir_p!(empty_dir)

      assert_raise Mix.Error, ~r/discovered 0 files/, fn ->
        capture_io(fn -> Checker.run(["--dir", empty_dir]) end)
      end
    end
  end

  # ==========================================================================
  # tenant_schema_reaper.ex / tenant_template.ex-shaped fixtures are excluded
  # by the file-selection step itself (design §7) -- proven here by pointing
  # --dir at a scratch dir containing a mode/2-calling support-module-shaped
  # file that is NOT named `*_test.exs`.
  # ==========================================================================

  describe "run/1 -- support-module-shaped files are excluded by file selection" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-check-async-sandbox-support-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{dir: dir}
    end

    test "a tenant_schema_reaper.ex-shaped mode/2 caller (not *_test.exs) is never scanned", %{
      dir: dir
    } do
      # Each support-module-shaped fixture below carries a real, anchored
      # `use ..., async: true` line in addition to its mode/2 call site --
      # not just the call site alone. Without that line, content-based
      # classification (`async_true_file?/1`) would already exclude these
      # files on its own, which means this test would pass even if a future
      # glob change widened file *selection* to let `.ex` files through --
      # proving nothing about the selection/glob mechanism this test claims
      # to pin. With the `use ..., async: true` line present, the ONLY thing
      # keeping these two files out of scope is that file selection never
      # even discovers them (they don't match `**/*_test.exs`).
      File.write!(
        Path.join(dir, "tenant_schema_reaper.ex"),
        fixture([
          "defmodule Letflow.TenantSchemaReaperFixture do",
          "  use Letflow.DataCase, async: true",
          "",
          "  def sweep_orphans do",
          "    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)",
          "  end",
          "end"
        ])
      )

      File.write!(
        Path.join(dir, "tenant_template.ex"),
        fixture([
          "defmodule Letflow.TenantTemplateFixture do",
          "  use Letflow.DataCase, async: true",
          "",
          "  def ensure_template! do",
          "    Sandbox.mode(Letflow.Repo, :auto)",
          "  end",
          "end"
        ])
      )

      # A real *_test.exs file must still be present, or --dir with zero
      # discovered files would raise the empty-scope usage error instead of
      # exercising the exclusion this test is actually about.
      File.write!(
        Path.join(dir, "harmless_test.exs"),
        fixture([
          "defmodule Letflow.HarmlessTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  test \"does nothing special\" do",
          "    assert 1 == 1",
          "  end",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert Checker.run(["--dir", dir]) == :ok
        end)

      assert output =~ "1 async:true test file(s) scanned"
      assert output =~ "0 new violations"
    end
  end

  # ==========================================================================
  # GH #2424 -- victim-side rules (modeless Repo files, new inline :auto)
  # ==========================================================================

  describe "GH #2424: async:true file reaching :auto is caught (existing rule)" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "letflow-check-2424-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "an async:true file with an inline :auto call fails with [ASYNC-SANDBOX]", %{dir: dir} do
      File.write!(
        Path.join(dir, "bystander_test.exs"),
        fixture([
          "defmodule Letflow.BystanderTest do",
          "  use Letflow.DataCase, async: true",
          "",
          "  setup do",
          "    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)",
          "  end",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, fn -> Checker.run(["--dir", dir]) end
        end)

      assert output =~ "[ASYNC-SANDBOX]"
    end
  end

  describe "inline_auto_sites/1" do
    test "finds a real inline :auto call" do
      content = fixture(["  setup do", "    Sandbox.mode(Letflow.Repo, :auto)", "  end"])
      assert [%{line_number: 2}] = Checker.inline_auto_sites(content)
    end

    test "ignores :manual, comments, moduledoc prose, strings and regexes" do
      content =
        fixture([
          "  @moduledoc \"\"\"",
          "  needs Sandbox.mode(Letflow.Repo, :auto)",
          "  \"\"\"",
          "  # Sandbox.mode(Letflow.Repo, :auto)",
          "  Sandbox.mode(Letflow.Repo, :manual)",
          "  x = \"Sandbox.mode(Letflow.Repo, :auto)\"",
          "  ~r/Sandbox.mode(Repo, :auto)/"
        ])

      assert Checker.inline_auto_sites(content) == []
    end
  end

  describe "modeless_repo_file?/1" do
    test "an async:false Repo caller that sets no mode is flagged" do
      content =
        fixture([
          "defmodule Letflow.NoModeTest do",
          "  use ExUnit.Case, async: false",
          "  test \"x\", do: Letflow.Repo.all(Foo)",
          "end"
        ])

      assert Checker.modeless_repo_file?(content)
    end

    test "DataCase, an own Sandbox mode/checkout or SandboxAutoMode clears it" do
      for evidence <- [
            "  use Letflow.DataCase, async: false",
            "  setup do: Sandbox.mode(Repo, :manual)",
            "  setup do: Ecto.Adapters.SQL.Sandbox.checkout(Repo)",
            "  alias Letflow.Test.SandboxAutoMode"
          ] do
        content = fixture([evidence, "  def f, do: Repo.all(Foo)"])
        refute Checker.modeless_repo_file?(content), evidence
      end
    end

    test "no Repo call (or only Repo.config, or Repo in prose/strings) is not flagged" do
      for body <- [
            "  def f, do: 1",
            "  def f, do: Repo.config()",
            "  # Repo.all(Foo)",
            "  def f, do: \"Repo.all(Foo)\""
          ] do
        content = fixture(["  use ExUnit.Case, async: false", body])
        refute Checker.modeless_repo_file?(content), body
      end
    end

    test "an async:true file is left to the reachability rule" do
      content = fixture(["  use ExUnit.Case, async: true", "  def f, do: Repo.all(Foo)"])
      refute Checker.modeless_repo_file?(content)
    end
  end

  describe "run/1 victim-side rules against a scratch --dir fixture" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "letflow-check-2424-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a new inline Sandbox.mode(_, :auto) outside the allow-list fails", %{dir: dir} do
      File.write!(
        Path.join(dir, "new_auto_test.exs"),
        fixture([
          "defmodule Letflow.NewAutoTest do",
          "  use Letflow.DataCase, async: false",
          "",
          "  setup do",
          "    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)",
          "  end",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found 1 new violation/, fn -> Checker.run(["--dir", dir]) end
        end)

      assert output =~ "[INLINE-AUTO]"
      assert output =~ "new_auto_test.exs:5"
    end

    test "a modeless async:false Repo file fails", %{dir: dir} do
      File.write!(
        Path.join(dir, "modeless_test.exs"),
        fixture([
          "defmodule Letflow.ModelessTest do",
          "  use ExUnit.Case, async: false",
          "  test \"x\", do: Letflow.Repo.all(Foo)",
          "end"
        ])
      )

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found 1 new violation/, fn -> Checker.run(["--dir", dir]) end
        end)

      assert output =~ "[NO-SANDBOX-MODE]"
    end

    test "a file reaching :auto through SandboxAutoMode passes", %{dir: dir} do
      File.write!(
        Path.join(dir, "helper_test.exs"),
        fixture([
          "defmodule Letflow.HelperTest do",
          "  use ExUnit.Case, async: false",
          "  alias Letflow.Test.SandboxAutoMode",
          "  setup_all do: SandboxAutoMode.enter_auto_mode!(Letflow.Repo)",
          "end"
        ])
      )

      capture_io(fn -> assert Checker.run(["--dir", dir]) == :ok end)
    end
  end

  # ==========================================================================
  # Real-tree smoke assertion -- proves §1's current boundary holds today
  # ==========================================================================

  describe "run/1 against the real test/ tree (no --dir)" do
    test "passes green against the current real tree" do
      # ISS-0480's own remedy (#1002/c6987864) reverted the two files this
      # task's @verified_safe allowlist names -- secrets_test.exs and
      # webhooks_test.exs -- back to `async: false`, so the real tree
      # currently has zero files that need the allowlist. This asserts the
      # check still passes clean either way: 0 violations, whether or not
      # the allowlist happens to be exercised right now. It does NOT assert
      # a specific permitted-exception count, since that count is a fact
      # about the real tree's current content, not about this task's own
      # correctness -- the allowlist mechanism itself is proven separately
      # by the --dir fixture tests above.
      output =
        capture_io(fn ->
          assert Checker.run([]) == :ok
        end)

      assert output =~ "OK --"
      assert output =~ "0 new violations"
    end
  end
end
