defmodule Letflow.Modules.Exam.AuthoringParentTest do
  @moduledoc """
  REQ-586 part A (GH #3315): the `parent_id` write rules of `Letflow.Modules.Exam.AuthoringRules`
  through the real router (`POST/PUT/DELETE /api/v1/modules/exam/authoring/...`).

  Test ids follow the design: C1..C6 cycle and replay, N1/N2 parent_not_found (INV-5), D1..D5
  has-children and delete, U1 a tenant that has not been upgraded.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  @base "/api/v1/modules/exam/authoring"

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
    |> put_req_header("x-trace-id", "t-3315")
    |> dispatch()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp admin(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      ExamFixtures.provisioned_tenant_with_exam_definitions(slug_prefix)

    ExamFixtures.activate_remaining_authoring_definitions!(schema_name)
    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3315-user-#{Ecto.UUID.generate()}",
        display_name: "GH 3315 authoring test user",
        email: "gh3315-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: schema_name
      )

    %{schema_name: schema_name, slug: slug, plaintext: plaintext}
  end

  defp category_fv(parent_id \\ nil) do
    base = %{"name" => %{"en" => "Category"}, "sort_order" => 0}
    if parent_id, do: Map.put(base, "parent_id", parent_id), else: base
  end

  defp question_fv(parent_id \\ nil) do
    base = %{
      "category_id" => Ecto.UUID.generate(),
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "draft",
      "version" => 1,
      "stem" => %{"en" => "What is 2 + 2?"}
    }

    if parent_id, do: Map.put(base, "parent_id", parent_id), else: base
  end

  defp create(ctx, type, fv, extra \\ %{}),
    do: request("POST", "#{@base}/#{type}", ctx, Map.merge(%{"field_values" => fv}, extra))

  defp create!(ctx, type, fv) do
    conn = create(ctx, type, fv)
    assert conn.status == 201, "create #{type}: #{conn.status} #{conn.resp_body}"
    json(conn)["record_id"]
  end

  defp put_category(ctx, id, parent_id),
    do:
      request("PUT", "#{@base}/category/#{id}", ctx, %{"field_values" => category_fv(parent_id)})

  defp stored_parent(ctx, type, id) do
    {:ok, record} = Latest.get(id, type, ctx.schema_name)
    record.field_values["parent_id"]
  end

  defp refusal(conn, status, reason) do
    assert conn.status == status, "#{conn.status} #{conn.resp_body}"
    body = json(conn)
    assert body["reason"] == reason
    Map.delete(body, "trace_id")
  end

  describe "cycle rule (category)" do
    test "C1 a category cannot be its own parent" do
      ctx = admin("gh3315-c1")
      a = create!(ctx, "category", category_fv())
      refusal(put_category(ctx, a, a), 422, "parent_cycle")
      assert stored_parent(ctx, "category", a) == nil
    end

    test "C2 a child cannot become the parent of its parent" do
      ctx = admin("gh3315-c2")
      a = create!(ctx, "category", category_fv())
      b = create!(ctx, "category", category_fv(a))
      refusal(put_category(ctx, a, b), 422, "parent_cycle")
    end

    test "C3 a grandchild cannot become the parent of its grandparent; row unchanged" do
      ctx = admin("gh3315-c3")
      a = create!(ctx, "category", category_fv())
      b = create!(ctx, "category", category_fv(a))
      c = create!(ctx, "category", category_fv(b))
      refusal(put_category(ctx, a, c), 422, "parent_cycle")
      assert stored_parent(ctx, "category", a) == nil
    end

    test "C4 a valid re-parent to a sibling is accepted" do
      ctx = admin("gh3315-c4")
      a = create!(ctx, "category", category_fv())
      b = create!(ctx, "category", category_fv(a))
      s = create!(ctx, "category", category_fv(a))
      assert put_category(ctx, b, s).status == 200
      assert stored_parent(ctx, "category", b) == s
    end

    test "C5 a pre-existing cycle does not loop" do
      ctx = admin("gh3315-c5")
      a = create!(ctx, "category", category_fv())
      b = create!(ctx, "category", category_fv(a))
      c = create!(ctx, "category", category_fv(a))
      ExamFixtures.force_field!(ctx.schema_name, "category", a, "parent_id", {:put, b})

      task = Task.async(fn -> put_category(ctx, c, a) end)
      conn = Task.await(task, 5_000)
      assert conn.status in [200, 422]
    end

    test "C6 an idempotent replay of a create and an update carrying parent_id answers the same" do
      ctx = admin("gh3315-c6")
      a = create!(ctx, "category", category_fv())
      key = %{"idempotency_key" => "c6-" <> Ecto.UUID.generate()}

      first = create(ctx, "category", category_fv(a), key)
      second = create(ctx, "category", category_fv(a), key)
      assert first.status == 201
      assert second.status == 201
      assert json(first)["record_id"] == json(second)["record_id"]

      b = json(first)["record_id"]
      s = create!(ctx, "category", category_fv())
      ukey = %{"idempotency_key" => "c6u-" <> Ecto.UUID.generate()}
      body = Map.merge(%{"field_values" => category_fv(s)}, ukey)
      assert request("PUT", "#{@base}/category/#{b}", ctx, body).status == 200
      assert request("PUT", "#{@base}/category/#{b}", ctx, body).status == 200
    end
  end

  describe "parent_not_found (INV-5)" do
    test "N1 an absent, a soft-deleted and another tenant's parent give one identical 422" do
      ctx = admin("gh3315-n1")
      other = admin("gh3315-n1b")

      for {type, fv} <- [{"category", &category_fv/1}, {"question", &question_fv/1}] do
        deleted = create!(ctx, type, fv.(nil))
        assert request("DELETE", "#{@base}/#{type}/#{deleted}", ctx).status == 200
        foreign = create!(other, type, fv.(nil))

        bodies =
          for parent <- [Ecto.UUID.generate(), deleted, foreign] do
            refusal(create(ctx, type, fv.(parent)), 422, "parent_not_found")
          end

        assert [body] = Enum.uniq(bodies)
        refute inspect(body) =~ foreign

        own = create!(ctx, type, fv.(nil))
        update = request("PUT", "#{@base}/#{type}/#{own}", ctx, %{"field_values" => fv.(foreign)})
        assert refusal(update, 422, "parent_not_found") == body
      end
    end

    test "N2 a malformed parent_id is the same refusal" do
      ctx = admin("gh3315-n2")

      absent =
        refusal(
          create(ctx, "category", category_fv(Ecto.UUID.generate())),
          422,
          "parent_not_found"
        )

      assert refusal(create(ctx, "category", category_fv("not-a-uuid")), 422, "parent_not_found") ==
               absent

      assert refusal(create(ctx, "category", category_fv(42)), 422, "parent_not_found") == absent
    end
  end

  describe "has-children refusal on delete" do
    test "D1 a category with a live child is not deleted" do
      ctx = admin("gh3315-d1")
      a = create!(ctx, "category", category_fv())
      _b = create!(ctx, "category", category_fv(a))
      refusal(request("DELETE", "#{@base}/category/#{a}", ctx), 409, "category_has_children")
      {:ok, record} = Latest.get(a, "category", ctx.schema_name)
      refute record.deleted
    end

    test "D2 a question with a live successor is not deleted" do
      ctx = admin("gh3315-d2")
      q1 = create!(ctx, "question", question_fv())
      _q2 = create!(ctx, "question", question_fv(q1))
      refusal(request("DELETE", "#{@base}/question/#{q1}", ctx), 409, "question_has_children")
    end

    test "D3 a leaf category deletes" do
      ctx = admin("gh3315-d3")
      a = create!(ctx, "category", category_fv())
      assert request("DELETE", "#{@base}/category/#{a}", ctx).status == 200
    end

    test "D4 the newest question version deletes" do
      ctx = admin("gh3315-d4")
      q1 = create!(ctx, "question", question_fv())
      q2 = create!(ctx, "question", question_fv(q1))
      assert request("DELETE", "#{@base}/question/#{q2}", ctx).status == 200
    end

    test "D5 deleting the child first lets the parent go" do
      ctx = admin("gh3315-d5")
      a = create!(ctx, "category", category_fv())
      b = create!(ctx, "category", category_fv(a))
      assert request("DELETE", "#{@base}/category/#{a}", ctx).status == 409
      assert request("DELETE", "#{@base}/category/#{b}", ctx).status == 200
      assert request("DELETE", "#{@base}/category/#{a}", ctx).status == 200
    end
  end

  describe "tenant that has not been upgraded" do
    test "U1 parent_id is rejected as an undeclared field; writes without it still work" do
      ctx = admin("gh3315-u1")
      ExamFixtures.downgrade_parent_id!(ctx.schema_name, "category")

      conn = create(ctx, "category", category_fv(Ecto.UUID.generate()))
      assert conn.status == 422
      assert [%{"code" => "additionalProperties", "path" => "/parent_id"}] = json(conn)["errors"]
      refute json(conn)["reason"] == "parent_not_found"

      a = create!(ctx, "category", category_fv())
      assert request("DELETE", "#{@base}/category/#{a}", ctx).status == 200
    end
  end
end
