defmodule Letflow.Scripts.GateBSeedFourEyesTest do
  @moduledoc """
  T-2701: step 8 of scripts/e2e/gate_b_seed.sh switches four-eyes ON for the stock opening
  approval and is loud: it logs the rules it saw and dies when it switched zero rows.

  Runs the real step-8 text (cut out of the script between its markers) under bash with
  stub `api`, `log`, `die` and `reason` functions: no network, no DB.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @script Path.expand("../../scripts/e2e/gate_b_seed.sh", __DIR__)

  defp tools_available?,
    do: System.find_executable("bash") != nil and System.find_executable("jq") != nil

  defp step8 do
    text = File.read!(@script)
    [_, rest] = String.split(text, ~s(log "== 8. four eyes ON), parts: 2)
    [body, _] = String.split(rest, ~s(log "== done), parts: 2)
    ~s(log "== 8. four eyes ON) <> body
  end

  # `rules_json` is what GET /approval-rules answers; PUT answers 200 with four_eyes true.
  defp run(rules_json) do
    dir = Path.join(System.tmp_dir!(), "t2701-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.write!(Path.join(dir, "rules.json"), rules_json)
    File.write!(Path.join(dir, "step8.sh"), step8())

    harness = ~S"""
    set -euo pipefail
    RESP="$D/resp.json"
    log() { printf '%s\n' "$*" >&2; }
    die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
    reason() { echo "?"; }
    api() {
      if [ "$1" = POST ]; then echo "POST $2" >> "$D/calls.log"; printf '{}' > "$RESP"; STATUS=200
      elif [ "$1" = GET ]; then echo "GET $2" >> "$D/calls.log"; cp "$D/rules.json" "$RESP"; STATUS=200
      else echo "PUT $2" >> "$D/puts.log"; printf '{"four_eyes":true}' > "$RESP"; STATUS=200; fi
    }
    . "$D/step8.sh"
    """

    {out, status} =
      System.cmd(System.find_executable("bash"), ["-c", harness],
        env: [{"D", dir}],
        stderr_to_stdout: true
      )

    puts = Path.join(dir, "puts.log")
    calls = Path.join(dir, "calls.log")
    Process.put(:calls, if(File.exists?(calls), do: File.read!(calls), else: ""))
    {out, status, if(File.exists?(puts), do: File.read!(puts), else: "")}
  end

  @opening ~s({"definition_name":"Stock opening","node_id":"approve","four_eyes":false,"in_active_definition":false})
  @other ~s({"definition_name":"Stock issue","node_id":"approve","four_eyes":false,"in_active_definition":true})

  test "T2701-1 an inactive opening row is switched ON, other rules are untouched, counts are logged" do
    if tools_available?() do
      {out, status, puts} = run(~s({"items":[#{@opening},#{@other}]}))
      assert status == 0, out
      assert puts == "PUT /approval-rules/Stock%20opening/approve\n"

      assert Process.get(:calls) ==
               "POST /tenant/modules/stock/ensure-seeds\nGET /approval-rules\n"

      assert out =~ "approval rules seen: 2"
      assert out =~ "rule Stock opening/approve four_eyes=false in_active_definition=false"
      assert out =~ "opening approval rows seen 1, switched or already ON 1"
    end
  end

  test "T2701-2 an opening row already ON counts and is not written again" do
    if tools_available?() do
      on = String.replace(@opening, ~s("four_eyes":false), ~s("four_eyes":true))
      {out, status, puts} = run(~s({"items":[#{on}]}))
      assert status == 0, out
      assert puts == ""
      assert out =~ "already ON"
    end
  end

  test "T2701-3 zero opening rows fails the seed loudly" do
    if tools_available?() do
      {out, status, puts} = run(~s({"items":[#{@other}]}))
      assert status == 1
      assert puts == ""
      assert out =~ "approval rules seen: 1"
      assert out =~ "STOP: four eyes: no stock opening approval row was switched ON (seen 0)"
    end
  end
end
