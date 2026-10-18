defmodule Letflow.Scripts.SeedVortexEntitiesActivateTest do
  @moduledoc """
  ISS-0931 (Q-931): `seed_entity_definition` in `scripts/seed_vortex_entities.sh`
  must send a `rationale` body on activate (API returns 422 otherwise) and must
  resume -- activate -- an existing INACTIVE draft left by an aborted earlier run,
  while leaving an already ACTIVE definition alone. Runs the script's own two
  functions (extracted verbatim) against a stub `curl`; no network, no DB.
  """
  use ExUnit.Case, async: true

  @script "scripts/seed_vortex_entities.sh"

  # Stub: GET by-name answers per $STUB_BY_NAME_STATUS ("404" | "active" | "inactive");
  # POST create answers an id; POST activate answers 422 unless the body carries a
  # rationale (mirrors the real API).
  @curl_stub ~S"""
  #!/usr/bin/env bash
  method=GET; url=""; outfile=""; data=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -o) outfile="$2"; shift 2 ;;
      -d) data="$2"; shift 2 ;;
      -w|-H) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  echo "$method $url $data" >> "$STUB_LOG"
  emit() { if [[ -n "$outfile" ]]; then printf '%s' "$1" > "$outfile"; else printf '%s' "$1"; fi; }
  case "$method $url" in
    "GET "*"/by-name/"*)
      if [[ "$STUB_BY_NAME_STATUS" == "404" ]]; then emit '{}'; printf 404
      else emit "{\"id\":\"def-1\",\"status\":\"$STUB_BY_NAME_STATUS\"}"; printf 200; fi ;;
    "POST "*"/entities/definitions") printf '{"id":"def-1"}' ;;
    "POST "*"/activate")
      if [[ "$data" == *'"rationale":"'?* ]]; then emit '{"status":"active"}'; printf 200
      else emit '{"detail":"rationale: field is required"}'; printf 422; fi ;;
  esac
  """

  defp bash, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")
  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  defp run_seed(by_name_status), do: by_name_status |> prepare_seed() |> exec_seed()

  # Split so a test can prepare several runs (on_exit must be registered from the test
  # process) and then execute them concurrently.
  defp prepare_seed(by_name_status) do
    dir = Path.join(System.tmp_dir!(), "iss0931-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    stub = Path.join(dir, "curl")
    File.write!(stub, @curl_stub)
    File.chmod!(stub, 0o755)
    log = Path.join(dir, "calls.log")
    File.write!(log, "")

    src = File.read!(@script)
    [_, from_activate] = String.split(src, "activate_definition() {", parts: 2)

    [funcs, _] =
      String.split(from_activate, ~s(\nseed_entity_definition "production_batch"), parts: 2)

    fixture = Path.join(dir, "fixture.json")
    File.write!(fixture, "{}")

    harness = """
    AUTH_HEADER="Authorization: Bearer t"; API="http://stub/api/v1"; QA_URL="http://stub"; REPO_ROOT="#{dir}"
    activate_definition() {#{funcs}
    seed_entity_definition "production_batch" "fixture.json"
    """

    harness_file = Path.join(dir, "harness.sh")
    File.write!(harness_file, "set -euo pipefail\n" <> harness)

    %{dir: dir, log: log, harness_file: harness_file, by_name_status: by_name_status}
  end

  defp exec_seed(%{dir: dir, log: log, harness_file: harness_file, by_name_status: status_in}) do
    {out, status} =
      System.cmd(bash(), [harness_file],
        env: [
          {"PATH", dir <> path_sep() <> System.get_env("PATH")},
          {"STUB_LOG", log},
          {"STUB_BY_NAME_STATUS", status_in},
          {"TMPDIR", dir}
        ],
        stderr_to_stdout: true
      )

    {out, status, File.read!(log)}
  end

  defp available?, do: bash() != nil and System.find_executable("jq") != nil

  test "fresh create then activate sends a rationale (no 422)" do
    if available?() do
      {out, status, calls} = run_seed("404")
      assert status == 0, out
      assert calls =~ ~s(/activate {"rationale":")
    end
  end

  test "an existing inactive draft is activated (resume after an aborted run)" do
    if available?() do
      {out, status, calls} = run_seed("inactive")
      assert status == 0, out
      assert calls =~ ~s(/activate {"rationale":")
      refute calls =~ "POST http://stub/api/v1/entities/definitions {"
    end
  end

  test "an existing active definition is left alone" do
    if available?() do
      {out, status, calls} = run_seed("active")
      assert status == 0, out
      refute calls =~ "/activate"
    end
  end

  test "two seeds running at the same time do not see each other's by-name answer (GH #2826)" do
    if available?() do
      # An 'inactive' run and an 'active' run share nothing but the machine: before the fix both
      # wrote /tmp/vortex_entity_def_check.json and one could read the other's answer.
      for _ <- 1..6 do
        inactive = prepare_seed("inactive")
        active = prepare_seed("active")

        [inactive_task, active_task] =
          for prepared <- [inactive, active], do: Task.async(fn -> exec_seed(prepared) end)

        {out_i, status_i, calls_i} = Task.await(inactive_task, 60_000)
        {out_a, status_a, calls_a} = Task.await(active_task, 60_000)

        assert status_i == 0, out_i
        assert status_a == 0, out_a
        assert calls_i =~ ~s(/activate {"rationale":")
        refute calls_a =~ "/activate"
      end
    end
  end

  test "the script never writes the definition check to a fixed shared /tmp path" do
    # Concurrent tests (and concurrent seed runs) share /tmp; a fixed path let one run
    # overwrite another's by-name answer (CI flake on the 'inactive draft' test).
    refute File.read!(@script) =~ "/tmp/vortex_entity_def_check.json"
  end
end
