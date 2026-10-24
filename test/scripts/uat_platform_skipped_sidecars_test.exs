defmodule Letflow.Scripts.UatPlatformSkippedSidecarsTest do
  @moduledoc """
  REQ-534 (GH #3103): the sidecars in `test/fixtures/uat/scenario-env-limitations/` for
  platform-sandbox-cross-tenant-probe (UNBUILT_FEATURE) and platform-frontend-guard-selfcheck /
  platform-out-of-order-effect-completion (COVERED_ELSEWHERE) carry `disposition: skipped` for
  `qa`. For the COVERED_ELSEWHERE ones every expected outcome id of the scenario must be in the
  reason, and every cited test file and test name must exist. The preflight must list all three
  under `== SKIPPED SCENARIOS ==`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @limits "test/fixtures/uat/scenario-env-limitations"
  @scenarios "test/fixtures/uat/scenarios/platform"
  @covered %{
    "platform-frontend-guard-selfcheck" => "frontend-guard-selfcheck",
    "platform-out-of-order-effect-completion" => "out-of-order-effect-completion"
  }
  @unbuilt "platform-sandbox-cross-tenant-probe"
  @jwt "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"

  defp sidecar(id), do: elem(YamlElixir.read_from_file(Path.join(@limits, id <> ".yaml")), 1)

  defp outcome_ids(file) do
    {:ok, docs} = YamlElixir.read_all_from_file(Path.join(@scenarios, file <> ".yaml"))
    scenario = Enum.find(docs, &is_map/1)
    Enum.map(scenario["expected_outcomes"], & &1["id"])
  end

  defp citations(reason) do
    for line <- String.split(reason, "\n"),
        [_, id, path, name] <- [Regex.run(~r/^(EO-\d+) \| (\S+) \| (.+)$/, String.trim(line))],
        do: {id, path, name}
  end

  for id <- [@unbuilt | Map.keys(@covered)] do
    test "S1 #{id}: skipped for qa with an issue_ref" do
      s = sidecar(unquote(id))
      assert s["scenario_id"] == unquote(id)
      assert s["disposition"] == "skipped"
      assert s["applies_to_environments"] == ["qa"]
      assert s["issue_ref"] =~ ~r/^ISS-\d+$/
      refute Map.has_key?(s, "applies_to_expected_outcomes")
    end
  end

  test "S2 sandbox sidecar: UNBUILT_FEATURE, names the Agent* routers and the removal condition" do
    s = sidecar(@unbuilt)
    assert s["classification"] == "UNBUILT_FEATURE"
    assert s["issue_ref"] == "ISS-0890"

    for router <- ~w(AgentRequests AgentResponses AgentEvents) do
      assert s["reason"] =~ router
    end

    assert s["review"] =~ "runtime-agent sandbox subsystem exists"
    assert s["review"] =~ "owner has decided to test it"
  end

  for {id, file} <- @covered do
    test "S3 #{id}: every outcome id is in the reason; cited tests exist" do
      s = sidecar(unquote(id))
      assert s["classification"] == "COVERED_ELSEWHERE"
      assert s["issue_ref"] == "ISS-0900"

      ids = outcome_ids(unquote(file))
      assert ids != []
      cites = citations(s["reason"])

      for eo <- ids do
        assert s["reason"] =~ eo
        assert Enum.any?(cites, fn {c, _, _} -> c == eo end), "#{eo} has no citation"
      end

      for {eo, path, name} <- cites do
        assert eo in ids
        assert File.regular?(path), "#{path} does not exist"
        assert File.read!(path) =~ name, "#{path} has no test named #{inspect(name)}"
      end
    end
  end

  test "S4 preflight lists the three scenarios under SKIPPED SCENARIOS", %{tmp_dir: tmp} do
    limits = Path.join(tmp, "limits")
    scen = Path.join(tmp, "scenarios/platform")
    File.mkdir_p!(limits)
    File.mkdir_p!(scen)

    for id <- [@unbuilt | Map.keys(@covered)] do
      File.cp!(Path.join(@limits, id <> ".yaml"), Path.join(limits, id <> ".yaml"))
    end

    for f <- ["sandbox-cross-tenant-probe" | Map.values(@covered)] do
      File.cp!(Path.join(@scenarios, f <> ".yaml"), Path.join(scen, f <> ".yaml"))
    end

    cred = Path.join(tmp, "cred.sh")

    File.write!(cred, """
    #!/bin/bash
    if [ "$1" = "token" ]; then
      printf '%s\n' '#{@jwt}'
    fi
    """)

    base_url = start_stub()

    args = [
      "scripts/uat_preflight.sh",
      "--base-url",
      base_url,
      "--environment",
      "qa",
      "--credential-source",
      cred,
      "--credential-protocol",
      "qa-uat-env",
      "--scenarios",
      Path.join(tmp, "scenarios"),
      "--env-limitations",
      limits,
      "--sha",
      "deadbeef",
      "--idp-url",
      base_url,
      "--out",
      Path.join(tmp, "out.json")
    ]

    launcher = System.get_env("UAT_PF_BASH") || System.find_executable("bash")
    {out, _} = System.cmd(launcher, args, stderr_to_stdout: true)

    assert out =~ "== SKIPPED SCENARIOS =="

    assert out =~
             "platform-sandbox-cross-tenant-probe  classification=UNBUILT_FEATURE  issue_ref=ISS-0890"

    for id <- Map.keys(@covered) do
      assert out =~ "#{id}  classification=COVERED_ELSEWHERE  issue_ref=ISS-0900"
    end
  end

  defp start_stub do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    pid = spawn_link(fn -> accept_loop(lsock) end)

    on_exit(fn ->
      :gen_tcp.close(lsock)
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn(fn -> serve(sock, "") end)
        accept_loop(lsock)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
      )

      :gen_tcp.close(sock)
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> serve(sock, acc <> data)
        {:error, _} -> :gen_tcp.close(sock)
      end
    end
  end
end
