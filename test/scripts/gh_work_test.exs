defmodule Letflow.Scripts.GhWorkTest do
  @moduledoc """
  ISS-1073 / GH #2430: `scripts/gh_work.sh` against a stub `gh` (no network).

  The stub serves `issues`, `pulls` and `comments` pages from fixture files, so
  these tests prove, hermetically:

    * pagination -- 250 open issues (three pages, 100 + 100 + 50) are all read,
      and an issue that exists only on page 3 shows up in `ready`;
    * `ready` ordering and exclusions (claimed, blocked by an open `Depends on:`,
      pull requests returned by the issues API, not `state:ready`);
    * `claims` / `stale` (linked open PR, idle hours, threshold);
    * `graph` (edges, closed-or-absent targets, cycles);
    * `check` fails on a `claimed:<checkout>` label with no supervisor/user claim
      comment for that checkout, and passes on a clean board.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../scripts", __DIR__) |> Path.join("gh_work" <> ".sh")

  # 2026-10-14T12:00:00Z
  @now 1_792_670_400

  @stub """
  #!/usr/bin/env bash
  # Stub gh: `gh api ENDPOINT` serves fixture pages from $GH_STUB_DIR.
  [ "$1" = "api" ] || { echo "stub gh: unsupported: $*" >&2; exit 1; }
  ep="$2"
  d="$GH_STUB_DIR"
  echo "$ep" >> "$d/calls.log"
  f=""
  case "$ep" in
    repos/*/issues/*/comments*)
      n="${ep#repos/*/issues/}"; n="${n%%/*}"; page="${ep##*page=}"
      f="$d/comments.$n.$page.json" ;;
    repos/*/issues\\?*) f="$d/issues.${ep##*page=}.json" ;;
    repos/*/pulls\\?*) f="$d/pulls.${ep##*page=}.json" ;;
  esac
  if [ -n "$f" ] && [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
  """

  defp iso(seconds_ago),
    do: (@now - seconds_ago) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp issue(n, labels, opts \\ []) do
    base = %{
      "number" => n,
      "title" => "issue #{n}",
      "body" => Keyword.get(opts, :body, ""),
      "updated_at" => iso(Keyword.get(opts, :idle_h, 1) * 3600),
      "labels" => Enum.map(labels, &%{"name" => &1})
    }

    if opts[:pull_request], do: Map.put(base, "pull_request", %{"url" => "x"}), else: base
  end

  defp write_pages!(dir, prefix, items) do
    items
    |> Enum.chunk_every(100)
    |> Enum.with_index(1)
    |> Enum.each(fn {chunk, page} ->
      File.write!(Path.join(dir, "#{prefix}.#{page}.json"), Jason.encode!(chunk))
    end)
  end

  defp setup_board(issues, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "gh-work-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    stub = Path.join(dir, "stub-gh")
    File.write!(stub, @stub)
    File.chmod!(stub, 0o755)

    write_pages!(dir, "issues", issues)
    write_pages!(dir, "pulls", Keyword.get(opts, :pulls, []))

    for {n, comments} <- Keyword.get(opts, :comments, []) do
      File.write!(Path.join(dir, "comments.#{n}.1.json"), Jason.encode!(comments))
    end

    {dir, stub}
  end

  defp run(dir, stub, args) do
    System.cmd("bash", [@script | args],
      env: [
        {"GH_BIN", stub},
        {"GH_STUB_DIR", dir},
        {"GH_REPO", "owner/repo"},
        {"GH_WORK_NOW", Integer.to_string(@now)}
      ],
      stderr_to_stdout: true
    )
  end

  # 250 open issues; #1..#9 are the interesting ones, #10..#250 are noise, and
  # the page-3 item #240 is `state:ready` prio:1.
  defp big_board do
    interesting = [
      issue(1, ["state:ready", "prio:2", "type:requirement", "stage:S4"]),
      issue(2, ["state:ready", "prio:1", "type:issue", "lane:board"]),
      issue(3, ["state:ready", "prio:1"], body: "Depends on: #2"),
      issue(4, ["state:ready"], body: "Depends on: #999\r\n"),
      issue(5, ["state:ready", "state:in-progress", "claimed:letflow"]),
      issue(6, ["state:in-progress", "claimed:letflow-2"], idle_h: 10),
      issue(7, ["state:in-progress", "claimed:letflow-3"], idle_h: 10),
      issue(8, ["state:in-progress", "claimed:remote"], idle_h: 1),
      issue(9, ["state:in-progress", "claimed:letflow-9"], idle_h: 1)
    ]

    noise =
      for n <- 10..250 do
        case n do
          240 -> issue(240, ["state:ready", "prio:1", "type:issue"])
          # a pull request returned by the issues API must never be listed
          241 -> issue(241, ["state:ready", "prio:1"], pull_request: true)
          _ -> issue(n, ["state:blocked"])
        end
      end

    interesting ++ noise
  end

  defp big_opts do
    [
      pulls: [
        %{
          "number" => 900,
          "title" => "work for #7",
          "body" => "Refs #7",
          "updated_at" => iso(1800)
        }
      ],
      comments: [
        {6, [%{"body" => "CLAIM letflow-2 by supervisor 2026-10-14T01:00:00Z"}]},
        {7, [%{"body" => "started"}]},
        {8, [%{"body" => "CLAIM letflow by supervisor 2026-10-14T01:00:00Z"}]},
        {5, [%{"body" => "CLAIM letflow by user 2026-10-14T01:00:00Z"}]},
        {9, [%{"body" => "CLAIM letflow-9 by supervisor"}]}
      ]
    ]
  end

  defp numbers(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> String.split("\t") |> hd()))
  end

  test "ready reads every page and orders by prio then number" do
    {dir, stub} = setup_board(big_board(), big_opts())
    {out, 0} = run(dir, stub, ["ready"])

    # #240 exists only on page 3 -> proves pagination beyond 100 issues.
    assert numbers(out) == ["#2", "#240", "#1", "#4"]
    refute out =~ "#241", "pull requests are not board items"
    refute out =~ "#3\t", "#3 depends on open #2"
    refute out =~ "#5\t", "#5 is claimed"

    calls = File.read!(Path.join(dir, "calls.log"))
    assert calls =~ "issues?state=open&per_page=100&page=3"
    assert Regex.scan(~r/issues\?state=open/, calls) |> length() == 3
  end

  test "ready --for filters to next:<checkout> and rejects an unknown checkout" do
    issues = [
      issue(1, ["state:ready", "next:letflow-2"]),
      issue(2, ["state:ready", "next:remote"]),
      issue(3, ["state:ready"])
    ]

    {dir, stub} = setup_board(issues)
    {out, 0} = run(dir, stub, ["ready", "--for", "letflow-2"])
    assert numbers(out) == ["#1"]

    {out, status} = run(dir, stub, ["ready", "--for", "alice"])
    assert status == 2
    assert out =~ "--for must be one of"
  end

  test "claims lists in-progress and claimed issues with linked PRs and idle hours" do
    {dir, stub} = setup_board(big_board(), big_opts())
    {out, 0} = run(dir, stub, ["claims"])

    assert numbers(out) == ["#5", "#6", "#7", "#8", "#9"]
    assert out =~ ~r/#7\tletflow-3\tin-progress\t#900\t0\t/
    assert out =~ ~r/#6\tletflow-2\tin-progress\t-\t10\t/
  end

  test "stale lists idle claims without an open PR, honours --hours" do
    {dir, stub} = setup_board(big_board(), big_opts())

    {out, 0} = run(dir, stub, ["stale"])
    # #6: idle 10h, no PR. #7 has a fresh PR. #8/#9 idle 1h.
    assert numbers(out) == ["#6"]

    {out, 0} = run(dir, stub, ["stale", "--hours", "1"])
    assert numbers(out) == ["#5", "#6", "#8", "#9"]
  end

  test "graph prints edges, closed-or-absent targets and cycles" do
    issues = [
      issue(10, ["state:ready"], body: "Depends on: #11, #999"),
      issue(11, ["state:ready"]),
      issue(20, ["state:blocked"], body: "depends on: #21"),
      issue(21, ["state:blocked"], body: "Depends on: #20")
    ]

    {dir, stub} = setup_board(issues)
    {out, 0} = run(dir, stub, ["graph"])

    assert out =~ "#10 depends on #11  [open]"
    assert out =~ "#10 depends on #999  [closed-or-absent]"
    assert out =~ "CYCLE among: #20 #21"

    {dir, stub} = setup_board([issue(1, ["state:ready"]), issue(2, [], body: "Depends on: #1")])
    {out, 0} = run(dir, stub, ["graph"])
    assert out =~ "no cycles"
  end

  test "check fails on claim labels the supervisor/user did not set" do
    {dir, stub} = setup_board(big_board(), big_opts())
    {out, status} = run(dir, stub, ["check"])

    assert status == 1
    # #7: claimed label, no CLAIM comment at all (a worker labelled itself)
    assert out =~ "#7: claimed:letflow-3 has no 'CLAIM letflow-3 by supervisor|user' comment"
    # #8: label says remote, the latest claim comment names letflow
    assert out =~ "#8: claimed:remote but the latest claim comment names letflow"
    # #9: letflow-9 is not a checkout
    assert out =~ "#9: claimed:letflow-9 is not a checkout"
    # #5: state:ready + state:in-progress is two state labels
    assert out =~ "#5: more than one state: label"
    # a properly recorded claim is not reported
    refute out =~ "#6:"
    assert out =~ "FAILED"
  end

  test "check passes on a clean board" do
    issues = [
      issue(1, ["state:ready", "prio:1", "next:letflow-3"]),
      issue(2, ["state:in-progress", "claimed:letflow"])
    ]

    comments = [{2, [%{"body" => "CLAIM letflow by supervisor 2026-10-14T01:00:00Z"}]}]
    {dir, stub} = setup_board(issues, comments: comments)
    {out, 0} = run(dir, stub, ["check"])
    assert out =~ "OK"
  end

  test "the script makes no write calls (the stub only ever sees GET-shaped api paths)" do
    {dir, stub} = setup_board(big_board(), big_opts())
    for cmd <- ["ready", "claims", "stale", "graph", "check"], do: run(dir, stub, [cmd])

    calls = dir |> Path.join("calls.log") |> File.read!() |> String.split("\n", trim: true)
    assert Enum.all?(calls, &String.starts_with?(&1, "repos/owner/repo/"))

    refute File.read!(@script) =~
             ~r/gh\s+(issue|pr)\s+(edit|create|close|comment)|--method|-X\s+(POST|PATCH|PUT|DELETE)/
  end
end
