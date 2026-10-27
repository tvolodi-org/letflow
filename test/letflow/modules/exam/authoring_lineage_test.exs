defmodule Letflow.Modules.Exam.AuthoringLineageTest do
  @moduledoc """
  REQ-586 part B (GH #3315): the question lineage rules of `Letflow.Modules.Exam.AuthoringRules`
  through the real router. Ids L1..L15 follow the design; L13..L15 drive `Authoring.update/2` and
  `AuthoringRules.check_write/5` with `preserve_keys` (the router's restricted-field carry-over).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam.Authoring
  alias Letflow.Modules.Exam.AuthoringRules

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
    |> put_req_header("x-trace-id", "t-3315b")
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
        username: "gh3315b-user-#{Ecto.UUID.generate()}",
        display_name: "GH 3315 lineage test user",
        email: "gh3315b-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: schema_name
      )

    %{schema_name: schema_name, slug: slug, plaintext: plaintext, user_id: user.id}
  end

  defp fv(parent_id, version, status) do
    base = %{
      "category_id" => Ecto.UUID.generate(),
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => status,
      "version" => version,
      "stem" => %{"en" => "What is 2 + 2?"}
    }

    if parent_id, do: Map.put(base, "parent_id", parent_id), else: base
  end

  defp create(ctx, parent, version, status),
    do:
      request("POST", "#{@base}/question", ctx, %{"field_values" => fv(parent, version, status)})

  defp create!(ctx, parent, version, status) do
    conn = create(ctx, parent, version, status)
    assert conn.status == 201, "create: #{conn.status} #{conn.resp_body}"
    json(conn)["record_id"]
  end

  defp put(ctx, id, parent, version, status),
    do:
      request("PUT", "#{@base}/question/#{id}", ctx, %{
        "field_values" => fv(parent, version, status)
      })

  defp stored(ctx, id) do
    {:ok, record} = Latest.get(id, "question", ctx.schema_name)
    record.field_values
  end

  defp refused(conn, reason) do
    assert conn.status == 422, "#{conn.status} #{conn.resp_body}"
    body = json(conn)
    assert body["reason"] == reason
    Map.delete(body, "trace_id")
  end

  test "L1 a second child of one parent is refused" do
    ctx = admin("gh3315b-l1")
    q1 = create!(ctx, nil, 1, "draft")
    _q2 = create!(ctx, q1, 2, "draft")
    refused(create(ctx, q1, 3, "draft"), "lineage_branch")
  end

  test "L2 a version not above the parent's is refused" do
    ctx = admin("gh3315b-l2")
    q1 = create!(ctx, nil, 1, "draft")
    refused(create(ctx, q1, 1, "draft"), "version_not_increasing")
    refused(create(ctx, q1, 0, "draft"), "version_not_increasing")
  end

  test "L3 a version not below a child's is refused" do
    ctx = admin("gh3315b-l3")
    q1 = create!(ctx, nil, 1, "draft")
    q3 = create!(ctx, q1, 3, "draft")
    refused(put(ctx, q1, nil, 3, "draft"), "version_not_increasing")
    refused(put(ctx, q3, q1, 1, "draft"), "version_not_increasing")
    assert stored(ctx, q3)["version"] == 3
  end

  test "L4 and L5 a draft child under an active parent is ok, activating it is refused" do
    ctx = admin("gh3315b-l4")
    q1 = create!(ctx, nil, 1, "active")
    q2 = create!(ctx, q1, 2, "draft")
    assert stored(ctx, q1)["status"] == "active"
    refused(put(ctx, q2, q1, 2, "active"), "lineage_active_conflict")
    assert stored(ctx, q2)["status"] == "draft"
  end

  test "L6 archive the parent, then activate the child: exactly one active, the latest" do
    ctx = admin("gh3315b-l6")
    q1 = create!(ctx, nil, 1, "active")
    q2 = create!(ctx, q1, 2, "draft")
    assert put(ctx, q1, nil, 1, "archived").status == 200
    assert put(ctx, q2, q1, 2, "active").status == 200
    assert stored(ctx, q1)["status"] == "archived"
    assert stored(ctx, q2)["status"] == "active"
  end

  test "L7 moving an active question under a lineage with another active is refused" do
    ctx = admin("gh3315b-l7")
    qa = create!(ctx, nil, 1, "active")
    q1 = create!(ctx, nil, 1, "active")
    q2 = create!(ctx, q1, 2, "draft")
    refused(put(ctx, qa, q2, 3, "active"), "lineage_active_conflict")
    assert stored(ctx, qa)["parent_id"] == nil
  end

  test "L8 draft, review and archived writes are never refused by the active rule" do
    ctx = admin("gh3315b-l8")
    q1 = create!(ctx, nil, 1, "active")
    q2 = create!(ctx, q1, 2, "draft")
    assert put(ctx, q2, q1, 2, "review").status == 200
    assert put(ctx, q2, q1, 2, "archived").status == 200
    assert put(ctx, q2, q1, 2, "draft").status == 200

    # a legacy state of two actives does not block an unchanged-parent draft write
    ExamFixtures.force_field!(ctx.schema_name, "question", q2, "status", {:put, "active"})
    assert put(ctx, q2, q1, 2, "draft").status == 200
  end

  test "L9 activating a root whose descendant is active is refused" do
    ctx = admin("gh3315b-l9")
    q1 = create!(ctx, nil, 1, "draft")
    _q2 = create!(ctx, q1, 2, "active")
    refused(put(ctx, q1, nil, 1, "active"), "lineage_active_conflict")
  end

  test "L10 the three refusals share a constant detail" do
    ctx = admin("gh3315b-l10")
    q1 = create!(ctx, nil, 1, "active")
    q2 = create!(ctx, q1, 2, "draft")

    bodies = [
      refused(create(ctx, q1, 3, "draft"), "lineage_branch"),
      refused(put(ctx, q2, q1, 1, "draft"), "version_not_increasing"),
      refused(put(ctx, q2, q1, 2, "active"), "lineage_active_conflict")
    ]

    assert bodies |> Enum.map(&Map.delete(&1, "reason")) |> Enum.uniq() |> length() == 1
  end

  test "L11 a lineage in another tenant never conflicts" do
    a = admin("gh3315b-l11a")
    b = admin("gh3315b-l11b")
    qb1 = create!(b, nil, 1, "active")
    _qb2 = create!(b, qb1, 2, "draft")

    q1 = create!(a, nil, 1, "active")
    q2 = create!(a, q1, 2, "draft")
    assert put(a, q1, nil, 1, "archived").status == 200
    assert put(a, q2, q1, 2, "active").status == 200
    refused(create(a, qb1, 2, "draft"), "parent_not_found")
  end

  test "L12 a pre-existing cycle terminates" do
    ctx = admin("gh3315b-l12")
    q1 = create!(ctx, nil, 1, "draft")
    q2 = create!(ctx, q1, 2, "draft")
    ExamFixtures.force_field!(ctx.schema_name, "question", q1, "parent_id", {:put, q2})

    task = Task.async(fn -> put(ctx, q2, q1, 2, "active") end)
    assert Task.await(task, 5_000).status in [200, 422]
  end

  describe "restricted keys carry the stored value (preserve_keys)" do
    defp update_attrs(ctx, id, body, preserve) do
      %{
        entity_type: "question",
        record_id: id,
        field_values: body,
        actor_id: ctx.user_id,
        idempotency_key: Ecto.UUID.generate(),
        preserve_keys: MapSet.new(preserve)
      }
    end

    test "L13 a restricted parent_id cannot bypass the active rule" do
      ctx = admin("gh3315b-l13")
      q1 = create!(ctx, nil, 1, "active")
      q2 = create!(ctx, q1, 2, "draft")
      body = fv(nil, 2, "active") |> Map.delete("parent_id")

      assert {:error, {:authoring_rule, :lineage_active_conflict}} =
               Authoring.update(update_attrs(ctx, q2, body, ["parent_id"]), ctx.schema_name)

      assert stored(ctx, q2)["status"] == "draft"
    end

    test "L14 a restricted status cannot bypass the active rule" do
      ctx = admin("gh3315b-l14")
      qa = create!(ctx, nil, 1, "active")
      q1 = create!(ctx, nil, 1, "active")
      q2 = create!(ctx, q1, 2, "draft")
      body = fv(q2, 3, "draft") |> Map.delete("status")

      assert {:error, {:authoring_rule, :lineage_active_conflict}} =
               Authoring.update(update_attrs(ctx, qa, body, ["status"]), ctx.schema_name)

      assert stored(ctx, qa)["parent_id"] == nil
    end

    test "L15 a restricted version is judged by its stored value" do
      ctx = admin("gh3315b-l15")
      q1 = create!(ctx, nil, 1, "draft")
      q2 = create!(ctx, q1, 2, "draft")
      ExamFixtures.force_field!(ctx.schema_name, "question", q2, "version", {:put, 1})
      body = fv(q1, 5, "draft")
      prefix = ctx.schema_name

      assert {:error, {:authoring_rule, :version_not_increasing}} =
               AuthoringRules.check_write("question", q2, body, prefix, MapSet.new(["version"]))

      assert :ok = AuthoringRules.check_write("question", q2, body, prefix)
      assert AuthoringRules.check_write("question", q2, body, prefix, MapSet.new()) == :ok
    end
  end
end
