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

  # GH #2682 / REQ-511: a question added to a session's `session_question` rows by hand, after
  # the session was created, is not in the session's snapshot; autosave reads the answer SHAPE
  # from the snapshot, so such a test must also give the snapshot an item for it (digest
  # recomputed). Only the type is read by autosave, so the key fields stay empty.
  defp add_snapshot_item!(schema, session_id, question_id, type) do
    ExamFixtures.rewrite_snapshot!(schema, session_id, fn snapshot ->
      snapshot
      |> Map.update!("order", &(&1 ++ [question_id]))
      |> put_in(["questions", question_id], %{
        "type" => type,
        "correct_option_ids" => [],
        "likert_options" => %{}
      })
    end)
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

    test "an already-open session -> {:session_already_open, that candidate's own open session id}" do
      %{schema_name: schema} = tenant("req332-elig-open")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"max_attempts" => 5})
      candidate_id = Ecto.UUID.generate()
      other_candidate_id = Ecto.UUID.generate()

      assert {:ok, first} = Session.create(candidate_id, exam.record_id, schema)

      # Another candidate's open session on the same exam is never the id returned to this one.
      assert {:ok, other} = Session.create(other_candidate_id, exam.record_id, schema)
      refute other.id == first.id

      assert {:error, {:session_already_open, open_id}} =
               Session.create(candidate_id, exam.record_id, schema)

      assert open_id == first.id
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
      assert Enum.count(results, &match?({:error, {:session_already_open, _id}}, &1)) == 1

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

      add_snapshot_item!(ctx.schema, ctx.session_id, short_text_question.record_id, "shorttext")

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

      add_snapshot_item!(ctx.schema, ctx.session_id, short_text_question.record_id, "shorttext")

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

      add_snapshot_item!(ctx.schema, ctx.session_id, short_text_question.record_id, "shorttext")

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

        add_snapshot_item!(ctx.schema, ctx.session_id, question.record_id, type)

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
      # bound must not bind here: the wait above makes elapsed exceed 10 seconds, so the reported
      # 10 is stored as-is. The bound itself is tested by the over-large clamp test further down.
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

    # GH #2682 / REQ-511: a broken bank entry is now caught when the exam is STARTED (the snapshot
    # builder validates every resolved question), not at submit time: the typed grading error
    # replaces the old `:question_without_correct_option` surfaced by a submit.
    test "a question with no correct option fails the START with a typed grading error naming the question, and creates no session" do
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

      assert {:error, {:grading_error, {:key_missing, broken_id}}} =
               Session.create(candidate_id, exam.record_id, schema)

      assert broken_id == broken_question.record_id

      import Ecto.Query

      assert Repo.aggregate(
               from(l in Letflow.Entities.Record.Latest, where: l.entity_type == "session"),
               :count,
               prefix: schema
             ) == 0
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
      # Wait so that at least 2 whole seconds have elapsed since started_at. Without the wait the
      # elapsed bound is typically 0, and a store-0 mutant would then pass (TEST-DESIGN-VALIDATOR G1).
      Process.sleep(2_100)

      assert {:ok, _} = q1075_save_time(ctx, 999_999)

      # The stored value is clamped to the session's elapsed seconds at save time: at least the 2
      # seconds waited above, and at most the elapsed seconds measured now (the save happened earlier).
      assert {:ok, state} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate_id, ctx.schema)

      elapsed_now = DateTime.diff(DateTime.utc_now(), state.session.started_at, :second)
      stored = state.answers[ctx.question_id].time_spent_seconds

      assert stored >= 2
      assert stored <= elapsed_now
      assert stored < 999_999
    end
  end

  # ---------------------------------------------------------------------
  # GH #2760 -- a soft-deleted exam cannot start a session and is not offered
  # (design: lib/letflow/design/gh2762-exam-soft-deleted-reads.md, section 3.1;
  # spec: test/specs/GH-2760.md)
  # ---------------------------------------------------------------------

  describe "GH #2760 -- soft-deleted exam on the START path" do
    defp count_rows(schema, entity_type) do
      import Ecto.Query

      Repo.aggregate(
        from(r in Letflow.Entities.Record.Latest, where: r.entity_type == ^entity_type),
        :count,
        prefix: schema
      )
    end

    test "T-60a: a soft-deleted exam whose status is still active -> :exam_not_active, nothing written" do
      %{schema_name: schema} = tenant("gh2760-deleted-active")
      %{exam: exam} = build_minimal_exam!(schema)
      ExamFixtures.delete_record!(schema, "exam", exam.record_id)

      assert {:error, :exam_not_active} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      assert count_rows(schema, "session") == 0
      assert count_rows(schema, "session_question") == 0
    end

    test "T-60a2: the deleted-exam refusal is the identical value a nonexistent exam id gets" do
      %{schema_name: schema} = tenant("gh2760-identical-nonexistent")
      %{exam: exam} = build_minimal_exam!(schema)
      ExamFixtures.delete_record!(schema, "exam", exam.record_id)
      candidate_id = Ecto.UUID.generate()

      deleted = Session.create(candidate_id, exam.record_id, schema)
      nonexistent = Session.create(candidate_id, Ecto.UUID.generate(), schema)

      assert deleted == nonexistent
      assert deleted == {:error, :exam_not_active}
    end

    test "T-60c: deleted AND archived -> :exam_not_active, never :exam_archived (no existence leak)" do
      %{schema_name: schema} = tenant("gh2760-deleted-archived")
      %{exam: exam} = build_minimal_exam!(schema, exam_attrs: %{"status" => "archived"})

      # Control: before the delete the archived exam is reported as archived.
      assert {:error, :exam_archived} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      ExamFixtures.delete_record!(schema, "exam", exam.record_id)

      assert {:error, :exam_not_active} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      assert count_rows(schema, "session") == 0
    end

    test "T-60d (guard): a live active exam still starts while a soft-deleted sibling exam exists" do
      %{schema_name: schema} = tenant("gh2760-live-with-deleted-sibling")
      %{exam: dead} = build_minimal_exam!(schema)
      %{exam: live} = build_minimal_exam!(schema)
      ExamFixtures.delete_record!(schema, "exam", dead.record_id)

      assert {:ok, view} = Session.create(Ecto.UUID.generate(), live.record_id, schema)
      assert view.exam_id == live.record_id
      assert view.status == :in_progress
    end

    test "T-60e (guard): a session started before its exam was deleted keeps working" do
      %{schema_name: schema} = tenant("gh2760-started-then-deleted")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()

      assert {:ok, view} = Session.create(candidate_id, exam.record_id, schema)
      ExamFixtures.delete_record!(schema, "exam", exam.record_id)

      assert {:ok, _} = Session.get_session_for_user(view.id, candidate_id, schema)
      assert {:ok, outcome} = Session.submit(view.id, candidate_id, schema)
      assert outcome.status == :submitted
    end

    # The delete-while-waiting race (a start blocked on the exam row's FOR UPDATE lock while a
    # delete commits) is deliberately NOT tested: DataCase runs this suite on one shared sandbox
    # connection, on which two processes' row locks never block each other, so the wait cannot be
    # produced deterministically. The predicate it relies on (the deleted condition sits inside the
    # locked WHERE, which Postgres re-evaluates after a lock wait) is exercised by T-60a..c, which
    # fail when it is removed.
  end

  describe "GH #2760 -- list_available_exams/2 does not offer a soft-deleted exam" do
    defp item_id(item), do: Map.get(item, :record_id) || Map.get(item, "record_id")

    test "T-60f: a soft-deleted active exam is absent, live active exams are present, shape unchanged" do
      %{schema_name: schema} = tenant("gh2760-list-excludes-deleted")
      %{exam: dead} = build_minimal_exam!(schema)
      %{exam: live} = build_minimal_exam!(schema)
      %{exam: archived} = build_minimal_exam!(schema, exam_attrs: %{"status" => "archived"})
      ExamFixtures.delete_record!(schema, "exam", dead.record_id)

      assert {:ok, %{items: items, next_cursor: cursor}} =
               Session.list_available_exams(schema, scope: :all)

      ids = Enum.map(items, &item_id/1)
      assert ids == [live.record_id]
      refute dead.record_id in ids
      refute archived.record_id in ids
      assert cursor == nil
    end

    test "T-60f2 (guard): with no deletion every active exam is still listed" do
      %{schema_name: schema} = tenant("gh2760-list-no-deletion")
      %{exam: a} = build_minimal_exam!(schema)
      %{exam: b} = build_minimal_exam!(schema)

      assert {:ok, %{items: items}} = Session.list_available_exams(schema, scope: :all)
      assert Enum.sort(Enum.map(items, &item_id/1)) == Enum.sort([a.record_id, b.record_id])
    end
  end

  # ---------------------------------------------------------------------
  # GH #2759 -- a soft-deleted question is not startable via a manual pin and is not drawn from
  # a random pool (design: lib/letflow/design/gh2762-exam-soft-deleted-reads.md, section 3.2;
  # spec: test/specs/GH-2759.md)
  # ---------------------------------------------------------------------

  describe "GH #2759 -- manual pin to a soft-deleted question" do
    test "T-59a: a pin to a deleted question (status still active) -> {:question_not_found, id}, nothing written" do
      %{schema_name: schema} = tenant("gh2759-pin-deleted")

      %{exam: exam, pinned_question_ids: [_live, dead_id]} =
        build_minimal_exam!(schema, mode: :manual, pool_size: 2)

      ExamFixtures.delete_record!(schema, "question", dead_id)

      assert {:error, {:question_not_found, ^dead_id}} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      assert count_rows(schema, "session") == 0
      assert count_rows(schema, "session_question") == 0
    end

    test "T-59c: the deleted-pin refusal has exactly the shape a pin to a nonexistent question gets" do
      %{schema_name: schema} = tenant("gh2759-pin-identical")

      %{exam: deleted_exam, pinned_question_ids: [dead_id]} =
        build_minimal_exam!(schema, mode: :manual, pool_size: 1)

      ExamFixtures.delete_record!(schema, "question", dead_id)

      missing_exam = create_exam!(schema, %{})
      missing_id = Ecto.UUID.generate()
      rule = create_rule!(schema, missing_exam.record_id, Ecto.UUID.generate(), 1, 0, "manual")
      create_manual_question!(schema, rule.record_id, missing_id, 0)

      deleted = Session.create(Ecto.UUID.generate(), deleted_exam.record_id, schema)
      missing = Session.create(Ecto.UUID.generate(), missing_exam.record_id, schema)

      # Same tuple shape, differing only in the id each pin named.
      assert deleted == {:error, {:question_not_found, dead_id}}
      assert missing == {:error, {:question_not_found, missing_id}}
    end

    test "T-59e (guard): a pin to a live question still starts while another exam's pin is deleted" do
      %{schema_name: schema} = tenant("gh2759-pin-live")

      %{exam: dead_exam, pinned_question_ids: [dead_id]} =
        build_minimal_exam!(schema, mode: :manual, pool_size: 1)

      %{exam: live_exam, pinned_question_ids: pinned} =
        build_minimal_exam!(schema, mode: :manual, pool_size: 2)

      ExamFixtures.delete_record!(schema, "question", dead_id)

      assert {:error, {:question_not_found, ^dead_id}} =
               Session.create(Ecto.UUID.generate(), dead_exam.record_id, schema)

      assert {:ok, view} = Session.create(Ecto.UUID.generate(), live_exam.record_id, schema)
      assert Enum.map(session_question_rows(schema, view.id), & &1["question_id"]) == pinned
    end

    test "T-59f (guard): a pin that is not a UUID is still {:question_not_found, id}" do
      %{schema_name: schema} = tenant("gh2759-pin-not-uuid")
      exam = create_exam!(schema, %{})
      rule = create_rule!(schema, exam.record_id, Ecto.UUID.generate(), 1, 0, "manual")
      create_manual_question!(schema, rule.record_id, "not-a-uuid", 0)

      assert {:error, {:question_not_found, "not-a-uuid"}} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    end
  end

  describe "GH #2759 -- a soft-deleted question is not drawn from a random pool" do
    test "T-59d: pool size == count with one deleted active question -> the resolver's undersized-pool error, nothing written" do
      %{schema_name: schema} = tenant("gh2759-pool-undersized")

      %{exam: exam, questions: [{dead_id, _, _} | _]} =
        build_minimal_exam!(schema, pool_size: 3, count: 3)

      ExamFixtures.delete_record!(schema, "question", dead_id)

      # Before the fix all three (the deleted one included) were drawn and the start succeeded.
      # Now the pool holds two, below the rule count, so the resolver refuses the whole start.
      assert {:error, :pool_underflow} =
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      assert count_rows(schema, "session") == 0
      assert count_rows(schema, "session_question") == 0
    end

    test "T-59g (guard): live pool questions are still all drawn when a deleted sibling is excluded" do
      %{schema_name: schema} = tenant("gh2759-pool-live")
      %{exam: exam, questions: questions} = build_minimal_exam!(schema, pool_size: 4, count: 3)
      [{dead_id, _, _} | live] = questions
      ExamFixtures.delete_record!(schema, "question", dead_id)
      live_ids = Enum.map(live, fn {id, _, _} -> id end)

      # The draw is random: with the deleted question still in the pool of 4 a single start misses
      # it 1 time in 4. Twenty independent starts make a regression slip through with probability
      # (1/4)^20, so this fails deterministically in practice if the pool filter is lost.
      for _ <- 1..20 do
        assert {:ok, view} = Session.create(Ecto.UUID.generate(), exam.record_id, schema)
        drawn = Enum.map(session_question_rows(schema, view.id), & &1["question_id"])

        assert Enum.sort(drawn) == Enum.sort(live_ids)
        refute dead_id in drawn
      end
    end
  end

  # ---------------------------------------------------------------------
  # GH #2762 -- a soft-deleted answer option is excluded from the START snapshot and from the
  # options shown to a NEW session; a start is refused only when a DRAWN question is left without
  # a live key (design: lib/letflow/design/gh2762-exam-soft-deleted-reads.md, section 3.3;
  # spec: test/specs/GH-2762.md). `Snapshot.live_options/3` itself is in
  # snapshot_live_options_test.exs; the late path and the start/late parity are in
  # snapshot_late_test.exs.
  # ---------------------------------------------------------------------

  # A question of `type` with options built from `option_specs` (`{is_correct, extra_attrs}`, in
  # sort order). Returns `%{id: question_id, option_ids: [..]}`.
  defp g62_question!(schema, category_id, type, option_specs) do
    question = create_question!(schema, category_id, %{"type" => type})

    option_ids =
      option_specs
      |> Enum.with_index()
      |> Enum.map(fn {{is_correct, attrs}, index} ->
        create_option!(schema, question.record_id, index, is_correct, attrs).record_id
      end)

    %{id: question.record_id, option_ids: option_ids}
  end

  # An exam with ONE manual rule pinning `question_ids` in order.
  defp g62_pin_exam!(schema, question_ids) do
    exam = create_exam!(schema, %{"max_attempts" => 50})
    rule = create_rule!(schema, exam.record_id, Ecto.UUID.generate(), 1, 0, "manual")

    question_ids
    |> Enum.with_index()
    |> Enum.each(fn {question_id, index} ->
      create_manual_question!(schema, rule.record_id, question_id, index)
    end)

    exam
  end

  # An exam with ONE random rule drawing `count` questions from `category_id`.
  defp g62_pool_exam!(schema, category_id, count) do
    exam = create_exam!(schema, %{"max_attempts" => 50})
    create_rule!(schema, exam.record_id, category_id, count)
    exam
  end

  defp g62_key_missing(question_id), do: {:error, {:grading_error, {:key_missing, question_id}}}

  defp g62_start!(schema, exam, seed \\ 1) do
    candidate = Ecto.UUID.generate()
    assert {:ok, view} = Session.create_with_seed(candidate, exam.record_id, schema, seed)
    {candidate, view}
  end

  defp g62_options_order(schema, session_id, question_id) do
    [row] =
      Enum.filter(session_question_rows(schema, session_id), &(&1["question_id"] == question_id))

    row["options_order"]
  end

  defp g62_item(schema, session_id, question_id),
    do: ExamFixtures.session_snapshot(schema, session_id)["questions"][question_id]

  defp g62_nothing_written!(schema) do
    assert count_rows(schema, "session") == 0
    assert count_rows(schema, "session_question") == 0
  end

  describe "GH #2762 -- START excludes soft-deleted options (incorrect ones never block)" do
    test "T-62a: a POOL question with a soft-deleted INCORRECT option starts; the id is in neither options_order nor the shown options, the key is unchanged" do
      %{schema_name: schema} = tenant("gh2762-62a")
      category = Ecto.UUID.generate()
      q = g62_question!(schema, category, "single", [{true, %{}}, {false, %{}}, {false, %{}}])
      [correct_id, wrong_kept, wrong_deleted] = q.option_ids
      exam = g62_pool_exam!(schema, category, 1)

      # Control: the snapshot of a start BEFORE the deletion.
      {_c0, before_view} = g62_start!(schema, exam)
      before_item = g62_item(schema, before_view.id, q.id)
      assert before_item["correct_option_ids"] == [correct_id]

      ExamFixtures.delete_record!(schema, "answer_option", wrong_deleted)

      {candidate, view} = g62_start!(schema, exam)
      item = g62_item(schema, view.id, q.id)

      assert item == before_item
      assert g62_options_order(schema, view.id, q.id) == [correct_id, wrong_kept]
      refute wrong_deleted in g62_options_order(schema, view.id, q.id)

      assert {:ok, %{questions: [%{options: shown}]}} =
               Session.get_session_state_for_user(view.id, candidate, schema)

      assert Enum.map(shown, & &1.id) == [correct_id, wrong_kept]
    end

    test "T-62b: a PINNED question with a soft-deleted INCORRECT option starts the same way" do
      %{schema_name: schema} = tenant("gh2762-62b")

      q =
        g62_question!(schema, Ecto.UUID.generate(), "single", [
          {true, %{}},
          {false, %{}},
          {false, %{}}
        ])

      [correct_id, wrong_kept, wrong_deleted] = q.option_ids
      exam = g62_pin_exam!(schema, [q.id])
      ExamFixtures.delete_record!(schema, "answer_option", wrong_deleted)

      {_candidate, view} = g62_start!(schema, exam)

      assert g62_item(schema, view.id, q.id)["correct_option_ids"] == [correct_id]
      assert g62_options_order(schema, view.id, q.id) == [correct_id, wrong_kept]
    end

    test "T-62c: SWAP on a pin -- old correct option deleted, new correct option added -> the start works, the new option is the key and scores correct" do
      %{schema_name: schema} = tenant("gh2762-62c")
      q = g62_question!(schema, Ecto.UUID.generate(), "single", [{true, %{}}, {false, %{}}])
      [old_correct, wrong] = q.option_ids
      exam = g62_pin_exam!(schema, [q.id])

      new_correct = create_option!(schema, q.id, 2, true).record_id
      ExamFixtures.delete_record!(schema, "answer_option", old_correct)

      {candidate, view} = g62_start!(schema, exam)

      assert g62_item(schema, view.id, q.id)["correct_option_ids"] == [new_correct]
      assert g62_options_order(schema, view.id, q.id) == [wrong, new_correct]
      refute old_correct in g62_options_order(schema, view.id, q.id)

      assert {:ok, _} =
               Session.autosave_answer(
                 view.id,
                 candidate,
                 %{question_id: q.id, selected_option_ids: [new_correct], time_spent_seconds: 1},
                 schema
               )

      assert {:ok, outcome} = Session.submit(view.id, candidate, schema)
      assert outcome.percentage == 100.0
      assert outcome.passed == true
    end

    test "T-62c2: SWAP in a pool, multiple-choice -- one of two correct options swapped -> the key is the live correct options only" do
      %{schema_name: schema} = tenant("gh2762-62c2")
      category = Ecto.UUID.generate()
      q = g62_question!(schema, category, "multiple", [{true, %{}}, {true, %{}}, {false, %{}}])
      [old_correct, kept_correct, _wrong] = q.option_ids
      exam = g62_pool_exam!(schema, category, 1)

      new_correct = create_option!(schema, q.id, 3, true).record_id
      ExamFixtures.delete_record!(schema, "answer_option", old_correct)

      {_candidate, view} = g62_start!(schema, exam)

      assert g62_item(schema, view.id, q.id)["correct_option_ids"] ==
               Enum.sort([kept_correct, new_correct])

      refute old_correct in g62_options_order(schema, view.id, q.id)
    end
  end

  describe "GH #2762 -- START refuses a DRAWN question left without a live key" do
    test "T-62d: a pin whose only correct option is soft-deleted -> {:key_missing, qid}, nothing written" do
      %{schema_name: schema} = tenant("gh2762-62d")
      q = g62_question!(schema, Ecto.UUID.generate(), "single", [{true, %{}}, {false, %{}}])
      exam = g62_pin_exam!(schema, [q.id])
      ExamFixtures.delete_record!(schema, "answer_option", hd(q.option_ids))

      assert g62_key_missing(q.id) ==
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      g62_nothing_written!(schema)
    end

    test "T-62d2: a pin with EVERY option soft-deleted (single) -> {:key_missing, qid}, nothing written" do
      %{schema_name: schema} = tenant("gh2762-62d2-single")
      q = g62_question!(schema, Ecto.UUID.generate(), "single", [{true, %{}}, {false, %{}}])
      exam = g62_pin_exam!(schema, [q.id])
      for id <- q.option_ids, do: ExamFixtures.delete_record!(schema, "answer_option", id)

      assert g62_key_missing(q.id) ==
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      g62_nothing_written!(schema)
    end

    test "T-62d2: a pin with EVERY option soft-deleted (likert) -> {:key_missing, qid}, nothing written" do
      %{schema_name: schema} = tenant("gh2762-62d2-likert")

      weighted = %{"likert_weight" => 1.0, "likert_polarity" => "positive"}

      q =
        g62_question!(schema, Ecto.UUID.generate(), "likert", [
          {false, weighted},
          {false, weighted}
        ])

      exam = g62_pin_exam!(schema, [q.id])
      for id <- q.option_ids, do: ExamFixtures.delete_record!(schema, "answer_option", id)

      assert g62_key_missing(q.id) ==
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      g62_nothing_written!(schema)
    end

    test "T-62d3: a refusal on a drawn pin that is NOT the first one names that pin, not the healthy first" do
      %{schema_name: schema} = tenant("gh2762-62d3")
      good = g62_question!(schema, Ecto.UUID.generate(), "single", [{true, %{}}, {false, %{}}])
      broken = g62_question!(schema, Ecto.UUID.generate(), "single", [{true, %{}}, {false, %{}}])
      exam = g62_pin_exam!(schema, [good.id, broken.id])
      ExamFixtures.delete_record!(schema, "answer_option", hd(broken.option_ids))

      assert g62_key_missing(broken.id) ==
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      g62_nothing_written!(schema)
    end

    test "T-62e: truefalse -- a soft-deleted CORRECT option with no live correct refuses; a soft-deleted INCORRECT one starts" do
      %{schema_name: schema} = tenant("gh2762-62e")

      refused =
        g62_question!(schema, Ecto.UUID.generate(), "truefalse", [{true, %{}}, {false, %{}}])

      built =
        g62_question!(schema, Ecto.UUID.generate(), "truefalse", [{true, %{}}, {false, %{}}])

      ExamFixtures.delete_record!(schema, "answer_option", hd(refused.option_ids))
      ExamFixtures.delete_record!(schema, "answer_option", List.last(built.option_ids))

      assert g62_key_missing(refused.id) ==
               Session.create(
                 Ecto.UUID.generate(),
                 g62_pin_exam!(schema, [refused.id]).record_id,
                 schema
               )

      {_candidate, view} = g62_start!(schema, g62_pin_exam!(schema, [built.id]))
      assert g62_item(schema, view.id, built.id)["correct_option_ids"] == [hd(built.option_ids)]
      assert g62_options_order(schema, view.id, built.id) == [hd(built.option_ids)]
    end

    test "T-62g: likert -- a soft-deleted weighted option is excluded and the start proceeds on the live options; a live option with a nil weight is still refused" do
      %{schema_name: schema} = tenant("gh2762-62g")
      weighted = fn w -> %{"likert_weight" => w, "likert_polarity" => "positive"} end

      ok_q =
        g62_question!(schema, Ecto.UUID.generate(), "likert", [
          {false, weighted.(1.0)},
          {false, weighted.(2.0)},
          {false, weighted.(3.0)}
        ])

      [kept_a, kept_b, deleted] = ok_q.option_ids
      ExamFixtures.delete_record!(schema, "answer_option", deleted)

      {_candidate, view} = g62_start!(schema, g62_pin_exam!(schema, [ok_q.id]))

      assert g62_item(schema, view.id, ok_q.id)["likert_options"] |> Map.keys() |> Enum.sort() ==
               Enum.sort([kept_a, kept_b])

      refute deleted in g62_options_order(schema, view.id, ok_q.id)

      nil_q =
        g62_question!(schema, Ecto.UUID.generate(), "likert", [
          {false, weighted.(1.0)},
          {false, weighted.(2.0)}
        ])

      ExamFixtures.force_field!(
        schema,
        "answer_option",
        hd(nil_q.option_ids),
        "likert_weight",
        {:put, nil}
      )

      assert g62_key_missing(nil_q.id) ==
               Session.create(
                 Ecto.UUID.generate(),
                 g62_pin_exam!(schema, [nil_q.id]).record_id,
                 schema
               )
    end

    test "T-62h / T-62h2: shorttext -- a soft-deleted option never blocks the start (GUARD) and is absent from options_order (RED on main)" do
      %{schema_name: schema} = tenant("gh2762-62h")
      q = g62_question!(schema, Ecto.UUID.generate(), "shorttext", [{false, %{}}, {false, %{}}])
      [deleted, kept] = q.option_ids
      ExamFixtures.delete_record!(schema, "answer_option", deleted)
      exam = g62_pin_exam!(schema, [q.id])

      {_candidate, view} = g62_start!(schema, exam)

      # T-62h: the start succeeded and built a snapshot; a shorttext item has no key.
      assert %{"type" => "shorttext", "correct_option_ids" => []} =
               g62_item(schema, view.id, q.id)

      # T-62h2
      assert g62_options_order(schema, view.id, q.id) == [kept]

      # A shorttext question left with NO live option at all is also never refused.
      empty = g62_question!(schema, Ecto.UUID.generate(), "shorttext", [{false, %{}}])
      ExamFixtures.delete_record!(schema, "answer_option", hd(empty.option_ids))
      {_c2, view2} = g62_start!(schema, g62_pin_exam!(schema, [empty.id]))
      assert g62_options_order(schema, view2.id, empty.id) == []
    end
  end

  describe "GH #2762 -- a broken POOL question blocks only the starts that DRAW it" do
    # A pool of three single-choice questions, the first of which has lost its only correct option.
    defp g62_broken_pool!(schema, count) do
      category = Ecto.UUID.generate()

      [broken | healthy] =
        for _ <- 1..3,
            do: g62_question!(schema, category, "single", [{true, %{}}, {false, %{}}])

      ExamFixtures.delete_record!(schema, "answer_option", hd(broken.option_ids))
      %{exam: g62_pool_exam!(schema, category, count), broken: broken, healthy: healthy}
    end

    test "T-62m: with count < pool size, a start whose draw misses the broken question succeeds, one that draws it is refused with that question's key_missing" do
      %{schema_name: schema} = tenant("gh2762-62m")
      %{exam: exam, broken: broken, healthy: healthy} = g62_broken_pool!(schema, 2)
      healthy_ids = Enum.map(healthy, & &1.id)

      # The draw is seeded, so each seed is deterministic; thirty seeds make both outcomes certain
      # in practice (each seed misses the broken question with probability 1/3).
      results =
        for seed <- 1..30 do
          {seed, Session.create_with_seed(Ecto.UUID.generate(), exam.record_id, schema, seed)}
        end

      {oks, errors} = Enum.split_with(results, fn {_seed, result} -> match?({:ok, _}, result) end)

      assert oks != [], "no seed missed the broken question"
      assert errors != [], "no seed drew the broken question"

      for {seed, {:ok, view}} <- oks do
        drawn = Enum.map(session_question_rows(schema, view.id), & &1["question_id"])
        assert {seed, Enum.sort(drawn)} == {seed, Enum.sort(healthy_ids)}
      end

      for {seed, result} <- errors do
        assert {seed, result} == {seed, g62_key_missing(broken.id)}
      end

      # Only the successful starts wrote anything.
      assert count_rows(schema, "session") == length(oks)
    end

    test "T-62n: count == pool size (the broken question is always drawn) -> {:key_missing, broken_qid}, nothing written" do
      %{schema_name: schema} = tenant("gh2762-62n")
      %{exam: exam, broken: broken} = g62_broken_pool!(schema, 3)

      for seed <- [1, 2, 3] do
        assert g62_key_missing(broken.id) ==
                 Session.create_with_seed(Ecto.UUID.generate(), exam.record_id, schema, seed)
      end

      g62_nothing_written!(schema)
    end

    test "T-62n2: two broken drawn questions -> the FIRST one in draw order is reported" do
      %{schema_name: schema} = tenant("gh2762-62n2")
      category = Ecto.UUID.generate()

      questions =
        for _ <- 1..3,
            do: g62_question!(schema, category, "single", [{true, %{}}, {false, %{}}])

      exam = g62_pool_exam!(schema, category, 3)

      # Control: the draw order for this seed while every question is still healthy.
      {_c, control} = g62_start!(schema, exam, 7)
      order = Enum.map(session_question_rows(schema, control.id), & &1["question_id"])
      assert Enum.sort(order) == Enum.sort(Enum.map(questions, & &1.id))
      [first, second, _third] = order

      for id <- [second, first] do
        q = Enum.find(questions, &(&1.id == id))
        ExamFixtures.delete_record!(schema, "answer_option", hd(q.option_ids))
      end

      assert g62_key_missing(first) ==
               Session.create_with_seed(Ecto.UUID.generate(), exam.record_id, schema, 7)
    end
  end

  describe "GH #2762 -- display of options for a session that is already running" do
    test "T-62l: an option deleted AFTER the start is still shown to that session (GUARD); a session started AFTER the deletion does not show it (RED on main)" do
      %{schema_name: schema} = tenant("gh2762-62l")
      category = Ecto.UUID.generate()
      q = g62_question!(schema, category, "single", [{true, %{}}, {false, %{}}, {false, %{}}])
      [correct_id, wrong_a, wrong_b] = q.option_ids
      exam = g62_pool_exam!(schema, category, 1)

      {early_candidate, early} = g62_start!(schema, exam)
      ExamFixtures.delete_record!(schema, "answer_option", wrong_b)

      # First half: the in-progress session keeps showing (and scoring against) what it captured.
      assert g62_options_order(schema, early.id, q.id) == [correct_id, wrong_a, wrong_b]

      assert {:ok, %{questions: [%{options: shown_early}]}} =
               Session.get_session_state_for_user(early.id, early_candidate, schema)

      assert Enum.map(shown_early, & &1.id) == [correct_id, wrong_a, wrong_b]

      # Second half: a session started after the deletion never lists it.
      {late_candidate, late} = g62_start!(schema, exam)
      assert g62_options_order(schema, late.id, q.id) == [correct_id, wrong_a]

      assert {:ok, %{questions: [%{options: shown_late}]}} =
               Session.get_session_state_for_user(late.id, late_candidate, schema)

      assert Enum.map(shown_late, & &1.id) == [correct_id, wrong_a]
    end
  end
end
