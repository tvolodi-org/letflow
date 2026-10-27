defmodule Letflow.Idempotency.SquatRemediationTest do
  @moduledoc """
  GH #2597 -- the audited single-key remediation (`Letflow.Idempotency.SquatRemediation`).
  Tests T4 (audit, remediate, re-audit, legitimate issuer succeeds, concurrent issuer), T5
  (refusals, validation, lock conflict, exact-key matching, tenant isolation), T6 (idempotent;
  the audit entry is written once and carries no payload content). Spec: `test/specs/GH-2597.md`.

  Real Postgres, `async: false` (the tenant fixtures switch the sandbox to `:auto`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.EventStore.Event
  alias Letflow.ExamFixtures
  alias Letflow.Identity.User
  alias Letflow.Idempotency.SquatAudit
  alias Letflow.Idempotency.SquatRemediation
  alias Letflow.Modules.Exam.Certificate
  alias Letflow.Modules.Exam.Session
  alias Letflow.Repo
  alias Letflow.SquatFixtures, as: F
  alias Letflow.TenantFixture

  @cert "certificate:issue:"
  @op "operator-1"

  defp tenant!(prefix \\ "gh2597-rem"), do: TenantFixture.provisioned_tenant!(slug_prefix: prefix)

  defp remediate(tid, key, op \\ @op), do: SquatRemediation.remediate(tid, key, op)

  # ── real-issuer world (exam, two candidates with submitted, passing sessions) ──

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2597-user-#{Ecto.UUID.generate()}",
      display_name: "GH-2597 User",
      email: "gh2597-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp exam_world!(slug) do
    %{tenant_id: tenant_id, schema_name: schema} =
      ExamFixtures.provisioned_tenant_with_exam_definitions(slug)

    category_id = Ecto.UUID.generate()

    exam =
      ExamFixtures.create_record!(schema, "exam", %{
        "title" => %{"en" => "GH-2597 Exam"},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 5,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => true
      })

    ExamFixtures.assign_all!(schema, exam.record_id)

    question =
      ExamFixtures.create_record!(schema, "question", %{
        "category_id" => category_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"}
      })

    correct =
      ExamFixtures.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => 0,
        "is_correct" => true,
        "text" => %{"en" => "Yes"}
      })

    ExamFixtures.create_record!(schema, "answer_option", %{
      "question_id" => question.record_id,
      "sort_order" => 1,
      "is_correct" => false,
      "text" => %{"en" => "No"}
    })

    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    %{tenant_id: tenant_id, schema: schema, exam: exam, question: question, correct: correct}
  end

  # A submitted, passed session for a fresh candidate: {candidate_id, session_id}.
  defp passed_session!(w) do
    candidate_id = insert_user!(w.schema).id
    {:ok, view} = Session.create(candidate_id, w.exam.record_id, w.schema)

    {:ok, _} =
      Session.autosave_answer(
        view.id,
        candidate_id,
        %{
          question_id: w.question.record_id,
          selected_option_ids: [w.correct.record_id],
          time_spent_seconds: 5
        },
        w.schema
      )

    {:ok, %{status: :submitted, passed: true}} = Session.submit(view.id, candidate_id, w.schema)
    {candidate_id, view.id}
  end

  # ---------------------------------------------------------------------------
  # T4
  # ---------------------------------------------------------------------------

  describe "T4 audit, remediate, re-audit, issue" do
    test "the squatted certificate key is found, removed, and the candidate can then be issued" do
      w = exam_world!("gh2597-t4")
      {legit_candidate, legit_sid} = passed_session!(w)
      {candidate, sid} = passed_session!(w)
      squatter = Ecto.UUID.generate()

      # The legitimate, unsquatted issuance for another session: must never be flagged.
      assert {:ok, %{first_issuance: true}} =
               Certificate.issue_or_get_for_user(legit_candidate, legit_sid, w.schema)

      key = @cert <> sid

      squat_record_id = Ecto.UUID.generate()

      squat =
        F.insert_squat!(w.schema, key,
          actor_id: squatter,
          payload: %{
            "entity_type" => "certificate",
            "record_id" => squat_record_id,
            "field_values" => %{"session_id" => sid}
          }
        )

      # The squatted candidate is locked out (the bug being remediated).
      assert {:error, _} = Certificate.issue_or_get_for_user(candidate, sid, w.schema)

      # 1. audit: exactly the squat
      assert {:ok, [f]} = SquatAudit.audit_tenant(w.tenant_id)

      assert %{
               key: ^key,
               verdict: :flagged,
               reason: :actor_mismatch,
               stored_actor: ^squatter,
               expected_actor: ^candidate
             } = f

      # 2. remediate
      assert {:ok, %{outcome: :removed, key: ^key}} = remediate(w.tenant_id, key)
      assert F.key_rows(w.schema, key) == 0

      # 3. re-audit: the removed key is gone, and the audit (which ran before the remediation
      #    and again after it) left no read-only setting on the connection
      assert {:ok, []} = SquatAudit.audit_tenant(w.tenant_id)

      # 4. the legitimate issuer now succeeds
      assert {:ok, view} = Certificate.issue_or_get_for_user(candidate, sid, w.schema)
      assert view.first_issuance == true
      assert view.session_id == sid

      # the squatter's event row is left in place (D2); the key text now has two events
      assert Repo.get_by(Event, [event_id: squat.event_id], prefix: w.schema)

      keys =
        Repo.all(from(e in Event, where: e.idempotency_key == ^key, select: e.actor_id),
          prefix: w.schema
        )

      assert Enum.sort(keys) == Enum.sort([squatter, candidate])

      # the audit chain entry
      assert [entry] = F.remediation_entries(w.schema)
      assert entry.resource_id == entry.before_state["row_id"]
      assert entry.resource_type == "event_idempotency"
      assert entry.actor_id == nil
      assert entry.after_state == %{"removed" => true, "rows_removed" => 1}
      assert entry.before_state["finding_ref"] == "GH #2597"
      refute inspect(entry.before_state) =~ key
      refute inspect(entry.after_state) =~ key
      refute entry.resource_id =~ key
      assert entry.before_state["operator"] == @op
      assert entry.before_state["stored_actor"] == squatter
      assert entry.before_state["expected_actor"] == candidate
      assert entry.before_state["reason"] == "actor_mismatch"
      assert entry.before_state["event_id"] == squat.event_id
      assert entry.before_state["squat_record_id"] == squat_record_id
      assert entry.before_state["squat_entity_type"] == "certificate"
      assert entry.before_state["event_type"] == "ENTITY_RECORD_CREATED"
      assert is_binary(entry.chain_hash)
      assert {:ok, :valid} = Audit.verify_chain(w.schema)
    end

    test "concurrent issuer: an issuer racing the remediation's delete completes once it commits" do
      w = exam_world!("gh2597-t4c")
      {candidate, sid} = passed_session!(w)
      key = @cert <> sid
      F.insert_squat!(w.schema, key, actor_id: Ecto.UUID.generate())

      parent = self()

      # Holds the delete of the squat row uncommitted, exactly the state a remediation
      # transaction is in between its DELETE and its COMMIT.
      remediation =
        Task.async(fn ->
          Repo.transaction(fn ->
            {1, _} =
              Repo.delete_all(from(i in "event_idempotency", where: i.idempotency_key == ^key),
                prefix: w.schema
              )

            send(parent, :deleted)

            receive do
              :commit -> :ok
            after
              15_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive :deleted, 5_000
      issuer = Task.async(fn -> Certificate.issue_or_get_for_user(candidate, sid, w.schema) end)

      # While the delete is uncommitted the issuer has not produced a certificate.
      assert Task.yield(issuer, 500) == nil
      send(remediation.pid, :commit)
      assert {:ok, :ok} = Task.await(remediation, 10_000)

      assert {:ok, %{first_issuance: true, session_id: ^sid}} = Task.await(issuer, 10_000)
      assert F.key_rows(w.schema, key) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # T5: refusals and validation
  # ---------------------------------------------------------------------------

  describe "T5 refusals" do
    test "a legitimate (clear) row is refused :not_flagged; nothing is written" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "timer_fired:ok"
      F.insert_squat!(s, key, actor_id: F.platform_actor(), event_type: "TIMER_FIRED")
      before = F.counts(s)

      assert {:error, {:not_flagged, %{verdict: :clear, key: ^key, schema: ^s}}} =
               remediate(tid, key)

      assert F.counts(s) == before
      assert F.remediation_entries(s) == []
    end

    test "a legitimate certificate row is refused" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      sid = Ecto.UUID.generate()
      F.put_session!(s, sid, owner)

      F.insert_squat!(s, @cert <> sid,
        actor_id: owner,
        payload: %{
          "entity_type" => "certificate",
          "record_id" => Ecto.UUID.generate(),
          "field_values" => %{"session_id" => sid}
        }
      )

      before = F.counts(s)
      assert {:error, {:not_flagged, %{verdict: :clear}}} = remediate(tid, @cert <> sid)
      assert F.counts(s) == before
    end

    for {key, reason} <- [
          {"entities-record-import:abc", :no_rule},
          {"req345-seed-abc", :no_rule},
          {"sys:abc", :reserved_prefix_present},
          {"script_run:b::sub_process_1::x", :derived_key},
          {"client:rec:someone:k", :no_rule}
        ] do
      test "report-only / unclassified key #{inspect(key)} is refused (#{reason}) and kept" do
        %{tenant_id: tid, schema_name: s} = tenant!()
        key = unquote(key)
        F.insert_squat!(s, key, actor_id: Ecto.UUID.generate(), event_type: "INSTANCE_STARTED")
        before = F.counts(s)

        assert {:error, {:not_flagged, %{verdict: :report_only, reason: unquote(reason)}}} =
                 remediate(tid, key)

        assert F.counts(s) == before
        assert F.remediation_entries(s) == []
      end
    end

    test "the audit listing returns the new action unfiltered and under every real filter (0051 D8 rule 3)" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:listed", actor_id: Ecto.UUID.generate())
      assert {:ok, %{outcome: :removed}} = remediate(tid, "script_run:listed")
      [entry] = F.remediation_entries(s)

      base = %{prefix: s, page_size: 50}

      # unfiltered
      assert {:ok, %{items: items}} = Audit.list_entries(base)

      assert Enum.any?(
               items,
               &(&1.id == entry.id and &1.action == "idempotency_squat.remediated")
             )

      # the filters list_entries really has (there is no action filter): resource type and id
      assert {:ok, %{items: [%{id: id}]}} =
               Audit.list_entries(Map.merge(base, %{resource_type: "event_idempotency"}))

      assert id == entry.id

      assert {:ok, %{items: [%{id: ^id}]}} =
               Audit.list_entries(Map.merge(base, %{resource_id: entry.resource_id}))

      # a filter for something else must not raise and must not return the entry
      assert {:ok, %{items: other}} =
               Audit.list_entries(Map.merge(base, %{resource_type: "user"}))

      refute Enum.any?(other, &(&1.id == entry.id))
    end

    test "a nonexistent key is :already_clear with no audit entry" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      before = F.counts(s)

      assert {:ok, %{outcome: :already_clear, key: "script_run:nope"}} =
               remediate(tid, "script_run:nope")

      assert F.counts(s) == before
    end

    test "an unregistered, malformed or non-binary tenant id is :unknown_tenant" do
      assert {:error, :unknown_tenant} = remediate(Ecto.UUID.generate(), "script_run:x")
      assert {:error, :unknown_tenant} = remediate("not-a-uuid", "script_run:x")
      assert {:error, :unknown_tenant} = remediate(nil, "script_run:x")
    end

    test "an invalid key is :invalid_key (empty, 256 bytes, NUL, invalid UTF-8, non-binary)" do
      %{tenant_id: tid} = tenant!()

      for bad <- ["", String.duplicate("a", 256), "script_run:\0x", <<255, 254>>, nil, :atom, 5] do
        assert {:error, :invalid_key} = remediate(tid, bad)
      end
    end

    test "a 255-byte key is accepted by validation" do
      %{tenant_id: tid} = tenant!()
      assert {:ok, %{outcome: :already_clear}} = remediate(tid, String.duplicate("a", 255))
    end

    test "an invalid operator is :invalid_operator and nothing is written" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())
      before = F.counts(s)

      for bad <- ["", "   ", String.duplicate("o", 101), "a\0b", <<255>>, nil, :op, 1] do
        assert {:error, :invalid_operator} = remediate(tid, "script_run:x", bad)
      end

      assert F.counts(s) == before
      assert remediate(tid, "script_run:x", String.duplicate("o", 100)) |> elem(0) == :ok
    end

    test "matching is exact: %, _ and trailing text never match another key" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      F.insert_squat!(s, "script_run:abc", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "script_run:100%", actor_id: Ecto.UUID.generate())
      before = F.counts(s)

      for probe <- [
            "script_run:%",
            "script_run:ab_",
            "script_run:abc ",
            "script_run:ABC",
            "script_run:1%",
            "script_run:"
          ] do
        assert {:ok, %{outcome: :already_clear}} = remediate(tid, probe), probe
      end

      assert F.counts(s) == before
      assert F.key_rows(s, "script_run:abc") == 1
      # ...while the literal key containing % is removed by exactly that key
      assert {:ok, %{outcome: :removed}} = remediate(tid, "script_run:100%")
      assert F.key_rows(s, "script_run:abc") == 1
    end

    test "a row lock held by another transaction past the 2s lock_timeout gives :lock_conflict, nothing written" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "script_run:locked"
      F.insert_squat!(s, key, actor_id: Ecto.UUID.generate())
      before = F.counts(s)
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s(SELECT 1 FROM "#{s}".event_idempotency WHERE idempotency_key = $1 FOR UPDATE),
              [key]
            )

            send(parent, :locked)

            receive do
              :release -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      assert_receive :locked, 5_000
      result = remediate(tid, key)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)

      assert result == {:error, :lock_conflict}
      assert F.counts(s) == before
      assert F.remediation_entries(s) == []

      # retry-safe: once the lock is gone the same call works
      assert {:ok, %{outcome: :removed}} = remediate(tid, key)
    end
  end

  # ---------------------------------------------------------------------------
  # T6 idempotency, the audit entry, isolation
  # ---------------------------------------------------------------------------

  describe "T6 idempotent, one audit entry, no payload content" do
    test "the second call is :already_clear and the audit row count stays 1" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "script_run:x"
      F.insert_squat!(s, key, actor_id: Ecto.UUID.generate())

      assert {:ok, %{outcome: :removed}} = remediate(tid, key)
      assert {:ok, %{outcome: :already_clear}} = remediate(tid, key)
      assert {:ok, %{outcome: :already_clear}} = remediate(tid, key)
      assert length(F.remediation_entries(s)) == 1
      assert F.counts(s).audit == 1
    end

    test "after the legitimate writer re-claims the key, a repeat is refused :not_flagged, nothing deleted" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "script_run:x"
      F.insert_squat!(s, key, actor_id: Ecto.UUID.generate())
      assert {:ok, %{outcome: :removed}} = remediate(tid, key)

      F.insert_squat!(s, key, actor_id: F.platform_actor(), event_type: "SCRIPT_RUN_RECORDED")
      assert {:error, {:not_flagged, %{verdict: :clear}}} = remediate(tid, key)
      assert F.key_rows(s, key) == 1
      assert length(F.remediation_entries(s)) == 1
    end

    test "the audit entry names ids, types and the operator but no payload or field_values content" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      key = "script_run:secret"
      marker = "PAYLOAD-SECRET-#{System.unique_integer([:positive])}"

      F.insert_squat!(s, key,
        actor_id: Ecto.UUID.generate(),
        payload: %{
          "entity_type" => "widget",
          "record_id" => Ecto.UUID.generate(),
          "field_values" => %{"title" => marker, "session_id" => marker}
        }
      )

      assert {:ok, %{outcome: :removed}} = remediate(tid, key, "op <b>")
      assert [entry] = F.remediation_entries(s)

      encoded =
        Jason.encode!(%{b: entry.before_state, a: entry.after_state, r: entry.resource_id})

      refute encoded =~ marker
      # the key text (client-chosen) appears nowhere in the entry
      refute encoded =~ key
      assert entry.before_state["finding_ref"] == "GH #2597"
      assert entry.after_state == %{"removed" => true, "rows_removed" => 1}
      refute Map.has_key?(entry.before_state, "payload")
      refute Map.has_key?(entry.before_state, "field_values")

      assert Enum.sort(Map.keys(entry.before_state)) ==
               Enum.sort(
                 ~w(finding_ref operator family row_id event_id event_type event_created_at
                            stored_actor expected_actor reason squat_entity_type squat_record_id)
               )

      assert entry.before_state["operator"] == "op <b>"
      assert entry.before_state["family"] == "script_run:"
      assert entry.before_state["event_created_at"] == DateTime.to_iso8601(F.created_at())
    end

    test "only the squat row is removed: its event, every other key and other families stay" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      squat = F.insert_squat!(s, "script_run:x", actor_id: Ecto.UUID.generate())
      F.insert_squat!(s, "script_run:y", actor_id: Ecto.UUID.generate())
      before = F.counts(s)

      assert {:ok, %{outcome: :removed}} = remediate(tid, "script_run:x")

      assert F.counts(s) == %{
               before
               | idempotency: before.idempotency - 1,
                 audit: before.audit + 1
             }

      assert Repo.get_by(Event, [event_id: squat.event_id], prefix: s)
      assert F.key_rows(s, "script_run:y") == 1
    end
  end

  describe "tenant isolation" do
    test "remediating tenant A never touches tenant B's row for the same key, nor writes B's audit" do
      %{tenant_id: a, schema_name: sa} = tenant!("gh2597-iso-a")
      %{tenant_id: b, schema_name: sb} = tenant!("gh2597-iso-b")
      key = "script_run:same-key"
      F.insert_squat!(sa, key, actor_id: Ecto.UUID.generate())
      F.insert_squat!(sb, key, actor_id: Ecto.UUID.generate())
      before_b = F.counts(sb)

      assert {:ok, %{outcome: :removed}} = remediate(a, key)

      assert F.key_rows(sa, key) == 0
      assert F.key_rows(sb, key) == 1
      assert F.counts(sb) == before_b
      assert F.remediation_entries(sb) == []
      assert [entry] = F.remediation_entries(sa)
      assert entry.tenant_id == a

      # the key exists only in B now: A answers already_clear, B still removes it
      assert {:ok, %{outcome: :already_clear}} = remediate(a, key)
      assert {:ok, %{outcome: :removed}} = remediate(b, key)
    end

    test "a key that exists only in tenant B is :already_clear when addressed to tenant A" do
      %{tenant_id: a} = tenant!("gh2597-iso-c")
      %{tenant_id: _b, schema_name: sb} = tenant!("gh2597-iso-d")
      F.insert_squat!(sb, "script_run:b-only", actor_id: Ecto.UUID.generate())

      assert {:ok, %{outcome: :already_clear}} = remediate(a, "script_run:b-only")
      assert F.key_rows(sb, "script_run:b-only") == 1
    end
  end

  describe "remediation runs the audit's rule evaluator inside a read-write transaction" do
    test "a flagged certificate key is removed even though classification reads through a writing view" do
      %{tenant_id: tid, schema_name: s} = tenant!()
      owner = Ecto.UUID.generate()
      sid = Ecto.UUID.generate()
      F.put_session!(s, sid, owner)
      key = @cert <> sid

      F.insert_squat!(s, key,
        actor_id: Ecto.UUID.generate(),
        payload: %{"entity_type" => "certificate", "field_values" => %{"session_id" => sid}}
      )

      # classification reads entity_record_latest; make that read perform an INSERT. If the
      # remediation transaction were read-only this would raise instead of removing the key.
      for sql <- [
            ~s|ALTER TABLE "#{s}".entity_record_latest RENAME TO entity_record_latest_real|,
            ~s|CREATE TABLE "#{s}".squat_probe (n int)|,
            ~s|CREATE FUNCTION "#{s}".probe_write() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN INSERT INTO "#{s}".squat_probe VALUES (1); RETURN true; END $$|,
            ~s|CREATE VIEW "#{s}".entity_record_latest AS SELECT * FROM "#{s}".entity_record_latest_real WHERE "#{s}".probe_write()|
          ] do
        Repo.query!(sql)
      end

      assert {:ok, %{outcome: :removed}} = remediate(tid, key)
      assert Repo.query!(~s|SELECT count(*) FROM "#{s}".squat_probe|).rows == [[1]]
    end
  end

  describe "remediable?/2 (GH #2668)" do
    @row_id "00000000-0000-0000-0000-000000000001"

    test "a flagged finding with reason nil is refused, not recorded as \"nil\"" do
      refute SquatRemediation.remediable?(
               %{verdict: :flagged, row_id: @row_id, reason: nil},
               @row_id
             )
    end

    test "a flagged finding with a reason for the locked row is remediable" do
      assert SquatRemediation.remediable?(
               %{verdict: :flagged, row_id: @row_id, reason: :wrong_event_type},
               @row_id
             )
    end

    test "unflagged findings and other rows are not remediable" do
      refute SquatRemediation.remediable?(
               %{verdict: :report_only, row_id: @row_id, reason: :no_rule},
               @row_id
             )

      refute SquatRemediation.remediable?(
               %{verdict: :flagged, row_id: "other", reason: :wrong_event_type},
               @row_id
             )
    end
  end
end
