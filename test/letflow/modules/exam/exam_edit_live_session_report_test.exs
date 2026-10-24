defmodule Letflow.Modules.Exam.ExamEditLiveSessionReportTest do
  @moduledoc """
  GH #2683 / REQ-512 (T-01..T-16 of the design in the task folder): the read-only report
  `docs/runbooks/gh2683-exam-edit-live-session-report.sql` lists authoring edits made while an exam
  had a live session.

  The test executes the SQL file itself, inside a read-only transaction, against two fixture tenants
  built with `Letflow.ExamStampFixtures.full_tenant!/1`. The fixture rows are raw `events` rows
  (same shape as `Letflow.Entities.Records` writes: `entity_type`, `entity_def_version`,
  `record_id`, and `field_values` for CREATED and UPDATED), inserted in chronological order so
  `global_seq` agrees with time.

  Runs OUTSIDE the Ecto sandbox (`async: false`): the fixtures commit real DDL and rows, and the
  report runs its own transaction. Every assertion is on the fixture's own ids; sibling tests'
  tenants on the shared database never affect them.
  """

  # ExUnit.Case, not DataCase: the fixtures commit real rows and need the sandbox in :auto mode
  # (setup_all cannot check out a sandbox connection that its on_exit teardown can still use).
  use ExUnit.Case, async: false

  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Exam.Authoring
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  @report "docs/runbooks/gh2683-exam-edit-live-session-report.sql"
  @columns ~w(tenant_id section exam_id entity_type record_id actor_id occurred_at event_type)
  @marker "MARKER-gh2683-field-value"
  @base ~N[2026-10-01 10:00:00]

  # ── timeline ───────────────────────────────────────────────────────────────────────────────
  # t0 setup records, t1 sessions start, t2..t4 rule changes, t5 the edits under test,
  # t6 a session that starts after the edit.
  defp at(minutes), do: NaiveDateTime.add(@base, minutes * 60, :second)
  defp iso(naive), do: NaiveDateTime.to_iso8601(naive) <> "Z"
  defp uuid, do: Ecto.UUID.generate()

  # ── event helpers ──────────────────────────────────────────────────────────────────────────

  defp record_payload(type, record_id, nil) do
    %{"entity_type" => type, "entity_def_version" => "1", "record_id" => record_id}
  end

  defp record_payload(type, record_id, field_values) do
    type
    |> record_payload(record_id, nil)
    |> Map.put("field_values", Map.put(field_values, "note", @marker))
  end

  # Inserts one events row through the schemaless Repo with an explicit prefix (no SQL text is
  # built from the tenant schema name).
  defp event!(schema, actor, at, type, payload, event_id \\ uuid()) do
    Repo.insert_all(
      "events",
      [
        %{
          event_id: Ecto.UUID.dump!(event_id),
          created_at: at,
          instance_id: Ecto.UUID.dump!(uuid()),
          event_type: type,
          payload: payload,
          actor_id: Ecto.UUID.dump!(actor),
          sequence_number: 1,
          idempotency_key: "gh2683-" <> uuid(),
          metadata: %{}
        }
      ],
      prefix: schema
    )

    event_id
  end

  defp create!(schema, actor, at, type, record_id, fv) do
    event!(schema, actor, at, "ENTITY_RECORD_CREATED", record_payload(type, record_id, fv))
  end

  defp update!(schema, actor, at, type, record_id, fv) do
    event!(schema, actor, at, "ENTITY_RECORD_UPDATED", record_payload(type, record_id, fv))
  end

  defp delete!(schema, actor, at, type, record_id) do
    event!(schema, actor, at, "ENTITY_RECORD_DELETED", record_payload(type, record_id, nil))
  end

  # An UPDATED event over 4096 bytes: the events row keeps a {"$ref"} and the body is stored in
  # event_payload_store, the path the report's COALESCE must follow.
  defp oversize_update!(schema, actor, at, type, record_id, fv) do
    event_id = uuid()

    body =
      record_payload(type, record_id, Map.put(fv, "description", String.duplicate("x", 5000)))

    event!(schema, actor, at, "ENTITY_RECORD_UPDATED", %{"$ref" => event_id}, event_id)

    Repo.insert_all(
      "event_payload_store",
      [
        %{
          id: Ecto.UUID.dump!(uuid()),
          event_id: Ecto.UUID.dump!(event_id),
          event_created_at: at,
          payload: body,
          byte_size: 5100,
          inserted_at: at
        }
      ],
      prefix: schema
    )
  end

  defp session_fv(exam_id, status, started, expires, user_id) do
    %{
      "exam_id" => exam_id,
      "status" => status,
      "started_at" => iso(started),
      "expires_at" => iso(expires),
      "user_id" => user_id
    }
  end

  # A complete exam `field_values` map for `Authoring.create/2` (as `exam_authoring_test.exs`).
  defp exam_fv(title) do
    %{
      "title" => %{"en" => title},
      "status" => "draft",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────────────────────

  # Tenant A carries every case of the design; tenant B carries one live edit of its own, so the
  # isolation test has rows on both sides.
  defp build_tenant_a(schema, actor, ids) do
    %{
      exam1: e1,
      exam2: e2,
      exam3: e3,
      exam4: e4,
      exam5: e5,
      exam6: e6,
      exam7: e7,
      exam9: e9,
      exam10: e10,
      exam11: e11
    } = ids

    # t0: rules and sections exist before any session starts
    create!(schema, actor, at(0), "exam_section", ids.sec2, %{"exam_id" => e2})
    create!(schema, actor, at(0), "exam_section", ids.sec7, %{"exam_id" => e7})
    create!(schema, actor, at(0), "exam_section", ids.sec11, %{"exam_id" => e11})
    create!(schema, actor, at(0), "exam_question_rule", ids.rule1, %{"exam_id" => e1})
    create!(schema, actor, at(0), "exam_question_rule", ids.rule9, %{"exam_id" => e9})

    # t1: candidate sessions start (session records carry exam_id, status, started_at, expires_at)
    user = uuid()
    s1 = ids.session1
    session_at = at(1)

    create!(
      schema,
      actor,
      session_at,
      "session",
      s1,
      session_fv(e1, "in_progress", session_at, at(60), user)
    )

    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session3,
      session_fv(e3, "grading_pending", at(1), at(60), user)
    )

    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session4,
      session_fv(e4, "in_progress", at(1), at(2), user)
    )

    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session5,
      session_fv(e5, "in_progress", at(1), at(60), user)
    )

    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session7,
      session_fv(e7, "in_progress", at(1), at(60), user)
    )

    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session9,
      session_fv(e9, "in_progress", at(1), at(60), user)
    )

    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session11,
      session_fv(e11, "in_progress", at(1), at(60), user)
    )

    # t2: session 5 is submitted before the edits (its latest event decides it is not live)
    update!(
      schema,
      actor,
      at(2),
      "session",
      ids.session5,
      session_fv(e5, "submitted", at(1), at(60), user)
    )

    # t3: a manual question on rule 9 while exam 9 is live (listed via the rule)
    create!(schema, actor, at(3), "exam_manual_question", ids.mq9, %{"rule_id" => ids.rule9})

    # t4: rule 9 moves to exam 10, after the edit above (the edit stays under exam 9)
    update!(schema, actor, at(4), "exam_question_rule", ids.rule9, %{"exam_id" => e10})

    # t5: the edits under test
    update!(schema, actor, at(5), "exam", e1, %{"title" => "E1"})
    update!(schema, actor, at(5), "exam_section", ids.sec2, %{"exam_id" => e2})
    update!(schema, actor, at(5), "exam_section", ids.sec3, %{"exam_id" => e3})
    update!(schema, actor, at(5), "exam", e4, %{"title" => "E4"})
    update!(schema, actor, at(5), "exam", e5, %{"title" => "E5"})
    update!(schema, actor, at(5), "exam", e6, %{"title" => "E6"})
    create!(schema, actor, at(5), "exam_manual_question", ids.mq1, %{"rule_id" => ids.rule1})
    update!(schema, actor, at(5), "question", ids.question1, %{"text" => "Q1"})
    delete!(schema, actor, at(5), "exam_manual_question", ids.mq0)
    delete!(schema, actor, at(5), "exam_section", ids.sec7)
    delete!(schema, actor, at(5), "exam_section", ids.sec12)
    oversize_update!(schema, actor, at(5), "exam_section", ids.sec11, %{"exam_id" => e11})

    # t6: session 6 starts after the edit to exam 6 above
    create!(
      schema,
      actor,
      at(6),
      "session",
      ids.session6,
      session_fv(e6, "in_progress", at(6), at(60), user)
    )
  end

  defp build_tenant_b(schema, actor, ids) do
    create!(
      schema,
      actor,
      at(1),
      "session",
      ids.session8,
      session_fv(ids.exam8, "in_progress", at(1), at(60), uuid())
    )

    update!(schema, actor, at(5), "exam", ids.exam8, %{"title" => "E8"})
  end

  defp ids do
    for name <- ~w(exam1 exam2 exam3 exam4 exam5 exam6 exam7 exam8 exam9 exam10 exam11 sec2 sec3
                   sec7 sec11 sec12 rule1 rule9 mq0 mq1 mq9 question1 session1 session3 session4
                   session5 session6 session7 session8 session9 session11),
        into: %{},
        do: {String.to_atom(name), uuid()}
  end

  defp run_report do
    sql = File.read!(Path.join(File.cwd!(), @report))

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION READ ONLY")
        Repo.query!(sql)
      end)

    {result.columns, Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))}
  end

  setup_all do
    # The module sets its own mode (GH #2424) instead of inheriting the fixtures' leftover :auto.
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    a = Fx.full_tenant!("gh2683-a")
    b = Fx.full_tenant!("gh2683-b")
    actor_a = Fx.insert_user!(a.schema_name).id
    actor_b = Fx.insert_user!(b.schema_name).id

    ids = ids()
    build_tenant_a(a.schema_name, actor_a, ids)
    build_tenant_b(b.schema_name, actor_b, ids)

    {columns, rows} = run_report()

    {:ok,
     a: a.tenant_id,
     a_schema: a.schema_name,
     b: b.tenant_id,
     ids: ids,
     columns: columns,
     rows: rows}
  end

  # The report's rows for one record id, from either fixture tenant.
  defp rows_for(ctx, record_id), do: Enum.filter(ctx.rows, &(&1["record_id"] == record_id))

  # ── T-01 ───────────────────────────────────────────────────────────────────────────────────

  describe "T-01 (AC1): the SQL file itself is executed" do
    test "the file runs and returns a result set with the report columns", ctx do
      assert ctx.columns == @columns
      assert is_list(ctx.rows)
      assert rows_for(ctx, ctx.ids.exam1) != []
    end

    test "the report runs in a read-only transaction: a write inside it is refused" do
      assert {:error, :probe} =
               Repo.transaction(fn ->
                 Repo.query!("SET TRANSACTION READ ONLY")

                 assert {:error, %Postgrex.Error{}} =
                          Repo.query(
                            "DELETE FROM public.tenant_schemas WHERE schema_name IS NULL"
                          )

                 Repo.rollback(:probe)
               end)
    end
  end

  # ── T-02..T-06 (AC2) ───────────────────────────────────────────────────────────────────────

  describe "T-02..T-06 (AC2): fixture edits" do
    test "T-02: a direct-type edit on an exam with a live session is listed with its exam id",
         ctx do
      assert [row] = rows_for(ctx, ctx.ids.exam1)
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == ctx.ids.exam1
      assert row["event_type"] == "ENTITY_RECORD_UPDATED"
      assert row["tenant_id"] == ctx.a
    end

    test "T-03: the same direct-type edit on an idle exam is not listed", ctx do
      assert rows_for(ctx, ctx.ids.sec2) == []
    end

    test "T-04: an exam_manual_question edit is listed via its rule, with the rule's exam id",
         ctx do
      assert [row] = rows_for(ctx, ctx.ids.mq1)
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == ctx.ids.exam1
      assert row["entity_type"] == "exam_manual_question"
    end

    test "T-05: a pool-type edit is listed in the unattributed section with no exam id", ctx do
      assert [row] = rows_for(ctx, ctx.ids.question1)
      assert row["section"] == "unattributed"
      assert row["exam_id"] == nil
      assert row["entity_type"] == "question"
    end

    test "T-06: a delete of an exam_manual_question with no earlier event is unattributed", ctx do
      assert [row] = rows_for(ctx, ctx.ids.mq0)
      assert row["section"] == "unattributed"
      assert row["exam_id"] == nil
      assert row["event_type"] == "ENTITY_RECORD_DELETED"
    end
  end

  # ── T-07..T-10 (AC3) ───────────────────────────────────────────────────────────────────────

  describe "T-07..T-10 (AC3): session boundaries" do
    test "T-07: a grading_pending session started before the edit is listed", ctx do
      assert [row] = rows_for(ctx, ctx.ids.sec3)
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == ctx.ids.exam3
    end

    test "T-08: an in_progress session past expires_at and not finalized is listed", ctx do
      assert [row] = rows_for(ctx, ctx.ids.exam4)
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == ctx.ids.exam4
    end

    test "T-09: a session submitted before the edit does not list the edit", ctx do
      assert rows_for(ctx, ctx.ids.exam5) == []
    end

    test "T-10: a session that starts after the edit does not list the edit", ctx do
      assert rows_for(ctx, ctx.ids.exam6) == []
    end
  end

  # ── T-A9 (GH #2680 slice 3) ────────────────────────────────────────────────────────────────

  describe "T-A9 (AC6 of GH #2680): an authoring edit through the module route is listed" do
    test "an exam created and edited through Authoring with a live session is listed with its exam id and actor",
         ctx do
      schema = ctx.a_schema
      actor = Fx.insert_user!(schema).id
      fv = exam_fv("T-A9 exam")

      {:ok, %{record: %{record_id: exam_id}}} =
        Authoring.create(
          %{entity_type: "exam", field_values: fv, actor_id: actor, idempotency_key: uuid()},
          schema
        )

      # A candidate session on the new exam that started before the edit below (report: started_at <= edit time).
      create!(
        schema,
        actor,
        at(1),
        "session",
        uuid(),
        session_fv(exam_id, "in_progress", at(1), at(60), uuid())
      )

      {:ok, _} =
        Authoring.update(
          %{
            entity_type: "exam",
            record_id: exam_id,
            field_values: Map.put(fv, "title", %{"en" => "T-A9 edited"}),
            actor_id: actor,
            idempotency_key: uuid()
          },
          schema
        )

      {_columns, rows} = run_report()

      assert [row] = Enum.filter(rows, &(&1["record_id"] == exam_id and &1["tenant_id"] == ctx.a))
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == exam_id
      assert row["event_type"] == "ENTITY_RECORD_UPDATED"
      assert row["actor_id"] == actor
    end
  end

  # ── T-11..T-12 (AC4) ───────────────────────────────────────────────────────────────────────

  describe "T-11..T-12 (AC4): deletes" do
    test "T-11: a delete of an exam_section is attributed via its earlier events", ctx do
      assert [row] = rows_for(ctx, ctx.ids.sec7)
      assert row["event_type"] == "ENTITY_RECORD_DELETED"
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == ctx.ids.exam7
    end

    test "T-12: a delete of an exam_section with no earlier event is unattributed", ctx do
      assert [row] = rows_for(ctx, ctx.ids.sec12)
      assert row["section"] == "unattributed"
      assert row["exam_id"] == nil
    end
  end

  # ── T-13 (AC5) ─────────────────────────────────────────────────────────────────────────────

  describe "T-13 (AC5): ids and times only" do
    test "the output has exactly the eight id/time columns and no fixture field value", ctx do
      assert ctx.columns == @columns
      refute Enum.any?(ctx.rows, &String.contains?(inspect(&1), @marker))
    end
  end

  # ── T-14 (AC6) ─────────────────────────────────────────────────────────────────────────────

  describe "T-14 (AC6): two-tenant isolation" do
    test "tenant B's rows never carry tenant A's exam or record ids, and the reverse", ctx do
      a_ids = for {name, id} <- ctx.ids, name not in [:exam8], do: id
      b_rows = Enum.filter(ctx.rows, &(&1["tenant_id"] == ctx.b))
      a_rows = Enum.filter(ctx.rows, &(&1["tenant_id"] == ctx.a))

      assert [%{"section" => "live_session_edit", "exam_id" => exam8}] = b_rows
      assert exam8 == ctx.ids.exam8
      refute Enum.any?(b_rows, &(&1["record_id"] in a_ids or &1["exam_id"] in a_ids))

      refute Enum.any?(
               a_rows,
               &(&1["record_id"] == ctx.ids.exam8 or &1["exam_id"] == ctx.ids.exam8)
             )
    end
  end

  # ── T-15..T-16 (edge cases from the design) ────────────────────────────────────────────────

  describe "T-15..T-16 (edge cases)" do
    test "T-15: a manual-question edit is attributed to the rule's exam as of the edit", ctx do
      assert [row] = rows_for(ctx, ctx.ids.mq9)
      assert row["exam_id"] == ctx.ids.exam9
      refute Enum.any?(ctx.rows, &(&1["exam_id"] == ctx.ids.exam10))
    end

    test "T-16: an over-size payload read from event_payload_store is attributed", ctx do
      assert [row] = rows_for(ctx, ctx.ids.sec11)
      assert row["section"] == "live_session_edit"
      assert row["exam_id"] == ctx.ids.exam11
    end
  end
end
