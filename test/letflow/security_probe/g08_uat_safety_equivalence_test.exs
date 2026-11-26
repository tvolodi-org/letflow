defmodule Letflow.SecurityProbe.G08UatSafetyEquivalenceTest do
  @moduledoc """
  G-08: the UAT runner has two paths — a run (`run`) and the cleanup replay of an aborted run
  (`replay_cleanup`). A safety check that one path makes and the other does not is a hole: the T-2606
  cleanup replay omitted the platform residue check and reported PASS with an instance still ACTIVE.

  The probe is `scripts/uat/tests/test_safety_equivalence.py`: it runs both paths against fake servers,
  reads the safety checks each of them made from the run log, and compares them with each other and with
  the reviewed expectations in `test/fixtures/security_probes/g08_uat_safety_checks.txt`. A baseline the run
  promised and that is gone fails the replay closed: it says it cannot judge the run instead of passing.
  The seeded failing cases (a replay that skips the residue check, a replay that fails open on a missing
  baseline) prove that the probe is not vacuous.

  Pure Python (no model, no database, no network beyond 127.0.0.1, no clock): about two seconds.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag probe_cost_s: 15

  @root Path.expand("../../..", __DIR__)
  @tests Path.join([@root, "scripts", "uat", "tests"])

  test "G08: the normal run and the cleanup replay judge the same safety checks" do
    {out, code} =
      System.cmd(
        "python3",
        [
          "-I",
          "-B",
          "-m",
          "unittest",
          "discover",
          "-v",
          "-s",
          @tests,
          "-p",
          "test_safety_equivalence.py"
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "OK", out
  end
end
