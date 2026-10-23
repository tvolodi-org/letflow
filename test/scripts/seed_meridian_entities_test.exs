defmodule Letflow.Scripts.SeedMeridianEntitiesTest do
  @moduledoc """
  GH #3077: `scripts/seed_meridian_entities.sh` gives the meridian refusal scenario (step 8,
  the risk manager's unredacted borrower export) data to refuse. Checks the fixtures, the
  scenario step and the persona script hook, and runs the WHOLE script against a stub `curl`
  (no network, no DB): it creates and activates `borrower`, restricts the personal-data fields,
  grants them to the seeding account only, and imports the three records.
  """
  use ExUnit.Case, async: true

  @script "scripts/seed_meridian_entities.sh"
  @definition "test/fixtures/qa/meridian_borrower_entity_definition.json"
  @records "test/fixtures/qa/meridian_borrower_records.json"
  @scenario "test/fixtures/uat/scenarios/meridian/refusal-loan-approval-and-disbursement.yaml"
  @restricted ~w(national_id date_of_birth contact_email)

  @curl_stub ~S"""
  #!/usr/bin/env bash
  method=GET; url=""; outfile=""; stdin_body=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -o) outfile="$2"; shift 2 ;;
      --data-binary) stdin_body=1; shift 2 ;;
      -w|-H) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  echo "$method $url" >> "$STUB_LOG"
  if [[ "$stdin_body" == "1" ]]; then body=$(cat | jq -c .); printf '{"url":"%s","body":%s}\n' "$url" "$body" >> "$STUB_STDIN_LOG"; fi
  emit() { if [[ -n "$outfile" && "$outfile" != "/dev/null" ]]; then printf '%s' "$1" > "$outfile"; else printf '%s' "$1"; fi; }
  case "$method $url" in
    "GET "*"/me/access") printf '{"permissions":["EntitiesDefinitionsWrite","EntitiesRecordsImport","EntitiesRestrictionsManage","UsersGroupsRolesManage"]}' ;;
    "GET "*"/by-name/"*) emit '{}'; printf 404 ;;
    "POST "*"/entities/definitions") printf '{"id":"def-1"}' ;;
    "POST "*"/activate") emit '{"status":"active"}'; printf 200 ;;
    "GET "*"/identity/users?search="*) printf '{"items":[{"id":"seed-id","username":"seeder-svc"}]}' ;;
    "POST "*"/restrictions/import") printf '{"inserted":{"field_restrictions":3,"field_grants":3}}' ;;
    "POST "*"/entities/query") printf '{"items":[],"next_cursor":null}' ;;
    "POST "*"/borrower/import") printf '{"results":[{"status":"created"}]}' ;;
  esac
  """

  defp bash, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")
  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")
  defp tools_available?, do: bash() != nil and System.find_executable("jq") != nil

  defp run_script(env) do
    dir = Path.join(System.tmp_dir!(), "gh3077-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    stub = Path.join(dir, "curl")
    File.write!(stub, @curl_stub)
    File.chmod!(stub, 0o755)
    log = Path.join(dir, "calls.log")
    stdin_log = Path.join(dir, "stdin.log")
    File.write!(stdin_log, "")

    {out, status} =
      System.cmd(bash(), [@script],
        env:
          [
            {"PATH", dir <> path_sep() <> System.get_env("PATH")},
            {"QA_AUTH_TOKEN", "tok"},
            {"QA_URL", "http://stub"},
            {"STUB_LOG", log},
            {"STUB_STDIN_LOG", stdin_log}
          ] ++ env,
        stderr_to_stdout: true
      )

    calls = if File.exists?(log), do: File.read!(log), else: ""

    bodies =
      stdin_log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    {out, status, calls, bodies}
  end

  test "fixtures: borrower type with restricted personal-data fields and a few records" do
    def_ = @definition |> File.read!() |> Jason.decode!()
    assert def_["name"] == "borrower"
    names = Enum.map(def_["fields"], & &1["name"])
    assert Enum.all?(@restricted, &(&1 in names))

    records = @records |> File.read!() |> Jason.decode!()
    assert records["entity_type"] == "borrower"
    assert length(records["records"]) >= 3

    for r <- records["records"] do
      assert Enum.all?(@restricted, &Map.has_key?(r["field_values"], &1))
      assert r["field_values"]["borrower_ref"] == r["record_id"]
    end
  end

  test "scenario step 8 names the export route and entity type, and the loan's borrower is seeded" do
    steps = @scenario |> File.read!() |> String.split("\n  - step: ")
    step8 = Enum.find(steps, &String.starts_with?(&1, "8\n"))
    assert step8 =~ "route: POST /api/v1/entities/records/borrower/export"
    assert step8 =~ "entity_type: borrower"
    assert step8 =~ "unredacted: true"
    assert step8 =~ "expect_refusal: true"

    step1 = Enum.find(steps, &String.starts_with?(&1, "1\n"))
    [_, applicant] = Regex.run(~r/applicant_id: (\S+)/, step1)

    refs =
      @records
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("records")
      |> Enum.map(& &1["record_id"])

    assert applicant in refs
  end

  test "the meridian persona script calls the entity seed when a seeding account is set" do
    src = File.read!("scripts/seed_meridian_persona_actors.sh")
    assert src =~ "seed_meridian_entities.sh"
    assert src =~ "SEED_ACTOR_USERNAME"
  end

  test "seed creates and activates borrower, restricts the fields for the seeder only, imports records" do
    if tools_available?() do
      {out, status, calls, bodies} = run_script([{"SEED_ACTOR_USERNAME", "seeder-svc"}])
      assert status == 0, out
      assert calls =~ "POST http://stub/api/v1/entities/definitions\n"
      assert calls =~ "POST http://stub/api/v1/entities/definitions/borrower/activate"
      assert calls =~ "POST http://stub/api/v1/entities/records/borrower/import"

      restr = Enum.find(bodies, &String.ends_with?(&1["url"], "/restrictions/import"))["body"]

      assert restr["field_restrictions"] |> Enum.map(& &1["field_name"]) |> Enum.sort() ==
               Enum.sort(@restricted)

      assert Enum.all?(restr["field_grants"], &(&1["user_id"] == "seed-id"))

      imp = Enum.find(bodies, &String.ends_with?(&1["url"], "/borrower/import"))["body"]
      assert length(imp["records"]) == 3
    end
  end

  test "seed refuses to run without SEED_ACTOR_USERNAME or as a persona, before any call" do
    if tools_available?() do
      {out, status, calls, _} = run_script([])
      assert status == 1
      assert out =~ "SEED_ACTOR_USERNAME is not set"
      assert calls == ""

      {out, status, calls, _} = run_script([{"SEED_ACTOR_USERNAME", "actor-meridian-miriam"}])
      assert status == 1
      assert out =~ "DEDICATED account"
      assert calls == ""
    end
  end
end
