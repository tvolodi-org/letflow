defmodule Letflow.Scripts.QoimeksQa2FixtureCountTest do
  @moduledoc """
  T-2357: `scripts/qoimeks_qa2_fixture_count.sh` creates QOI-EMP-2, the lot-tracked item UAT-LOT-0001 and
  its lot LOT-A on tenant qoimeks-qa2 only, and a second run creates nothing. The script talks HTTP
  through `curl`; the test puts a fake `curl` first on PATH that keeps a tiny state in a directory and
  logs every call, so no server runs (no model, no network).
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/qoimeks_qa2_fixture_count.sh", __DIR__)

  @fake_curl ~S"""
  #!/usr/bin/env bash
  # fake curl: state files <type>.json under $FAKE_STATE; last argument is the URL.
  url="${@: -1}"
  body=""
  for a in "$@"; do [ "$a" = "--data-binary" ] && body=$(cat); done
  echo "$url" >> "$FAKE_STATE/calls.log"
  case "$url" in
    */me/access)
      echo '{"permissions":["EntitiesQuery","OrgEmployeesWrite","EntitiesRecordsImport","CatalogLotsWrite"]}' ;;
    */entities/query)
      type=$(echo "$body" | jq -r .entity_type)
      f="$FAKE_STATE/$type.json"; [ -f "$f" ] || echo '[]' > "$f"
      jq -c '{items: ., next_cursor: null}' "$f" ;;
    */modules/org/employees)
      echo "$url POST" >> "$FAKE_STATE/writes.log"
      f="$FAKE_STATE/org_employee.json"
      echo "$body" | jq -c '{record_id: "emp-2", field_values: {code, org_unit_id, full_name}}' > "$FAKE_STATE/new.json"
      jq -c --slurpfile n "$FAKE_STATE/new.json" '. + $n' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      echo '{"record_id":"emp-2"}' ;;
    */entities/records/catalog_item/import*)
      echo "import item" >> "$FAKE_STATE/writes.log"
      f="$FAKE_STATE/catalog_item.json"; [ -f "$f" ] || echo '[]' > "$f"
      echo "$body" | jq -c '.records[0] | {record_id: "item-1", field_values: .field_values}' > "$FAKE_STATE/new.json"
      jq -c --slurpfile n "$FAKE_STATE/new.json" '. + $n' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      echo '{"results":[{"outcome":"created"}]}' ;;
    */modules/catalog_items/lots)
      echo "create lot" >> "$FAKE_STATE/writes.log"
      f="$FAKE_STATE/catalog_lot.json"; [ -f "$f" ] || echo '[]' > "$f"
      echo "$body" | jq -c '{record_id: "lot-1", field_values: {code, item_id}}' > "$FAKE_STATE/new.json"
      jq -c --slurpfile n "$FAKE_STATE/new.json" '. + $n' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      echo '{"record_id":"lot-1"}' ;;
    *) echo "unexpected url $url" >&2; exit 22 ;;
  esac
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "t2357_#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    state = Path.join(dir, "state")
    File.mkdir_p!(bin)
    File.mkdir_p!(state)
    on_exit(fn -> File.rm_rf!(dir) end)

    curl = Path.join(bin, "curl")
    File.write!(curl, @fake_curl)
    File.chmod!(curl, 0o755)

    File.write!(
      Path.join(state, "org_employee.json"),
      ~s([{"record_id":"emp-1","field_values":{"code":"QOI-EMP-1","org_unit_id":"unit-1"}}])
    )

    File.write!(
      Path.join(state, "catalog_uom.json"),
      ~s([{"record_id":"uom-1","field_values":{"code":"pcs","external_ref_system":"erp","external_ref_id":"U-PCS"}}])
    )

    {:ok, bin: bin, state: state}
  end

  defp run(ctx, env \\ []) do
    base = [
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
      {"FAKE_STATE", ctx.state},
      {"QA_AUTH_TOKEN", "test-token"}
    ]

    System.cmd("bash", [@script], env: base ++ env, stderr_to_stdout: true)
  end

  defp state(ctx, type),
    do: ctx.state |> Path.join("#{type}.json") |> File.read!() |> Jason.decode!()

  defp writes(ctx) do
    case File.read(Path.join(ctx.state, "writes.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  test "creates the employee, the lot-tracked item and its lot; a second run creates nothing",
       ctx do
    {out, 0} = run(ctx)
    assert out =~ "created: employee QOI-EMP-2"
    assert out =~ "created: item UAT-LOT-0001"
    assert out =~ "created: lot LOT-A"
    assert length(writes(ctx)) == 3

    [_, emp2] = state(ctx, "org_employee")
    assert emp2["field_values"]["code"] == "QOI-EMP-2"
    assert emp2["field_values"]["org_unit_id"] == "unit-1"

    [item] = state(ctx, "catalog_item")
    assert item["field_values"]["tracking_policy"] == "lot"
    assert item["field_values"]["base_uom_id"] == "U-PCS"

    [lot] = state(ctx, "catalog_lot")
    assert lot["field_values"] == %{"code" => "LOT-A", "item_id" => "item-1"}

    {out2, 0} = run(ctx)
    assert out2 =~ "exists:  employee QOI-EMP-2"
    assert out2 =~ "exists:  item UAT-LOT-0001"
    assert out2 =~ "exists:  lot LOT-A"
    assert out2 =~ "0 record(s) created"
    assert length(writes(ctx)) == 3
  end

  test "refuses qoimeks-qa, qoimeks-client1-qa and any other slug before any call", ctx do
    for slug <- ["qoimeks-qa", "qoimeks-client1-qa", "qoimeks-qa22", "other"] do
      {out, code} = run(ctx, [{"TENANT_SLUG", slug}])
      assert code == 2, out
      assert out =~ "refusing tenant"
    end

    refute File.exists?(Path.join(ctx.state, "calls.log"))
  end

  test "refuses a QA_URL that is not the qoimeks-qa2 host", ctx do
    for url <- [
          "https://qoimeks-qa.letflow.qa.bizdala.com",
          "https://qoimeks-client1-qa.letflow.qa.bizdala.com",
          "https://qoimeks-qa2.evil.example@other.example"
        ] do
      {out, code} = run(ctx, [{"QA_URL", url}])
      assert code == 2, out
      assert out =~ "refusing QA_URL"
    end

    refute File.exists?(Path.join(ctx.state, "calls.log"))
  end
end
