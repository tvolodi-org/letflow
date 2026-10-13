defmodule Letflow.Modules.Exam.SessionTest do
  @moduledoc """
  REQ-332 -- integration tests for `Letflow.Modules.Exam.Session` against a real
  provisioned tenant (DIRECTIVE T-1: no mocked database). Self-contained via
  `Letflow.ExamFixtures` (DIRECTIVE T-4), mirroring
  `test/letflow/entities/query_joins_test.exs`'s own hand-rolled
  tenant-fixture pattern.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Exam.Session
  alias Letflow.ExamFixtures
  alias Letflow.Repo

  # ---------------------------------------------------------------------
  # Shared fixture helpers
  # ---------------------------------------------------------------------

  defp tenant(slug), do: ExamFixtures.provisioned_tenant_with_exam_definitions(slug)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 1,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    }

    ExamFixtures.create_record!(schema, "exam", Map.merge(defaults, attrs))
  end

  defp create_question!(schema, category_id, attrs \\ %{}) do
    defaults = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "Stem?"}
    }

    ExamFixtures.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs \\ %{}) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"}
    }

    ExamFixtures.create_record!(schema, "answer_option", Map.merge(defaults, attrs))
  end

  # ISS-0722: `mode` defaults to "random" (every pre-existing call site keeps
  # this default, so it stays live -- see docs/anti-patterns.md ISS-0069);
  # manual-mode tests pass `"manual"` explicitly.
  defp create_rule!(schema, exam_id, category_id, count, sort_order \\ 0, mode \\ "random") do
    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam_id,
      "mode" => mode,
      "category_id" => category_id,
      "count" => count,
      "sort_order" => sort_order
    })
  end

  # ISS-0722: pins `question_id` to a `mode: "manual"` `exam_question_rule`,
  # at the given intra-rule `sort_order` (distinct from the rule's own
  # `sort_order` among the exam's rules -- design doc §3/§4).
  defp create_manual_question!(schema, rule_id, question_id, sort_order) do
    ExamFixtures.create_record!(schema, "exam_manual_question", %{
      "rule_id" => rule_id,
      "question_id" => question_id,
      "sort_order" => sort_order
    })
  end

  # Builds one single-choice question with two options (first correct) in
  # `category_id`, returning `{question_id, correct_option_id, wrong_option_id}`.
  defp build_single_choice_question!(schema, category_id) do
    question = create_question!(schema, category_id)
    correct = create_option!(schema, question.record_id, 0, true)
    wrong = create_option!(schema, question.record_id, 1, false)
    {question.record_id, correct.record_id, wrong.record_id}
  end

  # Builds a minimal exam with one rule/one pool of `pool_size` single-choice
  # questions, taking `count` of them, and returns everything a test needs.
  #
  # ISS-0722: `opts[:mode]` defaults to `:random` (unchanged behavior for
  # every existing caller). `mode: :manual` builds a single `mode: "manual"`
  # `exam_question_rule` instead, and pins all `pool_size` questions to it
  # via `exam_manual_question` rows in creation order (`sort_order` 0..n-1)
  # -- `count`/`category_id` still exist on the rule (schema requires
  # `count`, design doc §1) but are semantically unused by the manual path.
  # The returned map additionally carries `pinned_question_ids` (the manual
  # pin order) so tests can assert materialized order without recomputing
  # it from `questions`.
  defp build_minimal_exam!(schema, opts \\ []) do
    pool_size = Keyword.get(opts, :pool_size, 1)
    count = Keyword.get(opts, :count, 1)
    exam_attrs = Keyword.get(opts, :exam_attrs, %{})
    mode = Keyword.get(opts, :mode, :random)
    category_id = Ecto.UUID.generate()

    exam = create_exam!(schema, exam_attrs)

    questions =
      for _ <- 1..pool_size do
        build_single_choice_question!(schema, category_id)
      end

    case mode do
      :random ->
        create_rule!(schema, exam.record_id, category_id, count)
        %{exam: exam, category_id: category_id, questions: questions}

      :manual ->
        rule = create_rule!(schema, exam.record_id, category_id, count, 0, "manual")

        pinned_question_ids =
          questions
          |> Enum.with_index()
          |> Enum.map(fn {{question_id, _correct, _wrong}, index} ->
            create_manual_question!(schema, rule.record_id, question_id, index)
            question_id
          end)

        %{
          exam: exam,
          category_id: category_id,
          questions: questions,
          rule: rule,
          pinned_question_ids: pinned_question_ids
        }
    end
  end

  # ---------------------------------------------------------------------
  # create/3 -- eligibility checks (AC: six named checks, five implemented)
  # ---------------------------------------------------------------------

  describe "create/3 eligibility checks" do
    test "exam archived -> :exam_archived, distinct from :exam_not_active" do
      %{schema_name: schema} = tenant("req332-elig-archived")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"status" => "archived"})

      assert {:error, :exam_archived} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    end

    test "exam not active (draft) -> :exam_not_active" do
      %{schema_name: schema} = tenant("req332-elig-draft")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"status" => "draft"})

      assert {:error, :exam_not_active} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    end

    test "outside the availability window (not yet available) -> :outside_availability_window" do
      %{schema_name: schema} = tenant("req332-elig-window-future")
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> iso()

      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"available_from" => future})

      assert {:error, :outside_availability_window} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    end

    test "outside the availability window (already closed) -> :outside_availability_window" do
      %{schema_name: schema} = tenant("req332-elig-window-past")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> iso()

      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"available_until" => past})

      assert {:error, :outside_availability_window} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    end

    test "attempts exhausted -> :attempts_exhausted" do
      %{schema_name: schema} = tenant("req332-elig-attempts")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 1})
      candidate_id = Ecto.UUID.generate()

      # A prior, already-finished session for this exam/candidate.
      ExamFixtures.create_record!(schema, "session", %{
        "exam_id" => exam.record_id,
        "user_id" => candidate_id,
        "status" => "submitted",
        "seed" => 1,
        "started_at" => iso(DateTime.utc_now()),
        "expires_at" => iso(DateTime.utc_now()),
        "passed" => true
      })

      assert {:error, :attempts_exhausted} = Session.create(candidate_id, exam.record_id, schema)
    end

    test "an already-open session -> :session_already_open" do
      %{schema_name: schema} = tenant("req332-elig-open")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      candidate_id = Ecto.UUID.generate()

      assert {:ok, _first} = Session.create(candidate_id, exam.record_id, schema)

      assert {:error, :session_already_open} =
               Session.create(candidate_id, exam.record_id, schema)
    end

    test "two CONCURRENT create/3 calls for the same candidate+exam produce exactly one session (fails if the exam-row lock is removed)" do
      %{schema_name: schema} = tenant("req332-create-concurrent")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 1})
      candidate_id = Ecto.UUID.generate()

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Session.create(candidate_id, exam.record_id, schema) end)
        end

      results = Task.await_many(tasks, 15_000)

      # Exactly one of the two concurrent calls materializes a session; the
      # other observes it (via the now-serialized exam-row lock,
      # `lock_exam_row/2`) and is correctly rejected as an already-open
      # session -- not both succeeding, which is what REVIEWER's finding
      # (WF02-REQ332-20260913) showed was possible before `create_with_seed/4`
      # ran inside `Repo.transaction/1` with that lock.
      assert Enum.count(results, &match?({:ok, _session_view}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :session_already_open})) == 1

      import Ecto.Query

      session_rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where:
              r.entity_type == "session" and
                fragment("?->>?", r.field_values, "user_id") == ^candidate_id
          ),
          prefix: schema
        )

      # Exactly one `session` row was materialized for this candidate/exam --
      # if `lock("FOR UPDATE")` were removed from `lock_exam_row/2`, both
      # concurrent transactions could observe zero existing sessions
      # simultaneously and both materialize one, doubling this count and
      # silently violating the one-open-session/attempt-limit invariant.
      assert length(session_rows) == 1
    end

    test "eligible candidate creates a real, materialized session" do
      %{schema_name: schema} = tenant("req332-elig-happy")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)
      assert session_view.status == :in_progress
      assert session_view.exam_id == exam.record_id
      assert session_view.candidate_id == candidate_id
    end

    test "FINDING: the :not_assigned check is a documented no-op today (no exam_assignment entity exists)" do
      %{schema_name: schema} = tenant("req332-elig-not-assigned-finding")
      %{exam: exam} = build_minimal_exam!(schema)

      # No assignment of any kind was ever created for this candidate, yet
      # create/3 succeeds -- proving, rather than merely asserting in prose,
      # that :not_assigned is currently unreachable. See Letflow.Modules.Exam.Session's
      # moduledoc "FINDING" section for the full reasoning and REQ-332's
      # close-out for the escalation to ORCH/REQ-ANALYST this represents.
      assert {:ok, _session_view} = Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    end
  end

  # ---------------------------------------------------------------------
  # Session snapshot isolation
  # ---------------------------------------------------------------------

  describe "session snapshot isolation" do
    test "deleting/editing a bank question after session creation does not change the materialized rows" do
      %{schema_name: schema} = tenant("req332-snapshot")
      %{exam: exam, questions: [{question_id, _correct, _wrong}]} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      # Delete the bank question entirely.
      assert {:ok, _result} =
               Letflow.Entities.Records.delete_record(
                 %{
                   entity_type: "question",
                   record_id: question_id,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      # The session's own materialized session_question row is untouched --
      # fetched directly, since Session exposes no listing function itself.
      import Ecto.Query

      rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where:
              r.entity_type == "session_question" and
                fragment("?->>?", r.field_values, "session_id") == ^session_view.id
          ),
          prefix: schema
        )

      assert [row] = rows
      assert row.field_values["question_id"] == question_id
    end
  end

  # ---------------------------------------------------------------------
  # Seeded reproducibility (Session-level, via the internal create_with_seed/4 test seam)
  # ---------------------------------------------------------------------

  describe "seeded reproducibility (integration)" do
    test "the same stored seed and exam config resolve the same question set, order, and option order" do
      %{schema_name: schema} = tenant("req332-repro")

      %{exam: exam} =
        build_minimal_exam!(schema,
          pool_size: 4,
          count: 3,
          exam_attrs: %{"shuffle_questions" => true, "shuffle_options" => true}
        )

      seed = 12_345

      assert {:ok, session_a} =
               Session.create_with_seed(Ecto.UUID.generate(), exam.record_id, schema, seed)

      assert {:ok, session_b} =
               Session.create_with_seed(Ecto.UUID.generate(), exam.record_id, schema, seed)

      assert session_a.seed == seed
      assert session_b.seed == seed

      rows_a = session_question_rows(schema, session_a.id)
      rows_b = session_question_rows(schema, session_b.id)

      assert Enum.map(rows_a, & &1["question_id"]) == Enum.map(rows_b, & &1["question_id"])
      assert Enum.map(rows_a, & &1["options_order"]) == Enum.map(rows_b, & &1["options_order"])
    end
  end

  defp session_question_rows(schema, session_id) do
    import Ecto.Query

    Repo.all(
      from(r in Letflow.Entities.Record.Latest,
        where:
          r.entity_type == "session_question" and
            fragment("?->>?", r.field_values, "session_id") == ^session_id,
        order_by: fragment("(?->>'sort_order')::int", r.field_values)
      ),
      prefix: schema
    )
    |> Enum.map(& &1.field_values)
  end

  # ---------------------------------------------------------------------
  # ISS-0722 -- exam_question_rule mode "manual" materialization
  # ---------------------------------------------------------------------

  describe "ISS-0722 -- manual-mode question materialization" do
    test "pure manual-mode exam materializes exactly the pinned questions, in exam_manual_question.sort_order" do
      %{schema_name: schema} = tenant("iss0722-manual-only")

      %{exam: exam, pinned_question_ids: pinned_question_ids} =
        build_minimal_exam!(schema, mode: :manual, pool_size: 4)

      assert {:ok, session_view} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      rows = session_question_rows(schema, session_view.id)

      # Same questions, same count, same order as authored -- not just "some
      # permutation of the right set."
      assert Enum.map(rows, & &1["question_id"]) == pinned_question_ids
    end

    test "mixed-mode exam (random rule + manual rule) materializes both blocks, random-block-first then manual-block (design §4.2)" do
      %{schema_name: schema} = tenant("iss0722-mixed-mode")

      %{exam: exam, category_id: random_category_id, questions: random_questions} =
        build_minimal_exam!(schema, mode: :random, pool_size: 3, count: 3)

      random_question_ids =
        Enum.map(random_questions, fn {question_id, _c, _w} -> question_id end)

      manual_rule =
        create_rule!(schema, exam.record_id, random_category_id, 1, 1, "manual")

      manual_questions =
        for _ <- 1..2, do: build_single_choice_question!(schema, Ecto.UUID.generate())

      pinned_question_ids =
        manual_questions
        |> Enum.with_index()
        |> Enum.map(fn {{question_id, _c, _w}, index} ->
          create_manual_question!(schema, manual_rule.record_id, question_id, index)
          question_id
        end)

      assert {:ok, session_view} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      rows = session_question_rows(schema, session_view.id)
      materialized_ids = Enum.map(rows, & &1["question_id"])

      assert length(materialized_ids) == 5

      {random_block, manual_block} = Enum.split(materialized_ids, 3)

      # Random block: same set as the random pool (order is resolver-owned,
      # unshuffled here since shuffle_questions defaults to false), but
      # crucially it comes FIRST.
      assert Enum.sort(random_block) == Enum.sort(random_question_ids)
      # Manual block: exact pin order, LAST.
      assert manual_block == pinned_question_ids
    end

    test "manual rule with a LOWER sort_order than the random rule still materializes AFTER it -- block order is mode-based, not exam_question_rule.sort_order-based (design §4.2)" do
      %{schema_name: schema} = tenant("iss0722-sort-order-discriminator")

      exam = create_exam!(schema, %{})
      random_category_id = Ecto.UUID.generate()

      random_questions =
        for _ <- 1..3, do: build_single_choice_question!(schema, random_category_id)

      random_question_ids =
        Enum.map(random_questions, fn {question_id, _c, _w} -> question_id end)

      # Deliberately reversed relative to the "mixed-mode" test above: here
      # the random rule's sort_order (1) is HIGHER than the manual rule's
      # sort_order (0). If block order were actually driven by
      # exam_question_rule.sort_order (the tempting-but-wrong implementation
      # design §4.2 explicitly warns against), the manual block would
      # materialize first in this setup. The shipped implementation
      # (session.ex:734's unconditional `resolved_random ++ resolved_manual`)
      # ignores rule sort_order for block placement and always emits the
      # random block first -- this is the only fixture arrangement that can
      # distinguish the two implementations from each other.
      create_rule!(schema, exam.record_id, random_category_id, 3, 1, "random")
      manual_rule = create_rule!(schema, exam.record_id, random_category_id, 1, 0, "manual")

      manual_questions =
        for _ <- 1..2, do: build_single_choice_question!(schema, Ecto.UUID.generate())

      pinned_question_ids =
        manual_questions
        |> Enum.with_index()
        |> Enum.map(fn {{question_id, _c, _w}, index} ->
          create_manual_question!(schema, manual_rule.record_id, question_id, index)
          question_id
        end)

      assert {:ok, session_view} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      rows = session_question_rows(schema, session_view.id)
      materialized_ids = Enum.map(rows, & &1["question_id"])

      assert length(materialized_ids) == 5

      {random_block, manual_block} = Enum.split(materialized_ids, 3)

      # Random block first (by set, order is resolver-owned/unshuffled here),
      # manual block last in exact pin order -- despite the manual rule
      # having the numerically lower sort_order.
      assert Enum.sort(random_block) == Enum.sort(random_question_ids)
      assert manual_block == pinned_question_ids
    end

    test "shuffle_questions? true does NOT reorder manual-origin questions, even while shuffling the random-origin block (design §4.1)" do
      %{schema_name: schema} = tenant("iss0722-shuffle-carveout")

      %{exam: exam, category_id: random_category_id} =
        build_minimal_exam!(schema,
          mode: :random,
          pool_size: 8,
          count: 8,
          exam_attrs: %{"shuffle_questions" => true}
        )

      manual_rule =
        create_rule!(schema, exam.record_id, random_category_id, 1, 1, "manual")

      manual_questions =
        for _ <- 1..6, do: build_single_choice_question!(schema, Ecto.UUID.generate())

      pinned_question_ids =
        manual_questions
        |> Enum.with_index()
        |> Enum.map(fn {{question_id, _c, _w}, index} ->
          create_manual_question!(schema, manual_rule.record_id, question_id, index)
          question_id
        end)

      assert {:ok, session_view} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      rows = session_question_rows(schema, session_view.id)
      materialized_ids = Enum.map(rows, & &1["question_id"])

      assert length(materialized_ids) == 14

      # The LAST 6 materialized rows are the manual block (§4.2: random block
      # first). Its order must be EXACTLY the authored pin order -- not a
      # permutation, not "the right set in some order" -- regardless of
      # `shuffle_questions?: true` on the exam. This is the invariant
      # REVIEWER flagged as fragile: assert the precise list equality, not a
      # weaker set-membership check, so a mutant that accidentally folds the
      # manual block into the shuffle would fail this deterministically
      # (8-of-14 odds of an accidental exact-order match by chance is
      # negligible, and the code path is deterministic either way -- this
      # is not a statistical/seeded-randomness assertion, it's a structural
      # one: manual rows are never passed through `Enum.shuffle/1` at all).
      manual_block = Enum.take(materialized_ids, -6)
      assert manual_block == pinned_question_ids

      random_block = Enum.take(materialized_ids, 8)
      assert Enum.sort(random_block) != Enum.sort(manual_block)
    end

    test "a manual rule with zero exam_manual_question rows returns {:error, :manual_rule_empty} and creates no session" do
      %{schema_name: schema} = tenant("iss0722-manual-empty")

      exam = create_exam!(schema, %{})
      category_id = Ecto.UUID.generate()
      # Manual rule created directly (bypassing build_minimal_exam!/2's
      # :manual path, which always pins pool_size questions) so this rule
      # genuinely has zero exam_manual_question rows.
      create_rule!(schema, exam.record_id, category_id, 1, 0, "manual")

      candidate_id = Ecto.UUID.generate()

      assert {:error, :manual_rule_empty} =
               Session.create(candidate_id, exam.record_id, schema)

      # Mirrors how a rejected create/3 call must leave no trace: no
      # "session" entity record was written for this candidate/exam pair.
      # Raw query against entity_record_latest, same pattern as the
      # "session snapshot isolation" describe block above -- Session
      # exposes no listing function of its own.
      import Ecto.Query

      session_rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where:
              r.entity_type == "session" and
                fragment("?->>?", r.field_values, "exam_id") == ^exam.record_id and
                fragment("?->>?", r.field_values, "user_id") == ^candidate_id
          ),
          prefix: schema
        )

      assert session_rows == []
    end

    test "regression proof: a random-only exam's materialization is unchanged by the manual-mode fix" do
      %{schema_name: schema} = tenant("iss0722-random-only-regression")

      %{exam: exam, questions: questions} =
        build_minimal_exam!(schema, pool_size: 3, count: 3)

      question_ids = Enum.map(questions, fn {question_id, _c, _w} -> question_id end)

      assert {:ok, session_view} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      rows = session_question_rows(schema, session_view.id)
      materialized_ids = Enum.map(rows, & &1["question_id"])

      assert length(materialized_ids) == 3
      assert Enum.sort(materialized_ids) == Enum.sort(question_ids)
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0724 -- never-reorder invariant, property backstop across many seeds
  # (design doc lib/letflow/design/iss0724-exam-question-origin-separation.md
  # §4's named residual gap: the arity change from persist_session_questions/4
  # to /5 only catches a literal 4-arg revert at compile time. It cannot catch
  # a future edit that merges resolved_random/resolved_manual into one
  # reshuffled list and passes it as persist_session_questions(id, merged, [],
  # candidate_id, prefix) -- that compiles cleanly under the new 5-arity
  # signature, since neither argument carries provenance. This test is the
  # assertion-level backstop §4 explicitly defers to: it asserts the
  # never-reorder invariant (iss0722-...md §4.1 -- shuffle_questions? never
  # reorders manual-origin questions) end-to-end, across many distinct seeds,
  # so it is not merely "passed once" but demonstrably insensitive to seed
  # choice -- exactly the property a merge-then-reshuffle regression would
  # violate for ALMOST every seed (a reshuffled 14-element list matching the
  # authored 6-element manual order by chance is negligible).
  # ---------------------------------------------------------------------

  describe "ISS-0724 -- never-reorder invariant holds across many seeds" do
    test "manual-block question order and sort_order values are invariant to shuffle_questions?, across many distinct seeds" do
      %{schema_name: schema} = tenant("iss0724-never-reorder-property")

      %{exam: exam, category_id: random_category_id} =
        build_minimal_exam!(schema,
          mode: :random,
          pool_size: 8,
          count: 8,
          exam_attrs: %{"shuffle_questions" => true, "max_attempts" => 1000}
        )

      manual_rule =
        create_rule!(schema, exam.record_id, random_category_id, 1, 1, "manual")

      manual_questions =
        for _ <- 1..6, do: build_single_choice_question!(schema, Ecto.UUID.generate())

      pinned_question_ids =
        manual_questions
        |> Enum.with_index()
        |> Enum.map(fn {{question_id, _c, _w}, index} ->
          create_manual_question!(schema, manual_rule.record_id, question_id, index)
          question_id
        end)

      # sort_order for the manual block is always assigned starting right
      # after the random block's own 0..7 indices (materialize_session/5,
      # design §2 step 3) -- 8..13 here, regardless of seed.
      expected_manual_sort_orders = Enum.to_list(8..13)

      seeds = [
        1,
        2,
        3,
        5,
        8,
        13,
        21,
        34,
        55,
        89,
        144,
        233,
        1_000,
        7,
        42,
        1_337,
        999_983,
        2_024,
        17,
        64
      ]

      for seed <- seeds do
        candidate_id = Ecto.UUID.generate()

        assert {:ok, session_view} =
                 Session.create_with_seed(candidate_id, exam.record_id, schema, seed)

        rows = session_question_rows(schema, session_view.id)
        assert length(rows) == 14

        manual_rows = Enum.take(rows, -6)

        assert Enum.map(manual_rows, & &1["question_id"]) == pinned_question_ids,
               "seed #{seed}: manual-block question order diverged from the authored pin order"

        assert Enum.map(manual_rows, & &1["sort_order"]) == expected_manual_sort_orders,
               "seed #{seed}: manual-block sort_order values diverged from the assigned authored sequence"
      end
    end
  end

  # ---------------------------------------------------------------------
  # autosave_answer/4
  # ---------------------------------------------------------------------

  describe "autosave_answer/4" do
    setup do
      %{schema_name: schema} = tenant("req332-autosave-#{System.unique_integer([:positive])}")

      %{exam: exam, questions: [{question_id, correct_id, wrong_id}]} =
        build_minimal_exam!(schema)

      candidate_id = Ecto.UUID.generate()
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      %{
        schema: schema,
        exam: exam,
        session_id: session_view.id,
        candidate_id: candidate_id,
        question_id: question_id,
        correct_id: correct_id,
        wrong_id: wrong_id
      }
    end

    test "happy path saves and returns remaining_seconds clamped, never negative", ctx do
      assert {:ok, %{remaining_seconds: remaining}} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [ctx.correct_id],
                   time_spent_seconds: 5
                 },
                 ctx.schema
               )

      assert is_integer(remaining)
      assert remaining >= 0

      # This is what keeps the client clock server-authoritative (roadmap
      # 3.7): the response's remaining_seconds is computed from the
      # session's own stored, server-set expires_at, never from anything
      # the client sent.
    end

    test "server-side deadline enforcement: a save after the stored deadline is rejected regardless of what the client claims",
         ctx do
      # Force the session's own stored expires_at into the past directly --
      # there is no client-timestamp parameter on autosave_answer/4 for a
      # test (or a real caller) to supply instead; this proves the deadline
      # comes from server-held state, not any client-controlled input.
      force_session_status_and_expiry(ctx.schema, ctx.session_id, "in_progress", -10)

      assert {:error, :deadline_passed} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [ctx.correct_id],
                   time_spent_seconds: 1
                 },
                 ctx.schema
               )
    end

    test "ownership: another candidate cannot autosave into this session", ctx do
      assert {:error, :not_owner} =
               Session.autosave_answer(
                 ctx.session_id,
                 Ecto.UUID.generate(),
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [ctx.correct_id],
                   time_spent_seconds: 1
                 },
                 ctx.schema
               )
    end

    test "answer-shape: a single-choice question rejects more than one selected option", ctx do
      assert {:error, :answer_shape_invalid} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [ctx.correct_id, ctx.wrong_id],
                   time_spent_seconds: 1
                 },
                 ctx.schema
               )
    end

    test "answer-shape: a short-text question rejects any selected option ids", ctx do
      short_text_question =
        create_question!(ctx.schema, Ecto.UUID.generate(), %{"type" => "shorttext"})

      # Add it to this session's own materialised set directly (bypassing
      # create/3's pool resolution, which this test does not need).
      ExamFixtures.create_record!(ctx.schema, "session_question", %{
        "session_id" => ctx.session_id,
        "question_id" => short_text_question.record_id,
        "sort_order" => 99,
        "options_order" => []
      })

      assert {:error, :answer_shape_invalid} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: short_text_question.record_id,
                   selected_option_ids: [ctx.correct_id],
                   time_spent_seconds: 1
                 },
                 ctx.schema
               )
    end

    # ISS-0650: `answer_attrs()` had no `text_answer` field anywhere in the
    # write path -- a short-text question could never actually be answered.
    # This proves the full round trip: autosave with `text_answer`, then
    # read it back via `get_session_state_for_user/3`'s
    # `saved_answer.text_answer`, exactly as REQ-335's session-state route
    # exposes it to a resuming candidate.
    test "a short-text question accepts and persists text_answer, retrievable via get_session_state_for_user/3",
         ctx do
      short_text_question =
        create_question!(ctx.schema, Ecto.UUID.generate(), %{"type" => "shorttext"})

      ExamFixtures.create_record!(ctx.schema, "session_question", %{
        "session_id" => ctx.session_id,
        "question_id" => short_text_question.record_id,
        "sort_order" => 99,
        "options_order" => []
      })

      assert {:ok, %{remaining_seconds: remaining}} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: short_text_question.record_id,
                   selected_option_ids: [],
                   text_answer: "The mitochondria is the powerhouse of the cell.",
                   time_spent_seconds: 12
                 },
                 ctx.schema
               )

      assert is_integer(remaining)

      assert {:ok, state} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate_id, ctx.schema)

      assert %{
               text_answer: "The mitochondria is the powerhouse of the cell.",
               selected_option_ids: []
             } = Map.fetch!(state.answers, short_text_question.record_id)
    end

    # A second autosave with `text_answer: nil` (an explicit clear, or the
    # shape a not-yet-answered save would carry) upserts cleanly rather than
    # leaving the prior text stuck.
    test "a second short-text autosave upserts the stored text_answer, not duplicates", ctx do
      short_text_question =
        create_question!(ctx.schema, Ecto.UUID.generate(), %{"type" => "shorttext"})

      ExamFixtures.create_record!(ctx.schema, "session_question", %{
        "session_id" => ctx.session_id,
        "question_id" => short_text_question.record_id,
        "sort_order" => 99,
        "options_order" => []
      })

      assert {:ok, _} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: short_text_question.record_id,
                   selected_option_ids: [],
                   text_answer: "first draft",
                   time_spent_seconds: 1
                 },
                 ctx.schema
               )

      assert {:ok, _} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: short_text_question.record_id,
                   selected_option_ids: [],
                   text_answer: "final answer",
                   time_spent_seconds: 30
                 },
                 ctx.schema
               )

      assert {:ok, state} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate_id, ctx.schema)

      assert %{text_answer: "final answer"} =
               Map.fetch!(state.answers, short_text_question.record_id)
    end

    # ISS-0650 acceptance criterion: the option-based question types stay
    # exactly as strict as before -- a client sending free text for one of
    # them is a shape error, not silently dropped, matching
    # `check_answer_shape/3`'s existing per-type strictness (e.g. the
    # short-text-must-not-carry-selected-options check just above).
    test "text_answer is rejected for single/multiple/true_false/likert questions", ctx do
      for type <- ["single", "multiple", "truefalse", "likert"] do
        question = create_question!(ctx.schema, Ecto.UUID.generate(), %{"type" => type})

        ExamFixtures.create_record!(ctx.schema, "session_question", %{
          "session_id" => ctx.session_id,
          "question_id" => question.record_id,
          "sort_order" => 100,
          "options_order" => []
        })

        assert {:error, :answer_shape_invalid} =
                 Session.autosave_answer(
                   ctx.session_id,
                   ctx.candidate_id,
                   %{
                     question_id: question.record_id,
                     selected_option_ids: [],
                     text_answer: "should not be accepted",
                     time_spent_seconds: 1
                   },
                   ctx.schema
                 )
      end
    end

    test "an option id belonging to a different question is rejected", ctx do
      other_question = create_question!(ctx.schema, Ecto.UUID.generate())
      other_option = create_option!(ctx.schema, other_question.record_id, 0, true)

      assert {:error, :option_not_in_question} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [other_option.record_id],
                   time_spent_seconds: 1
                 },
                 ctx.schema
               )
    end

    test "the write path is the ordinary Records/Query path: a second save on the same question upserts, not duplicates",
         ctx do
      # Q-1075 / GH #2432: let more than 10 seconds elapse so the stored-value bound does not bind.
      Process.sleep(11_000)

      assert {:ok, _} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [ctx.correct_id],
                   time_spent_seconds: 5
                 },
                 ctx.schema
               )

      assert {:ok, _} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate_id,
                 %{
                   question_id: ctx.question_id,
                   selected_option_ids: [ctx.wrong_id],
                   time_spent_seconds: 10
                 },
                 ctx.schema
               )

      import Ecto.Query

      rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where:
              r.entity_type == "session_answer" and
                fragment("?->>?", r.field_values, "session_id") == ^ctx.session_id and
                fragment("?->>?", r.field_values, "question_id") == ^ctx.question_id
          ),
          prefix: ctx.schema
        )

      assert [row] = rows
      assert row.field_values["selected_option_ids"] == [ctx.wrong_id]
      # Q-1075 / GH #2432: this test pins the stored value exactly, so the session's elapsed
      # bound must not bind here. The clamp (min with elapsed seconds) is covered separately by
      # the clamp tests; this one waits past 10 seconds so that the reported 10 is stored as-is.
      assert row.field_values["time_spent_seconds"] == 10
    end
  end

  defp force_session_status_and_expiry(schema, session_id, status, offset_seconds) do
    assert {:ok, session} = Letflow.Entities.Record.Latest.get(session_id, "session", schema)
    fv = session.field_values

    attrs =
      Map.merge(fv, %{
        "status" => status,
        "expires_at" => DateTime.utc_now() |> DateTime.add(offset_seconds, :second) |> iso()
      })

    assert {:ok, _} =
             Letflow.Entities.Records.update_record(
               %{
                 entity_type: "session",
                 record_id: session_id,
                 field_values: attrs,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )
  end

  # ---------------------------------------------------------------------
  # submit/3
  # ---------------------------------------------------------------------

  describe "submit/3" do
    test "scores an all-single-choice session and lands it in :submitted" do
      %{schema_name: schema} = tenant("req332-submit-basic")

      %{exam: exam, questions: [{question_id, correct_id, _wrong_id}]} =
        build_minimal_exam!(schema)

      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: question_id,
                   selected_option_ids: [correct_id],
                   time_spent_seconds: 5
                 },
                 schema
               )

      assert {:ok, outcome} = Session.submit(session_view.id, candidate_id, schema)
      assert outcome.status == :submitted
      assert outcome.percentage == 100.0
      assert outcome.passed == true
    end

    test "an unanswered question in the session is graded as wrong, not skipped" do
      %{schema_name: schema} = tenant("req332-submit-unanswered")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)
      # No autosave at all.
      assert {:ok, outcome} = Session.submit(session_view.id, candidate_id, schema)

      assert outcome.status == :submitted
      assert outcome.percentage == 0.0
      assert outcome.passed == false
    end

    test "a session with a no-correct-option question surfaces the scoring error rather than a silent zero" do
      %{schema_name: schema} = tenant("req332-submit-no-correct")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      category_id = Ecto.UUID.generate()
      # A question with NO option marked is_correct -- a broken bank entry.
      broken_question = create_question!(schema, category_id)
      create_option!(schema, broken_question.record_id, 0, false)
      # ISS-0648 fix note: build_minimal_exam!/2 already registered a rule at
      # sort_order 0 for this exam; uq_exam_question_rule_exam_id_sort_order
      # is now genuinely enforced (this fix's own point), so this second
      # rule needs a distinct sort_order to avoid colliding with it -- a
      # pre-existing test-fixture gap this fix's own enforcement newly
      # surfaces, not a production bug.
      create_rule!(schema, exam.record_id, category_id, 1, 1)

      candidate_id = Ecto.UUID.generate()
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:error, :question_without_correct_option} =
               Session.submit(session_view.id, candidate_id, schema)
    end

    test "any short-text question in the session lands submit in :grading_pending, not :submitted" do
      %{schema_name: schema} = tenant("req332-submit-pending")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      category_id = Ecto.UUID.generate()
      short_text_question = create_question!(schema, category_id, %{"type" => "shorttext"})
      # See the "no-correct-option" test above for why sort_order 1 (not the
      # default 0, which build_minimal_exam!/2 already used).
      create_rule!(schema, exam.record_id, category_id, 1, 1)

      candidate_id = Ecto.UUID.generate()
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, outcome} = Session.submit(session_view.id, candidate_id, schema)
      assert outcome.status == :grading_pending
      assert outcome.passed == nil

      Process.sleep(0)
      _ = short_text_question
    end

    # ISS-0650: end-to-end proof that the candidate's actual submitted text
    # is what a human grader would see, not a hardcoded nil -- autosave a
    # real text_answer, submit (which routes the short_text question
    # through `Letflow.Modules.Exam.Scoring`'s `pending_manual` path), then read
    # the session's own `session_answer` state back via
    # `get_session_state_for_user/3` and confirm the exact text survived
    # the whole write -> score -> read round trip untouched.
    test "the candidate's real text_answer survives autosave -> submit (pending_manual) -> read back" do
      %{schema_name: schema} = tenant("req332-submit-pending-text")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      category_id = Ecto.UUID.generate()
      short_text_question = create_question!(schema, category_id, %{"type" => "shorttext"})
      create_rule!(schema, exam.record_id, category_id, 1, 1)

      candidate_id = Ecto.UUID.generate()
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      submitted_text = "Photosynthesis converts light energy into chemical energy."

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: short_text_question.record_id,
                   selected_option_ids: [],
                   text_answer: submitted_text,
                   time_spent_seconds: 45
                 },
                 schema
               )

      assert {:ok, outcome} = Session.submit(session_view.id, candidate_id, schema)
      assert outcome.status == :grading_pending
      assert outcome.passed == nil

      assert {:ok, state} =
               Session.get_session_state_for_user(session_view.id, candidate_id, schema)

      assert %{text_answer: ^submitted_text} =
               Map.fetch!(state.answers, short_text_question.record_id)
    end

    test "submission is idempotent: a second submit returns the recorded outcome without re-scoring" do
      %{schema_name: schema} = tenant("req332-submit-idempotent")
      %{exam: exam, questions: [{question_id, correct_id, _wrong}]} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: question_id,
                   selected_option_ids: [correct_id],
                   time_spent_seconds: 1
                 },
                 schema
               )

      assert {:ok, first_outcome} = Session.submit(session_view.id, candidate_id, schema)
      assert {:ok, second_outcome} = Session.submit(session_view.id, candidate_id, schema)

      assert first_outcome.percentage == second_outcome.percentage
      assert first_outcome.passed == second_outcome.passed

      import Ecto.Query

      score_rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where:
              r.entity_type == "session_question_score" and
                fragment("?->>?", r.field_values, "session_id") == ^session_view.id
          ),
          prefix: schema
        )

      # Exactly one score row per question -- re-submitting did not
      # re-score (which would have appended a second row per question,
      # since Records.create_record/2 mints a new record_id every call).
      assert length(score_rows) == 1
    end

    test "two CONCURRENT submits of the same session produce exactly one scored outcome (fails if row locking is removed)" do
      %{schema_name: schema} = tenant("req332-submit-concurrent")
      %{exam: exam, questions: [{question_id, correct_id, _wrong}]} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: question_id,
                   selected_option_ids: [correct_id],
                   time_spent_seconds: 1
                 },
                 schema
               )

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Session.submit(session_view.id, candidate_id, schema) end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.all?(results, &match?({:ok, _outcome}, &1))

      import Ecto.Query

      score_rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where:
              r.entity_type == "session_question_score" and
                fragment("?->>?", r.field_values, "session_id") == ^session_view.id
          ),
          prefix: schema
        )

      # Exactly one session_question_score row for the session's one
      # question -- if `lock("FOR UPDATE")` were removed from
      # Session.lock_session_row/2, both concurrent transactions could
      # observe status == "in_progress" simultaneously and both score and
      # persist, doubling this count.
      assert length(score_rows) == 1

      session_rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest,
            where: r.entity_type == "session" and r.record_id == ^session_view.id
          ),
          prefix: schema
        )

      assert [%{field_values: %{"status" => "submitted"}}] = session_rows
    end
  end

  # ---------------------------------------------------------------------
  # get_session_for_user/3 + tenant isolation
  # ---------------------------------------------------------------------

  describe "get_session_for_user/3 and tenant/ownership isolation" do
    test "a candidate cannot read another candidate's session" do
      %{schema_name: schema} = tenant("req332-cross-candidate")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      owner = Ecto.UUID.generate()
      intruder = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(owner, exam.record_id, schema)

      assert {:ok, _} = Session.get_session_for_user(session_view.id, owner, schema)

      assert {:error, :not_owner} =
               Session.get_session_for_user(session_view.id, intruder, schema)
    end

    test "a session in one tenant is invisible (not_found) when looked up under a different tenant's schema" do
      %{schema_name: schema_a} = tenant("req332-tenant-a")
      %{schema_name: schema_b} = tenant("req332-tenant-b")

      %{exam: exam_a} = build_minimal_exam!(schema_a)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam_a.record_id, schema_a)

      # Same candidate id, wrong tenant schema -- must not resolve at all.
      assert {:error, :session_not_found} =
               Session.get_session_for_user(session_view.id, candidate_id, schema_b)
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0631 -- session_status_atom/1 (replaces two unsafe
  # String.to_existing_atom/1 call sites, session.ex:865/911)
  # ---------------------------------------------------------------------

  describe "ISS-0631 -- session status atom mapping" do
    test "create/3 on a fresh session maps the persisted \"in_progress\" status to :in_progress" do
      # Functional regression test for the happy path -- NOT by itself proof
      # that the fix removed the load-order dependency (every other test in
      # this suite that touches session status runs in the same BEAM
      # instance and will already have interned :in_progress regardless of
      # whether this fix is correct). See the structural test below for the
      # test that actually proves that property.
      %{schema_name: schema} = tenant("iss0631-in-progress")
      %{exam: exam} = build_minimal_exam!(schema)

      assert {:ok, session_view} = Session.create(Ecto.UUID.generate(), exam.record_id, schema)
      assert session_view.status == :in_progress
    end

    test "auto_submitted: finalize_expired/3 on a still-open session maps the persisted status to :auto_submitted" do
      %{schema_name: schema} = tenant("iss0631-auto-submitted")
      %{exam: exam, questions: [{question_id, correct_id, _wrong}]} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: question_id,
                   selected_option_ids: [correct_id],
                   time_spent_seconds: 5
                 },
                 schema
               )

      deadline = DateTime.utc_now()

      assert {:ok, outcome} = Session.finalize_expired(session_view.id, deadline, schema)
      assert outcome.status == :auto_submitted
    end

    test "a corrupted persisted status string raises FunctionClauseError, not ArgumentError" do
      # Proves the "clear, explicit error" acceptance criterion: seeding a
      # status the entity definition's enum would never actually produce,
      # bypassing application-level validation, so get_session_for_user/3
      # reaches session_status_atom/1 with a string matching none of its
      # four clauses. Asserting the *specific* exception module is what
      # distinguishes "fixed" from "still calls String.to_existing_atom" --
      # both crash on a bad string, only the fixed version raises
      # FunctionClauseError instead of the opaque ArgumentError the old
      # to_existing_atom/1 call site produced.
      %{schema_name: schema} = tenant("iss0631-corrupted-status")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, session} =
               Letflow.Entities.Record.Latest.get(session_view.id, "session", schema)

      corrupted_attrs = Map.put(session.field_values, "status", "not_a_real_status")

      # Write directly against the entity_record_latest projection via its
      # own structural changeset -- Letflow.Entities.Records.update_record/2
      # enforces the entity definition's JSON-schema enum and would (rightly)
      # reject this value, so this bypasses that application-level
      # validation on purpose to seed a row session_status_atom/1 should
      # never see in a correctly-behaving system.
      assert {:ok, _} =
               session
               |> Letflow.Entities.Record.Latest.update_changeset(%{
                 field_values: corrupted_attrs
               })
               |> Letflow.Repo.update(prefix: schema)

      assert_raise FunctionClauseError, fn ->
        Session.get_session_for_user(session_view.id, candidate_id, schema)
      end
    end

    test "structural: session.ex no longer calls String.to_existing_atom/1 or String.to_atom/1 anywhere" do
      # This is the only test that can *honestly* prove the load-order
      # dependency is gone: every runtime test in this suite shares one BEAM
      # instance, so by the time any of them runs, :in_progress and the
      # other three status atoms are already interned as a side effect of
      # earlier tests -- a runtime test cannot distinguish "the fix removed
      # the dependency" from "the atom happened to already be interned by an
      # earlier test in the same run." Reading the module's own source text
      # and asserting neither unsafe conversion appears anywhere proves the
      # structural change directly, which is *why* the load-order dependency
      # is gone -- not a stylistic lint.
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/exam/session.ex"))

      refute source =~ "to_existing_atom"
      refute source =~ "to_atom("
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0648 design doc §2.2.1 / acceptance criterion 12 -- regression:
  # once `session_question` (a real §4 blast-radius entity type, declaring
  # `uq_session_question_session_id_question_id`) is activated, ISS-0648's
  # own fix (`Definitions.ensure_column_promotions/2`) now auto-promotes it
  # to a real per-entity-type table at "ddl_applied" -- which flips
  # `Letflow.Entities.Query.Compiler`'s read path (REQ-300, already shipped)
  # to project plain maps, not `%Letflow.Entities.Record.Latest{}` structs.
  # Before this file's own `fv/2` relaxation (session.ex:1041, from
  # `defp fv(%Latest{field_values: field_values}, key)` to
  # `defp fv(%{field_values: field_values}, key)`), every read of a
  # `session_question` row through `fv/2` -- reached via this module's own
  # `query_all/3` inside `get_session_state_for_user/3` -- raised
  # `FunctionClauseError`. `Letflow.ExamFixtures.provisioned_tenant_with_exam_definitions/1`
  # activates `session_question` with its real, undropped `constraints`
  # entry (only `foreign_keys` are stripped, deliberately, by that fixture --
  # see its own moduledoc -- so no real Postgres FK target table is needed
  # for this promotion to succeed), so this test's tenant setup alone is
  # what triggers the exact regression REVIEWER found empirically (42
  # failures in `test/letflow/exam/`), with no hand-rolled entity definition
  # needed.
  # ---------------------------------------------------------------------

  describe "ISS-0648 AC12 -- fv/2 reads a promoted session_question row correctly" do
    test "session_question is genuinely promoted (ddl_applied) and get_session_state_for_user/3 reads both rows via fv/2, not a raised FunctionClauseError" do
      %{tenant_id: tenant_id, schema_name: schema} = tenant("iss0648-ac12-session-question")

      %{exam: exam} = build_minimal_exam!(schema, pool_size: 2, count: 2)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      # Proves this is a genuine per-type-table promotion (the actual ISS-0648
      # blast radius), not merely a JSONB read -- if this assertion itself
      # ever regresses (e.g. `session_question` stops promoting on
      # activation), this test would silently stop proving anything, so it
      # is asserted explicitly rather than assumed.
      assert %Letflow.TenantProvisioning.ColumnPromotion{status: "ddl_applied"} =
               Repo.get_by(Letflow.TenantProvisioning.ColumnPromotion,
                 tenant_id: tenant_id,
                 entity_type: "session_question",
                 attribute: "session_id"
               )

      # Before the fv/2 fix: FunctionClauseError, because Compiler routes
      # session_question reads through {:per_type_table, _} ->
      # select_entity_row/1's plain-map projection once promoted, and the
      # old fv/2 clause only matched %Latest{}.
      assert {:ok, state} =
               Session.get_session_state_for_user(session_view.id, candidate_id, schema)

      assert length(state.questions) == 2

      for question_state <- state.questions do
        assert is_binary(question_state.question_id)
        assert is_integer(question_state.sort_order)
        assert question_state.type == :single
        assert length(question_state.options) == 2
      end

      # sort_order values are distinct across the two materialised rows --
      # real field_values read back correctly through fv/2 for each row, not
      # a single row's data duplicated by accident.
      assert state.questions |> Enum.map(& &1.sort_order) |> Enum.uniq() |> length() == 2
    end
  end

  # ---------------------------------------------------------------------
  # ISS-0674: session_view/1 exposes score_pct/passed across all four
  # statuses, so GET /modules/exam/exam-sessions/:id can render a candidate's
  # own already-computed result on a later reload (see
  # lib/letflow/design/iss0674-session-view-score-fields.md).
  # ---------------------------------------------------------------------

  describe "ISS-0674 -- session_view/1 score_pct/passed" do
    test ":in_progress -- both fields are nil (score_pct never persisted yet)" do
      %{schema_name: schema} = tenant("iss0674-in-progress")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)
      assert session_view.status == :in_progress
      assert session_view.score_pct == nil
      assert session_view.passed == nil
    end

    test ":submitted -- score_pct/passed carry the real persisted values on a later read" do
      %{schema_name: schema} = tenant("iss0674-submitted")

      %{exam: exam, questions: [{question_id, correct_id, _wrong_id}]} =
        build_minimal_exam!(schema)

      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: question_id,
                   selected_option_ids: [correct_id],
                   time_spent_seconds: 5
                 },
                 schema
               )

      assert {:ok, outcome} = Session.submit(session_view.id, candidate_id, schema)
      assert outcome.status == :submitted

      assert {:ok, reread} = Session.get_session_for_user(session_view.id, candidate_id, schema)
      assert reread.status == :submitted
      assert reread.score_pct == 100.0
      assert reread.passed == true
    end

    test ":auto_submitted -- score_pct/passed carry the real persisted values on a later read" do
      %{schema_name: schema} = tenant("iss0674-auto-submitted")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)
      # No autosave at all -- every question grades as wrong.

      deadline = DateTime.utc_now()
      assert {:ok, outcome} = Session.finalize_expired(session_view.id, deadline, schema)
      assert outcome.status == :auto_submitted

      assert {:ok, reread} = Session.get_session_for_user(session_view.id, candidate_id, schema)
      assert reread.status == :auto_submitted
      assert reread.score_pct == 0.0
      assert reread.passed == false
    end

    test ":grading_pending -- score_pct is present but passed stays nil (not yet a decided fact)" do
      %{schema_name: schema} = tenant("iss0674-grading-pending")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      category_id = Ecto.UUID.generate()
      create_question!(schema, category_id, %{"type" => "shorttext"})
      create_rule!(schema, exam.record_id, category_id, 1, 1)

      candidate_id = Ecto.UUID.generate()
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, outcome} = Session.submit(session_view.id, candidate_id, schema)
      assert outcome.status == :grading_pending

      assert {:ok, reread} = Session.get_session_for_user(session_view.id, candidate_id, schema)
      assert reread.status == :grading_pending
      assert reread.score_pct == 0.0
      assert reread.passed == nil
    end
  end

  # Q-1075 / GH #2432: the stored time per question is the bounded running total.
  defp q1075_save_time(ctx, seconds) do
    Session.autosave_answer(
      ctx.session_id,
      ctx.candidate_id,
      %{
        question_id: ctx.question_id,
        selected_option_ids: [ctx.correct_id],
        time_spent_seconds: seconds
      },
      ctx.schema
    )
  end

  defp q1075_stored_time(ctx) do
    assert {:ok, state} =
             Session.get_session_state_for_user(ctx.session_id, ctx.candidate_id, ctx.schema)

    state.answers[ctx.question_id].time_spent_seconds
  end

  describe "Q-1075 / GH #2432 -- time_spent_seconds is the bounded running total" do
    setup do
      %{schema_name: schema} = tenant("q1075-time-#{System.unique_integer([:positive])}")

      %{exam: exam, questions: [{question_id, correct_id, _wrong_id}]} =
        build_minimal_exam!(schema)

      candidate_id = Ecto.UUID.generate()
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      %{
        schema: schema,
        session_id: session_view.id,
        candidate_id: candidate_id,
        question_id: question_id,
        correct_id: correct_id
      }
    end

    test "a delayed save stores a non-zero time, and a later lower report never lowers it", ctx do
      # The stored value is clamped to the session's elapsed seconds, so wait long enough
      # for two whole seconds to have elapsed before the first save.
      Process.sleep(2_100)

      assert {:ok, _} = q1075_save_time(ctx, 2)
      assert q1075_stored_time(ctx) == 2

      assert {:ok, _} = q1075_save_time(ctx, 1)
      assert q1075_stored_time(ctx) == 2
    end

    test "an over-large report is clamped to the session's elapsed time, and the save still succeeds",
         ctx do
      assert {:ok, _} = q1075_save_time(ctx, 999_999)

      # The stored value is clamped to the session's elapsed seconds at save time. That is at most
      # the elapsed seconds measured now (the save happened earlier), so this is the upper bound.
      assert {:ok, state} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate_id, ctx.schema)

      elapsed_now = DateTime.diff(DateTime.utc_now(), state.session.started_at, :second)
      stored = state.answers[ctx.question_id].time_spent_seconds

      assert stored >= 0
      assert stored <= elapsed_now
      assert stored < 999_999
    end
  end
end
