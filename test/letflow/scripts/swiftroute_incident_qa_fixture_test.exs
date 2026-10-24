defmodule Letflow.Scripts.SwiftrouteIncidentQaFixtureTest do
  @moduledoc """
  ISS-1022 / Q-1004 (GH #2294) -- the QA deployment payload for the SwiftRoute "Driver Incident
  Report" process (`test/fixtures/qa/swiftroute_incident_process_definition.json`, deployed by
  `scripts/seed_swiftroute_incident_definition.sh`) must stay in step with its simulation copy
  (`test/fixtures/simulation/swiftroute/process_shipment_dispatch.yaml`; the filename is
  historical) and with the alias sidecar the UAT preflight resolves.

  Why the in-step guard: the D-ESC escalation work (ISS-1007 / Q-989) lives on the human-task
  nodes, the timer node, the completion edges (`condition: "true"`) and the timeout edges. If the
  JSON drifted from the YAML, the QA instance would run a different escalation than the engine
  tests prove. SERVICE_TASK `attributes` are deliberately NOT compared: the YAML carries the
  simulation's relative stub endpoints, the QA JSON the dispatchable https ones
  (ISS-0930; see `qa_fixture_service_task_endpoints_test.exs`).

  Scrutiny and variable_schemas are covered table-driven elsewhere
  (`shipped_definitions_default_edge_scrutiny_test.exs`, `shipped_definitions_variable_schemas_test.exs`,
  `swiftroute_d_esc_escalation_fixture_test.exs`), all of which discover this fixture by glob/list.
  Pure file I/O, `async: true`.

  The accountant actor that `finance-estimate` routes to is seeded under ISS-1011 / Q-993, not here.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)
  @json Path.join(@root, "test/fixtures/qa/swiftroute_incident_process_definition.json")
  @yaml Path.join(@root, "test/fixtures/simulation/swiftroute/process_shipment_dispatch.yaml")
  @alias_file Path.join(
                @root,
                "test/fixtures/uat/process-definition-aliases/proc-swiftroute-driver-incident.yaml"
              )
  @script Path.join(@root, "scripts/seed_swiftroute_incident_definition.sh")

  @escalation_nodes ~w(ops-assessment escalate-ops-assessment-to-ceo finance-estimate
                       escalate-finance-estimate-to-ceo)
  @notice_nodes ~w(ops-auto-close finance-auto-close)

  defp json, do: @json |> File.read!() |> Jason.decode!()
  defp yaml, do: YamlElixir.read_from_file!(@yaml)

  defp node(d, id), do: Enum.find(d["graph"]["nodes"], &(&1["id"] == id))

  defp edge_shape(e),
    do: {e["id"], e["source"], e["target"], e["condition"], e["is_default"] == true}

  test "the QA fixture is Driver Incident Report v1.2 and matches the simulation copy and alias" do
    j = json()
    y = yaml()
    {:ok, a} = YamlElixir.read_from_file(@alias_file)

    assert j["name"] == "Driver Incident Report"
    assert j["version"] == "1.2"
    assert j["description"] =~ "REQ-530"
    assert j["name"] == y["name"]
    assert j["version"] == y["version"]
    assert j["name"] == a["definition_name"], "preflight resolves the alias by this exact name"
  end

  test "the ops-escalation-timer branch is gone: nothing but the task branches feeds parallel-join" do
    for d <- [json(), yaml()] do
      refute node(d, "ops-escalation-timer")
      refute Enum.any?(d["graph"]["nodes"], &(&1["node_type"] == "TIMER"))

      assert d["graph"]["edges"]
             |> Enum.filter(&(&1["target"] == "parallel-join"))
             |> Enum.map(& &1["source"])
             |> Enum.sort() ==
               ~w(escalate-finance-estimate-to-ceo escalate-ops-assessment-to-ceo finance-auto-close
                  finance-estimate ops-assessment ops-auto-close)
    end
  end

  test "node ids, node types and edge shapes are identical to the simulation graph" do
    j = json()
    y = yaml()

    assert Enum.map(j["graph"]["nodes"], &{&1["id"], &1["node_type"]}) |> Enum.sort() ==
             Enum.map(y["graph"]["nodes"], &{&1["id"], &1["node_type"]}) |> Enum.sort()

    assert Enum.map(j["graph"]["edges"], &edge_shape/1) |> Enum.sort() ==
             Enum.map(y["graph"]["edges"], &edge_shape/1) |> Enum.sort()
  end

  test "the D-ESC escalation nodes carry exactly the simulation's roles, timers and pairs" do
    j = json()
    y = yaml()

    for id <- @escalation_nodes do
      assert node(j, id)["attributes"] == node(y, id)["attributes"],
             "#{id}: QA JSON attributes drifted from the simulation YAML"
    end

    # spot-pin the ruling itself so a simultaneous edit of both files is also caught
    ops = node(j, "ops-assessment")["attributes"]

    assert {ops["role"], ops["escalation_timer_duration"], ops["escalation_role"]} ==
             {"role-ops-manager", "P1D", "role-ceo"}

    fin = node(j, "finance-estimate")["attributes"]

    assert {fin["role"], fin["escalation_timer_duration"], fin["escalation_role"]} ==
             {"role-accountant", "P1D", "role-ceo"}
  end

  test "the fail-closed notice nodes exist as SERVICE_TASKs, and completion edges carry the true condition (timer-fire safe)" do
    j = json()

    for id <- @notice_nodes, do: assert(node(j, id)["node_type"] == "SERVICE_TASK")

    for id <- ~w(e6 e8 e6-escalated e8-escalated) do
      e = Enum.find(j["graph"]["edges"], &(&1["id"] == id))
      assert e["condition"] == "true", "#{id} must stay the conditioned completion edge"
    end
  end

  test "the injury gate defaults toward more scrutiny (the safety notification)" do
    j = json()
    default = Enum.find(j["graph"]["edges"], &(&1["id"] == "injury-check-default"))
    assert default["is_default"] == true
    assert default["target"] == "safety-notification"
  end

  test "variable_schemas declare the condition variable as a boolean" do
    schemas = Map.new(json()["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})
    assert schemas["injury_involved"]["type"] == "boolean"
  end

  # REQ-530 / GH #3086: the people-steps' form fields, and the typed variables they write.
  test "ops-assessment and escalate-ops-assessment-to-ceo require assessment_notes (string) and nothing else" do
    for id <- ~w(ops-assessment escalate-ops-assessment-to-ceo) do
      attrs = node(json(), id)["attributes"]

      assert attrs["form_schema"]["properties"]["assessment_notes"]["type"] == "string", id
      assert attrs["form_schema"]["required"] == ["assessment_notes"], id
      assert attrs["required_outputs"] == ["assessment_notes"], id
    end
  end

  test "finance-estimate and escalate-finance-estimate-to-ceo require estimated_cost_eur (number, minimum 0); finance_notes is optional" do
    for id <- ~w(finance-estimate escalate-finance-estimate-to-ceo) do
      attrs = node(json(), id)["attributes"]
      props = attrs["form_schema"]["properties"]

      assert props["estimated_cost_eur"]["type"] == "number", id
      assert props["estimated_cost_eur"]["minimum"] == 0, id
      assert props["finance_notes"]["type"] == "string", id
      assert attrs["form_schema"]["required"] == ["estimated_cost_eur"], id
      assert attrs["required_outputs"] == ["estimated_cost_eur"], id
      refute "finance_notes" in attrs["form_schema"]["required"], id
      refute "finance_notes" in attrs["required_outputs"], id
    end
  end

  test "variable_schemas type the three form values next to injury_involved" do
    schemas = Map.new(json()["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

    assert schemas["injury_involved"] == %{"type" => "boolean"}
    assert schemas["assessment_notes"] == %{"type" => "string"}
    assert schemas["estimated_cost_eur"] == %{"type" => "number", "minimum" => 0}
    assert schemas["finance_notes"] == %{"type" => "string"}
  end

  test "the form, required_outputs and variable_schemas of the four people-steps equal the simulation copy" do
    j = json()
    y = yaml()

    for id <- @escalation_nodes do
      assert node(j, id)["attributes"]["form_schema"] == node(y, id)["attributes"]["form_schema"],
             "#{id}: form_schema drifted from the simulation YAML"

      assert node(j, id)["attributes"]["required_outputs"] ==
               node(y, id)["attributes"]["required_outputs"],
             "#{id}: required_outputs drifted from the simulation YAML"
    end

    assert Enum.sort_by(j["variable_schemas"], & &1["variable_key"]) ==
             Enum.sort_by(y["variable_schemas"], & &1["variable_key"])
  end

  describe "seed script" do
    test "exists, targets this fixture and the Driver Incident Report name, sends via stdin" do
      src = File.read!(@script)

      assert src =~ "swiftroute_incident_process_definition.json"
      assert src =~ "Driver+Incident+Report"
      assert src =~ "--data-binary @-"
      refute src =~ ~r/-d\s+"\$\{PAYLOAD\}"/
      assert src =~ "proc-swiftroute-driver-incident"
      assert src =~ "ISS-1011"
    end

    test "prints no secret: the token is only ever used inside the Authorization header" do
      lines =
        @script
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))

      leaks =
        Enum.filter(lines, fn l ->
          l =~ ~r/(?<!\\)\$\{?QA_AUTH_TOKEN/ and l =~ ~r/\b(echo|printf)\b/
        end)

      assert leaks == [], inspect(leaks)
    end
  end

  describe "seed script behaviour against a stub curl (idempotency and activation)" do
    @stub ~S"""
    #!/usr/bin/env bash
    dir="${STUB_CURL_DIR}"
    args=("$@")
    last="${args[$(( ${#args[@]} - 1 ))]}"
    method=GET
    for ((i = 0; i < ${#args[@]}; i++)); do
      case "${args[$i]}" in
        -X) method="${args[$((i + 1))]}" ;;
        --data-binary) cat > /dev/null ;;
      esac
    done
    printf '%s %s\n' "${method}" "${last}" >> "${dir}/calls"
    if [[ "${last}" == */me/access ]]; then
      printf '%s' '{"permissions":["DefinitionsRead","DefinitionsWrite"]}'
    elif [[ "${last}" == */activate ]]; then
      printf '%s' '{"id":"d1","name":"Driver Incident Report","version":"1.0","status":"ACTIVE"}'
    elif [[ "${method}" == POST ]]; then
      printf '%s' '{"id":"d1","name":"Driver Incident Report","version":"1.0","status":"DRAFT"}'
    elif [[ -n "${STUB_ACTIVE_VERSION:-}" ]]; then
      printf '{"items":[{"id":"old1","name":"Driver Incident Report","version":"%s","status":"ACTIVE"}]}' "${STUB_ACTIVE_VERSION}"
    else
      printf '%s' '{"items":[]}'
    fi
    """

    defp seed_calls(active_version) do
      bash =
        case :os.type() do
          {:win32, _} ->
            git = System.find_executable("git")
            roots = if git, do: [Path.dirname(Path.dirname(git))], else: []
            roots = roots ++ ["C:/Program Files/Git"]

            Enum.find(
              Enum.map(roots, &Path.join([&1, "usr", "bin", "bash.exe"])),
              &File.exists?/1
            )

          _ ->
            System.find_executable("bash")
        end

      assert bash, "bash not found"
      dir = Path.join(System.tmp_dir!(), "incident_seed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      File.write!(Path.join(dir, "curl"), String.replace(@stub, "\r\n", "\n"))
      File.chmod!(Path.join(dir, "curl"), 0o755)
      sep = if match?({:win32, _}, :os.type()), do: ";", else: ":"

      {out, status} =
        System.cmd(bash, ["scripts/seed_swiftroute_incident_definition.sh"],
          cd: @root,
          stderr_to_stdout: true,
          env:
            [
              {"PATH", dir <> sep <> System.get_env("PATH", "")},
              {"STUB_CURL_DIR", String.replace(dir, "\\", "/")},
              {"QA_AUTH_TOKEN", "stub-token"},
              {"QA_URL", "https://stub.invalid"}
            ] ++ if(active_version, do: [{"STUB_ACTIVE_VERSION", active_version}], else: [])
        )

      assert status == 0, String.slice(out, 0, 1500)

      calls =
        case File.read(Path.join(dir, "calls")) do
          {:ok, c} -> c |> String.split(~r/\r?\n/, trim: true)
          _ -> []
        end

      {calls, out}
    end

    test "nothing ACTIVE: creates the definition and then activates it" do
      {calls, _} = seed_calls(nil)
      assert Enum.count(calls, &String.starts_with?(&1, "POST ")) == 2, inspect(calls)
      assert Enum.any?(calls, &(&1 =~ ~r{^POST \S+/definitions$})), inspect(calls)
      assert Enum.any?(calls, &(&1 =~ ~r{^POST \S+/definitions/d1/activate$})), inspect(calls)
    end

    test "ACTIVE at the fixture version: idempotent no-op (no POST at all)" do
      {calls, out} = seed_calls("1.2")
      assert Enum.reject(calls, &String.starts_with?(&1, "GET ")) == [], inspect(calls)
      assert out =~ "skipping creation"
    end

    test "ACTIVE newer than the fixture: never downgrades (no POST)" do
      {calls, _} = seed_calls("1.3")
      assert Enum.reject(calls, &String.starts_with?(&1, "GET ")) == [], inspect(calls)
    end

    test "ACTIVE older than the fixture: creates and activates the fixture version" do
      {calls, _} = seed_calls("1.0")
      assert Enum.count(calls, &String.starts_with?(&1, "POST ")) == 2, inspect(calls)
    end
  end
end
