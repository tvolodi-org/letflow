defmodule Letflow.Scripts.SeedEntitiesLargePagesTest do
  @moduledoc """
  GH #3078: `existing_keys_for` and `import_records_if_missing` in
  `scripts/seed_vortex_entities.sh` passed each query page and the accumulated keys to jq as
  `--argjson` argv values, which fails with "Argument list too long" once a tenant holds a few
  hundred records with full field_values. The JSON now goes to jq on stdin.

  Runs the script's own two functions (extracted verbatim) against a stateful stub `curl`
  holding more than 200 records whose query pages are well above 32 KB; no network, no DB.
  """
  use ExUnit.Case, async: true

  @script "scripts/seed_vortex_entities.sh"
  @meridian "scripts/seed_meridian_entities.sh"

  @total 250
  @preexisting 230

  # Stub store: $STUB_DIR/store.json is a JSON array of records. A query answers a page of 200
  # from the numeric cursor; an import appends the posted records and logs "IMPORT <n>".
  @curl_stub ~S"""
  #!/usr/bin/env bash
  method=GET; url=""; body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      --data-binary) body=$(cat); shift 2 ;;
      -H|-o|-w|-d) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  case "$method $url" in
    "POST "*"/entities/query")
      off=$(printf '%s' "$body" | jq -r '.cursor // 0')
      echo "QUERY $off" >> "$STUB_LOG"
      jq -c --argjson off "$off" '
        {items: .[$off:($off + 200)],
         next_cursor: (if length > ($off + 200) then ($off + 200) else null end)}' "$STUB_DIR/store.json" ;;
    "POST "*"/import")
      n=$(printf '%s' "$body" | jq '.records | length')
      echo "IMPORT $n" >> "$STUB_LOG"
      printf "%s" "$body" > "$STUB_DIR/body.json"
      jq -s ".[0] + .[1].records" "$STUB_DIR/store.json" "$STUB_DIR/body.json" > "$STUB_DIR/store.next"
      mv "$STUB_DIR/store.next" "$STUB_DIR/store.json"
      printf '{"results":[]}' ;;
  esac
  """

  defp bash, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")
  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")
  defp available?, do: bash() != nil and System.find_executable("jq") != nil

  defp record(i) do
    %{
      "field_values" => %{
        "batch_ref" => "B-#{String.pad_leading(Integer.to_string(i), 5, "0")}",
        "notes" => String.duplicate("x", 1000)
      }
    }
  end

  defp setup_dir do
    dir = Path.join(System.tmp_dir!(), "gh3078-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    stub = Path.join(dir, "curl")
    File.write!(stub, @curl_stub)
    File.chmod!(stub, 0o755)

    all = Enum.map(1..@total, &record/1)
    File.write!(Path.join(dir, "fixture.json"), Jason.encode!(%{"records" => all}))
    File.write!(Path.join(dir, "store.json"), Jason.encode!(Enum.take(all, @preexisting)))
    File.write!(Path.join(dir, "calls.log"), "")
    dir
  end

  defp run_import_twice(dir) do
    src = File.read!(@script)
    [_, from_fn] = String.split(src, "existing_keys_for() {", parts: 2)

    [funcs, _] =
      String.split(from_fn, ~s(\nimport_records_if_missing "production_batch"), parts: 2)

    harness = """
    set -euo pipefail
    AUTH_HEADER="Authorization: Bearer t"; API="http://stub/api/v1"; REPO_ROOT="#{dir}"
    existing_keys_for() {#{funcs}
    import_records_if_missing "production_batch" "batch_ref" "fixture.json"
    import_records_if_missing "production_batch" "batch_ref" "fixture.json"
    """

    harness_file = Path.join(dir, "harness.sh")
    File.write!(harness_file, harness)

    System.cmd(bash(), [harness_file],
      env: [
        {"PATH", dir <> path_sep() <> System.get_env("PATH")},
        {"STUB_DIR", dir},
        {"STUB_LOG", Path.join(dir, "calls.log")},
        {"TMPDIR", dir}
      ],
      stderr_to_stdout: true
    )
  end

  test "query pages far above 32 KB: the seed finishes, imports only the missing rows, and a re-run posts nothing" do
    if available?() do
      dir = setup_dir()
      assert byte_size(File.read!(Path.join(dir, "store.json"))) > 200_000

      {out, status} = run_import_twice(dir)
      assert status == 0, out
      refute out =~ "Argument list too long"

      assert out =~ "#{@total - @preexisting} of #{@total} production_batch record(s) are new."
      assert out =~ ~r/^  0 of #{@total} production_batch record\(s\) are new\./m

      calls = File.read!(Path.join(dir, "calls.log"))
      # exactly one import across both runs: the second run found every key already present
      assert calls |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "IMPORT")) ==
               ["IMPORT #{@total - @preexisting}"]

      keys =
        dir
        |> Path.join("store.json")
        |> File.read!()
        |> Jason.decode!()
        |> Enum.map(& &1["field_values"]["batch_ref"])

      assert length(keys) == @total
      assert length(Enum.uniq(keys)) == @total
    end
  end

  test "no seed script hands a query page, the accumulated keys or the existing keys to jq as argv" do
    for script <- [@script, @meridian] do
      src = File.read!(script)

      refute src =~ ~r/--argjson\s+(acc|page|existing)\b/,
             "#{script} passes growing JSON to jq via --argjson"

      refute src =~ ~r/--argjson\s+\w+\s+"\$\{(resp|keys|existing_keys)\}"/
    end
  end
end
