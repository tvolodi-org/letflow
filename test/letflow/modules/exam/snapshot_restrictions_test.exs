defmodule Letflow.Modules.Exam.SnapshotRestrictionsTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 8
  and 12.4 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`): the answer-key field restrictions as
  they apply to the new `session.exam_snapshot` field.

    * `Exam.answer_key_fields/0` is FIVE pairs (the four REQ-411 pairs plus `session.exam_snapshot`;
      the design's "six" is an arithmetic error the implementation corrected).
    * T-26: a TASK_WORKER, a TASK_WORKER that also holds CANDIDATE, and a TENANT_ADMIN all get the
      redaction sentinel for `exam_snapshot` from `POST /entities/query`; a `user_entity_grants`
      row (and nothing else) lifts it.
    * T-27: joined queries redact it on the far side (a session joined from an exam) and on the
      primary side (a session with its session_questions joined).
    * T-28: a process script's read (`ScriptReads`, reached through the entity port) omits it.
    * T-29: the CANDIDATE row of the permission golden holds none of the generic read permissions.
    * T-33/T-34: every exam-installed tenant (fresh, installed before REQ-411 with zero rows,
      installed with only the four old pairs) ends with all five rows after
      `Exam.ensure_answer_key_restrictions/1`, and a second run adds none.

  Real HTTP through `Letflow.Router` (bearer token plus `x-tenant-slug`). A failure message never
  prints a snapshot value.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.ExamStampFixtures, as: StampFx
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Session
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @five_pairs [
    {"answer_option", "is_correct"},
    {"answer_option", "likert_polarity"},
    {"answer_option", "likert_weight"},
    {"question", "explanation"},
    {"session", "exam_snapshot"}
  ]

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp post(ctx, path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp query(ctx, body), do: post(ctx, "/api/v1/entities/query", body)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp wire_sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2682-restr-#{Ecto.UUID.generate()}",
      display_name: "GH2682 Restrictions Test User",
      email: "gh2682-restr-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp token_ctx(tenant, roles) do
    user = insert_user!(tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp grant!(ctx, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(ctx.user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp restriction_pairs(schema) do
    from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name})
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  # An ExamFixtures tenant (real exam definitions, restrictions seeded by Exam.on_install/2) with
  # one real session started through Session.create/3.
  defp exam_tenant_with_session!(slug) do
    %{tenant_id: tenant_id, schema_name: schema} =
      Fx.provisioned_tenant_with_exam_definitions(slug)

    %Tenant{slug: tenant_slug} = Repo.get(Tenant, tenant_id)

    category_id = Ecto.UUID.generate()

    exam =
      Fx.create_record!(schema, "exam", %{
        "title" => %{"en" => "Exam"},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 5,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => false
      })

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

    for {sort_order, correct?} <- [{0, true}, {1, false}] do
      Fx.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => sort_order,
        "is_correct" => correct?,
        "text" => %{"en" => "Option #{sort_order}"}
      })
    end

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    assert {:ok, view} = Session.create(Ecto.UUID.generate(), exam.record_id, schema)

    %{
      tenant: %{schema_name: schema, slug: tenant_slug, tenant_id: tenant_id},
      exam_id: exam.record_id,
      session_id: view.id
    }
  end

  # ── T-26 ───────────────────────────────────────────────────────────────────────────────────

  describe "T-26 query redaction" do
    setup do
      fixture = exam_tenant_with_session!("gh2682-t26-#{System.unique_integer([:positive])}")
      snapshot = Fx.session_snapshot(fixture.tenant.schema_name, fixture.session_id)
      Map.put(fixture, :snapshot, snapshot)
    end

    for {label, roles} <- [
          {"TASK_WORKER", ["TASK_WORKER"]},
          {"TASK_WORKER holding CANDIDATE too", ["TASK_WORKER", "CANDIDATE"]},
          {"TENANT_ADMIN (restrictions are per user, not per role)", ["TENANT_ADMIN"]}
        ] do
      test "#{label}: exam_snapshot is the sentinel, unrestricted fields stay readable, no snapshot content in the body",
           %{tenant: tenant, exam_id: exam_id, snapshot: snapshot} do
        ctx = token_ctx(tenant, unquote(roles))

        conn = query(ctx, %{"entity_type" => "session"})
        assert conn.status == 200

        assert [item] = body_of(conn)["items"]
        fv = item["field_values"]

        assert fv["exam_snapshot"] == wire_sentinel()
        assert fv["exam_id"] == exam_id
        assert fv["status"] == "in_progress"

        refute conn.resp_body =~ snapshot["nonce"]
        refute conn.resp_body =~ snapshot["digest"]
        refute conn.resp_body =~ "correct_option_ids"
      end
    end

    test "CONTROL: a caller holding a user_entity_grants row for the field reads the real snapshot (the grant, not luck, decides)",
         %{tenant: tenant, snapshot: snapshot} do
      ctx = token_ctx(tenant, ["TASK_WORKER"])
      grant!(ctx, "session", "exam_snapshot")

      conn = query(ctx, %{"entity_type" => "session"})
      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["exam_snapshot"] == snapshot
    end

    test "CONTROL: without the session.exam_snapshot restriction row the same TASK_WORKER would read it (M5 would be caught)",
         %{tenant: tenant, snapshot: snapshot} do
      {1, _} =
        Repo.delete_all(
          from(r in "entity_field_restrictions",
            where: r.entity_type == "session" and r.field_name == "exam_snapshot"
          ),
          prefix: tenant.schema_name
        )

      ctx = token_ctx(tenant, ["TASK_WORKER"])
      conn = query(ctx, %{"entity_type" => "session"})
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["exam_snapshot"] == snapshot
    end
  end

  # ── T-27: joined queries ───────────────────────────────────────────────────────────────────

  describe "T-27 joins" do
    defp create_active_definition!(ctx, definition) do
      # GH #2581: exam is not installed in this tenant, so the tenant path refuses its names.
      entity_definition =
        Letflow.ManagedTypesSupport.plant_legacy_definition!(ctx.schema_name, definition)

      {:ok, activated} =
        Definitions.activate_definition(
          entity_definition.name,
          ctx.user_id,
          "gh2682 join go-live",
          ctx.schema_name
        )

      activated
    end

    # The real column-promotion path (a joined type needs its own per-type table); registers its
    # own cleanup because the tenant fixture's teardown does not delete ColumnPromotion rows.
    defp promote_and_create_table!(ctx, entity_type, attribute, pg_type, references_entity) do
      on_exit(fn ->
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^ctx.tenant_id))
      end)

      column_spec =
        if references_entity,
          do: %{pg_type: pg_type, nullable: true, references_entity: references_entity},
          else: %{pg_type: pg_type, nullable: true}

      {:ok, [row]} =
        TenantProvisioning.register_column_promotion(
          entity_type,
          attribute,
          column_spec,
          [ctx.tenant_id]
        )

      {:ok, %{status: "ddl_applied"}} = TenantProvisioning.run_column_promotion(row.id)
      :ok
    end

    defp seed_record!(ctx, entity_type, field_values) do
      {:ok, %{record: record}} =
        Records.create_record(
          %{
            entity_type: entity_type,
            field_values: field_values,
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema_name
        )

      record
    end

    # exam <- session (fk session_exam_fk) <- session_question (fk sq_session_fk): the join
    # direction of the platform is "the far side holds the foreign key", so a session is the FAR
    # side of an exam query and the PRIMARY side of a session query joined to its session_questions.
    defp join_fixture! do
      fixture =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "gh2682-t27-#{System.unique_integer([:positive])}",
          display_name: "GH2682 T-27 Join Test Tenant"
        )

      {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)
      user = insert_user!(fixture.schema_name)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: fixture.schema_name
        )

      ctx = %{
        tenant_id: fixture.tenant_id,
        schema_name: fixture.schema_name,
        slug: fixture.tenant.slug,
        plaintext: plaintext,
        user_id: user.id
      }

      create_active_definition!(ctx, %{
        name: "exam",
        display_name: "Exam",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      promote_and_create_table!(ctx, "exam", "title", "text", nil)

      create_active_definition!(ctx, %{
        name: "session",
        display_name: "Session",
        fields: [
          %{name: "exam_id", type: :string, queried: true},
          %{name: "status", type: :string, queried: true},
          %{name: "exam_snapshot", type: :json, queried: false}
        ],
        foreign_keys: [%{name: "session_exam_fk", field: "exam_id", references_entity: "exam"}]
      })

      promote_and_create_table!(ctx, "session", "exam_id", "uuid", "exam")

      create_active_definition!(ctx, %{
        name: "session_question",
        display_name: "Session Question",
        fields: [%{name: "session_id", type: :string, queried: true}],
        foreign_keys: [
          %{name: "sq_session_fk", field: "session_id", references_entity: "session"}
        ]
      })

      promote_and_create_table!(ctx, "session_question", "session_id", "uuid", "session")

      # the real seeding path: session.exam_snapshot joins the four REQ-411 pairs
      :ok = Exam.on_install(ctx.schema_name, %{})

      exam = seed_record!(ctx, "exam", %{"title" => "T-27 exam"})
      snapshot = Fx.empty_snapshot!(exam.record_id)

      session =
        seed_record!(ctx, "session", %{
          "exam_id" => exam.record_id,
          "status" => "in_progress",
          "exam_snapshot" => snapshot
        })

      seed_record!(ctx, "session_question", %{"session_id" => session.record_id})

      Map.put(ctx, :snapshot, snapshot)
    end

    test "the session is the FAR side of the join (primary exam): its exam_snapshot is the sentinel, its status stays readable" do
      ctx = join_fixture!()

      conn =
        query(ctx, %{
          "entity_type" => "exam",
          "join" => [%{"entity_type" => "session", "fk" => "session_exam_fk"}]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]

      assert item["session"]["field_values"]["exam_snapshot"] == wire_sentinel()
      assert item["session"]["field_values"]["status"] == "in_progress"
      refute conn.resp_body =~ ctx.snapshot["nonce"]
      refute conn.resp_body =~ ctx.snapshot["digest"]
    end

    test "the session is the PRIMARY side of the join (far side session_question): its exam_snapshot is the sentinel" do
      ctx = join_fixture!()

      conn =
        query(ctx, %{
          "entity_type" => "session",
          "join" => [%{"entity_type" => "session_question", "fk" => "sq_session_fk"}]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]

      assert item["primary"]["field_values"]["exam_snapshot"] == wire_sentinel()
      assert item["primary"]["field_values"]["status"] == "in_progress"
      refute conn.resp_body =~ ctx.snapshot["nonce"]
      refute conn.resp_body =~ ctx.snapshot["digest"]
    end

    test "CONTROL: a grant for the field lifts the redaction on the far side of the join" do
      ctx = join_fixture!()
      grant!(ctx, "session", "exam_snapshot")

      conn =
        query(ctx, %{
          "entity_type" => "exam",
          "join" => [%{"entity_type" => "session", "fk" => "session_exam_fk"}]
        })

      assert [item] = body_of(conn)["items"]
      assert item["session"]["field_values"]["exam_snapshot"] == ctx.snapshot
    end
  end

  # ── T-28: ScriptReads through the entity port ─────────────────────────────────────────────

  describe "T-28 script read" do
    setup do
      fixture = exam_tenant_with_session!("gh2682-t28-#{System.unique_integer([:positive])}")
      :ok = SP.flag_raw!(fixture.tenant.schema_name, "session")
      fixture
    end

    defp read_session(schema, session_id) do
      read = SP.id_read("s", "session", ["status", "exam_id", "exam_snapshot"])
      EntityPortImpl.prefetch(schema, [read], %{"cid" => session_id})
    end

    test "the row holds the unrestricted fields and no exam_snapshot key at all (omitted, not a sentinel)",
         %{tenant: tenant, session_id: session_id, exam_id: exam_id} do
      assert {:ok, %{"s" => [row]}} = read_session(tenant.schema_name, session_id)

      assert row["id"] == session_id
      assert row["status"] == "in_progress"
      assert row["exam_id"] == exam_id
      refute Map.has_key?(row, "exam_snapshot")
    end

    test "CONTROL: with the restriction row removed the same read does deliver the snapshot (the row, not the definition, omits it)",
         %{tenant: tenant, session_id: session_id} do
      Repo.delete_all(
        from(r in "entity_field_restrictions",
          where: r.entity_type == "session" and r.field_name == "exam_snapshot"
        ),
        prefix: tenant.schema_name
      )

      assert {:ok, %{"s" => [row]}} = read_session(tenant.schema_name, session_id)
      assert %{"v" => 1} = row["exam_snapshot"]
    end

    test "a match on the restricted field is refused before any record query (no oracle through the port)",
         %{tenant: tenant} do
      read = %{
        "name" => "s",
        "entity_type" => "session",
        "match" => %{"field" => "exam_snapshot", "value_from" => "tier"},
        "fields" => ["status"]
      }

      assert {:error, :reads_not_allowed} ==
               EntityPortImpl.prefetch(tenant.schema_name, [read], %{"tier" => "x"})
    end
  end

  # ── T-29: the golden ───────────────────────────────────────────────────────────────────────

  describe "T-29 golden" do
    test "golden and role_allows?/2 agree: CANDIDATE has no EntitiesQuery, EntitiesAggregate or EntitiesRecordsExport" do
      golden = File.read!(Path.join(File.cwd!(), "priv/permission_matrix/effective.golden"))

      rows =
        for line <- String.split(golden, "\n"),
            [role, permission, allowed | _rest] <- [String.split(line, " ")],
            role == "CANDIDATE",
            do: {permission, allowed}

      assert length(rows) > 10

      for permission <-
            ~w(EntitiesQuery EntitiesAggregate EntitiesRecordsExport EntitiesRecordsExportUnredacted) do
        assert {permission, "false"} in rows
        refute Authorization.role_allows?(:CANDIDATE, String.to_atom(permission))
      end
    end
  end

  # ── T-33 / T-34 / M5: the five restriction pairs on every exam-installed tenant ───────────

  describe "T-33/T-34 five rows" do
    test "Exam.answer_key_fields/0 is exactly the four REQ-411 pairs plus session.exam_snapshot (five, not six)" do
      assert Enum.sort(Exam.answer_key_fields()) == @five_pairs
      assert length(Exam.answer_key_fields()) == 5
    end

    test "a fixture-installed exam tenant (Exam.on_install/2) holds exactly the five rows" do
      %{schema_name: schema} = Fx.provisioned_tenant_with_exam_definitions("gh2682-t33-fixture")

      assert restriction_pairs(schema) == @five_pairs
    end

    test "a tenant installed before REQ-411 (zero rows): the reconcile adds all five, and a second run adds none (T-34)" do
      %{schema_name: schema} = StampFx.bare_tenant!("gh2682-t33-zero", true)
      assert restriction_pairs(schema) == []

      assert {:ok, 5} = Exam.ensure_answer_key_restrictions(schema)
      assert restriction_pairs(schema) == @five_pairs

      assert {:ok, 0} = Exam.ensure_answer_key_restrictions(schema)
      assert restriction_pairs(schema) == @five_pairs
    end

    test "a tenant installed before this change (the four old pairs only): the reconcile adds exactly session.exam_snapshot" do
      %{schema_name: schema} = StampFx.bare_tenant!("gh2682-t33-four", true)
      now = NaiveDateTime.utc_now()

      rows =
        for {entity_type, field_name} <- @five_pairs -- [{"session", "exam_snapshot"}] do
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: entity_type,
            field_name: field_name,
            inserted_at: now,
            updated_at: now
          }
        end

      {4, _} = Repo.insert_all("entity_field_restrictions", rows, prefix: schema)

      assert {:ok, 1} = Exam.ensure_answer_key_restrictions(schema)
      assert restriction_pairs(schema) == @five_pairs
    end

    test "Exam.on_install/2 itself is idempotent and seeds all five" do
      %{schema_name: schema} = StampFx.bare_tenant!("gh2682-t33-oninstall", true)

      assert :ok = Exam.on_install(schema, %{})
      assert :ok = Exam.on_install(schema, %{})
      assert restriction_pairs(schema) == @five_pairs
    end

    test "the reconcile refuses a schema that is not a registered tenant" do
      assert {:error, :invalid_schema_name} =
               Exam.ensure_answer_key_restrictions("no_such_schema")
    end
  end
end
