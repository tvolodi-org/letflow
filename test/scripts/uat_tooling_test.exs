defmodule Letflow.Scripts.UatToolingTest do
  @moduledoc """
  T-2606 (G18): the UAT runner (`scripts/uat/runner.py`) and the static check of the process files
  (`scripts/uat/check_processes.py`) are Python tooling with their own stdlib unit tests in
  `scripts/uat/tests`. No mix test maps to them, so the product CI would never run them: this test runs
  the whole suite, so a change of the runner is checked by the backend gate.

  The suite is pure: fake HTTP servers on 127.0.0.1, a fake mail trap, no database, no network, no model.
  It takes about fifteen seconds.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @tests Path.join([@root, "scripts", "uat", "tests"])

  test "the unit tests of the UAT tooling pass" do
    {out, code} =
      System.cmd("python3", ["-I", "-B", "-m", "unittest", "discover", "-s", @tests],
        cd: @root,
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "OK", out
  end

  test "the suite of the UAT tooling is there (a rule that cannot fail is caught here)" do
    assert File.dir?(@tests)
    assert File.exists?(Path.join(@tests, "test_platform_residue.py"))
    assert File.exists?(Path.join(@tests, "test_wait_mail.py"))
  end
end
