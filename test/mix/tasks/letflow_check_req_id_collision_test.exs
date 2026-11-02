defmodule Mix.Tasks.Letflow.CheckReqIdCollisionTest do
  @moduledoc """
  Regression coverage for ISS-0613 -- `mix letflow.check_req_id_collision`
  (`lib/mix/tasks/letflow.check_req_id_collision.ex`).

  Design: `lib/letflow/design/iss0613-req-id-collision-check.md`.

  ## Two groups

  The pure-core group (`parse_ids/1`, `normalize/1`, `detect_collisions/3`,
  `render_failure/1`) is hermetic and `async: true` -- no filesystem, no git.

  The task-level group exercises `run/1` end-to-end against **real,
  disposable git repositories** built per test under `System.tmp_dir!/0`:
  a bare "origin" repo plus a "work" clone that plays the role of this
  branch's checkout, with an optional second "other" clone that plays the
  role of a sibling session pushing a colliding id straight to `origin/main`
  first. This mirrors `letflow.lint_handoffs_test.exs`'s own precedent of
  exercising git-shelling logic against real repository state rather than a
  mocked `System.cmd/3`. `async: false`: `run/1` reads
  `docs/requirements.yaml` via a relative path with no path seam, so each
  test changes the OS process's working directory for its duration
  (`File.cd!/2`), which is not safe under `async: true`.

  ## The five scenarios (design section 3.2 / this task's brief)

    * T-NO-NEW-IDS -- no new REQ- id added by this branch: passes.
    * T-NEW-ID-FREE -- a new REQ- id added, absent from origin/main: passes.
    * T-COLLISION -- a new REQ- id added that ALSO exists on origin/main with
      different content: hard failure, message names the id and both entries.
    * T-REPUSH -- a new REQ- id added that exists on origin/main with
      IDENTICAL (normalized) content: passes (legitimate re-push, not a
      collision).
    * T-ORIGIN-UNRESOLVABLE -- `origin/main` cannot be resolved locally
      (never fetched): skips with a warning, exits 0, never raises.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Mix.Tasks.Letflow.CheckReqIdCollision, as: Check

  # ==========================================================================
  # Pure core (hermetic, no filesystem/git)
  # ==========================================================================

  @stages_section """
  stages:
    - id: S0
      name: Bootstrap
  """

  defp doc(body), do: @stages_section <> "requirements:\n" <> body

  defp req(id, fields) do
    Enum.join(["  - id: " <> id | Enum.map(fields, &("    " <> &1))], "\n") <> "\n"
  end

  describe "parse_ids/1 (hermetic)" do
    test "F-PARSE-BASIC -- extracts id, line, and full entry text" do
      content = doc(req("REQ-001", ["stage: S0", "title: Alpha"]))
      ids = Check.parse_ids(content)

      assert Map.has_key?(ids, "REQ-001")
      entry = ids["REQ-001"]
      assert entry.text =~ "- id: REQ-001"
      assert entry.text =~ "title: Alpha"
      assert is_integer(entry.line)
    end

    test "F-PARSE-NO-KEY -- a file with no top-level requirements: key parses to an empty map" do
      assert Check.parse_ids(@stages_section) == %{}
    end

    test "F-PARSE-MALFORMED-ID -- a non-well-formed id is skipped, not crashed on" do
      content = doc(req("REQ-001", ["stage: S0"]) <> req("REQ_BAD", ["stage: S1"]))
      ids = Check.parse_ids(content)

      assert Map.has_key?(ids, "REQ-001")
      refute Map.has_key?(ids, "REQ_BAD")
    end

    test "F-PARSE-BLOCK-NOTE -- 2-space prose between entries belongs to neither" do
      content =
        doc(
          req("REQ-001", ["stage: S0", "title: Alpha"]) <>
            "\n  # NOTE: some prose mentioning REQ-999 that is not an entry\n\n" <>
            req("REQ-002", ["stage: S0", "title: Beta"])
        )

      ids = Check.parse_ids(content)
      assert Map.keys(ids) |> Enum.sort() == ["REQ-001", "REQ-002"]
      refute ids["REQ-001"].text =~ "NOTE"
      refute ids["REQ-002"].text =~ "NOTE"
    end

    test "F-PARSE-DUP-KEEPS-LAST -- duplicate ids collapse to one map entry (map semantics)" do
      content =
        doc(
          req("REQ-001", ["stage: S0", "title: First"]) <>
            req("REQ-001", ["stage: S1", "title: Second"])
        )

      ids = Check.parse_ids(content)
      assert ids["REQ-001"].text =~ "Second"
    end
  end

  describe "normalize/1 (hermetic)" do
    test "F-NORMALIZE-CRLF -- CRLF and LF variants of the same text normalize equal" do
      lf = "  - id: REQ-001\n    title: Alpha\n"
      crlf = String.replace(lf, "\n", "\r\n")
      assert Check.normalize(lf) == Check.normalize(crlf)
    end

    test "F-NORMALIZE-TRAILING-WS -- trailing whitespace differences normalize equal" do
      a = "  - id: REQ-001\n    title: Alpha  \n"
      b = "  - id: REQ-001\n    title: Alpha\n"
      assert Check.normalize(a) == Check.normalize(b)
    end

    test "F-NORMALIZE-REAL-DIFF -- an actual content difference stays different" do
      a = Check.normalize("  - id: REQ-001\n    title: Alpha\n")
      b = Check.normalize("  - id: REQ-001\n    title: Beta\n")
      refute a == b
    end
  end

  describe "detect_collisions/3 (hermetic)" do
    defp entry(text, line \\ 1), do: %{line: line, text: text}

    test "F-DETECT-NO-NEW -- an id present in merge_base is never a candidate, whatever origin holds" do
      current = %{"REQ-001" => entry("- id: REQ-001\n    title: Alpha")}
      merge_base = %{"REQ-001" => entry("- id: REQ-001\n    title: Alpha")}
      origin = %{"REQ-001" => entry("- id: REQ-001\n    title: DIFFERENT")}

      assert Check.detect_collisions(current, merge_base, origin) == []
    end

    test "F-DETECT-NEW-FREE -- a new id absent from origin is not a collision" do
      current = %{"REQ-100" => entry("- id: REQ-100\n    title: New")}
      merge_base = %{}
      origin = %{}

      assert Check.detect_collisions(current, merge_base, origin) == []
    end

    test "F-DETECT-COLLISION -- a new id present in origin with different content is a collision" do
      current = %{"REQ-100" => entry("- id: REQ-100\n    title: Mine", 10)}
      merge_base = %{}
      origin = %{"REQ-100" => entry("- id: REQ-100\n    title: Theirs", 20)}

      assert [collision] = Check.detect_collisions(current, merge_base, origin)
      assert collision.id == "REQ-100"
      assert collision.branch_entry.line == 10
      assert collision.main_entry.line == 20
    end

    test "F-DETECT-REPUSH -- a new id present in origin with IDENTICAL (normalized) content is not a collision" do
      current = %{"REQ-100" => entry("- id: REQ-100\n    title: Same  \n")}
      merge_base = %{}
      origin = %{"REQ-100" => entry("- id: REQ-100\r\n    title: Same\r\n")}

      assert Check.detect_collisions(current, merge_base, origin) == []
    end

    test "F-DETECT-MULTIPLE -- multiple genuine collisions are all reported, sorted by id" do
      current = %{
        "REQ-200" => entry("- id: REQ-200\n    title: MineB"),
        "REQ-100" => entry("- id: REQ-100\n    title: MineA")
      }

      merge_base = %{}

      origin = %{
        "REQ-200" => entry("- id: REQ-200\n    title: TheirsB"),
        "REQ-100" => entry("- id: REQ-100\n    title: TheirsA")
      }

      collisions = Check.detect_collisions(current, merge_base, origin)
      assert Enum.map(collisions, & &1.id) == ["REQ-100", "REQ-200"]
    end
  end

  describe "render_failure/1 (hermetic)" do
    test "F-RENDER -- names the id, both branches, both entry texts, and a footer count" do
      collisions = [
        %{
          id: "REQ-312",
          branch_entry: %{line: 42, text: "  - id: REQ-312\n    title: Mine"},
          main_entry: %{line: 7, text: "  - id: REQ-312\n    title: Theirs"}
        }
      ]

      msg = Check.render_failure(collisions)

      assert msg =~ "REQ-ID COLLISION DETECTED"
      assert msg =~ "REQ-312 is defined both on this branch and on origin/main"
      assert msg =~ "line 42"
      assert msg =~ "line 7"
      assert msg =~ "title: Mine"
      assert msg =~ "title: Theirs"
      assert msg =~ "1 collision(s) found"
      assert msg =~ "mix letflow.check_req_id_collision"
    end

    test "F-RENDER-MULTI -- more than one collision reports every id, one footer count" do
      collisions = [
        %{
          id: "REQ-100",
          branch_entry: %{line: 1, text: "- id: REQ-100"},
          main_entry: %{line: 2, text: "- id: REQ-100"}
        },
        %{
          id: "REQ-200",
          branch_entry: %{line: 3, text: "- id: REQ-200"},
          main_entry: %{line: 4, text: "- id: REQ-200"}
        }
      ]

      msg = Check.render_failure(collisions)
      assert msg =~ "REQ-100"
      assert msg =~ "REQ-200"
      assert msg =~ "2 collision(s) found"
    end
  end
end

defmodule Mix.Tasks.Letflow.CheckReqIdCollisionTaskTest do
  @moduledoc """
  Task-level (T-*) coverage: `run/1` end-to-end against real, disposable git
  repositories. `async: false` -- see the moduledoc of the sibling hermetic
  suite above for why.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Mix.Tasks.Letflow.CheckReqIdCollision, as: Check

  @base_content """
  requirements:
    - id: REQ-001
      stage: S0
      title: Initial requirement
  """

  # -- git fixture helpers --------------------------------------------------

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> flunk("git #{Enum.join(args, " ")} in #{dir} exited #{status}:\n#{out}")
    end
  end

  defp fresh_dir do
    dir = Path.join(System.tmp_dir!(), "letflow-reqcol-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp configure_identity!(dir) do
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test User"])
    # Never sign test commits, regardless of the ambient environment's
    # global gpg/commit.gpgsign config.
    git!(dir, ["config", "commit.gpgsign", "false"])
  end

  defp write_requirements!(dir, content) do
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/requirements.yaml"), content)
  end

  defp commit!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-m", message])
  end

  # Builds an origin bare repo plus a "work" clone with one initial commit
  # (containing @base_content) already pushed to origin/main. Returns
  # {base_tmp_dir, origin_path, work_path}. `work`'s HEAD and origin/main are
  # identical at this point -- the common merge-base every scenario builds on.
  defp init_diverged_pair do
    base = fresh_dir()
    origin = Path.join(base, "origin.git")
    work = Path.join(base, "work")

    File.mkdir_p!(origin)
    git!(origin, ["init", "--bare", "-b", "main"])

    File.mkdir_p!(work)
    git!(work, ["init", "-b", "main"])
    configure_identity!(work)
    git!(work, ["remote", "add", "origin", origin])

    write_requirements!(work, @base_content)
    commit!(work, "initial")
    git!(work, ["push", "-u", "origin", "main"])

    {base, origin, work}
  end

  # Simulates a sibling session: clones `origin`, applies `content_fun` to
  # its own docs/requirements.yaml, commits, and pushes straight to
  # origin/main -- i.e. lands ahead of `work` without `work` having seen it
  # yet until `work` explicitly fetches.
  defp push_from_other_clone!(base, origin, content_fun) do
    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(base, ["clone", origin, other])
    configure_identity!(other)

    current = File.read!(Path.join(other, "docs/requirements.yaml"))
    write_requirements!(other, content_fun.(current))
    commit!(other, "other session's push")
    git!(other, ["push", "origin", "main"])
  end

  defp run_in(work, fun) do
    File.cd!(work, fun)
  end

  # ==========================================================================
  # Scenarios
  # ==========================================================================

  describe "T-NO-NEW-IDS -- no new REQ- id added by this branch" do
    test "passes" do
      {_base, _origin, work} = init_diverged_pair()

      # A local, uncommitted, non-id-affecting edit -- still the same ids.
      write_requirements!(work, @base_content <> "# a trailing comment, no new id\n")

      {result, out} =
        run_in(work, fn -> with_io(fn -> Check.run([]) end) end)

      assert result == :ok
      assert out =~ "OK -- no REQ-NNN id collision"
    end
  end

  describe "T-NEW-ID-FREE -- a new REQ- id added, absent from origin/main" do
    test "passes" do
      {_base, _origin, work} = init_diverged_pair()

      write_requirements!(
        work,
        @base_content <>
          "  - id: REQ-100\n    stage: S1\n    title: Newly invented, nobody else has it\n"
      )

      {result, out} =
        run_in(work, fn -> with_io(fn -> Check.run([]) end) end)

      assert result == :ok
      assert out =~ "OK -- no REQ-NNN id collision"
    end
  end

  describe "T-COLLISION -- a new REQ- id also exists on origin/main with different content" do
    test "raises, naming the id and both branches" do
      {base, origin, work} = init_diverged_pair()

      push_from_other_clone!(base, origin, fn current ->
        current <> "  - id: REQ-100\n    stage: S1\n    title: Theirs -- landed on main first\n"
      end)

      git!(work, ["fetch", "origin"])

      write_requirements!(
        work,
        @base_content <>
          "  - id: REQ-100\n    stage: S1\n    title: Mine -- independently invented\n"
      )

      {error, out} =
        run_in(work, fn ->
          with_io(fn -> assert_raise Mix.Error, fn -> Check.run([]) end end)
        end)

      message = Exception.message(error)
      assert message =~ "REQ-ID COLLISION DETECTED"
      assert message =~ "REQ-100"
      assert message =~ "Mine -- independently invented"
      assert message =~ "Theirs -- landed on main first"
      assert message =~ "1 collision(s) found"
      refute out =~ "OK -- no REQ-NNN id collision"
    end
  end

  describe "T-REPUSH -- a new REQ- id exists on origin/main with IDENTICAL content" do
    test "passes (legitimate re-push, not a collision)" do
      {base, origin, work} = init_diverged_pair()

      new_entry = "  - id: REQ-100\n    stage: S1\n    title: Same content both places\n"

      push_from_other_clone!(base, origin, fn current -> current <> new_entry end)
      git!(work, ["fetch", "origin"])

      write_requirements!(work, @base_content <> new_entry)

      {result, out} =
        run_in(work, fn -> with_io(fn -> Check.run([]) end) end)

      assert result == :ok
      assert out =~ "OK -- no REQ-NNN id collision"
    end

    test "passes even with CRLF/trailing-whitespace-only differences" do
      {base, origin, work} = init_diverged_pair()

      origin_entry = "  - id: REQ-100\n    stage: S1\n    title: Same content\n"

      branch_entry =
        String.replace(origin_entry, "\n", "\r\n") |> String.replace("content", "content  ")

      push_from_other_clone!(base, origin, fn current -> current <> origin_entry end)
      git!(work, ["fetch", "origin"])

      write_requirements!(work, @base_content <> branch_entry)

      {result, _out} =
        run_in(work, fn -> with_io(fn -> Check.run([]) end) end)

      assert result == :ok
    end
  end

  describe "T-ORIGIN-UNRESOLVABLE -- origin/main cannot be resolved locally" do
    test "skips with a warning and exits 0, never raises" do
      dir = fresh_dir()
      git!(dir, ["init", "-b", "main"])
      configure_identity!(dir)
      write_requirements!(dir, @base_content)
      commit!(dir, "initial, no remote at all")

      {result, out} =
        run_in(dir, fn -> with_io(fn -> Check.run([]) end) end)

      assert result == :ok
      assert out =~ "SKIPPED"
      assert out =~ "origin/main not resolvable locally"
      refute out =~ "COLLISION DETECTED"
    end

    test "skips even with an origin remote configured but never fetched" do
      dir = fresh_dir()
      other_bare = Path.join(dir, "unfetched_origin.git")
      File.mkdir_p!(other_bare)
      git!(other_bare, ["init", "--bare", "-b", "main"])

      work = Path.join(dir, "work")
      File.mkdir_p!(work)
      git!(work, ["init", "-b", "main"])
      configure_identity!(work)
      git!(work, ["remote", "add", "origin", other_bare])
      write_requirements!(work, @base_content)
      commit!(work, "initial, remote configured but never fetched")

      {result, out} =
        run_in(work, fn -> with_io(fn -> Check.run([]) end) end)

      assert result == :ok
      assert out =~ "SKIPPED"
    end
  end
end
