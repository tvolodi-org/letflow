defmodule Letflow.Modules.Exam.StampedTenantTest do
  @moduledoc """
  GH #2596 T-04, T-05 (AC2, AC6), design `lib/letflow/design/gh2596-exam-managed-types.md` sections
  5.4 and 14 (spec `test/specs/GH2596-exam-managed.md`): on a tenant whose six runtime definitions
  are STAMPED `managed_by = 'exam'`, the exam module's own flows keep working (each of the five
  `Records` write sites passes the exam `Owner`), while a plain tenant write, or an `Owner` of any
  other module id, is refused.

  Order matters: the authoring content (exam, question, options, rule: unmanaged types) is
  created first, then `Stamp.run_tenant/2` stamps the tenant, then the flows run. The existing
  exam suites (session, scoring, certificate, anti_cheat) run unchanged on UNSTAMPED tenants; this
  file is the stamped-tenant counterpart.

  Runs OUTSIDE the Ecto sandbox transaction: `async: false`, and the fixture switches the sandbox
  to `:auto`, because `Stamp` refuses to run inside a transaction (SECURITY F-1).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ManagedTypes.Owner
  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Exam.AntiCheat
  alias Letflow.Modules.Exam.Certificate
  alias Letflow.Modules.Exam.Session

  defp count(schema, entity_type) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == ^entity_type), :count,
      prefix: schema
    )
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp stamped_tenant! do
    %{schema_name: schema} = tenant = Fx.legacy_tenant!("gh2596-stamped")
    content = Fx.build_exam!(schema)
    candidate = Fx.insert_user!(schema)

    # 12 = 6 runtime types + 6 authoring types that build_exam! creates (answer_option, category,
    # exam, exam_manual_question, exam_question_rule, question). The other four authoring types
    # (exam_section, exam_question_rule_tag, question_tag, tag) have no row here, so are not stamped.
    assert %{status: :stamped, rows_stamped: 12, error: nil} = Stamp.run_tenant(schema, [])

    built_authoring =
      ~w(answer_option category exam exam_manual_question exam_question_rule question)

    for name <- Fx.runtime_types() ++ built_authoring do
      assert {:ok, "exam"} = ManagedTypes.owner_of(name, schema)
    end

    Map.merge(tenant, %{content: content, candidate: candidate})
  end

  describe "T-04 (AC6): the exam module's own flows on a stamped tenant" do
    test "start, save (create AND update path), signal, submit, issue and re-issue a certificate all succeed and persist" do
      %{
        schema_name: schema,
        content: %{exam: exam, question_id: question_id, correct_id: correct_id},
        candidate: candidate
      } = stamped_tenant!()

      # session + session_question writes (write_record/4)
      assert {:ok, view} = Session.create(candidate.id, exam.record_id, schema)
      assert count(schema, "session") == 1
      assert count(schema, "session_question") == 1

      attrs = %{
        question_id: question_id,
        selected_option_ids: [correct_id],
        time_spent_seconds: 3
      }

      # session_answer: first save creates the row, the second takes the update path (session.ex 1064)
      assert {:ok, _} = Session.autosave_answer(view.id, candidate.id, attrs, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 view.id,
                 candidate.id,
                 %{attrs | time_spent_seconds: 9},
                 schema
               )

      assert count(schema, "session_answer") == 1

      # session_event (anti_cheat.ex)
      assert {:ok, %{action_taken: :log, event_count: 1}} =
               AntiCheat.record_signal(view.id, candidate.id, :tab_switch, schema)

      assert count(schema, "session_event") == 1

      # submit: session update (session.ex 1263) + session_question_score writes
      assert {:ok, %{status: :submitted, passed: true}} =
               Session.submit(view.id, candidate.id, schema)

      assert {:ok, session} = Latest.get(view.id, "session", schema)
      assert session.field_values["status"] == "submitted"
      assert session.field_values["passed"] == true
      assert count(schema, "session_question_score") == 1

      # certificate create (certificate.ex) and idempotent re-issue
      assert {:ok, %{first_issuance: true} = certificate} =
               Certificate.issue_or_get_for_user(candidate.id, view.id, schema)

      assert {:ok, %{first_issuance: false} = again} =
               Certificate.issue_or_get_for_user(candidate.id, view.id, schema)

      assert again.id == certificate.id
      assert count(schema, "certificate") == 1
    end
  end

  describe "T-05 (AC2): only the exam Owner writes a stamped type" do
    test "a plain tenant write (/2) and an Owner of another module id are refused, with no event" do
      %{schema_name: schema, candidate: candidate} = stamped_tenant!()
      before_events = event_count(schema)
      before_sessions = count(schema, "session")

      now = DateTime.utc_now()

      attrs = %{
        entity_type: "session",
        field_values: %{
          "exam_id" => Ecto.UUID.generate(),
          "user_id" => candidate.id,
          "status" => "in_progress",
          "seed" => 1,
          "started_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(DateTime.add(now, 60, :second)),
          "passed" => false
        },
        actor_id: candidate.id,
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:error, :entity_type_managed} = Records.create_record(attrs, schema)
      assert {:error, :entity_type_managed} = Records.create_record(attrs, schema, :tenant)

      other = %Owner{module_id: "other_module", manages: MapSet.new(["session"])}
      assert {:error, :entity_type_managed} = Records.create_record(attrs, schema, other)

      forged_exam_claim = %Owner{
        module_id: "other_module",
        manages: MapSet.new(Fx.runtime_types())
      }

      assert {:error, :entity_type_managed} =
               Records.create_record(
                 %{attrs | idempotency_key: Ecto.UUID.generate()},
                 schema,
                 forged_exam_claim
               )

      assert event_count(schema) == before_events
      assert count(schema, "session") == before_sessions
    end

    test "the genuine exam Owner writes the same attrs" do
      %{schema_name: schema, candidate: candidate} = stamped_tenant!()

      now = DateTime.utc_now()

      attrs = %{
        entity_type: "session",
        field_values: %{
          "exam_id" => Ecto.UUID.generate(),
          "user_id" => candidate.id,
          "status" => "in_progress",
          "seed" => 1,
          "started_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(DateTime.add(now, 60, :second)),
          "passed" => false
        },
        actor_id: candidate.id,
        idempotency_key: Ecto.UUID.generate()
      }

      owner = ManagedTypes.owner_for!(Letflow.Modules.Exam)

      assert {:ok, %{record: %{entity_type: "session"}}} =
               Records.create_record(attrs, schema, owner)
    end
  end
end
