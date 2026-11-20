defmodule Letflow.Scripts.QoimeksQa2FixtureLedger3Test do
  @moduledoc """
  T-2394 / GH #4918: `scripts/qoimeks_qa2_fixture_ledger3.sh` prepares the changed-posting
  half of Qoimeks ledger-3 on qoimeks-qa2 only. A stateful fake `curl` stands in for the public
  API: the tests inspect the started instance and prove that a repeat and cleanup do not duplicate
  work. No server, network or credentials are used.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/qoimeks_qa2_fixture_ledger3.sh", __DIR__)
  @document_id "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  @genuine_instance "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @extra_instance "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @genuine_task "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @extra_task "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

  @fake_curl ~S"""
  #!/usr/bin/env bash
  set -euo pipefail
  method="GET"
  body=""
  idem=""
  url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -H)
        if [[ "$2" == Idempotency-Key:* ]]; then idem="${2#Idempotency-Key: }"; fi
        shift 2
        ;;
      --data-binary) body=$(cat); shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  printf '%s %s %s\n' "$method" "$url" "$idem" >> "$FAKE_STATE/calls.log"

  param() {
    local key="$1" part
    IFS='&' read -ra parts <<< "${url#*\?}"
    for part in "${parts[@]}"; do
      if [[ "$part" == "$key="* ]]; then printf '%s' "${part#*=}"; return; fi
    done
  }

  case "$url" in
    */me/access)
      echo '{"permissions":["StockRead","TasksRead","InstancesRead","InstancesStart","InstancesCancel"]}'
      ;;
    */modules/stock/documents/*)
      cat "$FAKE_STATE/document.json"
      ;;
    */instances?correlation_key=*)
      key=$(param correlation_key)
      jq -c --arg key "$key" '{items: [.instances[] | select(.correlation_key == $key) | {instance_id, correlation_key, status}], next_cursor: null}' "$FAKE_STATE/state.json"
      ;;
    */instances/*/cancel)
      [[ "$method" == "POST" ]]
      echo "$idem" > "$FAKE_STATE/cancel_idempotency.txt"
      id=$(basename "$(dirname "$url")")
      jq --arg id "$id" '(.instances[] | select(.instance_id == $id) | .status) = "CANCELLED" | (.tasks[] | select(.instance_id == $id) | .status) = "CANCELLED"' "$FAKE_STATE/state.json" > "$FAKE_STATE/state.tmp"
      mv "$FAKE_STATE/state.tmp" "$FAKE_STATE/state.json"
      jq -c --arg id "$id" '{instance_id: $id, status: "CANCELLED"}' "$FAKE_STATE/state.json"
      ;;
    */instances/*)
      id="${url##*/}"
      jq -c --arg id "$id" '.instances[] | select(.instance_id == $id)' "$FAKE_STATE/state.json"
      ;;
    */tasks?*)
      status=$(param status)
      instance=$(param instance_id)
      cursor=$(param cursor)
      if [[ "$cursor" == "next" ]]; then
        echo '{"items":[],"next_cursor":null}'
      else
        jq -c --arg status "$status" --arg instance "$instance" '{items: [.tasks[] | select(($status == "" or .status == $status) and ($instance == "" or .instance_id == $instance))], next_cursor: null}' "$FAKE_STATE/state.json"
      fi
      ;;
    */instances)
      [[ "$method" == "POST" ]]
      echo "$body" | jq -c . > "$FAKE_STATE/start_body.json"
      echo "$idem" > "$FAKE_STATE/start_idempotency.txt"
      key=$(echo "$body" | jq -r .correlation_key)
      jq -c --arg id "$EXTRA_INSTANCE" --arg task "$EXTRA_TASK" --arg key "$key" --argjson vars "$(echo "$body" | jq -c .initial_variables)" '.instances += [{instance_id: $id, correlation_key: $key, status: "ACTIVE", variables: $vars}] | .tasks += [{id: $task, instance_id: $id, node_id: "post", status: "PENDING"}]' "$FAKE_STATE/state.json" > "$FAKE_STATE/state.tmp"
      mv "$FAKE_STATE/state.tmp" "$FAKE_STATE/state.json"
      jq -c -n --arg id "$EXTRA_INSTANCE" '{instance_id: $id, status: "ACTIVE", created_at: "2026-11-20T00:00:00Z"}'
      ;;
    *) echo "unexpected $method $url" >&2; exit 22 ;;
  esac
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "t2394_#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    state_dir = Path.join(dir, "state")
    File.mkdir_p!(bin)
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    curl = Path.join(bin, "curl")
    File.write!(curl, @fake_curl)
    File.chmod!(curl, 0o755)

    File.write!(Path.join(state_dir, "document.json"), """
    {"id":"#{@document_id}","kind":"receipt","state":"issued"}
    """)

    variables = %{
      "document_id" => @document_id,
      "document_type" => "stock_receipt",
      "version_no" => 1,
      "org_unit_id" => "unit-1",
      "mark" => "posted",
      "posting" => %{
        "document_id" => @document_id,
        "document_type" => "stock_receipt",
        "cause" => "receipt",
        "client_op_id" => "version-1",
        "lines" => [%{"sku" => "item-1", "quantity" => "2"}]
      }
    }

    File.write!(Path.join(state_dir, "state.json"), """
    {"instances":[{"instance_id":"#{@genuine_instance}","correlation_key":null,"status":"ACTIVE","variables":#{Jason.encode!(variables)}}],"tasks":[{"id":"#{@genuine_task}","instance_id":"#{@genuine_instance}","node_id":"post","status":"PENDING"}]}
    """)

    {:ok,
     bin: bin,
     state_dir: state_dir,
     env: [
       {"PATH", bin <> ":" <> System.get_env("PATH")},
       {"FAKE_STATE", state_dir},
       {"EXTRA_INSTANCE", @extra_instance},
       {"EXTRA_TASK", @extra_task},
       {"QA_AUTH_TOKEN", "test-token"}
     ]}
  end

  defp run(ctx, args \\ [@document_id], env \\ []) do
    System.cmd("bash", [@script | args], env: ctx.env ++ env, stderr_to_stdout: true)
  end

  defp state(ctx), do: ctx.state_dir |> Path.join("state.json") |> File.read!() |> Jason.decode!()

  defp calls(ctx) do
    case File.read(Path.join(ctx.state_dir, "calls.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  test "starts one changed posting, repeats the same manifest, and cleanup is idempotent", ctx do
    {out, 0} = run(ctx)
    assert out =~ "created: changed posting fixture"
    assert out =~ "instance_id=#{@extra_instance}"
    assert out =~ "task_id=#{@extra_task}"
    assert out =~ "document_id=#{@document_id}"
    refute out =~ "test-token"

    start_body = ctx.state_dir |> Path.join("start_body.json") |> File.read!() |> Jason.decode!()
    assert start_body["definition_name"] == "stock_receipt"
    assert start_body["correlation_key"] == "uat-ledger3-#{@document_id}"

    assert start_body["initial_variables"]["posting"]["lines"] |> hd() |> Map.fetch!("quantity") ==
             "3"

    assert start_body["initial_variables"]["org_unit_id"] == "unit-1"

    assert String.trim(File.read!(Path.join(ctx.state_dir, "start_idempotency.txt"))) ==
             "uat-ledger3-#{@document_id}"

    {out2, 0} = run(ctx)
    assert out2 =~ "exists: changed posting fixture"

    for line <- [
          "instance_id=#{@extra_instance}",
          "task_id=#{@extra_task}",
          "document_id=#{@document_id}"
        ] do
      assert out2 =~ line
    end

    assert length(Enum.filter(calls(ctx), &String.starts_with?(&1, "POST "))) == 1

    {cleaned, 0} = run(ctx, ["--cleanup", @extra_instance])
    assert cleaned =~ "cancelled: instance_id=#{@extra_instance}"

    assert String.trim(File.read!(Path.join(ctx.state_dir, "cancel_idempotency.txt"))) ==
             "uat-ledger3-cleanup-#{@extra_instance}"

    extra = state(ctx)["instances"] |> Enum.find(&(&1["instance_id"] == @extra_instance))
    assert extra["status"] == "CANCELLED"

    assert state(ctx)["tasks"] |> Enum.find(&(&1["id"] == @extra_task)) |> Map.fetch!("status") ==
             "CANCELLED"

    {cleaned_again, 0} = run(ctx, ["--cleanup", @extra_instance])
    assert cleaned_again =~ "already cancelled: instance_id=#{@extra_instance}"
    assert length(Enum.filter(calls(ctx), &(&1 =~ "/cancel"))) == 1
    refute Enum.any?(calls(ctx), &(&1 =~ "/documents/" and String.starts_with?(&1, "POST ")))
  end

  test "cleanup refuses an instance outside the fixture correlation namespace", ctx do
    path = Path.join(ctx.state_dir, "state.json")

    other = %{
      "instance_id" => @extra_instance,
      "correlation_key" => "some-other-run",
      "status" => "ACTIVE",
      "variables" => %{"document_id" => @document_id}
    }

    File.write!(
      path,
      ctx |> state() |> Map.update!("instances", &(&1 ++ [other])) |> Jason.encode!()
    )

    {out, code} = run(ctx, ["--cleanup", @extra_instance])
    assert code == 1
    assert out =~ "not a qoimeks ledger-3 fixture instance"
    refute Enum.any?(calls(ctx), &(&1 =~ "/cancel"))
  end

  test "refuses qoimeks-qa, qoimeks-client1-qa and every other slug before any API call", ctx do
    for slug <- ["qoimeks-qa", "qoimeks-client1-qa", "qoimeks-qa22", "other"] do
      {out, code} = run(ctx, [@document_id], [{"TENANT_SLUG", slug}])
      assert code == 2, out
      assert out =~ "refusing tenant"
    end

    assert calls(ctx) == []
  end

  test "refuses a QA_URL that is not the qoimeks-qa2 host before any API call", ctx do
    for url <- [
          "https://qoimeks-qa.letflow.qa.bizdala.com",
          "https://qoimeks-client1-qa.letflow.qa.bizdala.com",
          "https://qoimeks-qa2.evil.example@other.example"
        ] do
      {out, code} = run(ctx, [@document_id], [{"QA_URL", url}])
      assert code == 2, out
      assert out =~ "refusing QA_URL"
    end

    assert calls(ctx) == []
  end
end
