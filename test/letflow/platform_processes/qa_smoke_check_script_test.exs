defmodule Letflow.PlatformProcesses.QaSmokeCheckScriptTest do
  # T-2739: the shell half of the QA deploy smoke check (deploy/redeploy-qa.sh, step 9b). The block
  # is cut out of the script and run with a fake `docker` that prints a fixed rpc answer.
  use ExUnit.Case, async: true

  @script "deploy/redeploy-qa.sh"

  defp run_block(rpc_output) do
    dir = Path.join(System.tmp_dir!(), "qa_smoke_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    docker = Path.join(dir, "docker")
    File.write!(docker, "#!/bin/bash\ncat <<'OUT'\n#{rpc_output}\nOUT\n")
    File.chmod!(docker, 0o755)

    src = File.read!(@script)
    [_, rest] = String.split(src, "SMOKE_OUT=$(", parts: 2)
    [_, block_tail] = String.split(rest, "\n", parts: 2)
    [tail, _] = String.split(block_tail, "\n# 10.", parts: 2)

    File.write!(
      Path.join(dir, "block.sh"),
      "APP_CTR=x\nSMOKE_OUT=$(docker exec x rpc) || SMOKE_OUT=\"\"\n" <> tail
    )

    System.cmd("bash", [Path.join(dir, "block.sh")],
      env: [{"PATH", dir <> ":" <> System.get_env("PATH")}],
      stderr_to_stdout: true
    )
  end

  test "SMOKE_OK passes the deploy" do
    assert {_out, 0} = run_block("SMOKE_OK\n:ok")
  end

  test "SMOKE_FAIL fails the deploy and the reason is printed" do
    {out, code} = run_block("SMOKE_FAIL :definition_missing\n:ok")
    assert code == 1
    assert out =~ "SMOKE_FAIL :definition_missing"
    assert out =~ "LETFLOW_PLATFORM_TENANT_ID"
  end

  test "no output fails the deploy" do
    assert {_out, 1} = run_block("")
  end
end
