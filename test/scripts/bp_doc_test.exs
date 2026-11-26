defmodule Letflow.Scripts.BpDocTest do
  @moduledoc """
  D-173: `scripts/bp/bp_doc.py` renders the business-process map into plain words --
  the map of every area under `docs/bp/` becomes a document under `docs/bp/` that the owner
  can read. The committed document must equal the render: this test runs the tool in
  `--check` mode on the real checkout, so a map that changed without its document fails
  the backend gate (the test is a global CI pin: `scripts/ci_select_tests.py`, the fixed
  safety set).

  The tool's own unit tests (`scripts/bp/tests/test_bp_doc.py`) cover the render itself on a
  fixture checkout (a fixture map, a fixture runner report, the `--check` failures); this one
  is the gate on the real tree.

  No database, no network, no model: the tool reads the map files, the orphan files and the
  runner scenario files, and writes nothing.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/bp/bp_doc.py")

  test "the committed document of every area equals the render of its map" do
    {out, code} =
      System.cmd(
        "python3",
        ["-I", "-B", @script, "--root", @root, "--check", "all"],
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "bp_doc --check: PASS"
  end
end
