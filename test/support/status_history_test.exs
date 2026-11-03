defmodule Letflow.Test.StatusHistoryTest do
  @moduledoc """
  ISS-0883 regression test — unit-level coverage of `Letflow.Test.StatusHistory.entries/1`
  against a hermetic, synthetic fixture reproducing PR #1972's real failure shape.

  Specified by `lib/letflow/design/iss0883-status-index-indent-check.md` ("Worked
  example (concrete, using PR #1972's actual shape)").

  Why this file exists separately from `test/docs/requirement_status_invariants_test.exs`'s
  A9/A11 blocks: A9 and A11 only ever run against the real on-disk
  `docs/status/requirement_status.*.yaml` files, which are (and should stay) well-formed.
  Nothing in the suite before this file demonstrated that the ISS-0883 fix actually
  *catches* malformed input — only that well-formed input still parses correctly. This
  file writes a throwaway fixture, at PR #1972's exact 0-indent shape, directly at
  `entries/1`, so the fix's two claims are both exercised for real:

    1. A 0-indent `- req:` entry is still COUNTED (the false-green/miscounting half of
       the bug — pre-fix, `~r/^  - (...)/` requires an exact 2-space prefix and simply
       never matches a 0-indent line, so `entries/1` would return `[]` for this fixture:
       confirmed by reading the pre-fix regex in the ISS-0883 design doc's "Root cause"
       section, quoted again at the `pre_fix_item_regex/0` doctest-style comment below
       — no revert-and-rerun needed, the anchor makes the non-match provable by
       inspection).
    2. The entry's recorded `indent` is `0`, not `2`, and A11's own one-line predicate
       (`indent != 2`) — reused verbatim, not reimplemented — flags it as a violation.

  Nothing here touches `docs/status/` or any real volume/index file.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Test.StatusHistory, as: SH

  # The pre-fix item regex, quoted verbatim from the ISS-0883 design doc's "Root cause"
  # section (`lib/letflow/design/iss0883-status-index-indent-check.md`, "Current behavior"
  # under "Part 1"). Kept here, uncalled by `entries/1` (which is fixed), purely so the
  # "the old regex does not match this fixture" claim is checked by a real `Regex.run/2`
  # call in this test run rather than asserted from memory.
  @pre_fix_item_regex ~r/^  - ([a-z][a-z0-9_]*): ?(.*)$/

  # PR #1972's exact malformed shape (design doc "Worked example"): item line at
  # 0-space indent, its fields at 2-space (i.e. shifted uniformly by -2 from the
  # documented 2-space item / 4-space field convention). One conforming, 2-space entry
  # is included alongside it so the fixture also proves the malformed entry doesn't
  # disturb correct parsing of its neighbor.
  @fixture_body """
  # Letflow — Requirement run history — VOLUME 99 (fixture, unwritten to disk elsewhere)
  #
  # APPEND ONE ENTRY PER EVENT. NEVER REWRITE, REORDER, EDIT OR DELETE A PAST ENTRY.
  #
  # ENTRY SCHEMA. Five fields, in this order, one entry per `- req:` list item:
  #   - req: <REQ-NNN | SCOPE-CHANGE>
  #     event: <started | done | blocked | cancelled | revised | verified>
  #     agent: <AGENT_ID that generated this entry>
  #     at: <real UTC timestamp from the clock, ISO-8601>
  #     note: >
  #       <short free-text>
  #
  # ROLL RULE: closure once lines > 1200 OR bytes > 120000.
  history:
    - req: REQ-001
      event: started
      agent: TEST-DESIGNER
      at: "2026-09-29T00:00:00Z"
      note: fixture entry, correctly indented
  - req: REQ-422
    event: done
    agent: ELIXIR-DEV
    at: "2026-09-29T00:00:00Z"
    note: fixture entry reproducing PR #1972's 0-indent malformed shape
  """

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "iss0883-entries-fixture-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, @fixture_body)
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, path: path}
  end

  test "pre-fix regex would not have matched PR #1972's 0-indent line (confirms fail-first)",
       %{path: _path} do
    zero_indent_line = "  - req: REQ-422" |> String.replace_leading("  ", "")

    assert zero_indent_line == "- req: REQ-422"

    assert Regex.run(@pre_fix_item_regex, zero_indent_line) == nil,
           "the pre-fix item regex #{inspect(@pre_fix_item_regex)} is hard-anchored to " <>
             "exactly 2 leading spaces; PR #1972's 0-indent line must NOT match it -- " <>
             "if it does, this fixture no longer reproduces the bug's shape"

    # And, for contrast, the pre-fix regex DOES match the fixture's correctly-indented
    # sibling entry -- proving the non-match above is about indent, not the line's
    # content or this regex being broken outright.
    assert Regex.run(@pre_fix_item_regex, "  - req: REQ-001") != nil
  end

  test "entries/1 counts the 0-indent entry (false-green/miscounting half of ISS-0883 fixed)",
       %{path: path} do
    entries = SH.entries(path)

    reqs = Enum.map(entries, & &1.req)

    assert reqs == ["REQ-001", "REQ-422"], """
    entries/1 must count BOTH entries in the fixture -- the correctly-indented REQ-001
    and the 0-indent REQ-422 reproducing PR #1972's shape. Pre-fix, entries/1's item
    regex would have returned only REQ-001 (silently dropping REQ-422), which is the
    exact false-green mechanism ISS-0883 fixes: a malformed append vanishing from the
    on-disk count instead of being caught as a mismatch by A9.

    Got: #{inspect(reqs)}
    """
  end

  test "entries/1 records indent: 0 for the malformed entry, and 2 for the conforming one",
       %{path: path} do
    entries = SH.entries(path)

    by_req = Map.new(entries, &{&1.req, &1})

    assert by_req["REQ-001"].indent == 2

    assert by_req["REQ-422"].indent == 0, """
    REQ-422's `- req:` line in the fixture is written with ZERO leading spaces
    (PR #1972's exact malformed shape). entries/1 must record its true on-disk indent,
    not default or normalise it -- design iss0883-status-index-indent-check.md is
    explicit that no `Map.get(raw, :indent, 2)`-style fallback is acceptable, since
    that would silently hide precisely this case.
    """
  end

  test "REQ-422's fields (event/agent/at/note) still attach correctly despite the 0-indent item line",
       %{path: path} do
    entries = SH.entries(path)
    entry = Enum.find(entries, &(&1.req == "REQ-422"))

    # Fields in this fixture sit at 2-space indent -- exactly current.indent (0) + 2 --
    # so the relative field-acceptance rule (design doc, "Field regex") must attach
    # them to this entry, not drop them as unrecognized.
    assert entry.event == "done"
    assert entry.agent == "ELIXIR-DEV"
    assert entry.at == "2026-09-29T00:00:00Z"
    assert entry.fields == [:req, :event, :agent, :at, :note]
  end

  test "A11's own indent-violation predicate (indent != 2), reused verbatim, flags only the malformed entry",
       %{path: path} do
    entries = SH.entries(path)

    # This is exactly A11's own filter in
    # test/docs/requirement_status_invariants_test.exs ("Enum.filter(&(&1.indent != 2))") --
    # reused here rather than reimplemented, per this test's own header comment.
    violations =
      entries
      |> Enum.filter(&(&1.indent != 2))
      |> Enum.map(&{&1.line, &1.indent, &1.req})

    assert violations == [{20, 0, "REQ-422"}], """
    A11's predicate must flag exactly one violation -- REQ-422 at indent 0 -- and must
    NOT flag REQ-001, which is correctly indented at 2 spaces.

    Got: #{inspect(violations)}
    """
  end
end
