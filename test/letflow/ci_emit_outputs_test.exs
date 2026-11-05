defmodule Letflow.CiEmitOutputsTest do
  @moduledoc """
  T-1311: `scripts/ci_emit_outputs.sh` writes the outputs of the "Select backend tests" step. The
  runner rejects a multi-line value whose delimiter is not on a line of its own ("Matching
  delimiter not found PLAN_EOF"), so these tests parse the file the way the runner does.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/ci_emit_outputs.sh")
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")

  # Runner-style parse: `key=value` lines and `key<<DELIM` ... DELIM (alone on its line) blocks.
  defp parse(text) do
    text |> String.split("\n") |> do_parse(%{})
  end

  defp do_parse([], acc), do: acc
  defp do_parse([""], acc), do: acc

  defp do_parse([line | rest], acc) do
    cond do
      String.contains?(line, "<<") ->
        [key, delim] = String.split(line, "<<", parts: 2)
        {body, after_body} = Enum.split_while(rest, &(&1 != delim))

        if after_body == [],
          do: flunk("Matching delimiter not found #{delim}"),
          else: do_parse(tl(after_body), Map.put(acc, key, Enum.join(body, "\n")))

      String.contains?(line, "=") ->
        [k, v] = String.split(line, "=", parts: 2)
        do_parse(rest, Map.put(acc, k, v))

      true ->
        flunk("Invalid format #{inspect(line)}")
    end
  end

  defp emit(plan) do
    out = Path.join(System.tmp_dir!(), "gh_out_#{System.unique_integer([:positive])}")
    File.write!(out, "")

    {_, 0} =
      System.cmd("bash", [@script, "selective", "why", "2 3", plan],
        env: [{"GITHUB_OUTPUT", out}]
      )

    text = File.read!(out)
    File.rm(out)
    parse(text)
  end

  @lib_plan "1 test/letflow/a_test.exs test/letflow/b_test.exs\n2 test/letflow/c_test.exs"
  @test_plan "1 test/letflow/x_test.exs"

  test "L1 lib-only plan with several lines, no trailing newline" do
    got = emit(@lib_plan)
    assert got["plan"] == @lib_plan
    assert got["mode"] == "selective" and got["skip_shards"] == "2 3"
  end

  test "L2 lib-only plan with a trailing newline (as $(cat) never gives, but files do)" do
    assert emit(@lib_plan <> "\n")["plan"] == @lib_plan
  end

  test "T1 test-only plan, one line, with and without trailing newline" do
    assert emit(@test_plan)["plan"] == @test_plan
    assert emit(@test_plan <> "\n")["plan"] == @test_plan
  end

  test "E1 empty plan still has a well-formed block" do
    assert emit("")["plan"] == ""
  end

  test "W1 ci.yml uses the script and the probe-branch rule" do
    yml = File.read!(@ci_yml)
    assert yml =~ "scripts/ci_emit_outputs.sh"
    refute yml =~ ~s(printf '%s' "$4")
    assert yml =~ "startsWith(github.head_ref, 'selective-probe/')"
    refute yml =~ "&& '' ||"
    assert yml =~ "scripts/ci_kill_switch.sh"
  end

  test "P1 probe PR blanks the kill switch, other runs keep it" do
    ks = Path.join(@root, "scripts/ci_kill_switch.sh")
    assert {"", 0} = System.cmd("bash", [ks, "off", "true"])
    assert {"off", 0} = System.cmd("bash", [ks, "off", "false"])
    assert {"off", 0} = System.cmd("bash", [ks, "off", ""])
    assert {"", 0} = System.cmd("bash", [ks, "", "false"])
  end

  test "D1 docs describe the probe PR" do
    doc = File.read!(Path.join([@root, "docs", "merge" <> "-queue.md"]))
    assert doc =~ "selective-probe/"
  end
end
