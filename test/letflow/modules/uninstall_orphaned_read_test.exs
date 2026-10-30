defmodule Letflow.Modules.UninstallOrphanedReadTest do
  @moduledoc """
  REQ-629 / GH #3515 (decision 0066 D3 and D8 slice 3): orphaned-read proof for the exam answer
  keys. Tests only; D3 forbids an "orphan read" path, so the answer-key rows, the type gate and the
  module mount must behave the same in the installed, uninstalled and reactivated states.

    R1  answer-key property (INV-2) of the generic query routes, three states (criterion 1)
    R1s session part, and `exam-sessions/mine` after uninstall (criterion 2)
    R2  the five `entity_field_restrictions` pairs and the whole-table count do not move (criterion 3)
    R3  an outsider's reply is byte-identical to the not-found reply, also before uninstall
        (criteria 4 and 5)
    X1  INV-10: tenant B is unchanged by A's uninstall (criterion 6)

  Real HTTP through `Letflow.Router` with bearer tokens. `async: false`: tenant provisioning needs
  `Sandbox.mode(:auto)`; the uninstall flag is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @why "test: REQ-629 transition"
  @trace "req629-trace-id"
  @answer_keys ~w(explanation is_correct likert_weight likert_polarity)
  @five_pairs [
    {"answer_option", "is_correct"},
    {"answer_option", "likert_polarity"},
    {"answer_option", "likert_weight"},
    {"question", "explanation"},
    {"session", "exam_snapshot"}
  ]
  @restricted_types ~w(question answer_option session)
  @hidden %{"items" => [], "next_cursor" => nil}

  setup do
    previous = Application.fetch_env(:letflow, :modules_uninstall_enabled)
    Application.put_env(:letflow, :modules_uninstall_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :modules_uninstall_enabled, value)
        :error -> Application.delete_env(:letflow, :modules_uninstall_enabled)
      end
    end)

    :ok
  end

  # ── fixtures ──

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
    conn(method, path, if(body, do: Jason.encode!(body), else: nil))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", @trace)
    |> dispatch()
  end

  defp reply(conn), do: {conn.status, conn.resp_body}

  defp user_ctx(tenant, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req629-#{Ecto.UUID.generate()}",
        display_name: "REQ-629 user",
        email: "req629-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp insert_type_row!(schema, table, row) do
    Repo.insert_all(table, [Map.put(row, :id, Ecto.UUID.bingenerate())], prefix: schema)
  end

  defp restrict_type!(schema, type) do
    now = NaiveDateTime.utc_now()

    insert_type_row!(schema, "entity_type_restrictions", %{
      entity_type: type,
      inserted_at: now,
      updated_at: now
    })
  end

  defp grant_type!(ctx, type) do
    insert_type_row!(ctx.schema_name, "user_entity_type_grants", %{
      user_id: Ecto.UUID.dump!(ctx.user_id),
      entity_type: type,
      inserted_at: NaiveDateTime.utc_now()
    })
  end

  # A tenant that went through the real `Installs.install("exam", ...)`, with one question, one
  # answer option carrying every answer-key field, and one session of another user.
  defp exam_tenant!(slug) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: slug)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fixture.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id))
    end)

    schema = fixture.schema_name
    {:ok, _} = EventTypes.seed!(schema)

    assert {:ok, _} =
             Installs.install("exam", Ecto.UUID.generate(), prefix: schema, rationale: @why)

    Fx.activate_exam_definitions_after_pack_install!(schema)

    category =
      Fx.create_record!(schema, "category", %{"name" => %{"en" => "Math"}, "sort_order" => 1})

    question =
      Fx.create_record!(schema, "question", %{
        "category_id" => category.record_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"},
        "explanation" => %{"en" => "SECRET-EXPLANATION-629"}
      })

    for {order, correct?} <- [{0, true}, {1, false}] do
      Fx.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => order,
        "is_correct" => correct?,
        "text" => %{"en" => "Option #{order}"},
        "likert_weight" => if(correct?, do: 4.0, else: 1.0),
        "likert_polarity" => "positive"
      })
    end

    exam =
      Fx.create_record!(schema, "exam", %{
        "title" => %{"en" => "Exam"},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 3,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => false
      })

    Fx.assign_all!(schema, exam.record_id)

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category.record_id,
      "count" => 1,
      "sort_order" => 0
    })

    candidate = user_ctx(%{schema_name: schema, slug: fixture.tenant.slug}, ["CANDIDATE"])
    assert {:ok, _view} = Session.create(candidate.user_id, exam.record_id, schema)

    tenant = %{schema_name: schema, slug: fixture.tenant.slug, tenant_id: fixture.tenant_id}
    Enum.each(@restricted_types, &restrict_type!(schema, &1))

    worker = user_ctx(tenant, ["TASK_WORKER"])
    Enum.each(@restricted_types, &grant_type!(worker, &1))

    %{
      tenant: tenant,
      worker: worker,
      outsider: user_ctx(tenant, ["TASK_WORKER"]),
      question_id: question.record_id
    }
  end

  defp uninstall!(f, id \\ "exam"),
    do: Installs.uninstall(id, f.worker.user_id, prefix: f.tenant.schema_name, rationale: @why)

  defp reactivate(f),
    do:
      Installs.reactivate("exam", f.worker.user_id, prefix: f.tenant.schema_name, rationale: @why)

  defp pairs(schema) do
    from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name})
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  defp restriction_rows(schema) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".entity_field_restrictions")
    n
  end

  defp q(type, extra \\ %{}), do: Map.merge(%{"entity_type" => type}, extra)

  defp agg(type, extra \\ %{}),
    do: Map.merge(%{"entity_type" => type, "aggregates" => [%{"fn" => "count"}]}, extra)

  # The four plain reads of criterion 1.
  defp read_replies(ctx) do
    [
      request(:post, "/api/v1/entities/query", ctx, q("question")),
      request(:post, "/api/v1/entities/query", ctx, q("answer_option")),
      request(:post, "/api/v1/entities/query/aggregate", ctx, agg("question")),
      request(:post, "/api/v1/entities/query/aggregate", ctx, agg("answer_option"))
    ]
    |> Enum.map(&reply/1)
  end

  # Requests that NAME an answer-key field in a clause.
  defp clause_requests do
    [
      {"/api/v1/entities/query",
       q("question", %{"filters" => [%{"field" => "explanation", "op" => "eq", "value" => "x"}]})},
      {"/api/v1/entities/query",
       q("answer_option", %{"sort" => [%{"field" => "is_correct", "dir" => "asc"}]})},
      {"/api/v1/entities/query/aggregate",
       agg("answer_option", %{"group_by" => [%{"field" => "likert_weight"}]})},
      {"/api/v1/entities/query/aggregate",
       agg("answer_option", %{
         "filters" => [%{"field" => "likert_polarity", "op" => "eq", "value" => "positive"}]
       })}
    ]
  end

  defp clause_replies(ctx),
    do: for({path, body} <- clause_requests(), do: reply(request(:post, path, ctx, body)))

  defp session_reply(ctx), do: reply(request(:post, "/api/v1/entities/query", ctx, q("session")))

  # installed -> uninstalled -> reactivated (nil when reactivate answers upgrade_required)
  defp three_states(f, capture) do
    installed = capture.(f)
    assert {:ok, _} = uninstall!(f)
    uninstalled = capture.(f)

    reactivated =
      case reactivate(f) do
        {:ok, _} -> capture.(f)
        {:error, :upgrade_required} -> nil
      end

    {installed, uninstalled, reactivated}
  end

  defp assert_same_states({installed, uninstalled, reactivated}) do
    assert uninstalled == installed

    # reactivate answering upgrade_required for the fixture would leave the third state unreachable
    if reactivated, do: assert(reactivated == installed)
  end

  defp assert_no_answer_key(bodies, f) do
    for {_status, body} <- bodies do
      refute body =~ "SECRET-EXPLANATION-629"
      refute body =~ "likert_weight\":4"

      for %{"field_values" => fv} <- List.wrap(Jason.decode!(body)["items"]),
          key <- @answer_keys,
          Map.has_key?(fv, key) do
        # a restricted field is the wire sentinel, never a value
        assert fv[key] == "__field_redacted__",
               "answer-key field #{key} readable in #{f.tenant.schema_name}"
      end
    end
  end

  describe "R1 answer-key property, three states (criterion 1)" do
    test "R1: plain reads are equal and carry no answer key" do
      f = exam_tenant!("req629-r1")
      states = three_states(f, &read_replies(&1.worker))
      assert_same_states(states)
      assert elem(states, 2), "reactivate answered upgrade_required: third state unreachable"
      {installed, _, _} = states
      assert Enum.all?(installed, fn {status, _} -> status == 200 end)
      assert_no_answer_key(installed, f)
    end

    test "R1: a clause that names an answer-key field is a 403 with equal bodies" do
      f = exam_tenant!("req629-r1c")
      states = three_states(f, &clause_replies(&1.worker))
      assert_same_states(states)
      {installed, _, _} = states
      assert Enum.all?(installed, fn {status, _} -> status == 403 end)
      assert installed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
    end
  end

  describe "R1s session part (criterion 2)" do
    test "R1s: session query is equal in the states and never returns the snapshot" do
      f = exam_tenant!("req629-r1s")
      states = three_states(f, &session_reply(&1.worker))
      assert_same_states(states)
      {{status, body}, _, _} = states
      assert status == 200
      refute body =~ "exam_snapshot\":{"
      # TASK_WORKER reads sessions tenant-wide by design (snapshot_restrictions_test T-26); the
      # answer-key part is what must hold: the snapshot is the sentinel in every row.
      for item <- Jason.decode!(body)["items"],
          do: assert(item["field_values"]["exam_snapshot"] == "__field_redacted__")
    end

    test "R1s: exam-sessions/mine after uninstall is the not-found of an unknown module id" do
      f = exam_tenant!("req629-r1m")
      assert {:ok, _} = uninstall!(f)

      mine = request(:get, "/api/v1/modules/exam/exam-sessions/mine", f.worker)
      unknown = request(:get, "/api/v1/modules/not-in-catalog/exam-sessions/mine", f.worker)

      assert mine.status == 404
      assert reply(mine) == reply(unknown)
    end
  end

  describe "R2 restriction rows unchanged (criterion 3)" do
    test "R2: the five pairs and the whole-table count are equal in the three states" do
      f = exam_tenant!("req629-r2")
      schema = f.tenant.schema_name
      assert Exam.answer_key_fields() |> Enum.sort() == @five_pairs

      snapshot = fn _ -> {pairs(schema), restriction_rows(schema)} end
      {installed, uninstalled, reactivated} = states = three_states(f, snapshot)

      assert {@five_pairs, 5} = installed
      assert_same_states(states)
      assert uninstalled == installed
      assert reactivated in [nil, installed]
    end
  end

  describe "R3 outsider reply is the not-found reply (criteria 4 and 5)" do
    defp outsider_vs_absent(f) do
      for type <- ["question", "answer_option"] do
        q_out = reply(request(:post, "/api/v1/entities/query", f.outsider, q(type)))
        q_abs = reply(request(:post, "/api/v1/entities/query", f.outsider, q("no_such_type_629")))
        a_out = reply(request(:post, "/api/v1/entities/query/aggregate", f.outsider, agg(type)))

        a_abs =
          reply(
            request(
              :post,
              "/api/v1/entities/query/aggregate",
              f.outsider,
              agg("no_such_type_629")
            )
          )

        {q_out, q_abs, a_out, a_abs}
      end
    end

    defp assert_outsider_hidden(f) do
      for {q_out, q_abs, a_out, a_abs} <- outsider_vs_absent(f) do
        assert q_out == q_abs
        assert {200, body} = q_out
        assert Jason.decode!(body) == @hidden
        assert a_out == a_abs
        assert {404, a_body} = a_out
        refute a_body =~ ~r/\bexam\b|module|uninstall|permission/i
      end
    end

    test "R3: byte-identical in the installed state and after uninstall" do
      f = exam_tenant!("req629-r3")
      assert_outsider_hidden(f)
      assert {:ok, _} = uninstall!(f)
      assert_outsider_hidden(f)
    end
  end

  describe "X1 INV-10 cross-tenant (criterion 6)" do
    test "X1: uninstalling in A leaves B's rows and replies equal" do
      a = exam_tenant!("req629-xa")
      b = exam_tenant!("req629-xb")
      schema_b = b.tenant.schema_name

      before_b = {pairs(schema_b), restriction_rows(schema_b), read_replies(b.worker)}
      assert {:ok, _} = uninstall!(a)

      assert {pairs(schema_b), restriction_rows(schema_b), read_replies(b.worker)} == before_b
      assert {@five_pairs, 5, _} = before_b

      # a tenant key in A's body changes nothing: A's answer is A's, and B's data never appears
      plain = reply(request(:post, "/api/v1/entities/query", a.worker, q("question")))

      forged =
        request(
          :post,
          "/api/v1/entities/query",
          a.worker,
          q("question", %{
            "tenant_id" => b.tenant.tenant_id,
            "tenant" => b.tenant.slug,
            "prefix" => schema_b
          })
        )

      refute forged.resp_body =~ b.question_id
      assert forged.status == elem(plain, 0)
      assert pairs(schema_b) == @five_pairs
    end
  end
end
