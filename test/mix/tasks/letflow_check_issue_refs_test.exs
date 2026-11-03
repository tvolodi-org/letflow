defmodule Mix.Tasks.Letflow.CheckIssueRefsTest do
  @moduledoc """
  Covers `mix letflow.check_issue_refs`, which enforces ISSUE_QUEUE.md's
  "Numbering schema": three registries number independently from 1, so every
  cross-reference carries its registry's prefix.

  Two halves, matching the sibling registration/staleness checks' own shape:

    * **Rule tests** drive `audit/2` with fixture content, one rule at a time,
      including the two-sided "offender fails / bystander passes" pairing that
      `web/tests/guards/meta-control.spec.ts` uses — a detector that never
      fires and a detector that always fires are equally useless.

    * **T-LIVE-\\*** run the real `docs/issues/` corpus, so the suite fails if
      the tree itself drifts. That is the half that would have caught the
      superseded `ISS-NNNN == queue id` rule decaying to 172/305, which
      nothing re-checked for three weeks.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Mix.Tasks.Letflow.CheckIssueRefs

  defp audit(content, path \\ "docs/issues/ISS-0042.yaml"),
    do: CheckIssueRefs.audit(content, path)

  defp valid_head, do: "id: ISS-0042\ntitle: something\n"

  describe "R1 -- bare numbers are rejected" do
    test "a bare github number is a violation, and the message names the fix" do
      [v] = audit(valid_head() <> "github_ref: 89\n")

      assert v.rule == :R1
      assert v.message =~ "GH-89"
      assert v.message =~ "ambiguous"
    end

    test "a bare queue number is a violation" do
      [v] = audit(valid_head() <> "queue_ref: 76\n")

      assert v.rule == :R1
      assert v.message =~ "Q-76"
    end

    test "BYSTANDER -- correctly prefixed refs produce nothing" do
      assert audit(valid_head() <> "queue_ref: Q-76\ngithub_ref: GH-89\n") == []
    end
  end

  describe "R2 -- superseded field names are rejected" do
    test "each old name is caught and mapped to its replacement" do
      for {old, new} <- [
            {"github_issue", "github_ref"},
            {"github_issue_number", "github_ref"},
            {"queue_task_id", "queue_ref"}
          ] do
        [v] = audit(valid_head() <> "#{old}: 12\n")

        assert v.rule == :R2, "#{old} should be R2"
        assert v.message =~ new
      end
    end

    test "BYSTANDER -- `github_issue_note` is commentary, not identity" do
      # Matched exactly rather than by prefix: 52 files carry this prose field
      # and none of them is a cross-reference.
      assert audit(valid_head() <> "github_issue_note: >\n  filed by hand\n") == []
    end
  end

  describe "R3 -- malformed values" do
    test "a full GitHub URL is not a ref -- this was 139 files' shape before normalisation" do
      [v] = audit(valid_head() <> "github_ref: https://github.com/tvolodi/letflow/issues/1\n")

      assert v.rule == :R3
      assert v.message =~ "URL is not a ref"
    end

    test "a wrong-registry prefix is rejected" do
      assert [%{rule: :R3}] = audit(valid_head() <> "github_ref: Q-89\n")
      assert [%{rule: :R3}] = audit(valid_head() <> "queue_ref: GH-76\n")
    end

    test "leading zeros are rejected -- GH-0089 and GH-89 must not both be writable" do
      assert [%{rule: :R3}] = audit(valid_head() <> "github_ref: GH-0089\n")
    end
  end

  describe "R4 -- null is legitimate but must be explained" do
    test "a bare null is a violation" do
      [v] = audit(valid_head() <> "queue_ref: null\n")

      assert v.rule == :R4
      assert v.message =~ "deliberate absence"
    end

    test "BYSTANDER -- an explained null passes" do
      assert audit(valid_head() <> "queue_ref: null   # filed directly via gh\n") == []
    end
  end

  describe "R5 -- id must match the filename" do
    test "a placeholder id is caught" do
      [v] = audit("id: PENDING\n", "docs/issues/ISS-REQ201-A.yaml")

      assert v.rule == :R5
      assert v.message =~ "invisible to every registry"
    end

    test "a mismatched id is caught" do
      [v] = audit("id: ISS-0043\n", "docs/issues/ISS-0042.yaml")

      assert v.rule == :R5
      assert v.message =~ "does not match filename"
    end

    test "BYSTANDER -- a matching id passes" do
      assert audit("id: ISS-0042\n", "docs/issues/ISS-0042.yaml") == []
    end
  end

  describe "parsing model" do
    test "indented refs inside a description block are prose, not identity fields" do
      # ISS-0285 and ISS-0448 quote historical `queue_task_id: 128` inside their
      # own description text. Reading those as fields would make a file fail for
      # correctly describing the past.
      content = """
      id: ISS-0042
      description: >
        The sibling registered against the same queue task,
        queue_task_id: 128, which is why the lock collided.
        github_issue: 89 was the mirror.
      """

      assert audit(content) == []
    end

    test "a trailing comment does not corrupt the value" do
      assert audit(valid_head() <> "github_ref: GH-89   # opened by ORCH\n") == []
    end
  end

  describe "T-LIVE-* -- the real docs/issues/ corpus" do
    setup do
      files = CheckIssueRefs.issue_files("docs/issues")

      {:ok,
       files: files, violations: Enum.flat_map(files, &CheckIssueRefs.audit(File.read!(&1), &1))}
    end

    test "T-LIVE-CLEAN -- the tree itself satisfies every rule", %{violations: violations} do
      assert violations == [],
             "docs/issues/ has drifted from the numbering schema:\n" <>
               Enum.map_join(violations, "\n", &"  [#{&1.rule}] #{&1.path}: #{&1.message}")
    end

    test "T-LIVE-NOT-VACUOUS -- the corpus is large enough for the rules to bite",
         %{files: files} do
      # A green run over an empty or tiny directory would prove nothing. 305
      # files carrying 297 GH-refs and 199 Q-refs were normalised on
      # 2026-09-09; this asserts the corpus is still substantial, not an exact
      # count, which would fail on every new issue.
      assert length(files) > 250
    end

    test "T-LIVE-NO-SUPERSEDED-NAMES -- the normalisation is not silently reverted",
         %{files: files} do
      offenders =
        for path <- files,
            line <- String.split(File.read!(path), ~r/\r?\n/),
            Regex.match?(~r/^(github_issue|github_issue_number|queue_task_id):/, line),
            do: path

      assert offenders == [],
             "superseded field names reappeared in: #{inspect(Enum.uniq(offenders))}"
    end
  end
end
