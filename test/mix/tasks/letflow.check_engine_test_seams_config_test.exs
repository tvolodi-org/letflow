defmodule Mix.Tasks.Letflow.CheckEngineTestSeamsConfigTest do
  @moduledoc """
  GH #2787: `mix letflow.check_engine_test_seams_config`, the static scan `mix letflow.check.static`
  runs, fails when a `config/*.exs` file other than `config/test.exs` names the `engine_test_seams`
  flag, and passes otherwise.

    * the real `config/` tree scans clean and `run/1` returns `:ok`;
    * a violation in `config.exs`, `prod.exs` or `runtime.exs` (code or comment) is reported as
      `path:line`, and `run/1` raises listing it;
    * `config/test.exs` itself is the only allowed place;
    * an empty or missing root is a hard error, never a silent pass;
    * the task is wired into `@check_static_steps` in `mix.exs`.

  `async: false`: the tests share the `Mix.shell/1` process and write fixtures under `tmp_dir`.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Letflow.CheckEngineTestSeamsConfig, as: Scan

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    dir = Path.join(System.tmp_dir!(), "gh2787_seams_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp put_file!(dir, name, content) do
    File.write!(Path.join(dir, name), content)
  end

  test "the real config/ tree scans clean and run/1 returns :ok" do
    assert Scan.scan("config") == []
    assert Scan.run([]) == :ok
    assert_received {:mix_shell, :info, ["engine_test_seams config scan: no violations"]}
  end

  test "config/test.exs is the only file allowed to set the flag", %{dir: dir} do
    put_file!(dir, "test.exs", "config :letflow, :engine_test_seams, true\n")
    put_file!(dir, "dev.exs", "config :letflow, :engine_test_seams, false\n")

    assert [%{path: path, line: 1}] = Scan.scan(dir)
    assert Path.basename(path) == "dev.exs"
  end

  test "a flag set in config.exs, prod.exs or runtime.exs is reported with path and line", %{
    dir: dir
  } do
    for name <- ["config.exs", "prod.exs", "runtime.exs"] do
      put_file!(dir, name, "import Config\n\nconfig :letflow, :engine_test_seams, true\n")
    end

    violations = Scan.scan(dir)

    assert Enum.map(violations, &{Path.basename(&1.path), &1.line}) == [
             {"config.exs", 3},
             {"prod.exs", 3},
             {"runtime.exs", 3}
           ]

    assert Enum.all?(violations, &(&1.text == "config :letflow, :engine_test_seams, true"))
  end

  test "a comment that names the flag is a violation too: the rule is the whole word, anywhere",
       %{
         dir: dir
       } do
    put_file!(dir, "config.exs", "# do not set engine_test_seams here\n")

    assert [%{line: 1, text: "# do not set engine_test_seams here"}] = Scan.scan(dir)
  end

  test "a longer identifier that merely contains the word is not a violation", %{dir: dir} do
    put_file!(dir, "config.exs", "config :letflow, :engine_test_seams_extra, true\n")

    assert Scan.scan(dir) == []
  end

  test "run/1 raises listing every violation as path:line", %{dir: dir} do
    put_file!(dir, "prod.exs", "config :letflow, :engine_test_seams, true\n")

    error =
      assert_raise Mix.Error, fn -> Scan.run(["--dir", dir]) end

    assert error.message =~ "1 violation(s)"
    assert error.message =~ "prod.exs:1"
  end

  test "an empty root is a hard error, never a silent pass", %{dir: dir} do
    assert_raise Mix.Error, ~r/no .*\/\*\.exs files found/, fn -> Scan.scan(dir) end

    missing = Path.join(dir, "does_not_exist")
    assert_raise Mix.Error, fn -> Scan.scan(missing) end
  end

  test "the task is wired into @check_static_steps in mix.exs, before format --check-formatted" do
    mix_exs = File.read!("mix.exs")
    [before_format, _] = String.split(mix_exs, "\"format --check-formatted\"", parts: 2)

    assert before_format =~ "\"letflow.check_engine_test_seams_config\""
  end
end
