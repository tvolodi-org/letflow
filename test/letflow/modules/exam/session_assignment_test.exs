Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Exam.SessionAssignmentTest do
  @moduledoc """
  REQ-582 part B: `Session.check_assigned/3` is enforced at exam start (fail closed).

  Test IDs follow the design: A-all, A-user, A-group, A-dept, A-none-withdrawn,
  A-order-and-http, A-isolation, E-assign-existing. Runs outside the Ecto sandbox transaction
  (`async: false`, ExamFixtures tenants run in `:auto`), like the other exam tenant tests.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ManagedTypes.AssignmentDefinition
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Installs
  alias Letflow.OrgFixture

  @start_path "/api/v1/modules/exam/exam-sessions"

  # ── fixtures ────────────────────────────────────────────────────────────

  defp tenant(slug) do
    %{tenant_id: tenant_id, schema_name: schema} =
      Fx.provisioned_tenant_with_exam_definitions(slug)

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)
    %{tenant_id: tenant_id, schema: schema, slug: slug}
  end

  defp insert_user!(schema, id \\ Ecto.UUID.generate()) do
    %User{}
    |> Ecto.Changeset.change(%{
      id: id,
      username: "req582-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-582 Test User",
      email: "req582-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  # One exam with one single-choice question and a random rule, NOT assigned to anyone.
  defp build_exam!(schema, exam_attrs \\ %{}) do
    category_id = Ecto.UUID.generate()

    exam =
      Fx.create_record!(
        schema,
        "exam",
        Map.merge(
          %{
            "title" => %{"en" => "Assignment Exam"},
            "status" => "active",
            "time_limit_minutes" => 30,
            "passing_score_pct" => 60.0,
            "max_attempts" => 5,
            "shuffle_questions" => false,
            "shuffle_options" => false,
            "show_answers" => "never",
            "on_tab_switch" => "log",
            "certificate_enabled" => false
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
        "stem" => %{"en" => "2 + 2?"}
      })

    for {correct?, i} <- [{true, 0}, {false, 1}] do
      Fx.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => i,
        "is_correct" => correct?,
        "text" => %{"en" => "Option #{i}"}
      })
    end

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    exam
  end

  defp session_count(schema, user_id) do
    Repo.aggregate(
      from(l in Latest,
        where:
          l.entity_type == "session" and fragment("?->>'user_id' = ?", l.field_values, ^user_id)
      ),
      :count,
      prefix: schema
    )
  end

  defp token_ctx(t, user) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["CANDIDATE"], expires_at: nil}, prefix: t.schema)

    %{plaintext: plaintext, slug: t.slug}
  end

  defp post_start(ctx, exam_id) do
    conn(:post, @start_path, Jason.encode!(%{"exam_id" => exam_id}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "req582-fixed-trace")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  # ── A-all ───────────────────────────────────────────────────────────────

  test "A-all: an active all assignment lets a candidate in no group or unit start" do
    t = tenant("req582-a-all")
    exam = build_exam!(t.schema)
    Fx.assign_all!(t.schema, exam.record_id)

    assert {:ok, view} = Session.create(Ecto.UUID.generate(), exam.record_id, t.schema)
    assert view.exam_id == exam.record_id
  end

  # ── A-user ──────────────────────────────────────────────────────────────

  test "A-user: only the assigned user starts; B is refused and gets no session record" do
    t = tenant("req582-a-user")
    exam = build_exam!(t.schema)
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    Fx.assign!(t.schema, exam.record_id, "user", a)

    assert {:ok, _} = Session.create(a, exam.record_id, t.schema)
    assert {:error, :not_assigned} = Session.create(b, exam.record_id, t.schema)
    assert session_count(t.schema, b) == 0
  end

  # ── A-group ─────────────────────────────────────────────────────────────

  test "A-group: member starts, non-member refused, removal from the group refuses" do
    t = tenant("req582-a-group")
    exam = build_exam!(t.schema)
    member = insert_user!(t.schema)
    outsider = insert_user!(t.schema)

    {:ok, group} = Identity.create_group(%{"name" => "req582-g"}, prefix: t.schema)
    {:ok, _} = Identity.add_group_member(group.id, member.id, prefix: t.schema)
    Fx.assign!(t.schema, exam.record_id, "group", group.id)

    assert {:error, :not_assigned} = Session.create(outsider.id, exam.record_id, t.schema)
    assert {:ok, view} = Session.create(member.id, exam.record_id, t.schema)

    # a second attempt needs the first one finished: remove the member, then a new exam start
    :ok = Identity.remove_group_member(group.id, member.id, prefix: t.schema)
    exam2 = build_exam!(t.schema)
    Fx.assign!(t.schema, exam2.record_id, "group", group.id)
    assert {:error, :not_assigned} = Session.create(member.id, exam2.record_id, t.schema)
    assert view.exam_id == exam.record_id
  end

  test "A-group: a non-UUID group assignee_id is refused without an exception" do
    t = tenant("req582-a-group-bad")
    exam = build_exam!(t.schema)
    Fx.assign!(t.schema, exam.record_id, "group", "not-a-uuid")

    assert {:error, :not_assigned} =
             Session.create(Ecto.UUID.generate(), exam.record_id, t.schema)
  end

  # ── A-dept ──────────────────────────────────────────────────────────────

  describe "A-dept" do
    setup do
      t = tenant("req582-a-dept")

      on_exit(fn ->
        Repo.delete_all(
          from(i in Letflow.Definitions.SolutionPackInstall, where: i.tenant_id == ^t.tenant_id)
        )

        Repo.delete_all(
          from(b in Letflow.Definitions.SolutionPackArtefactBase,
            where: b.tenant_id == ^t.tenant_id
          )
        )

        Repo.delete_all(
          from(cp in Letflow.TenantProvisioning.ColumnPromotion,
            where: cp.tenant_id == ^t.tenant_id
          )
        )
      end)

      {:ok, _} =
        Installs.install("org", Ecto.UUID.generate(), prefix: t.schema, rationale: "REQ-582 test")

      %{t: t}
    end

    defp membership!(schema, user_id, unit_id, active) do
      OrgFixture.create!(
        schema,
        "org_unit_membership",
        OrgFixture.values("org_unit_membership", "m", %{
          "user_id" => user_id,
          "org_unit_id" => unit_id,
          "active" => active
        })
      )
    end

    test "active membership matches; inactive, child-unit-only and none are refused", %{t: t} do
      exam = build_exam!(t.schema)
      unit = Ecto.UUID.generate()
      child = Ecto.UUID.generate()
      in_unit = Ecto.UUID.generate()
      inactive = Ecto.UUID.generate()
      child_only = Ecto.UUID.generate()
      nobody = Ecto.UUID.generate()

      membership!(t.schema, in_unit, unit, true)
      membership!(t.schema, inactive, unit, false)
      membership!(t.schema, child_only, child, true)
      Fx.assign!(t.schema, exam.record_id, "org_unit", unit)

      assert {:ok, _} = Session.create(in_unit, exam.record_id, t.schema)
      assert {:error, :not_assigned} = Session.create(inactive, exam.record_id, t.schema)
      assert {:error, :not_assigned} = Session.create(child_only, exam.record_id, t.schema)
      assert {:error, :not_assigned} = Session.create(nobody, exam.record_id, t.schema)
    end
  end

  test "A-dept: org module not installed matches nobody and returns an error tuple" do
    t = tenant("req582-a-dept-noorg")
    exam = build_exam!(t.schema)
    Fx.assign!(t.schema, exam.record_id, "org_unit", Ecto.UUID.generate())

    refute Installs.installed?("org", prefix: t.schema)

    assert {:error, :not_assigned} =
             Session.create(Ecto.UUID.generate(), exam.record_id, t.schema)
  end

  # ── A-none-withdrawn ────────────────────────────────────────────────────

  test "A-none-withdrawn: none, only withdrawn, user without assignee_id: refused for everyone" do
    t = tenant("req582-a-none")
    none = build_exam!(t.schema)
    withdrawn = build_exam!(t.schema)
    no_assignee = build_exam!(t.schema)
    several = build_exam!(t.schema)
    candidates = for _ <- 1..3, do: Ecto.UUID.generate()

    Fx.assign!(t.schema, withdrawn.record_id, "all", nil, active: false)
    Fx.assign!(t.schema, no_assignee.record_id, "user", nil)

    for c <- candidates, e <- [none, withdrawn, no_assignee] do
      assert {:error, :not_assigned} = Session.create(c, e.record_id, t.schema)
    end

    # one matching active assignment among several non-matching is enough
    [first, second, third] = candidates
    Fx.assign!(t.schema, several.record_id, "user", first)
    Fx.assign!(t.schema, several.record_id, "all", nil, active: false)
    Fx.assign!(t.schema, several.record_id, "user", second)

    assert {:ok, _} = Session.create(second, several.record_id, t.schema)
    assert {:error, :not_assigned} = Session.create(third, several.record_id, t.schema)
  end

  # ── A-order-and-http ────────────────────────────────────────────────────

  test "A-order-and-http: check runs before status; the route answers a fixed 403 text" do
    t = tenant("req582-a-order")
    archived = build_exam!(t.schema, %{"status" => "archived"})
    candidate = Ecto.UUID.generate()

    assert {:error, :not_assigned} = Session.create(candidate, archived.record_id, t.schema)
    Fx.assign_all!(t.schema, archived.record_id)
    assert {:error, :exam_archived} = Session.create(candidate, archived.record_id, t.schema)

    unassigned = build_exam!(t.schema)
    user = insert_user!(t.schema)
    ctx = token_ctx(t, user)

    conn = post_start(ctx, unassigned.record_id)
    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["detail"] == "you are not assigned to this exam"
    refute conn.resp_body =~ unassigned.record_id
    refute conn.resp_body =~ archived.record_id

    assigned = build_exam!(t.schema)
    Fx.assign!(t.schema, assigned.record_id, "user", user.id)
    assert post_start(ctx, assigned.record_id).status == 201
  end

  # ── A-isolation ─────────────────────────────────────────────────────────

  test "A-isolation: another tenant's exam id looks like an unknown id; no cross-tenant match" do
    a = tenant("req582-iso-a")
    b = tenant("req582-iso-b")
    exam_b = build_exam!(b.schema)
    Fx.assign_all!(b.schema, exam_b.record_id)
    user = insert_user!(a.schema)
    ctx = token_ctx(a, user)

    other = post_start(ctx, exam_b.record_id)
    unknown = post_start(ctx, Ecto.UUID.generate())
    assert other.status == unknown.status
    assert other.resp_body == unknown.resp_body

    # B's group membership of the same user id does not match in A
    exam_a = build_exam!(a.schema)
    {:ok, group_b} = Identity.create_group(%{"name" => "req582-iso-g"}, prefix: b.schema)
    insert_user!(b.schema, user.id)
    {:ok, _} = Identity.add_group_member(group_b.id, user.id, prefix: b.schema)
    Fx.assign!(a.schema, exam_a.record_id, "group", group_b.id)
    assert {:error, :not_assigned} = Session.create(user.id, exam_a.record_id, a.schema)

    # an assignment in B's schema for an exam id that exists in A is invisible to A
    {:ok, _} =
      Records.create_record(
        %{
          entity_type: "exam_assignment",
          field_values: %{
            "exam_id" => exam_a.record_id,
            "assignee_type" => "all",
            "assigned_by" => Ecto.UUID.generate(),
            "active" => true
          },
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        b.schema,
        ManagedTypes.owner_for!(Exam)
      )

    assert {:error, :not_assigned} = Session.create(user.id, exam_a.record_id, a.schema)
  end

  # ── E-assign-existing ───────────────────────────────────────────────────

  test "E-assign-existing: ensure_assignment_definition on an existing tenant, then assign, then start" do
    t = tenant("req582-e-existing")
    exam = build_exam!(t.schema)
    candidate = Ecto.UUID.generate()

    assert {:error, :not_found} =
             Definitions.get_active_definition_by_name("exam_assignment", t.schema)

    assert {:error, :not_assigned} = Session.create(candidate, exam.record_id, t.schema)

    assert %{status: :created} = AssignmentDefinition.run_tenant(t.schema, [])

    assert {:ok, _} =
             Records.create_record(
               %{
                 entity_type: "exam_assignment",
                 field_values: %{
                   "exam_id" => exam.record_id,
                   "assignee_type" => "all",
                   "assigned_by" => Ecto.UUID.generate(),
                   "active" => true
                 },
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               t.schema,
               ManagedTypes.owner_for!(Exam)
             )

    assert {:ok, _} = Session.create(candidate, exam.record_id, t.schema)
  end
end
