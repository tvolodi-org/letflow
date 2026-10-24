defmodule Letflow.Routers.TasksTest do
  @moduledoc """
  Tests for `Letflow.Routers.Tasks`/`Letflow.Tasks` (REQ-083) — the three
  read-path handlers (`GET /tasks`, `GET /tasks/inbox`, `GET /tasks/:id`).
  See `test/specs/REQ-083.md` for the acceptance-criterion -> test-case
  mapping and the rationale for each case (why the case exists, not merely a
  restatement of the criterion it covers).

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) and
  `Letflow.TenantFixture` for real provisioned tenant schemas, matching
  `test/letflow/routers/identity_test.exs`'s own established pattern for
  this class of test — same dispatch mechanism (direct
  `Letflow.Routers.Tasks.call/2`, `conn.assigns[:auth_context]` set directly,
  bypassing `AuthPipeline`), same `insert_*!` fixture-helper shape, same
  cross-tenant-identical-404 idiom, same full-key-set (not
  presence/exclusion-only) assertion discipline for AC5. `async: false` for
  the whole module — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.ServiceCatalog.Entry, as: CatalogEntry
  alias Letflow.ServiceCatalog.Version, as: CatalogVersion
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Tasks.init([])

  # ── Shared test dispatch helper (matches identity_test.exs's shape) ────
  #
  # REQ-085 extends this helper with an optional `:body` field -- identical
  # shape to identity_test.exs's own build_conn/4 -- so the four new write
  # routes can dispatch a JSON request body the same way GET-only REQ-083
  # tests never needed to.
  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())
    body = Keyword.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Tasks.call(conn, @opts)

  # ── Fixture helpers ──────────────────────────────────────────────────

  # Inserts a full instance_projections -> tokens -> tasks FK chain (the
  # `tasks` table carries mandatory FKs onto both, per
  # priv/repo/migrations/20260818110003_create_tasks.exs) and returns the
  # inserted `Letflow.Engine.Task` row.
  defp insert_task!(tenant, attrs) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: tenant.schema_name)

    token =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: Map.get(attrs, :node_id, "review"),
        branch_id: "b1"
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    default = %{
      instance_id: instance_id,
      token_id: token.id,
      node_id: Map.get(attrs, :node_id, "review"),
      node_name: Map.get(attrs, :node_name, "Review"),
      assignee_type: nil,
      assignee_ref: nil
    }

    %EngineTask{}
    |> EngineTask.insert_changeset(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_user!(tenant, attrs) do
    default = %{
      username: "user-#{Ecto.UUID.generate()}",
      display_name: "A User",
      email: "user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_group!(tenant, attrs) do
    default = %{name: "group-#{Ecto.UUID.generate()}", display_name: "A Group"}

    %Group{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_group_member!(tenant, group_id, user_id) do
    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group_id, user_id: user_id})
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # Direct insert against the tenant-schema-scoped TenantRole table (not
  # RoleRegistry.upsert_role/2, which issues an unprefixed query per the
  # design's rework-1 note) -- binds `role_name` to `group_id`. Every caller in
  # this file uses an arbitrary HUMAN_TASK routing name ("approver"), never
  # one of Letflow.Api.Authorization.roles/0's six platform-role literals, so
  # `kind: :process_routing_role` is the correct fixed kind here (ISS-0774)
  # -- not a caller-supplied parameter, since nothing in this file exercises
  # the platform-role domain.
  defp insert_role!(tenant, role_name, group_id) do
    %TenantRole{}
    |> Ecto.Changeset.change(%{name: role_name, kind: :process_routing_role, group_id: group_id})
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # ── REQ-085 fixture helpers (write-path tests) ──────────────────────────

  # Directly force a task row's status column -- used only to construct an
  # already-COMPLETED/already-CANCELLED fixture for AC3 (Task.complete_changeset/2
  # is production code driven exclusively by Letflow.Engine.complete_task/3;
  # bypassing it here with a raw Ecto.Changeset.change/2, matching this file's own
  # insert_group!/insert_group_member!/insert_role! precedent for direct fixture
  # writes, is deliberate -- REQ-085's own claim/assign/reassign functions never
  # write :status themselves, so there is no "real" write path to drive here).
  defp force_task_status!(tenant, task, status) do
    task
    |> Ecto.Changeset.change(%{status: status})
    |> Repo.update!(prefix: tenant.schema_name)
  end

  # ISS-0944: directly force an InstanceProjection row's status column --
  # used only to construct an already-ERROR fixture (the engine's own
  # :active -> :error transition is driven by dispatch/execution failures
  # deep inside complete_task/3, not something this router-layer test needs
  # to reproduce end-to-end; same direct-fixture-write rationale as
  # force_task_status!/3 above).
  defp force_instance_status!(tenant, instance_id, status) do
    InstanceProjection
    |> Repo.get!(instance_id, prefix: tenant.schema_name)
    |> Ecto.Changeset.change(%{status: status})
    |> Repo.update!(prefix: tenant.schema_name)
  end

  defp unique_name(prefix \\ "req085-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK) -> END -- the plainest graph shape, matching
  # engine_complete_task_test.exs's own single-hop shape. Completing `task`
  # drives the instance straight to :completed within the same call, which is
  # exactly what AC1 needs to observe ("the token has moved").
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # ISS-0942 AC4 fixture: same shape as graph_human_task_end/0, but the
  # HUMAN_TASK node's assignee is explicitly overridden to `assignee_type`/
  # `assignee_ref` via `resolve_assignee/1`'s documented precedence
  # (`node.attributes["assignee_type"]`, if present, always wins over the
  # `"role"`-derived "ROLE" default -- lib/letflow/engine/task_activation.ex).
  # `attributes["role"]` is still populated (CHK-09 requires a HUMAN_TASK
  # node's `role` to be a non-blank string at authoring time regardless of
  # the derived assignee_type), but its value is irrelevant once
  # `assignee_type` is explicit -- `assignee_ref` is always `attributes["role"]`
  # itself, so it is set to the real `assignee_ref` under test.
  defp graph_human_task_end_for_assignee(assignee_type, assignee_ref) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => assignee_ref, "assignee_type" => assignee_type}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp active_definition!(tenant, graph) do
    attrs = %{
      name: unique_name(),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: tenant.schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: tenant.schema_name)

    activated
  end

  # Starts a real instance (via the real Letflow.Engine.create/2, REQ-045) and
  # returns {instance_id, pending_task} -- the one real, non-Repo-bypassing way to
  # get a genuinely PENDING task whose owning instance is a live engine instance,
  # needed by AC1's "advances the owning instance" assertion (a task inserted via
  # insert_task!/2 alone has no instance an engine transition could actually drive).
  defp start_instance_with_pending_task!(tenant, graph) do
    definition = active_definition!(tenant, graph)

    start_attrs = %{
      definition_id: definition.id,
      initial_variables: %{"seed" => "value"},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique_idempotency_key("req085-start")
    }

    assert {:ok, result} = Engine.create(start_attrs, prefix: tenant.schema_name)

    [task] = Repo.all(EngineTask, prefix: tenant.schema_name)
    assert task.status == :pending

    {result.instance_id, task}
  end

  # ISS-0942 AC4 fixture: same as start_instance_with_pending_task!/2, but
  # using graph_human_task_end_for_assignee/2 so the resulting PENDING task's
  # assignee_type/assignee_ref are exactly `assignee_type`/`assignee_ref`,
  # created through the real Letflow.Engine.create/2 activation path (not a
  # raw insert_task!/2 fixture) -- needed so Engine.complete_task/3 (called
  # after Tasks.authorize_completion/3 returns :ok) has a real instance/
  # snapshot to drive, proving the matching-assignee path genuinely still
  # reaches and succeeds through the engine, not just the authz pre-check.
  defp start_instance_with_pending_task_for_assignee!(tenant, assignee_type, assignee_ref) do
    start_instance_with_pending_task!(
      tenant,
      graph_human_task_end_for_assignee(assignee_type, assignee_ref)
    )
  end

  # ── REQ-126 fixture helpers (form-version pinning) ──────────────────────

  # Same single-hop START -> HUMAN_TASK("task") -> END shape as
  # graph_human_task_end/0, with a different node attribute -- used as the
  # "v2" graph in REQ-126 AC3's promote-after-task-creation scenario (design
  # §7.2: "any graph delta ... the specific delta is irrelevant to this test,
  # only that v2 exists as a distinct process_definitions row").
  defp graph_human_task_end_v2 do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "a-different-approver"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # Like active_definition!/2 but takes an explicit `name` -- needed by AC3's
  # scenario, which promotes a *second* version under the *same* process name
  # (active_definition!/2 always mints a fresh unique_name/0, so it cannot
  # express "v2 of the same process" on its own).
  defp active_definition_named!(tenant, name, version, graph) do
    attrs = %{
      name: name,
      version: version,
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: tenant.schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: tenant.schema_name)

    activated
  end

  defp item_ids(body), do: Enum.map(body["items"], & &1["id"])

  # REQ-126 (MOB-3 form-version pinning) added "form_id"/"form_version" to both
  # maps -- this allowlist is updated to the new, intentional 11-key/13-key
  # shape (not weakened: the two new keys are exactly what REQ-126 AC1 asserts
  # must be present, see the "REQ-126" describe blocks below).
  @task_list_item_keys [
    "assignee_ref",
    "assignee_type",
    "created_at",
    "form_id",
    "form_version",
    "id",
    "instance_id",
    "node_id",
    "node_name",
    "status",
    "token_id"
  ]

  @task_detail_keys Enum.sort(
                      @task_list_item_keys ++ ["correlation_key", "updated_at", "form_schema"]
                    )

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- end-to-end coverage for all three handlers, list/inbox paginated
  # across >= 2 pages
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: GET /tasks/:id basic end-to-end" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-getbyid")}

    test "returns 200 with the task detail shape", %{tenant: tenant} do
      task = insert_task!(tenant, %{node_id: "n1", node_name: "Node One"})

      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == task.id
      assert body["node_id"] == "n1"
      assert body["status"] == "PENDING"
    end
  end

  describe "AC1: GET /tasks paginates across at least two pages (design §3.1)" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-list-page")}

    test "page_size=1 pages through two tasks with no overlap and no gap", %{tenant: tenant} do
      task_1 = insert_task!(tenant, %{node_id: "n1"})
      task_2 = insert_task!(tenant, %{node_id: "n2"})

      conn_1 =
        build_conn(:get, "/?page_size=1", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn_1.status == 200
      body_1 = Jason.decode!(conn_1.resp_body)
      assert length(body_1["items"]) == 1
      refute is_nil(body_1["next_cursor"])

      conn_2 =
        build_conn(
          :get,
          "/?page_size=1&cursor=#{URI.encode_www_form(body_1["next_cursor"])}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn_2.status == 200
      body_2 = Jason.decode!(conn_2.resp_body)
      assert length(body_2["items"]) == 1
      assert is_nil(body_2["next_cursor"])

      assert Enum.sort(item_ids(body_1) ++ item_ids(body_2)) ==
               Enum.sort([task_1.id, task_2.id])

      assert item_ids(body_1) != item_ids(body_2)
    end
  end

  describe "AC1: GET /tasks/inbox paginates across at least two pages" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-inbox-page")}

    test "an operator's inbox (whole-queue scope) pages through two tasks with no overlap and no gap",
         %{tenant: tenant} do
      task_1 = insert_task!(tenant, %{node_id: "n1"})
      task_2 = insert_task!(tenant, %{node_id: "n2"})

      # PROCESS_OPERATOR is not task-worker-only (Authorization.is_task_worker_only?/1),
      # so the inbox forces :unfiltered scope -- the whole tenant queue, per design §5.3
      # point 2 -- exercising the same cursor mechanism as GET /tasks.
      conn_1 =
        build_conn(:get, "/inbox?page_size=1", tenant, roles: ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn_1.status == 200
      body_1 = Jason.decode!(conn_1.resp_body)
      assert length(body_1["items"]) == 1
      refute is_nil(body_1["next_cursor"])

      conn_2 =
        build_conn(
          :get,
          "/inbox?page_size=1&cursor=#{URI.encode_www_form(body_1["next_cursor"])}",
          tenant,
          roles: ["PROCESS_OPERATOR"]
        )
        |> dispatch()

      assert conn_2.status == 200
      body_2 = Jason.decode!(conn_2.resp_body)
      assert length(body_2["items"]) == 1
      assert is_nil(body_2["next_cursor"])

      assert Enum.sort(item_ids(body_1) ++ item_ids(body_2)) ==
               Enum.sort([task_1.id, task_2.id])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- inbox is per-principal: direct/group/role inclusion, different-
  # user exclusion. Four explicit assertions, not folded into one.
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: GET /tasks/inbox scoping for a task-worker-only caller" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-inbox-scope")}

    test "returns a task assigned directly to X, via a group X belongs to, via a role X holds -- and never a task assigned only to a different user Y",
         %{tenant: tenant} do
      user_x = insert_user!(tenant, %{username: "user-x"}).id
      user_y = insert_user!(tenant, %{username: "user-y"}).id

      group = insert_group!(tenant, name: "reviewers")
      insert_group_member!(tenant, group.id, user_x)
      insert_role!(tenant, "approver", group.id)

      task_direct = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      task_via_group = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id})

      task_via_role =
        insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "approver"})

      task_other_user = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/inbox?page_size=50", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      # Four explicit assertions (AC2's own wording) -- not folded into one.
      assert task_direct.id in returned_ids
      assert task_via_group.id in returned_ids
      assert task_via_role.id in returned_ids
      refute task_other_user.id in returned_ids
    end
  end

  describe "AC2 extra assurance: a role held only in a DIFFERENT tenant does not leak into this tenant's inbox (INV-1 on the reworked resolve_principal_scope/2 path)" do
    test "a role name identical to one X holds in tenant A, but bound to a group in tenant B that X does NOT belong to in A, does not leak a tenant-B-assigned task into X's tenant-A inbox" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req083-role-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req083-role-iso-b")

      user_x = Ecto.UUID.generate()

      # Tenant B: a role named "approver" bound to a group X does NOT belong
      # to in A (this is checking the reworked resolve_principal_scope/2's
      # :prefix-scoped TenantRole query never crosses schemas) -- a task
      # assigned to that role must never surface in X's tenant-A inbox.
      group_b = insert_group!(tenant_b, name: "b-reviewers")
      insert_role!(tenant_b, "approver", group_b.id)
      task_in_b = insert_task!(tenant_b, %{assignee_type: "ROLE", assignee_ref: "approver"})

      # Tenant A: X holds no role at all (no TenantRole row, no group
      # membership) -- only a same-tenant, directly-assigned task exists.
      task_in_a = insert_task!(tenant_a, %{assignee_type: "USER", assignee_ref: user_x})

      conn =
        build_conn(:get, "/inbox?page_size=50", tenant_a,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      assert task_in_a.id in returned_ids
      refute task_in_b.id in returned_ids
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3/INV-5 -- cross-tenant task id == nonexistent id, byte-identical
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3/INV-5: GET /tasks/:id cross-tenant id is indistinguishable from a nonexistent id" do
    test "same status code and same response body" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req083-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req083-cross-b")

      tenant_b_task = insert_task!(tenant_b, %{})

      resp_cross_tenant =
        build_conn(:get, "/#{tenant_b_task.id}", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      resp_never_existed =
        build_conn(:get, "/#{Ecto.UUID.generate()}", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert resp_cross_tenant.status == 404
      assert resp_cross_tenant.status == resp_never_existed.status
      assert resp_cross_tenant.resp_body == resp_never_existed.resp_body
    end
  end

  describe "GET /tasks/:id applies the inbox principal scope to a task-worker-only caller (INV-2/INV-5)" do
    setup do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t0038-byid-scope")
      %{tenant: tenant, user_x: insert_user!(tenant, %{username: "user-x"}).id}
    end

    test "a ROLE task assigned to a role the caller does not hold answers 404, identical to a nonexistent id",
         %{tenant: tenant, user_x: user_x} do
      other_group = insert_group!(tenant, name: "others")
      insert_role!(tenant, "other-role", other_group.id)
      task = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "other-role"})

      hidden =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TASK_WORKER"], user_id: user_x)
        |> dispatch()

      missing =
        build_conn(:get, "/#{Ecto.UUID.generate()}", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert hidden.status == 404
      assert hidden.resp_body == missing.resp_body
      refute hidden.resp_body =~ "other-role"
    end

    test "tasks assigned to the caller, to their group or to a role they hold answer 200",
         %{tenant: tenant, user_x: user_x} do
      group = insert_group!(tenant, name: "reviewers")
      insert_group_member!(tenant, group.id, user_x)
      insert_role!(tenant, "approver", group.id)

      tasks = [
        insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x}),
        insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id}),
        insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "approver"})
      ]

      for task <- tasks do
        conn =
          build_conn(:get, "/#{task.id}", tenant, roles: ["TASK_WORKER"], user_id: user_x)
          |> dispatch()

        assert conn.status == 200
        assert Jason.decode!(conn.resp_body)["id"] == task.id
      end
    end

    test "a caller who is not task-worker-only still reads another role's task",
         %{tenant: tenant, user_x: user_x} do
      task = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "other-role"})

      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"], user_id: user_x)
        |> dispatch()

      assert conn.status == 200
    end

    test "a task of tenant B requested by a tenant A task worker answers 404", %{
      tenant: tenant_a,
      user_x: user_x
    } do
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "t0038-byid-scope-b")
      task_b = insert_task!(tenant_b, %{assignee_type: "USER", assignee_ref: user_x})

      conn =
        build_conn(:get, "/#{task_b.id}", tenant_a, roles: ["TASK_WORKER"], user_id: user_x)
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4/INV-1 -- tenant isolation on GET /tasks, identically-named nodes
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4/INV-1: GET /tasks tenant isolation with identically-named nodes" do
    test "tenant A caller sees no tenant B task, even though both tenants have a node named the same" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req083-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req083-iso-b")

      task_a =
        insert_task!(tenant_a, %{node_id: "shared_node", node_name: "Shared Node"})

      _task_b =
        insert_task!(tenant_b, %{node_id: "shared_node", node_name: "Shared Node"})

      conn =
        build_conn(:get, "/", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert item_ids(body) == [task_a.id]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5/INV-2 -- explicit field allowlist, full key-set assertion
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5/INV-2: response allowlists" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-allowlist")}

    test "GET /tasks item shape is exactly the nine allowlisted keys", %{tenant: tenant} do
      insert_task!(tenant, %{})

      conn = build_conn(:get, "/", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["items"] != []

      for item <- body["items"] do
        assert Map.keys(item) |> Enum.sort() == @task_list_item_keys
      end
    end

    test "GET /tasks/:id shape is exactly the eleven allowlisted keys (no claimed_by, etc.) -- form_schema is present (REQ-286), served as null for a task with no schema (AC2)",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn = build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.keys(body) |> Enum.sort() == @task_detail_keys
      assert Map.has_key?(body, "form_schema")
      assert is_nil(body["form_schema"])
      refute Map.has_key?(body, "claimed_by")
      refute Map.has_key?(body, "output_variables")
      refute Map.has_key?(body, "completed_by")
      refute Map.has_key?(body, "completed_at")
      refute Map.has_key?(body, "cancelled_at")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7 -- 403 without TasksRead on all three endpoints
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7: a caller without TasksRead gets 403 on all three endpoints" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-403")}

    test "GET /tasks -> 403 for a caller with no roles at all", %{tenant: tenant} do
      conn = build_conn(:get, "/", tenant, roles: []) |> dispatch()
      assert conn.status == 403
    end

    test "GET /tasks/inbox -> 403 for a caller with no roles at all", %{tenant: tenant} do
      conn = build_conn(:get, "/inbox", tenant, roles: []) |> dispatch()
      assert conn.status == 403
    end

    test "GET /tasks/:id -> 403 for a caller with no roles at all", %{tenant: tenant} do
      task = insert_task!(tenant, %{})
      conn = build_conn(:get, "/#{task.id}", tenant, roles: []) |> dispatch()
      assert conn.status == 403
    end

    # AGENT_RUNNER is a real, recognized role (Authorization.roles_from_strings/1
    # accepts it) that role_allows?/2 grants zero permissions to -- a role that
    # exists but genuinely lacks TasksRead, distinct from "no roles at all".
    test "GET /tasks -> 403 for a caller whose only role lacks TasksRead", %{tenant: tenant} do
      conn = build_conn(:get, "/", tenant, roles: ["AGENT_RUNNER"]) |> dispatch()
      assert conn.status == 403
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0774 T4 -- GET /tasks/inbox end-to-end, the SwiftRoute/T-0140 shape
  # (docs/issues/ISS-0774.yaml, design §3/§4; AC2 + AC3)
  # ══════════════════════════════════════════════════════════════════════

  describe "ISS-0774 T4: GET /tasks/inbox, process-routing-role-only vs. +companion platform role" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0774-t4")}

    # Binds a :platform_role-kind TenantRole -- distinct from this file's existing
    # insert_role!/3, which is fixed to :process_routing_role (see that helper's
    # own comment). Direct schema-scoped insert, matching insert_role!/3's own
    # precedent (not RoleRegistry.upsert_role/4, which issues an unprefixed query).
    defp insert_platform_role!(tenant, role_name, group_id) do
      %TenantRole{}
      |> Ecto.Changeset.change(%{name: role_name, kind: :platform_role, group_id: group_id})
      |> Repo.insert!(prefix: tenant.schema_name)
    end

    # Reproduces the exact SwiftRoute/T-0140 diagnostic shape (ISS-0774.yaml
    # "discovered live" section): a group bound to the process-definition's own
    # HUMAN_TASK routing role name ("role-ops-manager", the literal string used by
    # test/fixtures/simulation/swiftroute/process_route_approval.yaml's
    # "ops-review" node), the user added as a member, and a real assignable task
    # routed to that same role name -- then derives the caller's effective
    # platform-role set via the REAL Identity.list_effective_role_names/2 (the
    # exact function AuthPipeline calls in production), rather than hand-typing a
    # `roles:` list into build_conn/4. This is what ties this router-level test to
    # the actual identity-layer fix instead of merely re-asserting build_conn's
    # own bypass mechanism.
    test "process-routing-role-only caller (no companion platform role) still 403s -- request-time behavior unchanged",
         %{tenant: tenant} do
      user = insert_user!(tenant, %{username: "iss0774-ops-only"})
      group = insert_group!(tenant, name: "iss0774-ops-reviewers")
      insert_group_member!(tenant, group.id, user.id)
      insert_role!(tenant, "role-ops-manager", group.id)

      _task =
        insert_task!(tenant, %{
          node_id: "ops-review",
          node_name: "Ops Review",
          assignee_type: "ROLE",
          assignee_ref: "role-ops-manager"
        })

      effective_roles = Identity.list_effective_role_names(user.id, prefix: tenant.schema_name)
      assert effective_roles == []

      conn =
        build_conn(:get, "/inbox?page_size=50", tenant,
          roles: effective_roles,
          user_id: user.id
        )
        |> dispatch()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert conn |> get_resp_header("content-type") |> hd() =~ "problem+json"
      assert body["status"] == 403
    end

    test "SAME caller, plus a companion TASK_WORKER platform-role membership: 200, and their routed task appears in the inbox",
         %{tenant: tenant} do
      user = insert_user!(tenant, %{username: "iss0774-ops-plus-worker"})

      routing_group = insert_group!(tenant, name: "iss0774-ops-reviewers-2")
      insert_group_member!(tenant, routing_group.id, user.id)
      insert_role!(tenant, "role-ops-manager", routing_group.id)

      task =
        insert_task!(tenant, %{
          node_id: "ops-review",
          node_name: "Ops Review",
          assignee_type: "ROLE",
          assignee_ref: "role-ops-manager"
        })

      # Companion platform-role grant -- design §4's prescribed remedy (add each
      # SwiftRoute persona's TASK_WORKER membership alongside their existing
      # routing-group membership). A SEPARATE group, matching real provisioning
      # shape (a platform-role grant is not the same group as a routing role's).
      platform_group = insert_group!(tenant, name: "iss0774-task-workers")
      insert_group_member!(tenant, platform_group.id, user.id)
      insert_platform_role!(tenant, "TASK_WORKER", platform_group.id)

      effective_roles = Identity.list_effective_role_names(user.id, prefix: tenant.schema_name)
      assert effective_roles == ["TASK_WORKER"]

      conn =
        build_conn(:get, "/inbox?page_size=50", tenant,
          roles: effective_roles,
          user_id: user.id
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert task.id in item_ids(body)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Route-match ordering, validation, not-found -- additional coverage
  # ══════════════════════════════════════════════════════════════════════

  describe "route-match ordering: /inbox is not swallowed by /:id" do
    test "GET /tasks/inbox is served as the inbox, not as an invalid-UUID :id lookup" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req083-route-order")

      conn =
        build_conn(:get, "/inbox", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "items")
    end
  end

  describe "validation failures" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-validation")}

    test "GET /tasks?status=bogus is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/?status=bogus", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end

    test "GET /tasks?instance_id=not-a-uuid is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/?instance_id=not-a-uuid", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end

    test "GET /tasks/:id with a malformed id is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/not-a-uuid", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end

    test "GET /tasks?cursor=not-a-valid-cursor!!! is rejected with 422 (this router's own convention, distinct from Identity's 400)",
         %{tenant: tenant} do
      conn =
        build_conn(:get, "/?cursor=not-a-valid-cursor!!!", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 422
    end
  end

  describe "status filter narrows GET /tasks results" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-status-filter")}

    test "status=COMPLETED excludes a PENDING task", %{tenant: tenant} do
      pending_task = insert_task!(tenant, %{})

      conn =
        build_conn(:get, "/?status=COMPLETED", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute pending_task.id in item_ids(body)
    end
  end

  describe "GET /tasks with assignee_id filters an :all-scope caller's results (design §5.2 point 3)" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-assignee-id")}

    test "an operator supplying assignee_id sees only that user's task", %{tenant: tenant} do
      user_x = Ecto.UUID.generate()
      user_y = Ecto.UUID.generate()

      task_x = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      _task_y = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/?assignee_id=#{user_x}", tenant, roles: ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert item_ids(body) == [task_x.id]
    end
  end

  # INV-2 -- a task-worker's row scope can never be widened by a caller-
  # supplied assignee_id, even one naming a different user.
  describe "INV-2: a task-worker-only caller's GET /tasks scope ignores a caller-supplied assignee_id" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req083-inv2")}

    test "assignee_id naming a different user does not widen a task-worker's own scope",
         %{tenant: tenant} do
      user_x = Ecto.UUID.generate()
      user_y = Ecto.UUID.generate()

      _task_x = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      task_y = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/?assignee_id=#{user_y}", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute task_y.id in item_ids(body)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-132 -- AllowWithRowFilter row scoping on GET /tasks specifically
  # (design lib/letflow/design/req132-row-scoping.md, "Open questions" #2:
  # the mechanism is already shipped and covered for GET /tasks/inbox above,
  # but not yet for GET /tasks itself). See test/specs/REQ-132.md for the
  # full acceptance-criterion -> test-case mapping and rationale.
  # ══════════════════════════════════════════════════════════════════════

  describe "REQ-132 AC1: GET /tasks for a TASK_WORKER-only caller returns exactly the {:own_user_and_groups, user_id} scope" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req132-ac1")}

    test "own-assigned task and member-group task are returned; a different user's task and a non-member-group task are not",
         %{tenant: tenant} do
      user_x = insert_user!(tenant, %{username: "req132-ac1-x"}).id
      user_y = insert_user!(tenant, %{username: "req132-ac1-y"}).id

      member_group = insert_group!(tenant, name: "req132-ac1-member-group")
      insert_group_member!(tenant, member_group.id, user_x)

      non_member_group = insert_group!(tenant, name: "req132-ac1-non-member-group")
      # user_x deliberately never added as a member of non_member_group

      task_own = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})

      task_via_member_group =
        insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: member_group.id})

      task_other_user = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      task_via_non_member_group =
        insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: non_member_group.id})

      conn =
        build_conn(:get, "/?page_size=50", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      assert task_own.id in returned_ids
      assert task_via_member_group.id in returned_ids
      refute task_other_user.id in returned_ids
      refute task_via_non_member_group.id in returned_ids
    end
  end

  # AC2: assignee_id widening attack, with a group-task fixture -- distinct
  # from AC1's plain coverage (no query-param attack) and from the existing
  # INV-2 test above (no group fixture, so it can't show the caller's own
  # scope stays intact alongside the exclusion).
  describe "REQ-132 AC2: assignee_id widening attack with a group-task fixture" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req132-ac2")}

    test "?assignee_id=<different user> excludes that user's task but keeps own+group tasks",
         %{tenant: tenant} do
      user_x = insert_user!(tenant, %{username: "req132-ac2-x"}).id
      user_y = insert_user!(tenant, %{username: "req132-ac2-y"}).id

      group = insert_group!(tenant, name: "req132-ac2-group")
      insert_group_member!(tenant, group.id, user_x)

      task_own = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      task_via_group = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id})
      task_y = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      conn =
        build_conn(:get, "/?assignee_id=#{user_y}&page_size=50", tenant,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      # The attack: naming user_y via the query param must not surface user_y's task.
      refute task_y.id in returned_ids
      # The caller's own {:own_user_and_groups, _} scope is untouched by the
      # (ignored) query param -- still returns own + group tasks.
      assert task_own.id in returned_ids
      assert task_via_group.id in returned_ids
    end
  end

  describe "REQ-132 AC3: GET /tasks for a plain-:Allow role (task_scope: :all) stays unfiltered" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req132-ac3")}

    test "a TENANT_ADMIN caller sees tasks assigned to three different users/groups, none of which are their own",
         %{tenant: tenant} do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      some_group = insert_group!(tenant, name: "req132-ac3-group")

      task_a = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_a})
      task_b = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_b})

      task_group =
        insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: some_group.id})

      conn =
        build_conn(:get, "/?page_size=50", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      # No AllowWithRowFilter narrowing applies to a plain :Allow (task_scope:
      # :all) decision -- every task shows up regardless of who/what it is
      # assigned to, proving the row-filter mechanism is not applied
      # indiscriminately.
      assert task_a.id in returned_ids
      assert task_b.id in returned_ids
      assert task_group.id in returned_ids
    end
  end

  describe "REQ-132 AC5: GET /tasks -- REQ-072 tenant scoping still applies underneath the row filter" do
    test "a task-worker's own-tenant group task is returned, but a same-user task belonging to a different tenant is not" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req132-ac5-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req132-ac5-b")

      # group_members.user_id carries a foreign key onto the tenant-schema
      # users table, so user_x must be a real row in tenant_a specifically
      # (the id value itself is reused, unenforced, as the same "user" in
      # tenant_b's insert_task!/2 fixture below -- group_members's FK does
      # not apply there since that insert never touches group_members).
      user_x = insert_user!(tenant_a, %{username: "req132-ac5-x"}).id

      # Tenant A: user_x is a member of a group with a group-assigned task --
      # the one row the {:principal, _} scope should surface.
      group_a = insert_group!(tenant_a, name: "req132-ac5-group-a")
      insert_group_member!(tenant_a, group_a.id, user_x)
      task_in_a = insert_task!(tenant_a, %{assignee_type: "GROUP", assignee_ref: group_a.id})

      # Tenant B: a task directly assigned to the SAME user_id, in a
      # different tenant schema -- must never leak into tenant A's listing,
      # proving the :prefix scoping from REQ-072 still governs underneath
      # the {:own_user_and_groups, _} row filter, not merely user-id
      # matching alone.
      task_in_b = insert_task!(tenant_b, %{assignee_type: "USER", assignee_ref: user_x})

      conn =
        build_conn(:get, "/?page_size=50", tenant_a,
          roles: ["TASK_WORKER"],
          user_id: user_x
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      returned_ids = item_ids(body)

      assert task_in_a.id in returned_ids
      refute task_in_b.id in returned_ids
    end
  end

  describe "GET /tasks/:id 404s for a genuinely nonexistent id (not just cross-tenant)" do
    test "returns 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req083-notfound")

      conn =
        build_conn(:get, "/#{Ecto.UUID.generate()}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 404
    end
  end

  describe "unmatched route returns the RFC 9457 404 problem document" do
    test "an unknown sub-path 404s" do
      # REQ-447 PR 2: only the platform operator reaches the router's own 404 catch-all
      # (an ordinary tenant's admin gets the uniform 403 from the :UnmatchedRoute marker).
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req083-unmatched")
      Letflow.Support.PlatformTenantFixture.pin!(tenant.tenant_id)

      conn =
        build_conn(:get, "/bogus/nested/path", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 404

      # a tenant admin of the same tenant, with the pin cleared, is refused (403)
      Letflow.Support.PlatformTenantFixture.unpin!()

      denied =
        build_conn(:get, "/bogus/nested/path", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert denied.status == 403
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-126 -- version-pinned form references on task payloads (MOB-3).
  # See test/specs/REQ-126.md for the full acceptance-criterion -> test-case
  # mapping and rationale.
  # ══════════════════════════════════════════════════════════════════════

  # ── AC1 -- task payloads carry form_id/form_version, list and detail ────

  describe "REQ-126 AC1: task payloads returned by the read routes carry form_id/form_version" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req126-ac1")}

    test "GET /tasks/:id form_id/form_version match the activated node id and the started-from definition version",
         %{tenant: tenant} do
      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["form_id"] == "task"
      assert body["form_version"] == "1.0.0"
    end

    test "GET /tasks list item for the same task also carries the matching form_id/form_version",
         %{tenant: tenant} do
      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      conn =
        build_conn(:get, "/", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      [item] = Enum.filter(body["items"], &(&1["id"] == task.id))
      assert item["form_id"] == "task"
      assert item["form_version"] == "1.0.0"
    end
  end

  # ── AC3 -- form_version is pinned at task-creation time, not re-derived ─

  describe "REQ-126 AC3: form_version reflects the version pinned when the task was created, not a later promotion" do
    test "promoting a new process_definitions version (same name, different graph) after the task was created does not change the task's form_version" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req126-ac3")
      process_name = unique_name("req126-form-pin")

      # Step 1/2 (design §7.2) -- create/promote v1, start an instance from
      # it, which writes the instance_definition_snapshots row with
      # definition_ver: "1.0.0" and activates the "task" HUMAN_TASK node.
      v1 = active_definition_named!(tenant, process_name, "1.0.0", graph_human_task_end())

      start_attrs = %{
        definition_id: v1.id,
        initial_variables: %{"seed" => "value"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("req126-ac3-start")
      }

      assert {:ok, _result} = Engine.create(start_attrs, prefix: tenant.schema_name)

      [task] = Repo.all(EngineTask, prefix: tenant.schema_name)
      assert task.status == :pending

      # Step 3 -- promote a NEW definition version v2, same process name, a
      # different graph (the "task" node's attributes changed). Definitions.
      # activate/2 atomically deprecates v1 in the same transaction (PD-03),
      # so v2 -- not v1 -- is now the tenant's live/active definition for
      # this process name.
      v2 =
        active_definition_named!(tenant, process_name, "2.0.0", graph_human_task_end_v2())

      assert v2.status == :active

      v1_reloaded =
        Repo.get!(Letflow.Definitions.ProcessDefinition, v1.id, prefix: tenant.schema_name)

      assert v1_reloaded.status == :deprecated

      # Step 4/5 -- the task's form_version must still name v1, never v2:
      # proof the read derives from instance_definition_snapshots.definition_ver
      # (frozen at instance-start) rather than a live process_definitions
      # lookup for the process's currently-active version.
      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["form_version"] == "1.0.0"
      refute body["form_version"] == "2.0.0"
    end
  end

  # ── AC5 -- form_id/form_version are present (non-nil), not merely allowed
  #    keys -- distinct from AC1's own "correct value" assertion, this test
  #    exists specifically so an unimplemented/always-nil path cannot pass as
  #    a satisfied one (design §7.3).

  describe "REQ-126 AC5: form_id/form_version are present rather than null for an ordinarily-created task" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req126-ac5")}

    test "a task activated via the real engine flow has non-nil form_id and form_version in its GET /tasks/:id body",
         %{tenant: tenant} do
      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute is_nil(body["form_id"])
      refute is_nil(body["form_version"])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-286 -- expose form_schema on the task-detail response only.
  # AC2 (nil case) is covered by "AC5/INV-2: response allowlists" above
  # (`is_nil(body["form_schema"])` for a task whose node carries none).
  # ══════════════════════════════════════════════════════════════════════

  # Same single-hop START -> HUMAN_TASK("task") -> END shape as
  # graph_human_task_end/0, with a "form_schema" node attribute added --
  # REQ-273's activation path (Letflow.Engine.TaskActivation.resolve_form_schema/1)
  # persists this onto the activated task's own `form_schema` column.
  defp graph_human_task_end_with_form_schema(schema) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver", "form_schema" => schema}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  describe "REQ-286 AC1: form_schema appears in the task-detail response for a task whose definition node carries one" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req286-ac1")}

    test "GET /tasks/:id serves the exact form_schema persisted by REQ-273 at activation",
         %{tenant: tenant} do
      schema = %{
        "type" => "object",
        "properties" => %{"comment" => %{"type" => "string"}}
      }

      {_instance_id, task} =
        start_instance_with_pending_task!(tenant, graph_human_task_end_with_form_schema(schema))

      # Confirm REQ-273 genuinely persisted the schema onto the task row --
      # this HTTP-level test asserts the served value equals what REQ-273
      # persisted, not merely what task_detail_map/3 does in isolation.
      persisted = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert persisted.form_schema == schema

      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["form_schema"] == schema
    end
  end

  describe "REQ-286 AC3: the served schema is the version pinned to the task, not the definition's current one" do
    test "advancing the definition's form_schema after the task is activated does not change the already-served schema" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req286-ac3")
      process_name = unique_name("req286-form-pin")

      v1_schema = %{"type" => "object", "properties" => %{"comment" => %{"type" => "string"}}}

      v1 =
        active_definition_named!(
          tenant,
          process_name,
          "1.0.0",
          graph_human_task_end_with_form_schema(v1_schema)
        )

      start_attrs = %{
        definition_id: v1.id,
        initial_variables: %{"seed" => "value"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("req286-ac3-start")
      }

      assert {:ok, _result} = Engine.create(start_attrs, prefix: tenant.schema_name)

      [task] = Repo.all(EngineTask, prefix: tenant.schema_name)
      assert task.status == :pending

      # Promote a NEW definition version (same process name) whose "task"
      # node carries a DIFFERENT form_schema, strictly after the task above
      # was already activated against v1.
      v2_schema = %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}}}

      v2 =
        active_definition_named!(
          tenant,
          process_name,
          "2.0.0",
          graph_human_task_end_with_form_schema(v2_schema)
        )

      assert v2.status == :active

      v1_reloaded =
        Repo.get!(Letflow.Definitions.ProcessDefinition, v1.id, prefix: tenant.schema_name)

      assert v1_reloaded.status == :deprecated

      # The task's served form_schema must still be v1's, never v2's --
      # proof form_schema is read off the task's own write-once column
      # (pinned at activation), not re-derived from the process's currently
      # active definition.
      conn =
        build_conn(:get, "/#{task.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["form_schema"] == v1_schema
      refute body["form_schema"] == v2_schema
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-085 -- write path (POST /tasks/:id/complete|claim|assign|reassign).
  # See test/specs/REQ-085.md for the full acceptance-criterion -> test-case
  # mapping and rationale.
  # ══════════════════════════════════════════════════════════════════════

  # ── AC1 -- completing a task advances the owning instance ──────────────

  describe "REQ-085 AC1: POST /tasks/:id/complete advances the owning instance" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac1")}

    test "output variables merge into the instance's variables and the token moves, asserted through the real router response and via a direct instance/task read",
         %{tenant: tenant} do
      {instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      # ISS-0942: graph_human_task_end/0's HUMAN_TASK node carries
      # attributes: %{"role" => "approver"}, which resolve_assignee/1
      # (ISS-0905) derives to assignee_type "ROLE"/assignee_ref "approver" --
      # POST /tasks/:id/complete now enforces that check (Tasks.authorize_completion/3),
      # so the caller completing this task must actually hold "approver",
      # same as a real tenant's TENANT_ADMIN would need a role grant to
      # act as this task's assignee. This test is about the engine
      # completion flow (AC1), not authorization, so the caller is wired to
      # satisfy the gate rather than testing it.
      caller = insert_user!(tenant, %{username: "req085-ac1-caller"})
      approver_group = insert_group!(tenant, name: "req085-ac1-approvers")
      insert_group_member!(tenant, approver_group.id, caller.id)
      insert_role!(tenant, "approver", approver_group.id)

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant,
          roles: ["TENANT_ADMIN"],
          user_id: caller.id,
          body: %{"decision" => "approved"}
        )
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["task_id"] == task.id
      assert resp["instance_id"] == instance_id
      assert resp["instance_status"] == "COMPLETED"
      assert resp["current_nodes"] == []
      assert resp["variables"] == %{"seed" => "value", "decision" => "approved"}

      # Not only the 200 -- the owning instance's own row, read directly.
      projection = Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []
      assert projection.variables == %{"seed" => "value", "decision" => "approved"}

      completed_task = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert completed_task.status == :completed
      assert completed_task.output_variables == %{"decision" => "approved"}

      # The token moved -- no token remains active at the old node.
      refute Enum.any?(
               Repo.all(TokenRecord, prefix: tenant.schema_name),
               &(&1.node_id == "task" and &1.status == :active)
             )
    end
  end

  # ── AC2 -- handleComplete performs no direct write to the tasks table ──

  describe "REQ-085 AC2/INV-TW85-2: handleComplete routes to the engine, never writes tasks directly" do
    test "grep for Repo. inside lib/letflow/routers/tasks.ex (source with comments/docstrings stripped) returns no hit" do
      source =
        "lib/letflow/routers/tasks.ex"
        |> File.read!()
        |> strip_comments_and_docs()

      refute source =~ "Repo.",
             "a Repo. call was found in lib/letflow/routers/tasks.ex -- handleComplete must " <>
               "route through Letflow.Engine.complete_task/3 (REQ-048), never write the " <>
               "tasks table directly"
    end
  end

  # ── AC3 -- completing an already-completed/-cancelled task is a 409, no second transition ──

  describe "REQ-085 AC3: completing a non-PENDING task returns 409 with no second transition" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac3")}

    test "completing an already-COMPLETED task returns 409 and leaves the task/instance state unchanged",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{}) |> then(&force_task_status!(tenant, &1, :completed))
      before_task = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)

      before_projection =
        Repo.get!(InstanceProjection, task.instance_id, prefix: tenant.schema_name)

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TENANT_ADMIN"], body: %{})
        |> dispatch()

      assert conn.status == 409

      after_task = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert after_task.status == before_task.status
      assert after_task.output_variables == before_task.output_variables
      assert after_task.completed_by == before_task.completed_by
      assert after_task.updated_at == before_task.updated_at

      after_projection =
        Repo.get!(InstanceProjection, task.instance_id, prefix: tenant.schema_name)

      assert after_projection.status == before_projection.status
      assert after_projection.variables == before_projection.variables
    end

    test "completing an already-CANCELLED task returns 409 and leaves the task/instance state unchanged",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{}) |> then(&force_task_status!(tenant, &1, :cancelled))
      before_task = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)

      before_projection =
        Repo.get!(InstanceProjection, task.instance_id, prefix: tenant.schema_name)

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TENANT_ADMIN"], body: %{})
        |> dispatch()

      assert conn.status == 409

      after_task = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert after_task.status == before_task.status
      assert after_task.output_variables == before_task.output_variables
      assert after_task.updated_at == before_task.updated_at

      after_projection =
        Repo.get!(InstanceProjection, task.instance_id, prefix: tenant.schema_name)

      assert after_projection.status == before_projection.status
      assert after_projection.variables == before_projection.variables
    end
  end

  # ── ISS-0944 -- completing a task whose owning instance is not :active ──

  describe "ISS-0944: completing a task owned by a non-active instance returns 409, not 500" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0944-ac1")}

    test "owning instance in :error status -> 409 Conflict with a problem-document body (not 500)",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})
      force_instance_status!(tenant, task.instance_id, :error)

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TENANT_ADMIN"], body: %{})
        |> dispatch()

      assert conn.status == 409
      resp = Jason.decode!(conn.resp_body)
      assert resp["detail"] == "instance is error"

      # Unchanged -- no second transition was attempted.
      after_task = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert after_task.status == :pending

      after_projection =
        Repo.get!(InstanceProjection, task.instance_id, prefix: tenant.schema_name)

      assert after_projection.status == :error
    end
  end

  # ── AC4 -- two concurrent claims of the same task, exactly one winner ──

  describe "REQ-085 AC4: two concurrent claims of the same task" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac4")}

    test "produce exactly one 200 success and one deterministic non-500 rejection, real concurrency",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})
      user_1 = Ecto.UUID.generate()
      user_2 = Ecto.UUID.generate()

      async_1 =
        Task.async(fn ->
          build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: user_1)
          |> dispatch()
        end)

      async_2 =
        Task.async(fn ->
          build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: user_2)
          |> dispatch()
        end)

      [resp_1, resp_2] = Task.await_many([async_1, async_2], 5_000)
      statuses = [resp_1.status, resp_2.status]

      assert Enum.sort(statuses) == [200, 409]
      refute 500 in statuses

      winner_id = if resp_1.status == 200, do: user_1, else: user_2

      claimed = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert claimed.assignee_type == "USER"
      assert claimed.assignee_ref == winner_id
    end
  end

  # ── AC5 -- claim rejected for a different user / a non-member group ────

  describe "REQ-085 AC5: claim rejected with no state change" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac5")}

    test "claiming a task assigned to a different user in the same tenant is rejected, task row unchanged",
         %{tenant: tenant} do
      other_user = Ecto.UUID.generate()
      caller = Ecto.UUID.generate()
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: other_user})

      conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 409

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.assignee_type == "USER"
      assert unchanged.assignee_ref == other_user
    end

    test "claiming a task assigned to a group the caller does not belong to is rejected, task row unchanged",
         %{tenant: tenant} do
      caller = Ecto.UUID.generate()
      group = insert_group!(tenant, name: "req085-ac5-group")
      task = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id})

      # caller deliberately never added as a member of `group`
      conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 409

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.assignee_type == "GROUP"
      assert unchanged.assignee_ref == group.id
    end
  end

  # ── AC6 -- cross-tenant task id == nonexistent id, all four verbs ──────

  describe "REQ-085 AC6/INV-TW85-4: a cross-tenant task id behaves identically to a nonexistent id" do
    test "complete/claim/assign/reassign each 404 identically, no state change on the other tenant's row" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac6-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac6-b")

      task_b = insert_task!(tenant_b, %{})
      nonexistent_id = Ecto.UUID.generate()

      verb_bodies = [
        {"complete", %{}},
        {"claim", nil},
        {"assign", %{"user_id" => Ecto.UUID.generate()}},
        {"reassign", %{"user_id" => Ecto.UUID.generate()}}
      ]

      for {verb, body} <- verb_bodies do
        fields = [roles: ["TENANT_ADMIN"]] ++ if body, do: [body: body], else: []

        resp_cross_tenant =
          build_conn(:post, "/#{task_b.id}/#{verb}", tenant_a, fields) |> dispatch()

        resp_nonexistent =
          build_conn(:post, "/#{nonexistent_id}/#{verb}", tenant_a, fields) |> dispatch()

        assert resp_cross_tenant.status == 404, "#{verb}: expected 404 for a cross-tenant id"

        assert resp_cross_tenant.status == resp_nonexistent.status,
               "#{verb}: cross-tenant and nonexistent-id responses diverged in status"

        assert resp_cross_tenant.resp_body == resp_nonexistent.resp_body,
               "#{verb}: cross-tenant and nonexistent-id responses diverged in body"
      end

      unchanged = Repo.get!(EngineTask, task_b.id, prefix: tenant_b.schema_name)
      assert unchanged.status == :pending
      assert unchanged.assignee_type == nil
      assert unchanged.assignee_ref == nil
    end
  end

  # ── AC7 -- permission gates, no state change on 403 ─────────────────────

  describe "REQ-085 AC7: permission gates deny with no state change" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req085-ac7")}

    # AGENT_RUNNER is a real, recognized role (per REQ-083's own precedent in
    # this file) that role_allows?/2 grants zero permissions to -- lacks
    # TasksComplete specifically.
    test "a caller without TasksComplete cannot complete (403), task state unchanged",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["AGENT_RUNNER"], body: %{})
        |> dispatch()

      assert conn.status == 403

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.status == :pending
    end

    # Design §2's own resolution: claim shares complete's :TasksComplete gate,
    # not :TasksAssign -- AC7's own text names complete only, so this
    # assertion is added explicitly per the design doc's own instruction.
    test "a caller without TasksComplete cannot claim (403), task state unchanged",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["AGENT_RUNNER"])
        |> dispatch()

      assert conn.status == 403

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.assignee_type == nil
    end

    # TASK_WORKER holds :TasksComplete but not :TasksAssign (confirmed at
    # design doc §0) -- exactly the role class that must be denied here.
    test "a caller without TasksAssign cannot assign (403), task state unchanged",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn =
        build_conn(:post, "/#{task.id}/assign", tenant,
          roles: ["TASK_WORKER"],
          body: %{"user_id" => Ecto.UUID.generate()}
        )
        |> dispatch()

      assert conn.status == 403

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.assignee_type == nil
    end

    test "a caller without TasksAssign cannot reassign (403), task state unchanged",
         %{tenant: tenant} do
      other_user = Ecto.UUID.generate()
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: other_user})

      conn =
        build_conn(:post, "/#{task.id}/reassign", tenant,
          roles: ["TASK_WORKER"],
          body: %{"user_id" => Ecto.UUID.generate()}
        )
        |> dispatch()

      assert conn.status == 403

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.assignee_ref == other_user
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Additional coverage the design doc flags as testable (assign/reassign
  # happy paths, error branches, invalid-UUID/missing-body-field cases) --
  # not literally named by any single AC, but explicitly called out by the
  # design's own AC traceability and error-union tables.
  # ══════════════════════════════════════════════════════════════════════

  describe "REQ-085: assign/reassign happy paths and error branches" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req085-assign")}

    test "assign writes assignee_type/assignee_ref on an unassigned task", %{tenant: tenant} do
      task = insert_task!(tenant, %{})
      target_user = Ecto.UUID.generate()

      conn =
        build_conn(:post, "/#{task.id}/assign", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => target_user}
        )
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["assignee_type"] == "USER"
      assert resp["assignee_ref"] == target_user

      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_type == "USER"
      assert row.assignee_ref == target_user
    end

    test "assign on an already-assigned task returns 409 :already_assigned, no state change",
         %{tenant: tenant} do
      existing = Ecto.UUID.generate()
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: existing})

      conn =
        build_conn(:post, "/#{task.id}/assign", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => Ecto.UUID.generate()}
        )
        |> dispatch()

      assert conn.status == 409
      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_ref == existing
    end

    test "reassign writes a new assignee on an already-assigned task, overwriting the old one",
         %{tenant: tenant} do
      existing = Ecto.UUID.generate()
      new_user = Ecto.UUID.generate()
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: existing})

      conn =
        build_conn(:post, "/#{task.id}/reassign", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => new_user}
        )
        |> dispatch()

      assert conn.status == 200
      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_type == "USER"
      assert row.assignee_ref == new_user
    end

    test "reassign on an unassigned task returns 409 :not_currently_assigned, no state change",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn =
        build_conn(:post, "/#{task.id}/reassign", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => Ecto.UUID.generate()}
        )
        |> dispatch()

      assert conn.status == 409
      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_type == nil
    end

    test "claim on a task whose assignee_type is not USER/GROUP/ROLE returns 409 :not_claimable, no state change",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{assignee_type: "BOGUS", assignee_ref: "x"})

      conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"])
        |> dispatch()

      assert conn.status == 409
      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_type == "BOGUS"
    end

    test "re-claiming a task already claimed by the same caller is an idempotent 200 no-op (design §3.4 OQ-2)",
         %{tenant: tenant} do
      caller = Ecto.UUID.generate()
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: caller})

      conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 200
      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_ref == caller
    end

    test "claiming a task assigned to a role the caller holds succeeds and rewrites it to USER/caller",
         %{tenant: tenant} do
      caller = insert_user!(tenant, %{username: "req085-role-claim-caller"}).id
      group = insert_group!(tenant, name: "req085-role-claim-group")
      insert_group_member!(tenant, group.id, caller)
      insert_role!(tenant, "approver", group.id)
      task = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "approver"})

      conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 200
      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_type == "USER"
      assert row.assignee_ref == caller
    end

    test "POST /tasks/:id/assign with a malformed id is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:post, "/not-a-uuid/assign", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => Ecto.UUID.generate()}
        )
        |> dispatch()

      assert conn.status == 400
    end

    test "POST /tasks/:id/assign with a missing user_id is rejected with 422", %{tenant: tenant} do
      task = insert_task!(tenant, %{})

      conn =
        build_conn(:post, "/#{task.id}/assign", tenant, roles: ["TENANT_ADMIN"], body: %{})
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /tasks/:id/reassign with an empty-string user_id is rejected with 422",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: Ecto.UUID.generate()})

      conn =
        build_conn(:post, "/#{task.id}/reassign", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => ""}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /tasks/:id/complete with a malformed id is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:post, "/not-a-uuid/complete", tenant, roles: ["TENANT_ADMIN"], body: %{})
        |> dispatch()

      assert conn.status == 400
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0942 -- POST /tasks/:id/complete authorization gap
  # (`Tasks.authorize_completion/3`, called from `handle_complete/3` before
  # `Engine.complete_task/3`). See
  # lib/letflow/design/iss0942-task-complete-authorization-gap.md.
  # ══════════════════════════════════════════════════════════════════════

  describe "ISS-0942 AC1: 403 on a task assigned to a different USER" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0942-ac1")}

    test "a caller who is not the USER assignee gets 403, not 200 -- Engine.complete_task/3 never reached",
         %{tenant: tenant} do
      other_user = Ecto.UUID.generate()
      caller = Ecto.UUID.generate()
      task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: other_user})

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] == "task is assigned to a different user"

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.status == :pending
      assert unchanged.assignee_type == "USER"
      assert unchanged.assignee_ref == other_user
      assert unchanged.completed_at == nil
    end
  end

  describe "ISS-0942 AC2: 403 on a task assigned to a GROUP the caller is not a member of" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0942-ac2")}

    test "a caller who does not belong to the assigned GROUP gets 403, task state unchanged",
         %{tenant: tenant} do
      caller = Ecto.UUID.generate()
      group = insert_group!(tenant, name: "iss0942-ac2-group")
      task = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id})

      # caller deliberately never added as a member of `group`
      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] == "caller is not a member of the assigned group"

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.status == :pending
      assert unchanged.assignee_type == "GROUP"
      assert unchanged.assignee_ref == group.id
    end
  end

  # REQ-530 (GH #3086): the Driver Incident Report's people-steps are assigned by role. ops-assessment
  # is role-ops-manager and finance-estimate is role-accountant (test/letflow/engine/swiftroute_escalation_timer_test.exs
  # pins those assignees on the real fixture); the other role must be refused at the complete route.
  defp insert_user_holding_role!(tenant, role_name) do
    user = insert_user!(tenant, %{username: unique_name("req530-" <> role_name)})
    group = insert_group!(tenant, %{})
    insert_group_member!(tenant, group.id, user.id)
    insert_role!(tenant, role_name, group.id)
    user.id
  end

  describe "REQ-530: the other incident role cannot complete a people-step (403 at the complete route)" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req530-role")}

    test "an Accountant cannot complete ops-assessment (role-ops-manager); the task stays pending",
         %{tenant: tenant} do
      caller = insert_user_holding_role!(tenant, "role-accountant")
      task = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "role-ops-manager"})

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["detail"] == "caller does not hold the assigned role"
      assert Repo.get!(EngineTask, task.id, prefix: tenant.schema_name).status == :pending
    end

    test "an Operations Manager cannot complete finance-estimate (role-accountant); the task stays pending",
         %{tenant: tenant} do
      caller = insert_user_holding_role!(tenant, "role-ops-manager")
      task = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "role-accountant"})

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["detail"] == "caller does not hold the assigned role"
      assert Repo.get!(EngineTask, task.id, prefix: tenant.schema_name).status == :pending
    end
  end

  describe "ISS-0942 AC3/AC7: 403 on a task assigned to a ROLE the caller does not hold -- the live UAT exploit" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0942-ac3")}

    test "a caller who does not hold the assigned ROLE gets 403, task state unchanged",
         %{tenant: tenant} do
      caller = Ecto.UUID.generate()

      task =
        insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "role-compliance-officer"})

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant, roles: ["TASK_WORKER"], user_id: caller)
        |> dispatch()

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] == "caller does not hold the assigned role"

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.status == :pending
      assert unchanged.assignee_type == "ROLE"
      assert unchanged.assignee_ref == "role-compliance-officer"
    end

    # AC7 -- regression test reproducing the EXACT live UAT exploit scenario
    # from test/uat-reports/uat-2026-10-01-ISS0912-NARRATIVE.yaml,
    # meridian/regulatory-compliance-review-bafin, Step 2: "complete as
    # claudia -> 200 (note she holds no role-compliance-officer; claim as
    # claudia -> 409)". A ROLE-assigned task, an actor who is NOT a member
    # of that role: claim correctly 409s (unchanged by this fix); complete
    # without ever claiming must now ALSO reject (403), not silently
    # succeed (200) the way live UAT observed pre-fix.
    test "claim correctly 409s for a non-member actor, and complete (skipping claim entirely) now 403s too -- pre-fix this returned 200",
         %{tenant: tenant} do
      claudia = insert_user!(tenant, %{username: "iss0942-ac7-claudia"}).id

      task =
        insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "role-compliance-officer"})

      claim_conn =
        build_conn(:post, "/#{task.id}/claim", tenant, roles: ["TASK_WORKER"], user_id: claudia)
        |> dispatch()

      assert claim_conn.status == 409
      claim_body = Jason.decode!(claim_conn.resp_body)
      assert claim_body["detail"] == "caller does not hold the assigned role"

      # The exploit path: skip /claim entirely, call /complete directly.
      complete_conn =
        build_conn(:post, "/#{task.id}/complete", tenant,
          roles: ["TASK_WORKER"],
          user_id: claudia,
          body: %{}
        )
        |> dispatch()

      assert complete_conn.status == 403,
             "pre-ISS-0942, a non-member actor completed a ROLE-assigned task with HTTP 200 " <>
               "without ever claiming it -- this must now be 403"

      complete_body = Jason.decode!(complete_conn.resp_body)
      assert complete_body["detail"] == "caller does not hold the assigned role"

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.status == :pending
      assert unchanged.assignee_type == "ROLE"
      assert unchanged.assignee_ref == "role-compliance-officer"
      assert unchanged.completed_at == nil
      assert unchanged.completed_by == nil
    end
  end

  describe "ISS-0942 AC4: matching/permitted assignee and unassigned-task completion are unchanged (no regression)" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0942-ac4")}

    test "a USER-type assignee completing their own task still succeeds with 200", %{
      tenant: tenant
    } do
      caller = Ecto.UUID.generate()
      {instance_id, task} = start_instance_with_pending_task_for_assignee!(tenant, "USER", caller)

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant,
          roles: ["TASK_WORKER"],
          user_id: caller,
          body: %{}
        )
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["instance_id"] == instance_id
    end

    test "a GROUP member completing a GROUP-assigned task still succeeds with 200", %{
      tenant: tenant
    } do
      caller = insert_user!(tenant, %{username: "iss0942-ac4-group-member"}).id
      group = insert_group!(tenant, name: "iss0942-ac4-group")
      insert_group_member!(tenant, group.id, caller)

      {instance_id, task} =
        start_instance_with_pending_task_for_assignee!(tenant, "GROUP", group.id)

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant,
          roles: ["TASK_WORKER"],
          user_id: caller,
          body: %{}
        )
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["instance_id"] == instance_id
    end

    test "a ROLE holder completing a ROLE-assigned task still succeeds with 200", %{
      tenant: tenant
    } do
      caller = insert_user!(tenant, %{username: "iss0942-ac4-role-holder"}).id
      group = insert_group!(tenant, name: "iss0942-ac4-role-group")
      insert_group_member!(tenant, group.id, caller)
      insert_role!(tenant, "role-compliance-officer", group.id)

      {instance_id, task} =
        start_instance_with_pending_task_for_assignee!(tenant, "ROLE", "role-compliance-officer")

      conn =
        build_conn(:post, "/#{task.id}/complete", tenant,
          roles: ["TASK_WORKER"],
          user_id: caller,
          body: %{}
        )
        |> dispatch()

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["instance_id"] == instance_id
    end

    # Unlike the USER/GROUP/ROLE cases above, a genuinely unassigned
    # (assignee_type: nil) task cannot be produced through the real
    # authoring/activation path -- CHK-09 (Letflow.Definitions.Graph)
    # requires every HUMAN_TASK node's `attributes["role"]` to be a
    # non-blank string, so `Definitions.create/2` rejects any graph that
    # would resolve to a nil assignee_ref/assignee_type (confirmed:
    # `resolve_assignee/1` only returns `nil` when both `"assignee_type"`
    # and `"role"` are absent). This precedence branch is therefore tested
    # directly against `Letflow.Tasks.authorize_completion/3` -- the same
    # boundary `apply_claim/5`'s own unassigned-task clause is unit-level
    # verified at elsewhere in this codebase -- rather than through a full
    # HTTP round-trip that cannot legitimately exist.
    test "Letflow.Tasks.authorize_completion/3 returns :ok for a genuinely unassigned task -- permissive case unchanged",
         %{tenant: tenant} do
      task = insert_task!(tenant, %{})
      assert task.assignee_type == nil

      assert :ok =
               Letflow.Tasks.authorize_completion(task.id, Ecto.UUID.generate(),
                 prefix: tenant.schema_name
               )
    end
  end

  describe "ISS-0942 AC5: invalid_task_id/task_not_found responses are unchanged" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0942-ac5")}

    test "a malformed task id on complete still returns 400", %{tenant: tenant} do
      conn =
        build_conn(:post, "/not-a-uuid/complete", tenant, roles: ["TASK_WORKER"], body: %{})
        |> dispatch()

      assert conn.status == 400
    end

    test "a nonexistent task id on complete still returns 404", %{tenant: tenant} do
      conn =
        build_conn(:post, "/#{Ecto.UUID.generate()}/complete", tenant,
          roles: ["TASK_WORKER"],
          body: %{}
        )
        |> dispatch()

      assert conn.status == 404
    end
  end

  describe "ISS-0942: claim's own 409 mapping of the three assignee-mismatch atoms is unaffected by this fix" do
    setup do: %{
            tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0942-claim-unaffected")
          }

    test "claim still returns 409 (not 403) for USER/GROUP/ROLE assignee mismatches", %{
      tenant: tenant
    } do
      other_user = Ecto.UUID.generate()
      user_task = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: other_user})

      user_conn =
        build_conn(:post, "/#{user_task.id}/claim", tenant,
          roles: ["TASK_WORKER"],
          user_id: Ecto.UUID.generate()
        )
        |> dispatch()

      assert user_conn.status == 409

      group = insert_group!(tenant, name: "iss0942-claim-unaffected-group")
      group_task = insert_task!(tenant, %{assignee_type: "GROUP", assignee_ref: group.id})

      group_conn =
        build_conn(:post, "/#{group_task.id}/claim", tenant,
          roles: ["TASK_WORKER"],
          user_id: Ecto.UUID.generate()
        )
        |> dispatch()

      assert group_conn.status == 409

      role_task = insert_task!(tenant, %{assignee_type: "ROLE", assignee_ref: "role-whatever"})

      role_conn =
        build_conn(:post, "/#{role_task.id}/claim", tenant,
          roles: ["TASK_WORKER"],
          user_id: Ecto.UUID.generate()
        )
        |> dispatch()

      assert role_conn.status == 409
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0905 -- role-assignee task created via the real activation path
  # ══════════════════════════════════════════════════════════════════════

  describe "ISS-0905: role-assignee task created via the real activation path" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0905")}

    # graph_human_task_end/0 (already defined above for REQ-085 AC1) is
    # exactly the fixture this bug needs: a single :HUMAN_TASK node carrying
    # only attributes: %{"role" => "approver"} -- no "assignee_type" key --
    # the only shape any authoring path in this codebase ever produces
    # (CHK-09). start_instance_with_pending_task!/2 drives it through the
    # real Letflow.Engine.create/2 activation path, not insert_task!/2 (which
    # bypasses resolve_assignee/1 entirely and therefore cannot exercise this
    # bug at all).

    # Fail-first against unfixed code: pre-fix, resolve_assignee/1 returns
    # assignee_type: nil for this task, which matches none of
    # filter_by_assignee_scope/2's three OR arms, so the role's sole member
    # sees 0 items instead of 1.
    test "a role-assigned task created via Engine.create/2 IS visible in GET /tasks/inbox to a member of that role",
         %{tenant: tenant} do
      member = insert_user!(tenant, %{username: "iss0905-marco"})
      group = insert_group!(tenant, name: "iss0905-approvers")
      insert_group_member!(tenant, group.id, member.id)
      insert_role!(tenant, "approver", group.id)

      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      # "approver" here is a :process_routing_role (insert_role!/3), not a
      # platform role -- Identity.list_effective_role_names/2 only surfaces
      # platform roles (ISS-0774), so it plays no part in this scoping check.
      # The inbox route's own RBAC gate is satisfied the same way every other
      # scoped-inbox test in this file satisfies it (build_conn's roles:
      # field, a companion platform-role grant) -- the assignee-scope
      # filtering that actually proves this bug's fix is
      # resolve_principal_scope/2's real, DB-backed role_names resolution
      # (queries ALL TenantRole rows regardless of :kind), reached via
      # filter_by_assignee_scope/2's {:principal, ...} clause.
      conn =
        build_conn(:get, "/inbox?page_size=50", tenant,
          roles: ["TASK_WORKER"],
          user_id: member.id
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert task.id in item_ids(body)
    end

    # Fail-first: pre-fix, apply_claim/5's first clause
    # (%Task{assignee_type: nil}) matches this row unconditionally and lets
    # any authenticated caller self-assign -- this is the issue's Tobias
    # case (a non-member could claim it, HTTP 200). Post-fix, assignee_type
    # is "ROLE" and apply_claim/5's ROLE clause rejects a non-member with
    # :assignee_role_not_held (409), and the task row is unchanged.
    test "the same role-assigned task is REJECTED when claimed by a non-member (ISS-0905)",
         %{tenant: tenant} do
      non_member = insert_user!(tenant, %{username: "iss0905-tobias"})

      # Some OTHER role's group exists so `approver` genuinely has zero
      # members bound -- non_member is a member of a different group/role
      # entirely, matching the issue's "authenticated TASK_WORKER, not a
      # member of role-ops-manager" shape.
      other_group = insert_group!(tenant, name: "iss0905-other-group")
      insert_group_member!(tenant, other_group.id, non_member.id)
      insert_role!(tenant, "some-other-role", other_group.id)

      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      conn =
        build_conn(:post, "/#{task.id}/claim", tenant,
          roles: ["TASK_WORKER"],
          user_id: non_member.id
        )
        |> dispatch()

      assert conn.status == 409

      unchanged = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert unchanged.assignee_type == "ROLE"
      assert unchanged.assignee_ref == "approver"
    end

    # Confirms the persisted row's actual assignee_type post-activation, as
    # a direct proof this fix's derivation reached the real insert path (not
    # just resolve_assignee/1's own unit test).
    test "the persisted task row's assignee_type is \"ROLE\" (not nil) after real activation from a role-only HUMAN_TASK node",
         %{tenant: tenant} do
      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      row = Repo.get!(EngineTask, task.id, prefix: tenant.schema_name)
      assert row.assignee_type == "ROLE"
      assert row.assignee_ref == "approver"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0917 -- POST /tasks/:id/complete when the next node is a catalog
  # SERVICE_TASK (R1-R3 of the ISS-0917 design, section 6.3). See
  # test/specs/ISS-0917.md for rationale and the fail-first / mutant record.
  # ══════════════════════════════════════════════════════════════════════

  # START -> HUMAN_TASK(role approver) -> SERVICE_TASK(service_id) -> END
  defp graph_human_task_then_catalog(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"service_id" => service_id, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # Registers a global catalog entry (cleaned up on exit) and returns it.
  defp register_catalog_entry!(endpoint_url) do
    service_id =
      "iss0917-router-svc-" <> to_string(System.unique_integer([:positive, :monotonic]))

    on_exit(fn ->
      Repo.delete_all(from(v in CatalogVersion, where: v.service_id == ^service_id))
      Repo.delete_all(from(e in CatalogEntry, where: e.service_id == ^service_id))
    end)

    assert {:ok, entry} =
             Letflow.ServiceCatalog.register(%{
               service_id: service_id,
               endpoint_url: endpoint_url,
               required_auth: :NONE,
               timeout_ms: 5_000,
               scope: :global
             })

    entry
  end

  # The caller must hold the HUMAN_TASK's "approver" role (ISS-0942 gate).
  defp approver_caller!(tenant, label) do
    caller = insert_user!(tenant, %{username: "iss0917-#{label}-caller"})
    group = insert_group!(tenant, name: "iss0917-#{label}-approvers")
    insert_group_member!(tenant, group.id, caller.id)
    insert_role!(tenant, "approver", group.id)
    caller
  end

  defp complete_request(tenant, task, caller, body) do
    build_conn(:post, "/#{task.id}/complete", tenant,
      roles: ["TENANT_ADMIN"],
      user_id: caller.id,
      body: body
    )
    |> dispatch()
  end

  describe "ISS-0917 R1: completing a task whose next node is a catalog SERVICE_TASK" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0917-r1")}

    test "answers 200 with instance_status ACTIVE and the token parked at the SERVICE_TASK (pre-fix: 500)",
         %{tenant: tenant} do
      entry = register_catalog_entry!("https://example.test/iss0917/router")

      {instance_id, task} =
        start_instance_with_pending_task!(tenant, graph_human_task_then_catalog(entry.service_id))

      caller = approver_caller!(tenant, "r1")
      conn = complete_request(tenant, task, caller, %{"decision" => "approved"})

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      assert resp["instance_id"] == instance_id
      assert resp["instance_status"] == "ACTIVE"
      assert resp["current_nodes"] == ["svc"]

      projection = Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name)
      assert projection.status == :active

      assert [row] =
               Repo.all(
                 from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
                   where: d.instance_id == ^instance_id
                 ),
                 prefix: tenant.schema_name
               )

      assert row.config_snapshot["rendered_url"] == "https://example.test/iss0917/router"
    end
  end

  describe "ISS-0917 R2: {:instance_execution_error, _, _} maps to 409, naming only the error_type" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0917-r2")}

    test "an unresolvable pin (rebound to a non-existent version) answers 409 and the body leaks neither variables, service id nor URL",
         %{tenant: tenant} do
      entry = register_catalog_entry!("https://example.test/iss0917/leak-check")

      {instance_id, task} =
        start_instance_with_pending_task!(tenant, graph_human_task_then_catalog(entry.service_id))

      assert {:ok, %{changed: [_]}} =
               Letflow.Engine.PinRebind.rebind_pins(
                 instance_id,
                 %{
                   entries: [%{kind: :catalog_entry, ref: entry.service_id, version: "9.9.9"}],
                   reason: "ISS-0917 R2",
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("iss0917-r2-rebind")
                 },
                 prefix: tenant.schema_name
               )

      caller = approver_caller!(tenant, "r2")
      conn = complete_request(tenant, task, caller, %{"decision" => "zz-variable-value-zz"})

      assert conn.status == 409
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == 409
      assert resp["detail"] == "instance entered ERROR status: service_task_catalog_unresolved"

      refute conn.resp_body =~ "zz-variable-value-zz"
      refute conn.resp_body =~ entry.service_id
      refute conn.resp_body =~ "example.test"
      refute conn.resp_body =~ "svc"

      # the instance really is parked in ERROR (the 409 is not masking a rollback)
      projection = Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name)
      assert projection.status == :error
    end
  end

  describe "ISS-0917 R3: other complete_error() members still fall through to the 500 catch-all" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss0917-r3")}

    test "{:error, :snapshot_not_found} (instance definition snapshot removed) is still 500, not 409",
         %{tenant: tenant} do
      {_instance_id, task} = start_instance_with_pending_task!(tenant, graph_human_task_end())

      Repo.delete_all(Letflow.Definitions.InstanceDefinitionSnapshot, prefix: tenant.schema_name)

      caller = approver_caller!(tenant, "r3")
      conn = complete_request(tenant, task, caller, %{})

      assert conn.status == 500
    end
  end

  # ── Test-file-local helper (REQ-085 AC2) -- matches
  #    test/letflow/routers/req078_supporting_routes_test.exs's own
  #    strip_comments_and_docs/1 precedent for a grep-shaped structural test.
  defp strip_comments_and_docs(source) do
    source
    |> String.replace(~r/@(module)?doc\s+"""(.|\n)*?"""/, "")
    |> String.split("\n")
    |> Enum.map(fn line -> line |> String.split("#") |> hd() end)
    |> Enum.join("\n")
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-447 PR 1 -- TENANT_ADMIN is excluded from the task-worker-only row filter
  # (design 3.1; is_task_worker_only?/1 governs both GET /tasks and GET /tasks/inbox).
  # ══════════════════════════════════════════════════════════════════════

  describe "REQ-447: a TENANT_ADMIN + TASK_WORKER caller sees the whole tenant queue" do
    setup do: %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req447-taskscope")}

    test "GET /tasks and GET /tasks/inbox are unfiltered for TENANT_ADMIN + TASK_WORKER; TASK_WORKER alone stays filtered",
         %{tenant: tenant} do
      user_x = insert_user!(tenant, %{username: "req447-x"}).id
      user_y = insert_user!(tenant, %{username: "req447-y"}).id

      task_x = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_x})
      task_y = insert_task!(tenant, %{assignee_type: "USER", assignee_ref: user_y})

      for path <- ["/?page_size=50", "/inbox?page_size=50"] do
        admin_conn =
          build_conn(:get, path, tenant, roles: ["TENANT_ADMIN", "TASK_WORKER"], user_id: user_x)
          |> dispatch()

        assert admin_conn.status == 200, "#{path} for TENANT_ADMIN + TASK_WORKER"
        admin_ids = admin_conn.resp_body |> Jason.decode!() |> item_ids()

        assert task_x.id in admin_ids

        assert task_y.id in admin_ids,
               "#{path}: TENANT_ADMIN + TASK_WORKER must see another user's task"

        # Control, same data and path: TASK_WORKER alone is row-filtered to its own tasks.
        worker_conn =
          build_conn(:get, path, tenant, roles: ["TASK_WORKER"], user_id: user_x) |> dispatch()

        assert worker_conn.status == 200
        worker_ids = worker_conn.resp_body |> Jason.decode!() |> item_ids()

        assert task_x.id in worker_ids
        refute task_y.id in worker_ids, "#{path}: TASK_WORKER alone must stay filtered"
      end
    end
  end
end
