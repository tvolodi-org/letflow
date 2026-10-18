defmodule Letflow.Modules.Exam.SnapshotLiveOptionsTest do
  @moduledoc """
  GH #2762 -- `Snapshot.live_options/3`, the ONE shared function that decides which answer-option
  rows count, with an explicit mode (design `lib/letflow/design/gh2762-exam-soft-deleted-reads.md`
  section 5; spec `test/specs/GH-2762.md`, tests T-62k1 .. T-62k4).

  The function is pure over rows exposing `deleted` and `field_values`, so these tests build both
  row shapes the compiler can return (`Latest` structs and plain maps of a promoted table) by hand.
  The end-to-end behaviour on real Postgres rows is in `session_test.exs` (start path) and
  `snapshot_late_test.exs` (late path and parity).
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.Snapshot

  @qid "11111111-1111-4111-8111-111111111111"

  # A compiler row. `shape` selects the `Latest` struct or a plain map (promoted per-type table).
  defp row(id, deleted, field_values, shape \\ :latest)

  defp row(id, deleted, field_values, :latest),
    do: %Latest{record_id: id, deleted: deleted, field_values: field_values}

  defp row(id, deleted, field_values, :map),
    do: %{record_id: id, deleted: deleted, field_values: field_values}

  defp correct(id, deleted, shape \\ :latest),
    do: row(id, deleted, %{"is_correct" => true}, shape)

  defp wrong(id, deleted, shape \\ :latest), do: row(id, deleted, %{"is_correct" => false}, shape)

  defp weighted(id, deleted),
    do: row(id, deleted, %{"is_correct" => false, "likert_weight" => 2.0})

  defp unweighted(id, deleted),
    do: row(id, deleted, %{"is_correct" => false, "likert_weight" => nil})

  defp ids(rows), do: Enum.map(rows, & &1.record_id)

  defp q(type), do: %{type: type, question_id: @qid}
  defp refusal, do: {:error, {:grading_error, {:key_missing, @qid}}}

  # An atom no clause matches, built at runtime so the compiler cannot see it as a literal.
  defp unknown_mode, do: List.first([:sideways])

  describe "T-62k1 live_options/3 mode :start" do
    for type <- ~w(single multiple truefalse), shape <- [:latest, :map] do
      test "#{type} (#{shape}): deleted rows are excluded, refusal iff no live correct option" do
        type = unquote(type)
        shape = unquote(shape)

        # all live: unchanged
        assert {:ok, rows} =
                 Snapshot.live_options(
                   [correct("a", false, shape), wrong("b", false, shape)],
                   q(type),
                   :start
                 )

        assert ids(rows) == ["a", "b"]

        # a deleted INCORRECT option is dropped
        assert {:ok, rows} =
                 Snapshot.live_options(
                   [correct("a", false, shape), wrong("b", true, shape)],
                   q(type),
                   :start
                 )

        assert ids(rows) == ["a"]

        # SWAP: old correct deleted, new correct live -> only the new key remains; input order kept
        assert {:ok, rows} =
                 Snapshot.live_options(
                   [
                     correct("old", true, shape),
                     wrong("w", false, shape),
                     correct("new", false, shape)
                   ],
                   q(type),
                   :start
                 )

        assert ids(rows) == ["w", "new"]
        assert Enum.all?(rows, &(&1.deleted == false))

        # deleted correct, only incorrect live -> refused
        assert Snapshot.live_options(
                 [correct("old", true, shape), wrong("w", false, shape)],
                 q(type),
                 :start
               ) ==
                 refusal()

        # every option deleted, and no options at all -> refused
        assert Snapshot.live_options(
                 [correct("old", true, shape), wrong("w", true, shape)],
                 q(type),
                 :start
               ) ==
                 refusal()

        assert Snapshot.live_options([], q(type), :start) == refusal()
      end
    end

    test "multiple: one of two correct options swapped keeps the other and the new one" do
      assert {:ok, rows} =
               Snapshot.live_options(
                 [
                   correct("c1", true),
                   correct("c2", false),
                   wrong("w", false),
                   correct("c3", false)
                 ],
                 q("multiple"),
                 :start
               )

      assert ids(rows) == ["c2", "w", "c3"]
    end

    test "likert: refusal iff the live set is empty; a live option with a nil weight is NOT refused here" do
      assert {:ok, rows} =
               Snapshot.live_options(
                 [weighted("a", false), weighted("b", true)],
                 q("likert"),
                 :start
               )

      assert ids(rows) == ["a"]

      # the live-set typed signal mirrors build_likert/3's empty check only; the nil weight is
      # still refused later by build_from_resolved/4 (covered end to end in session_test.exs).
      assert {:ok, rows} =
               Snapshot.live_options([unweighted("a", false)], q("likert"), :start)

      assert ids(rows) == ["a"]

      assert Snapshot.live_options(
               [weighted("a", true), weighted("b", true)],
               q("likert"),
               :start
             ) ==
               refusal()

      assert Snapshot.live_options([], q("likert"), :start) == refusal()
    end

    test "shorttext and unknown types are never refused: deleted rows are dropped, empty is fine" do
      for type <- ["shorttext", "bogus", nil] do
        assert Snapshot.live_options([], q(type), :start) == {:ok, []}

        assert {:ok, rows} =
                 Snapshot.live_options([correct("a", true), wrong("b", false)], q(type), :start)

        assert ids(rows) == ["b"]
      end
    end
  end

  describe "T-62k2 live_options/3 mode :late (the #2734 rule, unchanged)" do
    for type <- ~w(single multiple truefalse), shape <- [:latest, :map] do
      test "#{type} (#{shape}): a deleted correct option refuses, a deleted incorrect one is dropped" do
        type = unquote(type)
        shape = unquote(shape)

        assert {:ok, rows} =
                 Snapshot.live_options(
                   [correct("a", false, shape), wrong("b", true, shape)],
                   q(type),
                   :late
                 )

        assert ids(rows) == ["a"]

        # refuses even though another correct option stays live (never a smaller correct set)
        assert Snapshot.live_options(
                 [
                   correct("old", true, shape),
                   correct("other", false, shape),
                   wrong("w", false, shape)
                 ],
                 q(type),
                 :late
               ) == refusal()

        # all live: unchanged; empty input is not refused by the late rule (check_key does that later)
        assert {:ok, rows} =
                 Snapshot.live_options(
                   [correct("a", false, shape), wrong("b", false, shape)],
                   q(type),
                   :late
                 )

        assert ids(rows) == ["a", "b"]
        assert Snapshot.live_options([], q(type), :late) == {:ok, []}
      end
    end

    test "likert: a deleted weighted option or a deleted is_correct option refuses; a deleted unweighted one is dropped" do
      assert Snapshot.live_options(
               [weighted("a", false), weighted("b", true)],
               q("likert"),
               :late
             ) ==
               refusal()

      assert Snapshot.live_options(
               [
                 weighted("a", false),
                 row("b", true, %{"likert_weight" => nil, "is_correct" => true})
               ],
               q("likert"),
               :late
             ) == refusal()

      assert {:ok, rows} =
               Snapshot.live_options(
                 [weighted("a", false), unweighted("b", true)],
                 q("likert"),
                 :late
               )

      assert ids(rows) == ["a"]
    end

    test "shorttext and unknown types are exempt: a deleted is_correct option is dropped, not refused" do
      for type <- ["shorttext", "bogus", nil] do
        assert {:ok, rows} =
                 Snapshot.live_options([correct("a", true), wrong("b", false)], q(type), :late)

        assert ids(rows) == ["b"]
      end
    end
  end

  describe "T-62k3 the two modes diverge exactly where the design says" do
    test "single: deleted correct + live new correct -> :start accepts, :late refuses" do
      rows = [correct("old", true), wrong("w", false), correct("new", false)]

      assert {:ok, live} = Snapshot.live_options(rows, q("single"), :start)
      assert ids(live) == ["w", "new"]
      assert Snapshot.live_options(rows, q("single"), :late) == refusal()
    end

    test "single: deleted correct and NO live correct -> both modes refuse with the same value" do
      rows = [correct("old", true), wrong("w", false)]

      assert Snapshot.live_options(rows, q("single"), :start) == refusal()
      assert Snapshot.live_options(rows, q("single"), :late) == refusal()
    end

    test "single: only a deleted incorrect option -> both modes return the same live rows" do
      rows = [correct("a", false), wrong("b", true)]

      assert Snapshot.live_options(rows, q("single"), :start) ==
               Snapshot.live_options(rows, q("single"), :late)
    end

    test "likert: the late rule refuses a deleted weighted option that the start rule accepts" do
      rows = [weighted("a", false), weighted("b", true)]

      assert {:ok, [%{record_id: "a"}]} = Snapshot.live_options(rows, q("likert"), :start)
      assert Snapshot.live_options(rows, q("likert"), :late) == refusal()
    end
  end

  describe "T-62k4 unknown mode" do
    test "a mode other than :start / :late is a FunctionClauseError (no catch-all)" do
      assert_raise FunctionClauseError, fn ->
        Snapshot.live_options([correct("a", false)], q("single"), unknown_mode())
      end
    end
  end
end
