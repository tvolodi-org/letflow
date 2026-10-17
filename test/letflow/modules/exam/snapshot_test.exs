defmodule Letflow.Modules.Exam.SnapshotTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 4,
  7 and 17.2 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`): `Letflow.Modules.Exam.Snapshot`,
  the pure builders and readers (T-15, T-16, T-17, T-18, T-41, T-54, T-55) plus the one real
  jsonb round trip (T-41). Runs against the real Postgres through `Letflow.DataCase` only for the
  round trip; every other test is a direct call of a pure function.

  A snapshot with a missing `exam` object is forged here with `ExamFixtures.with_digest/1`
  because the production builder refuses to produce one.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Letflow.ExamFixtures
  alias Letflow.Modules.Exam.Snapshot

  @exam_id "11111111-1111-4111-8111-111111111111"
  @q1 "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
  @q2 "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
  @o1 "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"
  @o2 "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
  @o3 "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3"

  @taken_at ~U[2026-10-17 10:00:00.000000Z]

  defp exam_fv(threshold) do
    %{
      "passing_score_pct" => threshold,
      "certificate_enabled" => true,
      "title" => %{"en" => "Title"},
      "time_limit_minutes" => 30
    }
  end

  defp info, do: %{origin: :start, exam_id: @exam_id, taken_at: @taken_at}

  defp opt(id, attrs \\ []) do
    Map.merge(
      %{id: id, is_correct: false, likert_weight: nil, likert_polarity: nil},
      Map.new(attrs)
    )
  end

  defp single(correct_ids, wrong_ids) do
    %{
      type: "single",
      options: Enum.map(correct_ids, &opt(&1, is_correct: true)) ++ Enum.map(wrong_ids, &opt/1)
    }
  end

  defp build(items, order, threshold \\ 60) do
    Snapshot.build_from_resolved(exam_fv(threshold), items, order, info())
  end

  defp build!(items, order) do
    assert {:ok, snapshot} = build(items, order)
    snapshot
  end

  # What a Postgres jsonb column hands back: the snapshot encoded and decoded again.
  defp roundtrip(snapshot), do: snapshot |> Jason.encode!() |> Jason.decode!()

  defp row(snapshot), do: %{"exam_snapshot" => snapshot}

  defp grading(reason), do: {:error, {:grading_error, reason}}

  defp likert_options(weights_and_polarities) do
    weights_and_polarities
    |> Enum.with_index()
    |> Enum.map(fn {{weight, polarity}, index} ->
      opt("cccccccc-cccc-4ccc-8ccc-cccccccccc0#{index}",
        likert_weight: weight,
        likert_polarity: polarity
      )
    end)
  end

  # ── T-41 / 4.1: the stored shape ────────────────────────────────────────────────────────────

  describe "build_from_resolved/4: the stored shape (design 4.1)" do
    test "a start snapshot carries v, origin, taken_at, a 32-hex nonce, the exam section, order, items and a sha256 digest" do
      snapshot = build!(%{@q1 => single([@o2], [@o1, @o3])}, [@q1])

      assert snapshot["v"] == 1
      assert snapshot["origin"] == "start"
      assert snapshot["taken_at"] == DateTime.to_iso8601(@taken_at)
      assert snapshot["nonce"] =~ ~r/\A[0-9a-f]{32}\z/
      assert snapshot["digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert snapshot["order"] == [@q1]

      assert snapshot["exam"] == %{
               "exam_id" => @exam_id,
               "passing_score_pct" => "60",
               "certificate_enabled" => true,
               "title" => %{"en" => "Title"},
               "time_limit_minutes" => 30
             }

      assert snapshot["questions"] == %{
               @q1 => %{
                 "type" => "single",
                 "correct_option_ids" => [@o2],
                 "likert_options" => %{}
               }
             }
    end

    test "only the CORRECT option ids are stored, sorted; a wrong option id never appears in the encoding" do
      snapshot =
        build!(
          %{
            @q1 => %{
              type: "multiple",
              options: [opt(@o3, is_correct: true), opt(@o1, is_correct: true), opt(@o2)]
            }
          },
          [@q1]
        )

      assert snapshot["questions"][@q1]["correct_option_ids"] == [@o1, @o3]
      refute Snapshot.canonical_encode(snapshot) =~ @o2
    end

    test "is_correct counts only as the literal true (a truthy string is not a correct option)" do
      assert grading({:key_missing, @q1}) ==
               build(
                 %{
                   @q1 => %{
                     type: "single",
                     options: [opt(@o1, is_correct: "true"), opt(@o2, is_correct: 1)]
                   }
                 },
                 [@q1]
               )
    end

    test "two builds of the same input differ in nonce and digest (the nonce is random)" do
      items = %{@q1 => single([@o1], [@o2])}
      first = build!(items, [@q1])
      second = build!(items, [@q1])

      refute first["nonce"] == second["nonce"]
      refute first["digest"] == second["digest"]
    end

    test "only the questions named in order are copied, and a repeated id in order is stored once" do
      items = %{@q1 => single([@o1], [@o2]), @q2 => single([@o3], [@o1])}
      snapshot = build!(items, [@q1, @q1])

      assert Map.keys(snapshot["questions"]) == [@q1]
      assert snapshot["order"] == [@q1, @q1]
    end

    test "the digest verifies after a jsonb-style encode/decode round trip, and the content is unchanged by it" do
      snapshot = build!(%{@q1 => single([@o1], [@o2])}, [@q1])
      decoded = roundtrip(snapshot)

      assert decoded == snapshot
      assert {:ok, ^decoded} = Snapshot.fetch_verified(row(decoded))
    end
  end

  # ── T-54: the number to decimal string rule (17.2) ──────────────────────────────────────────

  describe "T-54: the stored-number rule for the threshold and likert weights" do
    test "the threshold is normalised to a decimal string: 60, 60.0, \"60.00\", Decimal and exponent forms" do
      table = [
        {60, "60"},
        {60.0, "60"},
        {"60.00", "60"},
        {"60", "60"},
        {72.5, "72.5"},
        {"72.50", "72.5"},
        {Decimal.new("72.50"), "72.5"},
        {0, "0"},
        {0.0, "0"},
        {100, "100"},
        {"100.0", "100"},
        {"1e2", "100"}
      ]

      for {input, expected} <- table do
        assert {:ok, snapshot} = build(%{}, [], input)
        assert {input, snapshot["exam"]["passing_score_pct"]} == {input, expected}
      end
    end

    test "a nil threshold is :threshold_missing" do
      assert grading(:threshold_missing) == build(%{}, [], nil)
    end

    test "a non-numeric, partially numeric, non-finite, out-of-range or huge threshold is :threshold_invalid" do
      invalid = [
        "abc",
        "60abc",
        "",
        " ",
        -1,
        101,
        100.01,
        "-0.5",
        "101",
        "NaN",
        "Infinity",
        Decimal.new("NaN"),
        Decimal.new("Infinity"),
        # exponent bomb: bounded BEFORE any rendering
        "1e999999999",
        "1e41",
        true,
        [60],
        %{"v" => 60}
      ]

      for input <- invalid do
        assert {input, build(%{}, [], input)} == {input, grading(:threshold_invalid)}
      end
    end

    test "the exponent bomb is refused quickly and never builds a huge string" do
      {micros, result} = :timer.tc(fn -> build(%{}, [], "1e999999999") end)

      assert result == grading(:threshold_invalid)
      assert micros < 1_000_000
    end

    test "normalize_number/1 is total: any term is {:ok, finite Decimal} or :error, never a raise" do
      for value <- [nil, :atom, %{}, [], {1, 2}, "x", 1.0e308, -1.0e308, "1e-41", "0.0000000001"] do
        result = Snapshot.normalize_number(value)
        assert result == :error or match?({:ok, %Decimal{}}, result)
      end

      assert {:ok, zero} = Snapshot.normalize_number("0.000")
      assert Decimal.eq?(zero, 0)
    end

    test "likert weights are stored as decimal strings: 3.5, 1, \"0.10\" and a Decimal keep a byte-stable form" do
      options =
        likert_options([
          {3.5, "positive"},
          {1, "negative"},
          {"0.10", "positive"},
          {Decimal.new("2.250"), "negative"}
        ])

      assert {:ok, snapshot} = build(%{@q1 => %{type: "likert", options: options}}, [@q1])

      weights =
        snapshot["questions"][@q1]["likert_options"]
        |> Enum.sort()
        |> Enum.map(fn {_id, entry} -> entry["weight"] end)

      assert weights == ["3.5", "1", "0.1", "2.25"]
    end
  end

  # ── T-17 / T-55: the item key rule (7.2, D-2) ───────────────────────────────────────────────

  describe "T-17 key rule" do
    test "single, multiple and truefalse with NO correct option are {:key_missing, id}" do
      for type <- ["single", "multiple", "truefalse"] do
        assert {type, build(%{@q1 => %{type: type, options: [opt(@o1), opt(@o2)]}}, [@q1])} ==
                 {type, grading({:key_missing, @q1})}

        assert {type, build(%{@q1 => %{type: type, options: []}}, [@q1])} ==
                 {type, grading({:key_missing, @q1})}
      end
    end

    test "a question in order with no item is {:question_item_missing, id}" do
      assert grading({:question_item_missing, @q2}) ==
               build(%{@q1 => single([@o1], [@o2])}, [@q1, @q2])
    end

    test "an item that is not a map with a type and an options list is {:key_missing, id}" do
      assert grading({:key_missing, @q1}) == build(%{@q1 => %{type: "single"}}, [@q1])

      assert grading({:key_missing, @q1}) ==
               build(%{@q1 => %{type: "single", options: :none}}, [@q1])
    end

    test "a likert question with a complete map and NO correct option is VALID" do
      options = likert_options([{1, "positive"}, {3, "positive"}, {5, "negative"}])

      assert {:ok, snapshot} = build(%{@q1 => %{type: "likert", options: options}}, [@q1])
      item = snapshot["questions"][@q1]

      assert item["correct_option_ids"] == []
      assert map_size(item["likert_options"]) == 3
    end

    test "a likert question that also has correct-option rows still builds, and keeps the sorted correct ids" do
      options =
        Enum.map(
          likert_options([{1, "positive"}, {2, "positive"}]),
          &Map.put(&1, :is_correct, true)
        )

      assert {:ok, snapshot} = build(%{@q1 => %{type: "likert", options: options}}, [@q1])
      assert length(snapshot["questions"][@q1]["correct_option_ids"]) == 2
    end

    test "a likert question with zero options, or any option lacking a weight or a polarity, or an unparsable weight, is {:key_missing, id}" do
      bad = [
        [],
        likert_options([{1, "positive"}, {nil, "positive"}]),
        likert_options([{1, "positive"}, {2, nil}]),
        likert_options([{1, "positive"}, {"abc", "positive"}]),
        likert_options([{1, "positive"}, {2, "neutral"}]),
        likert_options([{1, "positive"}, {"1e999999999", "negative"}])
      ]

      for options <- bad do
        assert {options, build(%{@q1 => %{type: "likert", options: options}}, [@q1])} ==
                 {options, grading({:key_missing, @q1})}
      end
    end

    test "a shorttext question with no options, or with options and none correct, is VALID" do
      for options <- [[], [opt(@o1), opt(@o2)]] do
        assert {:ok, snapshot} = build(%{@q1 => %{type: "shorttext", options: options}}, [@q1])

        assert snapshot["questions"][@q1] ==
                 %{"type" => "shorttext", "correct_option_ids" => [], "likert_options" => %{}}
      end
    end

    test "a type outside the five is {:question_type_invalid, id} (T-55b)" do
      for type <- ["essay", "SINGLE", "", nil, :single, 7] do
        assert {type,
                build(%{@q1 => %{type: type, options: [opt(@o1, is_correct: true)]}}, [@q1])} ==
                 {type, grading({:question_type_invalid, @q1})}
      end
    end

    test "T-55d: a canonical encoding over 2 MiB is :snapshot_too_large" do
      big = fn question_id ->
        ids = for _ <- 1..20_000, do: Ecto.UUID.generate()
        {question_id, %{type: "multiple", options: Enum.map(ids, &opt(&1, is_correct: true))}}
      end

      qs = Enum.map(["q-a", "q-b", "q-c"], big)

      assert grading(:snapshot_too_large) == build(Map.new(qs), Enum.map(qs, &elem(&1, 0)))
    end
  end

  # ── T-15 / T-16 / T-18: the readers ────────────────────────────────────────────────────────

  describe "fetch_verified/1 and fetch_structural/1" do
    test "a missing or nil exam_snapshot is :snapshot_missing on both" do
      for read <- [&Snapshot.fetch_verified/1, &Snapshot.fetch_structural/1] do
        assert grading(:snapshot_missing) == read.(%{})
        assert grading(:snapshot_missing) == read.(%{"exam_snapshot" => nil})
        assert grading(:snapshot_missing) == read.(%{"status" => "in_progress"})
      end
    end

    test "a non-object, a wrong version, an unknown origin or a missing nonce or digest is :snapshot_corrupt on both" do
      good = roundtrip(build!(%{@q1 => single([@o1], [@o2])}, [@q1]))

      bad = [
        "garbage",
        5,
        [],
        true,
        Map.put(good, "v", 2),
        Map.delete(good, "v"),
        Map.put(good, "origin", "weird"),
        Map.delete(good, "origin"),
        Map.delete(good, "nonce"),
        Map.put(good, "nonce", 5),
        Map.delete(good, "digest"),
        Map.put(good, "exam", "not a map"),
        Map.put(good, "order", %{}),
        Map.put(good, "questions", [])
      ]

      for snapshot <- bad, read <- [&Snapshot.fetch_verified/1, &Snapshot.fetch_structural/1] do
        assert {snapshot, read.(row(snapshot))} == {snapshot, grading(:snapshot_corrupt)}
      end
    end

    test "T-18: a content change that leaves the stored digest alone is :snapshot_corrupt when verified, yet structurally valid" do
      good = roundtrip(build!(%{@q1 => single([@o1], [@o2])}, [@q1]))

      tampered_key = put_in(good, ["questions", @q1, "correct_option_ids"], [@o2])
      tampered_nonce = Map.put(good, "nonce", String.duplicate("0", 32))
      tampered_threshold = put_in(good, ["exam", "passing_score_pct"], "1")
      tampered_order = Map.put(good, "order", [])

      for snapshot <- [tampered_key, tampered_nonce, tampered_threshold, tampered_order] do
        assert grading(:snapshot_corrupt) == Snapshot.fetch_verified(row(snapshot))
        assert {:ok, ^snapshot} = Snapshot.fetch_structural(row(snapshot))
      end
    end

    test "an untouched snapshot verifies" do
      good = roundtrip(build!(%{@q1 => single([@o1], [@o2])}, [@q1]))
      assert {:ok, ^good} = Snapshot.fetch_verified(row(good))
    end

    test "a late or late_certificate origin is structurally accepted as the shared storage contract" do
      for origin <- ["late", "late_certificate"] do
        forged =
          ExamFixtures.with_digest(%{
            "v" => 1,
            "origin" => origin,
            "nonce" => "n",
            "digest" => "x"
          })

        assert {:ok, _} = Snapshot.fetch_verified(row(forged))
      end
    end
  end

  describe "threshold/1" do
    defp forged(exam),
      do:
        ExamFixtures.with_digest(
          %{"v" => 1, "origin" => "start", "nonce" => "n", "digest" => "x"}
          |> put_exam(exam)
        )

    defp put_exam(snapshot, :absent), do: snapshot
    defp put_exam(snapshot, exam), do: Map.put(snapshot, "exam", exam)

    test "T-16: a snapshot with no exam object is :exam_section_missing, never a default threshold" do
      snapshot = forged(:absent)

      assert {:ok, ^snapshot} = Snapshot.fetch_verified(row(snapshot))
      assert grading(:exam_section_missing) == Snapshot.threshold(snapshot)
    end

    test "T-15: an exam object with the threshold key absent, or nil, is :threshold_missing" do
      assert grading(:threshold_missing) == Snapshot.threshold(forged(%{"exam_id" => @exam_id}))

      assert grading(:threshold_missing) ==
               Snapshot.threshold(forged(%{"passing_score_pct" => nil}))
    end

    test "T-55a: a stored threshold that is not a valid decimal string in 0..100 is :threshold_invalid" do
      for stored <- ["abc", "", "-1", "101", "NaN", "1e999999999", 60, 60.0, true, %{}] do
        assert {stored, Snapshot.threshold(forged(%{"passing_score_pct" => stored}))} ==
                 {stored, grading(:threshold_invalid)}
      end
    end

    test "a valid stored threshold reads back as a float" do
      for {stored, expected} <- [
            {"60", 60.0},
            {"72.5", 72.5},
            {"0", 0.0},
            {"100", 100.0},
            {"60.00", 60.0}
          ] do
        assert {:ok, ^expected} = Snapshot.threshold(forged(%{"passing_score_pct" => stored}))
      end
    end
  end

  describe "question_item/2 and question_type/2" do
    setup do
      items = %{
        @q1 => single([@o1], [@o2]),
        @q2 => %{type: "shorttext", options: []}
      }

      %{snapshot: build!(items, [@q1, @q2])}
    end

    test "an item is returned for a known question and {:question_item_missing, id} for an unknown one",
         %{snapshot: snapshot} do
      assert {:ok, %{"type" => "single"}} = Snapshot.question_item(snapshot, @q1)
      assert grading({:question_item_missing, @o1}) == Snapshot.question_item(snapshot, @o1)
    end

    test "a snapshot without a questions object (late_certificate shape) is :snapshot_corrupt", %{
      snapshot: snapshot
    } do
      assert grading(:snapshot_corrupt) ==
               Snapshot.question_item(Map.delete(snapshot, "questions"), @q1)

      assert grading(:snapshot_corrupt) ==
               Snapshot.to_scoring_questions(Map.delete(snapshot, "questions"))
    end

    test "the type is the snapshot's own, mapped to the five atoms", %{snapshot: snapshot} do
      assert {:ok, :single} = Snapshot.question_type(snapshot, @q1)
      assert {:ok, :short_text} = Snapshot.question_type(snapshot, @q2)

      for {stored, atom} <- [
            {"single", :single},
            {"multiple", :multiple},
            {"truefalse", :true_false},
            {"likert", :likert},
            {"shorttext", :short_text}
          ] do
        forged = put_in(snapshot, ["questions", @q1, "type"], stored)
        assert {:ok, ^atom} = Snapshot.question_type(forged, @q1)
      end
    end

    test "a stored type outside the five is {:question_type_invalid, id}", %{snapshot: snapshot} do
      forged = put_in(snapshot, ["questions", @q1, "type"], "essay")
      assert grading({:question_type_invalid, @q1}) == Snapshot.question_type(forged, @q1)
    end

    test "a missing item is {:question_item_missing, id} for question_type too", %{
      snapshot: snapshot
    } do
      assert grading({:question_item_missing, "nope"}) == Snapshot.question_type(snapshot, "nope")
    end
  end

  describe "to_scoring_questions/1" do
    test "maps the items in order to the Scoring.question_row shape, with likert weights as floats and polarities as atoms" do
      likert = likert_options([{1, "positive"}, {3.5, "negative"}])

      snapshot =
        build!(
          %{
            @q1 => %{type: "truefalse", options: [opt(@o1, is_correct: true), opt(@o2)]},
            @q2 => %{type: "likert", options: likert}
          },
          [@q2, @q1]
        )

      assert {:ok, [first, second]} = Snapshot.to_scoring_questions(snapshot)

      assert first.question_id == @q2
      assert first.type == :likert
      assert first.correct_option_ids == []

      assert Enum.sort(Enum.map(Map.values(first.likert_options), &{&1.weight, &1.polarity})) ==
               [{1.0, :positive}, {3.5, :negative}]

      assert second == %{
               question_id: @q1,
               type: :true_false,
               correct_option_ids: [@o1],
               likert_options: %{}
             }
    end

    test "the digest is not checked here (that is fetch_verified/1's job), the structure is" do
      snapshot = build!(%{@q1 => single([@o1], [@o2])}, [@q1])
      assert {:ok, [_]} = Snapshot.to_scoring_questions(Map.put(snapshot, "digest", "sha256:x"))
    end

    test "T-17: an order id with no item is {:question_item_missing, id}" do
      snapshot = build!(%{@q1 => single([@o1], [@o2])}, [@q1])
      forged = Map.put(snapshot, "order", [@q1, @q2])

      assert grading({:question_item_missing, @q2}) == Snapshot.to_scoring_questions(forged)
    end

    test "T-17: stored items that break the key rule are {:key_missing, id}, and a bad type {:question_type_invalid, id}" do
      snapshot =
        build!(
          %{
            @q1 => single([@o1], [@o2]),
            @q2 => %{type: "likert", options: likert_options([{1, "positive"}, {2, "negative"}])}
          },
          [@q1, @q2]
        )

      empty_correct = put_in(snapshot, ["questions", @q1, "correct_option_ids"], [])
      non_binary_ids = put_in(snapshot, ["questions", @q1, "correct_option_ids"], [1, 2])
      no_ids = update_in(snapshot, ["questions", @q1], &Map.delete(&1, "correct_option_ids"))
      empty_likert = put_in(snapshot, ["questions", @q2, "likert_options"], %{})
      likert_not_map = put_in(snapshot, ["questions", @q2, "likert_options"], [])

      bad_weight =
        update_in(snapshot, ["questions", @q2, "likert_options"], fn options ->
          Map.new(options, fn {id, entry} -> {id, Map.put(entry, "weight", "abc")} end)
        end)

      numeric_weight =
        update_in(snapshot, ["questions", @q2, "likert_options"], fn options ->
          Map.new(options, fn {id, entry} -> {id, Map.put(entry, "weight", 3)} end)
        end)

      bad_polarity =
        update_in(snapshot, ["questions", @q2, "likert_options"], fn options ->
          Map.new(options, fn {id, entry} -> {id, Map.put(entry, "polarity", "x")} end)
        end)

      for forged <- [empty_correct, non_binary_ids, no_ids] do
        assert grading({:key_missing, @q1}) == Snapshot.to_scoring_questions(forged)
      end

      for forged <- [empty_likert, likert_not_map, bad_weight, numeric_weight, bad_polarity] do
        assert grading({:key_missing, @q2}) == Snapshot.to_scoring_questions(forged)
      end

      assert grading({:question_type_invalid, @q1}) ==
               Snapshot.to_scoring_questions(
                 put_in(snapshot, ["questions", @q1, "type"], "essay")
               )
    end

    test "T-17: a stored shorttext or likert item with NO correct option is valid; an order that is not a list or holds a non-id is corrupt" do
      snapshot = build!(%{@q1 => %{type: "shorttext", options: []}}, [@q1])

      assert {:ok, [%{type: :short_text, correct_option_ids: []}]} =
               Snapshot.to_scoring_questions(snapshot)

      assert grading(:snapshot_corrupt) ==
               Snapshot.to_scoring_questions(Map.delete(snapshot, "order"))

      assert grading(:snapshot_corrupt) ==
               Snapshot.to_scoring_questions(Map.put(snapshot, "order", [1]))
    end
  end

  # ── canonical encoding ────────────────────────────────────────────────────────────────────

  describe "canonical_encode/1" do
    test "keys are sorted at every level, lists keep their order, and there is no whitespace" do
      value = %{
        "b" => [3, 1, %{"z" => nil, "a" => true}],
        "a" => "é",
        "c" => %{"y" => 1.5, "x" => "s"}
      }

      assert Snapshot.canonical_encode(value) ==
               ~s({"a":"é","b":[3,1,{"a":true,"z":null}],"c":{"x":"s","y":1.5}})
    end

    test "two maps with the same content and different insertion order encode identically; a list reorder does not" do
      one = Map.new([{"x", 1}, {"a", %{"k" => 1, "j" => 2}}])
      other = %{"a" => %{"j" => 2, "k" => 1}, "x" => 1}

      assert Snapshot.canonical_encode(one) == Snapshot.canonical_encode(other)

      refute Snapshot.canonical_encode(%{"l" => [1, 2]}) ==
               Snapshot.canonical_encode(%{"l" => [2, 1]})
    end

    test "atom keys encode as their string form, so a built snapshot and its decoded copy encode identically" do
      assert Snapshot.canonical_encode(%{a: 1}) == Snapshot.canonical_encode(%{"a" => 1})
    end
  end

  # ── T-41: property over a REAL jsonb column ───────────────────────────────────────────────

  describe "T-41: random snapshots round-trip a real jsonb column and re-verify" do
    @weights ["0.1", "3.5", "1", "2.25", 0.5, 2, "10"]
    @thresholds [60, 60.0, "72.5", 0, 100, "99.99", 33.3]

    defp question_generator do
      gen all(
            type <-
              StreamData.member_of(["single", "multiple", "truefalse", "likert", "shorttext"]),
            n_options <- StreamData.integer(2..5),
            weights <- StreamData.list_of(StreamData.member_of(@weights), length: 5),
            correct_mask <- StreamData.list_of(StreamData.boolean(), length: 5)
          ) do
        ids = for i <- 1..n_options, do: Ecto.UUID.generate() <> "-#{i}"

        options =
          ids
          |> Enum.with_index()
          |> Enum.map(fn {id, index} ->
            opt(id,
              is_correct:
                type in ["single", "multiple", "truefalse"] and
                  (index == 0 or Enum.at(correct_mask, index)),
              likert_weight: Enum.at(weights, index),
              likert_polarity: if(rem(index, 2) == 0, do: "positive", else: "negative")
            )
          end)

        %{type: type, options: options}
      end
    end

    test "build -> jsonb -> fetch_verified returns the identical snapshot with byte-stable decimal strings" do
      check all(
              threshold <- StreamData.member_of(@thresholds),
              questions <- StreamData.list_of(question_generator(), min_length: 1, max_length: 4),
              max_runs: 25
            ) do
        keyed = Enum.map(questions, &{Ecto.UUID.generate(), &1})
        order = Enum.map(keyed, &elem(&1, 0))

        assert {:ok, snapshot} = build(Map.new(keyed), order, threshold)

        %{rows: [[stored]]} = Repo.query!("SELECT $1::jsonb", [snapshot])

        assert stored == snapshot
        assert {:ok, ^stored} = Snapshot.fetch_verified(row(stored))
        assert Snapshot.canonical_encode(stored) == Snapshot.canonical_encode(snapshot)

        # the normalised threshold and every weight are decimal STRINGS that survive the column
        assert is_binary(stored["exam"]["passing_score_pct"])

        for {_id, %{"likert_options" => options}} <- stored["questions"],
            {_option_id, %{"weight" => weight}} <- options do
          assert is_binary(weight)
        end
      end
    end

    test "the byte-stable cases named by the design: 0.1, 3.5 and the normalised 60 survive jsonb unchanged" do
      options = likert_options([{"0.1", "positive"}, {3.5, "negative"}])

      assert {:ok, snapshot} =
               build(%{@q1 => %{type: "likert", options: options}}, [@q1], 60.0)

      %{rows: [[stored]]} = Repo.query!("SELECT $1::jsonb", [snapshot])

      assert stored["exam"]["passing_score_pct"] == "60"

      assert stored["questions"][@q1]["likert_options"]
             |> Map.values()
             |> Enum.map(& &1["weight"])
             |> Enum.sort() ==
               ["0.1", "3.5"]
    end
  end

  # ── T-55 completeness ─────────────────────────────────────────────────────────────────────

  describe "T-55 completeness: every grading_reason() of design 7.2 that PR a can produce has a test" do
    # Reasons PR b alone produces (certificate path / late path); PR a only declares them.
    @pr_b_reasons [:certificate_facts_missing]

    test "each reason is produced by a concrete input below" do
      big_ids = for _ <- 1..20_000, do: Ecto.UUID.generate()
      big_item = %{type: "multiple", options: Enum.map(big_ids, &opt(&1, is_correct: true))}
      good = build!(%{@q1 => single([@o1], [@o2])}, [@q1])

      produced = %{
        snapshot_missing: Snapshot.fetch_verified(%{}),
        snapshot_corrupt: Snapshot.fetch_verified(row("garbage")),
        threshold_missing: build(%{}, [], nil),
        threshold_invalid: build(%{}, [], "abc"),
        exam_section_missing: Snapshot.threshold(Map.delete(good, "exam")),
        question_item_missing: build(%{}, [@q1]),
        question_type_invalid: build(%{@q1 => %{type: "x", options: []}}, [@q1]),
        key_missing: build(%{@q1 => %{type: "single", options: []}}, [@q1]),
        snapshot_too_large:
          build(%{"a" => big_item, "b" => big_item, "c" => big_item}, ["a", "b", "c"])
      }

      reasons =
        for {_tag, {:error, {:grading_error, reason}}} <- produced do
          if is_tuple(reason), do: elem(reason, 0), else: reason
        end

      assert Enum.sort(reasons) == Enum.sort(Map.keys(produced))

      declared = [
        :snapshot_missing,
        :snapshot_corrupt,
        :threshold_missing,
        :threshold_invalid,
        :exam_section_missing,
        :question_item_missing,
        :question_type_invalid,
        :key_missing,
        :certificate_facts_missing,
        :snapshot_too_large
      ]

      assert Enum.sort(declared -- @pr_b_reasons) == Enum.sort(Map.keys(produced))
    end
  end
end
