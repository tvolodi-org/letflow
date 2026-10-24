defmodule Letflow.Modules.Exam.ExamAuthoringTest do
  @moduledoc """
  GH #2680 / REQ-510 slice 1 (T-1..T-14 of the design in the task folder): the exam module's
  authoring write surface, `POST/PUT/DELETE /api/v1/modules/exam/authoring/...`, gated by the
  dedicated `:ExamAuthoringWrite` permission. Full pipeline dispatch, as `exam_sessions_test.exs`.

  Answer-key fields (`question.explanation`, `answer_option.is_correct`, ...) are restricted per
  user by the exam module's `on_install`; the admin of these tests is granted them, and one test
  (T-12) uses an admin without the grants.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Authoring

  @base "/api/v1/modules/exam/authoring"
  @restricted [
    {"question", "explanation"},
    {"answer_option", "is_correct"},
    {"answer_option", "likert_weight"},
    {"answer_option", "likert_polarity"}
  ]

  # ── Dispatch and fixtures ──────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "t-2680")
    |> dispatch()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp tenant(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      ExamFixtures.provisioned_tenant_with_exam_definitions(slug_prefix)

    ExamFixtures.activate_remaining_authoring_definitions!(schema_name)
    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)
    %{tenant_id: tenant_id, schema_name: schema_name, slug: slug}
  end

  defp user_ctx(tenant, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2680-user-#{Ecto.UUID.generate()}",
        display_name: "GH 2680 authoring test user",
        email: "gh2680-#{Ecto.UUID.generate()}@example.com",
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

  defp grant_answer_key!(ctx) do
    for {type, field} <- @restricted do
      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(ctx.user_id),
            entity_type: type,
            field_name: field,
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema_name
      )
    end

    ctx
  end

  defp admin_ctx(tenant), do: tenant |> user_ctx(["TENANT_ADMIN"]) |> grant_answer_key!()

  defp valid_fv("exam") do
    %{
      "title" => %{"en" => "Exam"},
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

  defp valid_fv("exam_section"), do: %{"exam_id" => Ecto.UUID.generate(), "sort_order" => 0}

  defp valid_fv("exam_question_rule") do
    %{
      "exam_id" => Ecto.UUID.generate(),
      "mode" => "random",
      "category_id" => Ecto.UUID.generate(),
      "count" => 1,
      "sort_order" => 0
    }
  end

  defp valid_fv("exam_question_rule_tag"),
    do: %{"rule_id" => Ecto.UUID.generate(), "tag_id" => Ecto.UUID.generate()}

  defp valid_fv("exam_manual_question") do
    %{
      "rule_id" => Ecto.UUID.generate(),
      "question_id" => Ecto.UUID.generate(),
      "sort_order" => 0
    }
  end

  defp valid_fv("question") do
    %{
      "category_id" => Ecto.UUID.generate(),
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "draft",
      "version" => 1,
      "stem" => %{"en" => "What is 2 + 2?"},
      "explanation" => %{"en" => "It is 4."}
    }
  end

  defp valid_fv("answer_option") do
    %{
      "question_id" => Ecto.UUID.generate(),
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "Four"}
    }
  end

  defp valid_fv("question_tag"),
    do: %{"question_id" => Ecto.UUID.generate(), "tag_id" => Ecto.UUID.generate()}

  defp valid_fv("tag"), do: %{"name" => "tag-" <> Ecto.UUID.generate()}
  defp valid_fv("category"), do: %{"name" => %{"en" => "Category"}, "sort_order" => 0}

  # One field per type that an update changes, and its new value.
  defp mutation("exam"), do: {"max_attempts", 5}
  defp mutation("exam_section"), do: {"sort_order", 1}
  defp mutation("exam_question_rule"), do: {"count", 2}
  defp mutation("exam_question_rule_tag"), do: {"tag_id", Ecto.UUID.generate()}
  defp mutation("exam_manual_question"), do: {"sort_order", 1}
  defp mutation("question"), do: {"difficulty", "hard"}
  defp mutation("answer_option"), do: {"sort_order", 1}
  defp mutation("question_tag"), do: {"tag_id", Ecto.UUID.generate()}
  defp mutation("tag"), do: {"name", "renamed-" <> Ecto.UUID.generate()}
  defp mutation("category"), do: {"sort_order", 1}

  defp create!(ctx, type, fv \\ nil) do
    conn =
      request("POST", "#{@base}/#{type}", ctx, %{"field_values" => fv || valid_fv(type)})

    assert conn.status == 201, "create #{type}: #{conn.status} #{conn.resp_body}"
    json(conn)["record_id"]
  end

  defp stored(schema, type, record_id) do
    {:ok, record} = Latest.get(record_id, type, schema)
    record
  end

  defp count_rows(schema, type) do
    Repo.aggregate(
      from(r in Latest, where: r.entity_type == ^type and r.deleted == false),
      :count,
      prefix: schema
    )
  end

  # ── T-1..T-3: the three operations as the permitted role, for every authoring type ──

  describe "the permitted role (TENANT_ADMIN)" do
    test "T-1 create: 201 for each of the ten authoring types, readable afterwards" do
      tenant = tenant("gh2680-create")
      ctx = admin_ctx(tenant)

      for type <- Authoring.authoring_types() do
        fv = valid_fv(type)
        conn = request("POST", "#{@base}/#{type}", ctx, %{"field_values" => fv})
        assert conn.status == 201, "#{type}: #{conn.status} #{conn.resp_body}"
        body = json(conn)
        assert body["field_values"]["name"] == fv["name"] or type != "tag"

        record = stored(tenant.schema_name, type, body["record_id"])
        assert record.entity_type == type
        refute record.deleted
      end
    end

    test "T-2 update: 200 for each of the ten types, field_values replaced" do
      tenant = tenant("gh2680-update")
      ctx = admin_ctx(tenant)

      for type <- Authoring.authoring_types() do
        record_id = create!(ctx, type)
        {key, value} = mutation(type)
        fv = Map.put(valid_fv(type), key, value)

        conn =
          request("PUT", "#{@base}/#{type}/#{record_id}", ctx, %{"field_values" => fv})

        assert conn.status == 200, "#{type}: #{conn.status} #{conn.resp_body}"
        assert stored(tenant.schema_name, type, record_id).field_values[key] == value
      end
    end

    test "T-3 delete: 200 for each of the ten types, record soft-deleted" do
      tenant = tenant("gh2680-delete")
      ctx = admin_ctx(tenant)

      for type <- Authoring.authoring_types() do
        record_id = create!(ctx, type)
        conn = request("DELETE", "#{@base}/#{type}/#{record_id}", ctx)
        assert conn.status == 200, "#{type}: #{conn.status} #{conn.resp_body}"
        assert stored(tenant.schema_name, type, record_id).deleted
      end
    end
  end

  # ── T-4, T-5: refused without the permission; platform admin allowed ──

  describe "without the permission" do
    test "T-4 create, update and delete are 403 for PROCESS_OPERATOR and CANDIDATE; nothing written" do
      tenant = tenant("gh2680-refused")
      admin = admin_ctx(tenant)
      record_id = create!(admin, "category")
      before = count_rows(tenant.schema_name, "category")

      for role <- ["PROCESS_OPERATOR", "CANDIDATE", "TASK_WORKER"] do
        ctx = user_ctx(tenant, [role])
        fv = %{"field_values" => valid_fv("category")}

        assert request("POST", "#{@base}/category", ctx, fv).status == 403
        assert request("PUT", "#{@base}/category/#{record_id}", ctx, fv).status == 403
        assert request("DELETE", "#{@base}/category/#{record_id}", ctx).status == 403
      end

      assert count_rows(tenant.schema_name, "category") == before
      refute stored(tenant.schema_name, "category", record_id).deleted
    end

    test "T-4b PROCESS_OPERATOR still writes through the generic route (the types are unmanaged)" do
      tenant = tenant("gh2680-generic")
      ctx = user_ctx(tenant, ["PROCESS_OPERATOR"])

      conn =
        request("POST", "/api/v1/entities/records/category", ctx, %{
          "field_values" => valid_fv("category")
        })

      assert conn.status == 201
    end

    test "T-5 PLATFORM_ADMIN and TENANT_ADMIN hold the permission through the core rules" do
      assert Letflow.Api.Authorization.role_allows?(:PLATFORM_ADMIN, :ExamAuthoringWrite)
      assert Letflow.Api.Authorization.role_allows?(:TENANT_ADMIN, :ExamAuthoringWrite)
      refute Letflow.Api.Authorization.role_allows?(:PROCESS_OPERATOR, :ExamAuthoringWrite)
      refute Letflow.Api.Authorization.role_allows?(:CANDIDATE, :ExamAuthoringWrite)
    end
  end

  # ── T-6..T-8: INV-5 and INV-10/INV-1 negatives ──

  describe "INV-5 and INV-10 negatives" do
    test "T-6 a non-authoring type is the same constant 404 on all three routes; nothing written" do
      tenant = tenant("gh2680-nontype")
      ctx = admin_ctx(tenant)
      rid = Ecto.UUID.generate()

      for type <- ["session", "certificate", "no_such_type"] do
        fv = %{"field_values" => %{"x" => 1}}
        post = request("POST", "#{@base}/#{type}", ctx, fv)
        put = request("PUT", "#{@base}/#{type}/#{rid}", ctx, fv)
        del = request("DELETE", "#{@base}/#{type}/#{rid}", ctx)

        assert [post.status, put.status, del.status] == [404, 404, 404]
        assert post.resp_body == put.resp_body
        assert put.resp_body == del.resp_body
      end

      assert count_rows(tenant.schema_name, "session") == 0
    end

    test "T-7 INV-10: an admin of tenant B cannot touch tenant A's record; the answer is a random-uuid 404" do
      tenant_a = tenant("gh2680-a")
      tenant_b = tenant("gh2680-b")
      admin_a = admin_ctx(tenant_a)
      admin_b = admin_ctx(tenant_b)
      record_id = create!(admin_a, "category")
      original = stored(tenant_a.schema_name, "category", record_id).field_values
      fv = %{"field_values" => Map.put(valid_fv("category"), "sort_order", 9)}

      put = request("PUT", "#{@base}/category/#{record_id}", admin_b, fv)
      del = request("DELETE", "#{@base}/category/#{record_id}", admin_b)
      rnd_put = request("PUT", "#{@base}/category/#{Ecto.UUID.generate()}", admin_b, fv)
      rnd_del = request("DELETE", "#{@base}/category/#{Ecto.UUID.generate()}", admin_b)

      assert [put.status, del.status] == [404, 404]
      assert put.resp_body == rnd_put.resp_body
      assert del.resp_body == rnd_del.resp_body

      after_a = stored(tenant_a.schema_name, "category", record_id)
      assert after_a.field_values == original
      refute after_a.deleted

      # A POST by B lands in B's schema only.
      b_id = create!(admin_b, "category")
      assert {:error, :not_found} = Latest.get(b_id, "category", tenant_a.schema_name)
      assert {:ok, _} = Latest.get(b_id, "category", tenant_b.schema_name)
    end

    test "T-8 INV-5: same 403 for an existing and an absent id; same 404 for another type's id and a random id" do
      tenant = tenant("gh2680-inv5")
      admin = admin_ctx(tenant)
      plain = user_ctx(tenant, ["PROCESS_OPERATOR"])
      tag_id = create!(admin, "tag")
      fv = %{"field_values" => valid_fv("category")}

      existing = request("PUT", "#{@base}/tag/#{tag_id}", plain, fv)
      absent = request("PUT", "#{@base}/tag/#{Ecto.UUID.generate()}", plain, fv)
      assert existing.status == 403
      assert existing.resp_body == absent.resp_body

      other_type = request("PUT", "#{@base}/category/#{tag_id}", admin, fv)
      random = request("PUT", "#{@base}/category/#{Ecto.UUID.generate()}", admin, fv)
      assert other_type.status == 404
      assert other_type.resp_body == random.resp_body

      bad_id = request("DELETE", "#{@base}/category/not-a-uuid", admin)
      assert bad_id.status == 404
    end
  end

  # ── T-9..T-12: validation, idempotency, versions, restricted fields ──

  describe "request handling parity with the generic routes" do
    test "T-9 validation: non-object body 400, missing field_values 422, bad idempotency_key 422" do
      tenant = tenant("gh2680-validation")
      ctx = admin_ctx(tenant)

      assert request("POST", "#{@base}/tag", ctx, [1, 2]).status == 400
      assert request("POST", "#{@base}/tag", ctx, %{"other" => 1}).status == 422

      too_long = String.duplicate("k", 200)

      assert request("POST", "#{@base}/tag", ctx, %{
               "field_values" => valid_fv("tag"),
               "idempotency_key" => too_long
             }).status == 422

      assert request("POST", "#{@base}/tag", ctx, %{
               "field_values" => %{"name" => 5}
             }).status == 422
    end

    test "T-10 idempotent replay returns the same record; the same key with another payload conflicts" do
      tenant = tenant("gh2680-idem")
      ctx = admin_ctx(tenant)
      fv = valid_fv("tag")
      body = %{"field_values" => fv, "idempotency_key" => "k-" <> Ecto.UUID.generate()}

      first = request("POST", "#{@base}/tag", ctx, body)
      replay = request("POST", "#{@base}/tag", ctx, body)
      assert first.status == 201
      assert json(replay)["record_id"] == json(first)["record_id"]
      assert count_rows(tenant.schema_name, "tag") == 1

      other = request("POST", "#{@base}/tag", ctx, %{body | "field_values" => valid_fv("tag")})
      assert other.status == 422
    end

    test "T-11 a stale expected_last_event_global_seq is 409 on PUT and on DELETE" do
      tenant = tenant("gh2680-seq")
      ctx = admin_ctx(tenant)
      record_id = create!(ctx, "category")
      fv = valid_fv("category")

      put =
        request("PUT", "#{@base}/category/#{record_id}", ctx, %{
          "field_values" => fv,
          "expected_last_event_global_seq" => 0
        })

      del =
        request("DELETE", "#{@base}/category/#{record_id}?expected_last_event_global_seq=0", ctx)

      bad =
        request(
          "DELETE",
          "#{@base}/category/#{record_id}?expected_last_event_global_seq=abc",
          ctx
        )

      assert [put.status, del.status, bad.status] == [409, 409, 400]
      refute stored(tenant.schema_name, "category", record_id).deleted
    end

    test "T-12 restricted answer-key fields: an ungranted admin is refused 403; update keeps the stored value" do
      tenant = tenant("gh2680-restricted")
      granted = admin_ctx(tenant)
      ungranted = user_ctx(tenant, ["TENANT_ADMIN"])
      record_id = create!(granted, "answer_option")

      refused =
        request("POST", "#{@base}/answer_option", ungranted, %{
          "field_values" => valid_fv("answer_option")
        })

      assert refused.status == 403

      # A body without the restricted keys is allowed for the ungranted admin on update, and the
      # stored `is_correct` is carried over.
      fv = valid_fv("answer_option") |> Map.delete("is_correct") |> Map.put("sort_order", 4)

      updated =
        request("PUT", "#{@base}/answer_option/#{record_id}", ungranted, %{"field_values" => fv})

      assert updated.status == 200, updated.resp_body
      assert stored(tenant.schema_name, "answer_option", record_id).field_values["is_correct"]

      assert stored(tenant.schema_name, "answer_option", record_id).field_values["sort_order"] ==
               4

      assert json(updated)["field_values"]["is_correct"] == "__field_redacted__"
    end
  end

  # ── T-13, T-14: the manifest; the planted tenant's rows are unstamped ──

  describe "slice boundary" do
    test "T-13 the ten authoring types are declared (GH #2680 slice 3); this planted tenant's rows are unstamped, so the generic route still accepts them" do
      tenant = tenant("gh2680-unmanaged")

      for type <- Authoring.authoring_types() do
        assert ManagedTypes.owner_of(type, tenant.schema_name) == :unmanaged
        assert type in Exam.manifest().manages_entity_types
      end

      # The stamp (not the manifest) is what closes generic writes on an installed tenant: see
      # `exam_managed_types_http_test.exs`, which runs the refusal on a stamped tenant.
      assert length(Exam.manifest().manages_entity_types) == 16
      ctx = user_ctx(tenant, ["TENANT_ADMIN"])

      conn =
        request("POST", "/api/v1/entities/records/exam", ctx, %{
          "field_values" => valid_fv("exam")
        })

      assert conn.status == 201
    end

    test "T-14 manifest: the permission is declared and routed three times, with no role grant" do
      manifest = Exam.manifest()
      assert :ExamAuthoringWrite in manifest.permissions

      assert Enum.count(manifest.route_policies, fn {_m, _p, key} ->
               key == :ExamAuthoringWrite
             end) ==
               3

      assert Map.keys(manifest.role_grants) == [:CANDIDATE]
      refute :ExamAuthoringWrite in manifest.role_grants[:CANDIDATE]
    end
  end
end
