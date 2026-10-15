defmodule Letflow.Routers.EntityWritesPromotionRoutesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B1 follow-ups (TDV F3, REVIEWER F2, SEC): router wiring of the activator
  on the two promotion routes and `Letflow.Api.Context.activator/1`.

    * `POST /promotions/:id/apply` and `POST /tenants/:test_tenant_id/promote/:process_key`
      with a graph WITH lines: the activator recorded is the calling
      principal when it is a user of the TARGET tenant; a principal that is not (an actor with no
      users row in the target) gets 422 `entity_write_activator_not_in_target_tenant` and nothing
      is written; the same graph WITHOUT lines promotes as before; a refused line set is 422
      `entity_writes_invalid`.
    * A target-tenant principal can activate the same graph as a draft (the F2 recovery path).
    * `Context.activator/1` recomputes `platform_tenant?` from the database-resolved tenant: a
      stored flag is ignored and `PLATFORM_ADMIN` is dropped outside the platform tenant; a
      platform operator acting in another tenant is refused (SEC ruled this intended).

  `async: false` (VM-global platform-tenant pin, application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Context
  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  @promotions_opts Letflow.Routers.Promotions.init([])
  @definitions_opts Letflow.Routers.Definitions.init([])
  @tenants_opts Letflow.Routers.Tenants.init([])

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2587-b1-#{Ecto.UUID.generate()}",
      display_name: "GH-2587 B1 Routes User",
      email: "gh2587-b1-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp tenant!(prefix, with_type?) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: prefix)
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)

    if with_type? do
      {:ok, row} =
        EntityDefinitions.create_definition(
          %{
            definition: %{
              name: "stock_move",
              display_name: "stock_move",
              fields: [%{name: "label", type: :string}],
              writable_by_process: true,
              append_only: true
            },
            created_by: Ecto.UUID.generate()
          },
          schema
        )

      {:ok, _} =
        EntityDefinitions.activate_definition(row.name, Ecto.UUID.generate(), "go", schema)
    end

    Map.merge(tenant, %{schema: schema, user: user!(schema)})
  end

  defp lines_graph(type \\ "stock_move") do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "ht",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => "R",
            "entity_writes" => [
              %{
                "op" => "create",
                "entity_type" => type,
                "fields" => %{"label" => %{"const" => "x"}}
              }
            ]
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end

  defp plain_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp active_source!(source, key, graph) do
    row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: key,
        version: "2.0.0",
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: source.schema)

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^row.id)
      |> Repo.update_all([set: [status: :active]], prefix: source.schema)

    row
  end

  defp build_conn(method, path, target, user_id, roles, body) do
    conn = conn(method, path)

    conn =
      if body,
        do: put_req_header(%{conn | body_params: body}, "content-type", "application/json"),
        else: conn

    conn
    |> assign(:auth_context, %{user_id: user_id, tenant_id: target.tenant_id, roles: roles})
    |> assign(:trace_id, "gh2587-b1-routes")
  end

  defp target_rows(target, key),
    do: Repo.all(from(d in ProcessDefinition, where: d.name == ^key), prefix: target.schema)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Submit, approve and rehearse a review, then apply as `user_id`.
  defp apply_review(source, target, key, user_id) do
    submit =
      build_conn(:post, "/", target, Ecto.UUID.generate(), ["PLATFORM_ADMIN"], %{
        "source_tenant_id" => source.tenant_id,
        "target_tenant_id" => target.tenant_id,
        "process_key" => key,
        "base_version" => "1.0.0"
      })
      |> Letflow.Routers.Promotions.call(@promotions_opts)

    assert submit.status == 201, submit.resp_body
    %{"review_id" => review_id, "plan_digest" => digest} = json(submit)

    approve =
      build_conn(:post, "/#{review_id}/approve", target, user_id, ["PLATFORM_ADMIN"], %{
        "plan_digest" => digest
      })
      |> Letflow.Routers.Promotions.call(@promotions_opts)

    assert approve.status == 200, approve.resp_body

    %PromotionAssertionRun{
      review_id: review_id,
      idempotency_key: unique("b1-run"),
      plan_digest: digest,
      status: :passed,
      assertions_total: 1,
      assertions_passed: 1,
      assertions_failed: 0,
      completed_at: DateTime.utc_now()
    }
    |> Repo.insert!(prefix: target.schema)

    build_conn(:post, "/#{review_id}/apply", target, user_id, ["PLATFORM_ADMIN"], %{
      "plan_digest" => digest
    })
    |> Letflow.Routers.Promotions.call(@promotions_opts)
  end

  defp promote(source, target, key, user_id) do
    build_conn(
      :post,
      "/#{source.tenant_id}/promote/#{key}",
      target,
      user_id,
      ["PLATFORM_ADMIN"],
      nil
    )
    |> Letflow.Routers.Tenants.call(@tenants_opts)
  end

  setup do
    source = tenant!("gh2587-b1-rsrc", false)
    target = tenant!("gh2587-b1-rtgt", true)
    # the target is THE platform tenant: its PLATFORM_ADMIN is the operator
    Fixture.pin!(target.tenant_id)
    %{source: source, target: target}
  end

  describe "POST /promotions/:id/apply" do
    test "a target-tenant user is recorded as the activator", %{source: s, target: t} do
      key = unique("apply-ok")
      active_source!(s, key, lines_graph())

      resp = apply_review(s, t, key, t.user.id)
      assert resp.status == 200, resp.resp_body

      user_id = t.user.id

      assert [
               %{
                 status: :active,
                 activated_by: %{
                   "user_id" => ^user_id,
                   "roles" => ["PLATFORM_ADMIN"],
                   "authorized" => [%{"entity_type" => "stock_move", "op" => "create"}]
                 }
               }
             ] = target_rows(t, key)
    end

    test "an actor who is not a user of the target tenant: distinct 422, nothing written",
         %{source: s, target: t} do
      key = unique("apply-foreign")
      active_source!(s, key, lines_graph())

      resp = apply_review(s, t, key, Ecto.UUID.generate())

      assert resp.status == 422, resp.resp_body
      assert json(resp) == %{"error" => "entity_write_activator_not_in_target_tenant"}
      assert target_rows(t, key) == []
    end

    test "the same actor promotes the graph WITHOUT lines as before", %{source: s, target: t} do
      key = unique("apply-plain")
      active_source!(s, key, plain_graph())

      resp = apply_review(s, t, key, Ecto.UUID.generate())
      assert resp.status == 200, resp.resp_body
      assert [%{status: :active, activated_by: nil}] = target_rows(t, key)
    end

    test "a refused line set is 422 entity_writes_invalid", %{source: s, target: t} do
      key = unique("apply-bad")
      active_source!(s, key, lines_graph("ghost_type"))

      resp = apply_review(s, t, key, t.user.id)
      assert resp.status == 422, resp.resp_body

      assert %{
               "error" => "entity_writes_invalid",
               "violations" => [
                 %{"node_id" => "ht", "index" => 0, "code" => "entity_type_not_found"}
               ]
             } = json(resp)

      assert target_rows(t, key) == []
    end
  end

  describe "POST /tenants/:test_tenant_id/promote/:process_key" do
    test "a target-tenant user is recorded as the activator", %{source: s, target: t} do
      key = unique("promote-ok")
      active_source!(s, key, lines_graph())

      resp = promote(s, t, key, t.user.id)
      assert resp.status == 201, resp.resp_body

      user_id = t.user.id
      assert [%{status: :active, activated_by: %{"user_id" => ^user_id}}] = target_rows(t, key)
    end

    test "an actor not in the target tenant: distinct 422, nothing written; without lines it promotes",
         %{source: s, target: t} do
      key = unique("promote-foreign")
      active_source!(s, key, lines_graph())

      resp = promote(s, t, key, Ecto.UUID.generate())
      assert resp.status == 422, resp.resp_body
      assert json(resp) == %{"error" => "entity_write_activator_not_in_target_tenant"}
      assert target_rows(t, key) == []

      plain = unique("promote-plain")
      active_source!(s, plain, plain_graph())
      assert promote(s, t, plain, Ecto.UUID.generate()).status == 201
      assert [%{activated_by: nil}] = target_rows(t, plain)
    end

    test "a refused line set is 422 entity_writes_invalid", %{source: s, target: t} do
      key = unique("promote-bad")
      active_source!(s, key, lines_graph("ghost_type"))

      resp = promote(s, t, key, t.user.id)
      assert resp.status == 422, resp.resp_body
      assert %{"error" => "entity_writes_invalid", "violations" => [%{"index" => 0}]} = json(resp)
      assert target_rows(t, key) == []
    end
  end

  describe "recovery and the platform-operator limit" do
    test "a target-tenant principal activates the same graph as a draft", %{target: t} do
      assert {:ok, draft} =
               Definitions.create(
                 %{
                   name: unique("draft"),
                   version: "1",
                   graph: lines_graph(),
                   created_by: t.user.id
                 },
                 prefix: t.schema
               )

      activator =
        Letflow.Definitions.Activator.from_auth_context(
          %{user_id: t.user.id, roles: ["TENANT_ADMIN"]},
          false
        )

      assert {:ok, %{already_active: false}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator)

      assert %{activated_by: %{"user_id" => user_id}} =
               Repo.get!(ProcessDefinition, draft.id, prefix: t.schema)

      assert user_id == t.user.id
    end

    test "Context.activator/1 ignores a stored flag and drops PLATFORM_ADMIN outside the platform tenant",
         %{source: s, target: t} do
      ctx = fn tenant ->
        conn(:get, "/")
        |> assign(:auth_context, %{
          user_id: t.user.id,
          tenant_id: tenant.tenant_id,
          roles: ["PLATFORM_ADMIN"],
          platform_tenant?: true
        })
      end

      assert %{roles: ["PLATFORM_ADMIN"], entities_records_write?: true} =
               Context.activator(ctx.(t))

      # the same stored flag, a tenant that is NOT the platform tenant: nothing is conferred
      assert %{roles: [], entities_records_write?: false} = Context.activator(ctx.(s))
      assert Context.activator(conn(:get, "/")) == nil
    end

    test "a platform operator acting in another tenant is refused at activation (intended)",
         %{source: s, target: t} do
      other = tenant!("gh2587-b1-other", true)

      {:ok, draft} =
        Definitions.create(
          %{name: unique("op"), version: "1", graph: lines_graph(), created_by: s.user.id},
          prefix: other.schema
        )

      # PLATFORM_ADMIN alone holds nothing outside the platform tenant: refused at the route
      resp =
        build_conn(:post, "/#{draft.id}/activate", other, t.user.id, ["PLATFORM_ADMIN"], nil)
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp.status == 403, resp.resp_body

      # with a tenant role the route passes, but the operator's user row lives in `t`, not in
      # `other`: the activator is refused
      resp =
        build_conn(
          :post,
          "/#{draft.id}/activate",
          other,
          t.user.id,
          ["PLATFORM_ADMIN", "TENANT_ADMIN"],
          nil
        )
        |> Letflow.Routers.Definitions.call(@definitions_opts)

      assert resp.status == 422, resp.resp_body

      assert %{
               "error" => "entity_writes_invalid",
               "violations" => [%{"code" => "entity_write_activator_required"}]
             } = json(resp)

      assert %{status: :draft} = Repo.get!(ProcessDefinition, draft.id, prefix: other.schema)
    end
  end
end
