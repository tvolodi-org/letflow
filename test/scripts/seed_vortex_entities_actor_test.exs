defmodule Letflow.Scripts.SeedVortexEntitiesActorTest do
  @moduledoc """
  GH #2784 PR A: `scripts/seed_vortex_entities.sh` imports records over the generic write route,
  which now applies type access and field restrictions to the CALLER. So the script

    * requires `SEED_ACTOR_USERNAME` (a dedicated, non-persona account) and refuses a persona;
    * grants that account `production_batch.cost_figure` and `shipment_manifest` in the same
      restrictions import;
    * refuses to import when the token does not belong to that account (the grants would do
      nothing for it);
    * fails loudly on any `status: "error"` entry of an import response.

  Runs the WHOLE script against a stub `curl` (no network, no DB), same approach as
  `seed_vortex_entities_activate_test.exs`.
  """
  use ExUnit.Case, async: true

  @script "scripts/seed_vortex_entities.sh"

  # Stub: logs "METHOD URL" per call, copies a `--data-binary @-` body to $STUB_STDIN_LOG, and
  # answers per URL. The third by-name GET (after the two definition checks) is the token-owner
  # check and answers $STUB_OWNER_STATUS.
  @curl_stub ~S"""
  #!/usr/bin/env bash
  method=GET; url=""; outfile=""; stdin_body=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -o) outfile="$2"; shift 2 ;;
      --data-binary) stdin_body=1; shift 2 ;;
      -d|-w|-H) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  echo "$method $url" >> "$STUB_LOG"
  body=""
  if [[ "$stdin_body" == "1" ]]; then body=$(cat); printf '%s' "$body" | jq -c . >> "$STUB_STDIN_LOG"; fi
  emit() { if [[ -n "$outfile" && "$outfile" != "/dev/null" ]]; then printf '%s' "$1" > "$outfile"; else printf '%s' "$1"; fi; }
  case "$method $url" in
    "GET "*"/me/access") printf '{"permissions":["EntitiesDefinitionsRead","EntitiesDefinitionsWrite","EntitiesRecordsImport","EntitiesRestrictionsManage","UsersGroupsRolesManage"]}' ;;
    "GET "*"/by-name/"*)
      n=$(( $(cat "$STUB_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNTER"
      if (( n >= 3 )); then printf '%s' "$STUB_OWNER_STATUS"
      else emit '{"id":"def-1","status":"active"}'; printf 200; fi ;;
    "GET "*"/identity/users?search="*)
      name="${url##*search=}"
      if [[ "$STUB_FUZZY" == "1" ]]; then
        printf '{"items":[{"id":"decoy-%s","username":"%s-extra"},{"id":"id-%s","username":"%s"}]}' "$name" "$name" "$name" "$name"
      elif [[ "$STUB_FUZZY" == "2" ]]; then
        printf '{"items":[{"id":"decoy-%s","username":"%s-extra"}]}' "$name" "$name"
      else
        printf '{"items":[{"id":"id-%s","username":"%s"}]}' "$name" "$name"
      fi ;;
    "POST "*"/restrictions/import") printf '{"inserted":{"field_restrictions":1,"field_grants":2,"type_restrictions":1,"type_grants":1}}' ;;
    "POST "*"/entities/query") printf '{"items":[],"next_cursor":null}' ;;
    "POST "*"/shipment_manifest/import") printf '%s' "$STUB_SHIPMENT_IMPORT_RESPONSE" ;;
    "POST "*"/import") printf '%s' "$STUB_IMPORT_RESPONSE" ;;
  esac
  """

  @ok_import ~S|{"results":[{"status":"ok","record_id":"r","source_record_id":null}]}|
  @refused_import ~S|{"results":[{"status":"error","source_record_id":null,"reason":{"type":"field_restricted"}}]}|

  defp bash, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")
  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  defp run_seed(opts) do
    dir = Path.join(System.tmp_dir!(), "gh2784-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    stub = Path.join(dir, "curl")
    File.write!(stub, @curl_stub)
    File.chmod!(stub, 0o755)
    log = Path.join(dir, "calls.log")
    stdin_log = Path.join(dir, "stdin.log")
    File.write!(log, "")
    File.write!(stdin_log, "")

    actor = Keyword.get(opts, :actor, "seeder-svc")

    env =
      [
        {"PATH", dir <> path_sep() <> System.get_env("PATH")},
        {"STUB_LOG", log},
        {"STUB_STDIN_LOG", stdin_log},
        {"STUB_COUNTER", Path.join(dir, "counter")},
        {"STUB_OWNER_STATUS", Keyword.get(opts, :owner_status, "200")},
        {"STUB_IMPORT_RESPONSE", Keyword.get(opts, :import_response, @ok_import)},
        {"STUB_SHIPMENT_IMPORT_RESPONSE",
         Keyword.get(
           opts,
           :shipment_import_response,
           Keyword.get(opts, :import_response, @ok_import)
         )},
        {"STUB_FUZZY", Keyword.get(opts, :fuzzy, "0")},
        {"QA_AUTH_TOKEN", "t"},
        {"QA_URL", "http://stub"},
        {"TMPDIR", dir}
      ] ++ if(actor, do: [{"SEED_ACTOR_USERNAME", actor}], else: [])

    {out, status} = System.cmd(bash(), [@script], env: env, stderr_to_stdout: true)
    %{out: out, status: status, calls: File.read!(log), stdin: File.read!(stdin_log)}
  end

  test "SEED_ACTOR_USERNAME is required: the script refuses before any call" do
    result = run_seed(actor: nil)
    assert result.status != 0
    assert result.out =~ "SEED_ACTOR_USERNAME is not set"
    assert result.calls == ""
  end

  test "a persona account is refused as the seeder" do
    result = run_seed(actor: "actor-vortex-anna")
    assert result.status != 0
    assert result.out =~ "DEDICATED account"
    refute result.calls =~ "restrictions/import"
  end

  test "Karl is refused as the seeder too" do
    result = run_seed(actor: "actor-vortex-karl")
    assert result.status != 0
    assert result.out =~ "DEDICATED account"
    refute result.calls =~ "restrictions/import"
  end

  test "the username is matched exactly: a fuzzy search hit is never used" do
    result = run_seed(fuzzy: "1")
    assert result.status == 0, result.out
    [payload | _] = String.split(result.stdin, "\n", trim: true)
    assert payload =~ "id-seeder-svc"
    refute payload =~ "decoy-"

    refuted = run_seed(fuzzy: "2")
    assert refuted.status != 0
    assert refuted.out =~ "not found (exact username match)"
    refute refuted.calls =~ "restrictions/import"
  end

  test "the seeding account is granted the restricted field and the restricted type" do
    result = run_seed([])
    assert result.status == 0, result.out
    [payload | _imports] = String.split(result.stdin, "\n", trim: true)
    decoded = Jason.decode!(payload)

    assert %{"user_id" => "id-seeder-svc", "entity_type" => "production_batch"} =
             Enum.find(decoded["field_grants"], &(&1["user_id"] == "id-seeder-svc"))

    assert decoded["type_grants"] == [
             %{"user_id" => "id-seeder-svc", "entity_type" => "shipment_manifest"}
           ]

    # the persona grants are unchanged: Anna keeps hers, Karl has none
    assert Enum.any?(decoded["field_grants"], &(&1["user_id"] == "id-actor-vortex-anna"))
    refute payload =~ "id-actor-vortex-karl"

    # the token-owner probe is a GET of the restricted type's definition, after the two step-1 checks
    by_name = "GET http://stub/api/v1/entities/definitions/by-name/shipment_manifest"
    assert result.calls |> String.split("\n") |> Enum.count(&(&1 == by_name)) == 2

    assert result.calls =~ "POST http://stub/api/v1/entities/records/production_batch/import"
    assert result.calls =~ "POST http://stub/api/v1/entities/records/shipment_manifest/import"
  end

  test "a token that does not belong to the seeding account stops before any record import" do
    result = run_seed(owner_status: "404")
    assert result.status != 0
    assert result.out =~ "does not belong to SEED_ACTOR_USERNAME"

    refute result.calls =~ "records/production_batch/import"
    refute result.calls =~ "records/shipment_manifest/import"
  end

  test "a refused entry in the SECOND entity's import fails the script" do
    result = run_seed(shipment_import_response: @refused_import)
    assert result.status != 0
    assert result.out =~ "shipment_manifest entry"
    assert result.calls =~ "records/production_batch/import"
  end

  test "a non-JSON import response fails the script" do
    result = run_seed(import_response: "<html>gateway</html>")
    assert result.status != 0
  end

  test "any status error entry of an import response fails the script" do
    result = run_seed(import_response: @refused_import)
    assert result.status != 0
    assert result.out =~ "were refused"
    assert result.out =~ "field_restricted"
  end
end
