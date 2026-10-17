defmodule Letflow.Modules.Exam.CertificateSnapshotTest do
  @moduledoc """
  GH #2682 / REQ-511 PR b, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 6,
  12.1 (T-09, T-10, T-11), 12.3 (T-25), 17.2, 17.6 and 18.5 (spec
  `test/specs/GH2682-exam-snapshot-pr-b.md`): `Letflow.Modules.Exam.Certificate` reads the exam
  facts (the certificate flag and the title) ONLY from the session's own snapshot, never from the
  live `exam` row, against a real provisioned tenant (DIRECTIVE T-1).

    * T-09 (certificate flag), T-10 (title), T-11 (no live exam read): one test per field class,
      "after start" being any edit between the session start and the certificate request.
    * T-55c: a snapshot without usable certificate facts is `:certificate_facts_missing`.
    * Legacy `submitted` sessions (no snapshot, record inserted before the cutover) get
      certificate-only `late_certificate` facts once, with one audit entry (T-25, T-58); a
      post-cutover session that lost its snapshot, a tenant that is not rolled out, a corrupt
      snapshot, a non-owner and a non-submitted session never get one.
    * N2 (SECURITY-REVIEWER): `certificate_enabled` is a REQUIRED boolean of the `exam` definition,
      so nil/absent cannot come from a validated write; if a row nevertheless holds nil the snapshot
      carries it and the certificate is `{:grading_error, :certificate_facts_missing}` (an HTTP 500
      with a constant body), no longer the old 409 `:exam_not_certifiable`.

  Legacy sessions are built by `Letflow.ExamFixtures.legacy_session!/2` (design 18.5).

  Runs against Postgres outside the sandbox transaction: `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.ExamStampFixtures, as: StampFx
  alias Letflow.Modules.Exam.Certificate
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Exam.Snapshot
  alias Letflow.Modules.Exam.Snapshot.Rollout

  @late_action "exam.session_snapshot_late"
  @original_title %{"en" => "Original Title"}

  # ── fixtures ───────────────────────────────────────────────────────────────────────────────

  defp tenant(slug), do: Fx.provisioned_tenant_with_exam_definitions(slug)

  # One certifiable (by default) exam with one single-choice question, a fresh tenant, a REAL
  # candidate user, a started session answered `correct` (or wrongly) and submitted.
  defp submitted!(slug, exam_attrs, answer) do
    %{schema_name: schema} = tenant(slug)
    category_id = Ecto.UUID.generate()

    exam =
      Fx.create_record!(
        schema,
        "exam",
        Map.merge(
          %{
            "title" => @original_title,
            "status" => "active",
            "time_limit_minutes" => 30,
            "passing_score_pct" => 60.0,
            "max_attempts" => 10,
            "shuffle_questions" => false,
            "shuffle_options" => false,
            "show_answers" => "never",
            "on_tab_switch" => "log",
            "certificate_enabled" => true
          },
          exam_attrs
        )
      )

    question =
      Fx.create_record!(schema, "question", %{
        "category_id" => category_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"}
      })

    [correct, wrong] =
      for {sort_order, is_correct} <- [{0, true}, {1, false}] do
        Fx.create_record!(schema, "answer_option", %{
          "question_id" => question.record_id,
          "sort_order" => sort_order,
          "is_correct" => is_correct,
          "text" => %{"en" => "Option #{sort_order}"}
        }).record_id
      end

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    candidate = StampFx.insert_user!(schema).id
    assert {:ok, view} = Session.create(candidate, exam.record_id, schema)

    chosen = if answer == :correct, do: correct, else: wrong

    assert {:ok, _} =
             Session.autosave_answer(
               view.id,
               candidate,
               %{
                 question_id: question.record_id,
                 selected_option_ids: [chosen],
                 time_spent_seconds: 0
               },
               schema
             )

    assert {:ok, %{status: :submitted}} = Session.submit(view.id, candidate, schema)

    %{
      schema: schema,
      exam: exam,
      q_id: question.record_id,
      correct: correct,
      wrong: wrong,
      candidate: candidate,
      session_id: view.id
    }
  end

  defp passed!(slug, exam_attrs), do: submitted!(slug, exam_attrs, :correct)

  defp issue(ctx),
    do: Certificate.issue_or_get_for_user(ctx.candidate, ctx.session_id, ctx.schema)

  defp session_fv(schema, session_id) do
    assert {:ok, row} = Latest.get(session_id, "session", schema)
    row.field_values
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp late_audit(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT actor_id::text, resource_id::text, after_state::text | <>
          ~s|FROM "#{schema}".audit_entries WHERE action = $1 ORDER BY timestamp|,
        [@late_action]
      )

    for [actor_id, resource_id, after_state] <- rows,
        do: %{
          actor_id: actor_id,
          resource_id: resource_id,
          after_state: Jason.decode!(after_state)
        }
  end

  defp hard_delete!(schema, entity_type, record_id) do
    assert {1, _} =
             Repo.delete_all(
               from(l in Latest,
                 where: l.entity_type == ^entity_type and l.record_id == ^record_id
               ),
               prefix: schema
             )

    :ok
  end

  defp state(ctx) do
    %{
      fv: session_fv(ctx.schema, ctx.session_id),
      events: event_count(ctx.schema),
      audit: length(late_audit(ctx.schema))
    }
  end

  defp grading(reason), do: {:error, {:grading_error, reason}}

  # ── T-09 / T-10 / T-11: one test per field class ───────────────────────────────────────────

  describe "T-09 exam.certificate_enabled" do
    test "enabled at start, disabled after the submit and before the request: the certificate IS issued" do
      ctx = passed!("gh2682-b-t09-on", %{"certificate_enabled" => true})
      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{"certificate_enabled" => false})

      assert {:ok, certificate} = issue(ctx)
      assert certificate.session_id == ctx.session_id
      assert certificate.first_issuance == true
    end

    test "disabled at start, enabled later: refused with :exam_not_certifiable" do
      ctx = passed!("gh2682-b-t09-off", %{"certificate_enabled" => false})
      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{"certificate_enabled" => true})

      assert {:error, :exam_not_certifiable} = issue(ctx)
    end
  end

  describe "T-10 exam.title" do
    test "a title edited after the start does not reach the certificate: exam_title is the snapshot's" do
      ctx = passed!("gh2682-b-t10", %{})

      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{
        "title" => %{"en" => "Renamed After Start"}
      })

      assert {:ok, certificate} = issue(ctx)
      assert certificate.exam_title == @original_title
    end

    test "the snapshot is the ONLY source: a snapshot with another title, the live title unchanged, decides the certificate" do
      ctx = passed!("gh2682-b-t10-source", %{})
      sentinel = %{"en" => "Title Only The Snapshot Has"}

      Fx.rewrite_snapshot!(ctx.schema, ctx.session_id, &put_in(&1, ["exam", "title"], sentinel))

      assert {:ok, certificate} = issue(ctx)
      assert certificate.exam_title == sentinel
    end
  end

  describe "T-11 the certificate path reads no live exam" do
    test "the live exam archived, soft-deleted or removed after the submit: issuance still succeeds" do
      archived = passed!("gh2682-b-t11-archived", %{})

      Fx.update_record!(archived.schema, "exam", archived.exam.record_id, %{
        "status" => "archived"
      })

      assert {:ok, %{exam_title: @original_title}} = issue(archived)

      soft = passed!("gh2682-b-t11-soft", %{})
      :ok = Fx.delete_record!(soft.schema, "exam", soft.exam.record_id)
      assert {:ok, %{exam_title: @original_title}} = issue(soft)

      gone = passed!("gh2682-b-t11-gone", %{})
      :ok = hard_delete!(gone.schema, "exam", gone.exam.record_id)
      assert {:ok, %{exam_title: @original_title}} = issue(gone)
    end

    test "a nil live flag and a deleted live title after the submit change nothing" do
      ctx = passed!("gh2682-b-t11-nil", %{})
      Fx.force_field!(ctx.schema, "exam", ctx.exam.record_id, "certificate_enabled", {:put, nil})
      Fx.force_field!(ctx.schema, "exam", ctx.exam.record_id, "title", :delete)

      assert {:ok, %{exam_title: @original_title}} = issue(ctx)
    end
  end

  # ── T-55c and N2: unusable facts ───────────────────────────────────────────────────────────

  describe "T-55c certificate facts that are not usable" do
    test "Snapshot.certificate_facts/1: a boolean flag and a present title are the only success" do
      ok = %{"exam" => %{"certificate_enabled" => true, "title" => "T"}}
      assert {:ok, %{certificate_enabled: true, title: "T"}} = Snapshot.certificate_facts(ok)

      assert {:ok, %{certificate_enabled: false, title: %{"en" => "T"}}} =
               Snapshot.certificate_facts(%{
                 "exam" => %{"certificate_enabled" => false, "title" => %{"en" => "T"}}
               })

      for bad <- [
            %{},
            %{"exam" => "x"},
            %{"exam" => %{}},
            %{"exam" => %{"title" => "T"}},
            %{"exam" => %{"certificate_enabled" => nil, "title" => "T"}},
            %{"exam" => %{"certificate_enabled" => "true", "title" => "T"}},
            %{"exam" => %{"certificate_enabled" => 1, "title" => "T"}},
            %{"exam" => %{"certificate_enabled" => true}},
            %{"exam" => %{"certificate_enabled" => true, "title" => nil}}
          ] do
        assert {bad, Snapshot.certificate_facts(bad)} ==
                 {bad, grading(:certificate_facts_missing)}
      end
    end

    test "a stored snapshot whose flag is not a boolean, or whose title is absent: the certificate is {:grading_error, :certificate_facts_missing}, nothing is issued" do
      ctx = passed!("gh2682-b-t55c", %{})
      pristine = Fx.session_snapshot(ctx.schema, ctx.session_id)

      forgeries = [
        &put_in(&1, ["exam", "certificate_enabled"], "yes"),
        &put_in(&1, ["exam", "certificate_enabled"], nil),
        &update_in(&1, ["exam"], fn exam -> Map.delete(exam, "title") end),
        &update_in(&1, ["exam"], fn exam -> Map.delete(exam, "certificate_enabled") end)
      ]

      for forge <- forgeries do
        Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => pristine})
        Fx.rewrite_snapshot!(ctx.schema, ctx.session_id, forge)

        assert grading(:certificate_facts_missing) == issue(ctx)
      end

      assert certificates(ctx.schema) == 0
    end

    test "N2 an exam row holding a nil certificate flag at the start: the snapshot carries the nil and the certificate is :certificate_facts_missing (was a 409 before GH #2682)" do
      ctx = passed!("gh2682-b-n2", %{})

      # certificate_enabled is `required: true, type: boolean` in the exam definition: only a
      # direct row write can leave it nil
      assert {:ok, exam_definition} =
               Letflow.Entities.Definitions.get_active_definition_by_name("exam", ctx.schema)

      assert %{"required" => true, "type" => "boolean"} =
               Enum.find(
                 exam_definition.definition_json["fields"],
                 &(&1["name"] == "certificate_enabled")
               )

      Fx.force_field!(ctx.schema, "exam", ctx.exam.record_id, "certificate_enabled", {:put, nil})

      candidate = StampFx.insert_user!(ctx.schema).id
      assert {:ok, view} = Session.create(candidate, ctx.exam.record_id, ctx.schema)
      assert Fx.session_snapshot(ctx.schema, view.id)["exam"]["certificate_enabled"] == nil

      assert {:ok, %{status: :submitted}} = Session.submit(view.id, candidate, ctx.schema)

      assert grading(:certificate_facts_missing) ==
               Certificate.issue_or_get_for_user(candidate, view.id, ctx.schema)
    end
  end

  defp certificates(schema) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == "certificate"), :count,
      prefix: schema
    )
  end

  # ── guards and ownership keep their meaning ────────────────────────────────────────────────

  describe "the guard order and ownership are unchanged" do
    test "not submitted -> :session_not_submitted; not passed -> :session_not_passed; both before and after the snapshot is read" do
      failed = submitted!("gh2682-b-guard-failed", %{}, :wrong)
      assert {:error, :session_not_passed} = issue(failed)

      open = passed!("gh2682-b-guard-open", %{})

      # a second, started-but-unsubmitted session of the same tenant/exam
      other = StampFx.insert_user!(open.schema).id

      assert {:ok, view} = Session.create(other, open.exam.record_id, open.schema)

      assert {:error, :session_not_submitted} =
               Certificate.issue_or_get_for_user(other, view.id, open.schema)
    end

    test "another candidate's session is :not_owner and a random id :session_not_found; neither writes a snapshot" do
      ctx = passed!("gh2682-b-owner", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      stranger = StampFx.insert_user!(ctx.schema).id
      before = state(ctx)

      assert {:error, :not_owner} =
               Certificate.issue_or_get_for_user(stranger, ctx.session_id, ctx.schema)

      assert {:error, :not_owner} =
               Session.get_snapshot_for_user(ctx.session_id, stranger, ctx.schema)

      assert {:error, :session_not_found} =
               Certificate.issue_or_get_for_user(stranger, Ecto.UUID.generate(), ctx.schema)

      assert {:error, :session_not_found} =
               Session.get_snapshot_for_user(Ecto.UUID.generate(), stranger, ctx.schema)

      assert state(ctx) == before
    end

    test "a corrupt stored snapshot is {:grading_error, :snapshot_corrupt}: no certificate, and it is not replaced" do
      ctx = passed!("gh2682-b-corrupt", %{})
      pristine = Fx.session_snapshot(ctx.schema, ctx.session_id)
      tampered = put_in(pristine, ["exam", "title"], %{"en" => "Forged"})
      Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => tampered})

      assert grading(:snapshot_corrupt) == issue(ctx)
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == tampered

      # also on a pre-cutover record: a present-but-bad snapshot is never healed
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => tampered})
      before = state(ctx)

      assert grading(:snapshot_corrupt) == issue(ctx)
      assert state(ctx) == before
      assert certificates(ctx.schema) == 0
    end
  end

  # ── legacy submitted sessions: late_certificate facts ──────────────────────────────────────

  describe "T-25 / T-58 a legacy submitted session gets certificate-only facts, once" do
    test "the certificate is issued from late_certificate facts: only exam_id, flag and title, one audit entry, a verified digest; a second request re-snapshots nothing" do
      ctx = passed!("gh2682-b-latecert", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      started_at = session_fv(ctx.schema, ctx.session_id)["started_at"]

      assert {:ok, certificate} = issue(ctx)
      assert certificate.exam_title == @original_title

      fv = session_fv(ctx.schema, ctx.session_id)
      snapshot = fv["exam_snapshot"]
      assert %{"origin" => "late_certificate", "taken_at" => _, "v" => 1} = snapshot

      assert snapshot["exam"] == %{
               "exam_id" => ctx.exam.record_id,
               "certificate_enabled" => true,
               "title" => @original_title
             }

      refute Map.has_key?(snapshot, "order")
      refute Map.has_key?(snapshot, "questions")
      assert {:ok, _verified} = Snapshot.fetch_verified(fv)

      assert [entry] = late_audit(ctx.schema)
      assert entry.resource_id == ctx.session_id
      assert entry.actor_id == ctx.candidate
      assert Enum.sort(Map.keys(entry.after_state)) == ~w(exam_id origin started_at taken_at)
      assert entry.after_state["origin"] == "late_certificate"
      assert entry.after_state["exam_id"] == ctx.exam.record_id
      assert entry.after_state["started_at"] == started_at
      assert entry.after_state["taken_at"] == snapshot["taken_at"]

      # a live edit between the two requests changes nothing: the facts were taken once
      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{
        "title" => %{"en" => "Renamed Later"},
        "certificate_enabled" => false
      })

      assert {:ok, again} = issue(ctx)
      assert again.exam_title == @original_title
      assert again.first_issuance == false
      assert session_fv(ctx.schema, ctx.session_id) == fv

      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == snapshot
      assert length(late_audit(ctx.schema)) == 1
    end

    test "the late facts are read from the live exam AT THE FIRST REQUEST (documented residual), then frozen" do
      ctx = passed!("gh2682-b-latecert-live", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{
        "title" => %{"en" => "Edited Before The First Request"}
      })

      assert {:ok, %{exam_title: %{"en" => "Edited Before The First Request"}}} = issue(ctx)

      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{
        "title" => %{"en" => "Edited After"}
      })

      assert {:ok, snapshot} =
               Session.get_snapshot_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot["exam"]["title"] == %{"en" => "Edited Before The First Request"}
    end

    test "get_snapshot_for_user/3 takes the facts once (one update event, one audit entry) and returns the stored snapshot afterwards" do
      ctx = passed!("gh2682-b-latecert-once", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      events = event_count(ctx.schema)

      assert {:ok, first} =
               Session.get_snapshot_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert first["origin"] == "late_certificate"
      assert event_count(ctx.schema) == events + 1

      assert {:ok, ^first} =
               Session.get_snapshot_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert {:ok, ^first} =
               Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)

      assert event_count(ctx.schema) == events + 1
      assert length(late_audit(ctx.schema)) == 1
    end

    test "legacy facts with the certificate disabled: :exam_not_certifiable (the facts are still taken, once)" do
      ctx = passed!("gh2682-b-latecert-off", %{"certificate_enabled" => false})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      assert {:error, :exam_not_certifiable} = issue(ctx)

      assert %{"origin" => "late_certificate", "exam" => %{"certificate_enabled" => false}} =
               Fx.session_snapshot(ctx.schema, ctx.session_id)
    end

    test "a tenant that is not rolled out refuses with {:snapshot_error, :definition_missing}, writes nothing, and works after the rollout" do
      ctx = passed!("gh2682-b-latecert-rollout", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      Fx.downgrade_session_definition!(ctx.schema)
      before = state(ctx)

      assert {:error, {:snapshot_error, :definition_missing}} == issue(ctx)

      assert {:error, {:snapshot_error, :definition_missing}} ==
               Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)

      assert state(ctx) == before

      assert %{status: :upgraded} = Rollout.run_tenant(ctx.schema, [])
      assert {:ok, %{exam_title: @original_title}} = issue(ctx)
    end

    test "a tenant without the snapshot restriction row refuses with {:snapshot_error, :restrictions_missing}" do
      ctx = passed!("gh2682-b-latecert-restriction", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      assert Fx.delete_answer_key_restrictions!(ctx.schema) == 5
      before = state(ctx)

      assert {:error, {:snapshot_error, :restrictions_missing}} == issue(ctx)
      assert state(ctx) == before
    end

    test "T-61 a submitted session of a POST-cutover record that lost its snapshot is :snapshot_missing: no facts, no write, no audit entry" do
      ctx = passed!("gh2682-b-latecert-t61", %{})
      Fx.force_field!(ctx.schema, "session", ctx.session_id, "exam_snapshot", :delete)
      before = state(ctx)

      assert grading(:snapshot_missing) == issue(ctx)

      assert grading(:snapshot_missing) ==
               Session.get_snapshot_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert grading(:snapshot_missing) ==
               Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)

      assert state(ctx) == before
      assert certificates(ctx.schema) == 0
    end

    test "legacy facts from a live exam that is gone, or holds a nil flag, are typed grading errors that write nothing" do
      gone = passed!("gh2682-b-latecert-gone", %{})
      :ok = Fx.legacy_session!(gone.schema, gone.session_id)
      :ok = hard_delete!(gone.schema, "exam", gone.exam.record_id)
      before = state(gone)

      assert grading(:exam_section_missing) == issue(gone)
      assert state(gone) == before

      nil_flag = passed!("gh2682-b-latecert-nilflag", %{})
      :ok = Fx.legacy_session!(nil_flag.schema, nil_flag.session_id)

      Fx.force_field!(
        nil_flag.schema,
        "exam",
        nil_flag.exam.record_id,
        "certificate_enabled",
        {:put, nil}
      )

      before = state(nil_flag)

      assert grading(:certificate_facts_missing) == issue(nil_flag)
      assert state(nil_flag) == before
    end

    test "a failing audit insert rolls the facts back: no snapshot, no event, no certificate" do
      ctx = passed!("gh2682-b-latecert-audit", %{})
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      Repo.query!(
        ~s|ALTER TABLE "#{ctx.schema}".audit_entries ADD CONSTRAINT gh2682_block_late_audit | <>
          ~s|CHECK (action <> '#{@late_action}')|
      )

      before = state(ctx)

      raised? =
        try do
          issue(ctx)
          false
        rescue
          _error in [Ecto.ConstraintError, Postgrex.Error] -> true
        end

      assert raised?
      assert state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil
      assert certificates(ctx.schema) == 0
    end
  end
end
