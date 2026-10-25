defmodule Letflow.Routers.TenantAuditorRoutesTest do
  @moduledoc """
  REQ-448 AC2 (`lib/letflow/design/req448-tenant-auditor-role.md` sections 7.1-7.4; spec
  `test/specs/REQ-448.md`): what a read-only `TENANT_AUDITOR` can and cannot reach. Real
  Postgres, real routers, the platform tenant pinned on a third tenant. Model:
  `tenant_admin_routes_test.exs`.

    * 200: definitions, instances, tasks (UNFILTERED: `task_scope :all`, also with `TASK_WORKER`
      held), the inbox, audit, `POST /entities/query` (and aggregate), the attachment reads, and
      the read-class POSTs that persist nothing (validate, solution-packs export and
      update-review), the last three proved state-free by a whole-schema row-count snapshot.
    * 403: one named write route per router mounted in `Letflow.Plugs.ApiPipeline` (31; the
      mounted set is parsed from the pipeline source so a new router fails this test until it is
      named here); for the four read-only routers (Audit, Services, Help, Me) the named non-GET
      probe, which is NOT a real route and answers 403 through the `:UnmatchedRoute` marker.
    * `GET /promotions`, `GET /promotions/platform-events`: 200 (ISS-1109: `:PromotionsRead` is
      granted); every `:PromotionsManage` route stays 403 (the 403 body is asserted); a non-party
      auditor gets the same 404 on `GET /:id` and `GET /:id/context` as for a nonexistent id and
      as a `TENANT_ADMIN` does (the ISS-1029 stored-tenant check applies to the auditor).
    * Item L1: `POST .../attachments/:id/link` is `:AttachmentLinksIssue`: 200 for the five roles
      that reached it before REQ-448, 403 for the auditor, `AGENT_RUNNER` and `CANDIDATE`, and a
      403 writes no signing secret. `GET .../link-content` still answers 200 for the auditor.
    * An auditor of an inactive tenant is halted by `TenantStatus`; field restrictions redact for
      the auditor exactly as for other roles (INV-2).

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Definitions
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Group
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Repository.Attachments
  alias Letflow.Secrets.Secret
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope
  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]

  @pipeline_source File.read!("lib/letflow/plugs/api_pipeline.ex")
  @unused_uuid "00000000-0000-4000-8000-000000000004"
  @auditor ["TENANT_AUDITOR"]

  # One named write route per router mounted in Letflow.Plugs.ApiPipeline (design 7.2).
  # {router, mount prefix, verb, local path, kind}; kind :route is a declared route of the router
  # (checked against __authz_routes__/0), :probe is the named non-GET unmatched probe of a
  # read-only router, :modules is the plain-Plug Modules router (full pipeline only).
  @named_routes [
    {Letflow.Routers.Identity, "/identity", :post, "/users", :route},
    {Letflow.Routers.Tenants, "/tenants", :post, "/", :route},
    {Letflow.Routers.TenantSettings, "/tenant/settings", :patch, "/", :route},
    {Letflow.Routers.Labels, "/labels", :put, "/:message_id", :route},
    {Letflow.Routers.NotificationTemplates, "/notification-templates", :put, "/:template_key",
     :route},
    {Letflow.Routers.TenantConfigBundle, "/tenant/config-bundle", :post, "/import", :route},
    {Letflow.Routers.IntegrationMappings, "/integration-mappings", :post, "/", :route},
    {Letflow.Routers.TenantModules, "/tenant/modules", :post, "/", :route},
    {Letflow.Routers.TenantSolutions, "/tenant/solutions", :post, "/", :route},
    {Letflow.Routers.Modules, "/modules", :post, "/exam/exam-sessions", :modules},
    {Letflow.Routers.Instances, "/instances", :post, "/", :route},
    {Letflow.Routers.Definitions, "/definitions", :post, "/", :route},
    {Letflow.Routers.Tasks, "/tasks", :post, "/:id/complete", :route},
    {Letflow.Routers.Promotions, "/promotions", :post, "/", :route},
    {Letflow.Routers.Onboarding, "/onboarding", :post, "/", :route},
    {Letflow.Routers.SolutionPacks, "/solution-packs", :post, "/install", :route},
    {Letflow.Routers.Audit, "/audit", :post, "/", :probe},
    {Letflow.Routers.Dlq, "/dlq", :post, "/:id/retry", :route},
    {Letflow.Routers.Webhooks, "/webhooks", :post, "/subscriptions", :route},
    {Letflow.Routers.Documents, "/documents", :post, "/:document_id/hold", :route},
    {Letflow.Routers.EntityViews, "/entity-views", :post, "/", :route},
    {Letflow.Routers.Services, "/services", :post, "/", :probe},
    {Letflow.Routers.AdminServices, "/admin/services", :post, "/", :route},
    {Letflow.Routers.Entities, "/entities", :post, "/records/:entity_type", :route},
    {Letflow.Routers.PublicReadHandles, "/public-read-handles", :post, "/", :route},
    {Letflow.Routers.Help, "/help", :post, "/resolved", :probe},
    {Letflow.Routers.PlatformMigrations, "/platform-migrations", :post, "/rollouts", :route},
    {Letflow.Routers.EventRetention, "/event-retention", :post, "/retirements", :route},
    {Letflow.Routers.Me, "/me", :post, "/memberships", :probe},
    {Letflow.Routers.ScriptRules, "/script-rules", :post, "/:key/versions", :route},
    # REQ-496 (GH #2530): this router's ONLY route is the read-only GET; it requires
    # :UsersGroupsRolesManage (tenant-admin class), which TENANT_AUDITOR does not hold, so the
    # real route (not a probe) is named and must answer the auditor 403.
    {Letflow.Routers.TenantScopeNodePaths, "/tenant/scope-node-paths", :get, "/consistency",
     :route},
    {Letflow.Routers.ScriptPolicy, "/script-policy", :put, "/kill-switch", :route},
    # REQ-497 PR 1b (GH #2533): the scope-enforcement flip requires :UsersGroupsRolesManage
    # (tenant-admin class), which TENANT_AUDITOR does not hold, so the real PUT must answer 403.
    {Letflow.Routers.TenantScopeEnforcement, "/tenant/scope-enforcement", :put, "/", :route},
    # REQ-517 PR 2a (GH #2535): the scoped role grant admin plane requires
    # :UsersGroupsRolesManage (tenant-admin class), which TENANT_AUDITOR does not hold.
    {Letflow.Routers.TenantRoleScopeGrants, "/tenant/role-scope-grants", :post, "/", :route}
  ]

  # Additional named routes (design 7.2 "also" column and the supervisor's decisions).
  @extra_routes [
    {Letflow.Routers.Identity, :get, "/users"},
    {Letflow.Routers.Identity, :post, "/tokens"},
    {Letflow.Routers.Identity, :post, "/roles"},
    # REQ-517 PR 2a: the service-principal flag route and the other grant routes.
    {Letflow.Routers.Identity, :put, "/users/:id/service-principal"},
    {Letflow.Routers.TenantRoleScopeGrants, :get, "/"},
    {Letflow.Routers.TenantRoleScopeGrants, :delete, "/:id"},
    {Letflow.Routers.TenantRoleScopeGrants, :post, "/make-tenant-wide"},
    {Letflow.Routers.Tenants, :post, "/:test_tenant_id/promote/:process_key"},
    {Letflow.Routers.Instances, :post, "/:id/cancel"},
    {Letflow.Routers.Instances, :post, "/:id/attachments"},
    {Letflow.Routers.Instances, :delete, "/:id/attachments/:attachment_id"},
    {Letflow.Routers.Definitions, :post, "/:process_key/rollback"},
    {Letflow.Routers.Tasks, :post, "/:id/claim"},
    {Letflow.Routers.Tasks, :post, "/:id/assign"},
    {Letflow.Routers.Promotions, :post, "/plan"},
    {Letflow.Routers.Promotions, :post, "/:id/approve"},
    {Letflow.Routers.Promotions, :post, "/:id/reject"},
    {Letflow.Routers.Promotions, :post, "/:id/apply"},
    {Letflow.Routers.Promotions, :post, "/:review_id/run-assertions"},
    {Letflow.Routers.SolutionPacks, :post, "/:pack_id/update-apply"},
    {Letflow.Routers.Dlq, :get, "/"},
    {Letflow.Routers.Dlq, :get, "/:id"},
    {Letflow.Routers.Webhooks, :get, "/subscriptions"},
    {Letflow.Routers.Entities, :post, "/records/:entity_type/export"},
    {Letflow.Routers.Entities, :post, "/records/:entity_type/import"},
    {Letflow.Routers.Entities, :post, "/definitions"},
    {Letflow.Routers.Entities, :post, "/restrictions/import"}
  ]

  # Design 2.5 / F16: every NON-GET route whose permission the auditor holds, each verified
  # read-only on this branch. Anything else the auditor reaches with a non-GET is a failure.
  @allowed_non_get [
    {Letflow.Routers.Definitions, "POST", "/:id/validate"},
    {Letflow.Routers.SolutionPacks, "POST", "/export"},
    {Letflow.Routers.SolutionPacks, "POST", "/:pack_id/update-review"},
    {Letflow.Routers.Entities, "POST", "/query"},
    {Letflow.Routers.Entities, "POST", "/query/aggregate"}
  ]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # --- request helpers -------------------------------------------------------------------------

  defp conn_for(method, path, fixture, roles, opts) do
    body = Keyword.get(opts, :body)
    user_id = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    Fixture.router_conn(method, path, fixture, roles, body)
    |> assign(:auth_context, %{user_id: user_id, tenant_id: fixture.tenant_id, roles: roles})
  end

  defp call(router, method, path, fixture, roles, opts \\ []) do
    conn = conn_for(method, path, fixture, roles, opts)
    router.call(conn, router.init([]))
  end

  defp api(method, path, fixture, token, body) do
    Fixture.api_conn(method, path, token, fixture.tenant.slug, body) |> Fixture.dispatch_api()
  end

  defp concrete(path), do: Regex.replace(~r/:[a-z_]+/, path, @unused_uuid)

  defp verb(method), do: method |> to_string() |> String.downcase() |> String.to_atom()

  defp body_for(method) when method in [:post, :put, :patch], do: %{}
  defp body_for(_method), do: nil

  defp ids(conn),
    do: conn.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["id"])

  defp mounted_routers do
    ~r/forward\(\s*"([^"]+)"\s*,\s*to:\s*([A-Za-z0-9_.]+)\s*\)/
    |> Regex.scan(@pipeline_source)
    |> Enum.map(fn [_all, _prefix, module] -> Module.concat([module]) end)
  end

  # Every mounted router that exposes `__authz_routes__/0` (all but the plain-Plug Modules router).
  # `Code.ensure_loaded?/1` first: `function_exported?/3` is false for a module not yet loaded.
  defp authorized_routers do
    for router <- mounted_routers(),
        Code.ensure_loaded?(router),
        function_exported?(router, :__authz_routes__, 0),
        do: router
  end

  # Whole-state snapshot: every table of every fixture schema plus the global tables the routes
  # under test could write.
  defp snapshot(ctx) do
    schemas =
      for fixture <- [ctx.a, ctx.b, ctx.p], into: %{} do
        %{rows: tables} =
          Repo.query!(
            "SELECT tablename FROM pg_tables WHERE schemaname = $1 ORDER BY tablename",
            [fixture.schema_name]
          )

        counts =
          for [table] <- tables, into: %{} do
            %{rows: [[n]]} =
              Repo.query!(~s|SELECT count(*) FROM "#{fixture.schema_name}"."#{table}"|)

            {table, n}
          end

        {fixture.schema_name, counts}
      end

    tenant_ids = Enum.map([ctx.a, ctx.b, ctx.p], & &1.tenant_id)

    %{
      schemas: schemas,
      secrets: Repo.aggregate(from(s in Secret, where: s.tenant_id in ^tenant_ids), :count),
      pack_bases:
        Repo.aggregate(
          from(b in SolutionPackArtefactBase, where: b.tenant_id in ^tenant_ids),
          :count
        ),
      pack_resolutions:
        Repo.aggregate(
          from(r in PackUpdateResolution, where: r.tenant_id in ^tenant_ids),
          :count
        ),
      tenants:
        from(t in Tenant, where: t.id in ^tenant_ids)
        |> Repo.all()
        |> Enum.map(&{&1.id, &1.status, &1.updated_at})
        |> Enum.sort()
    }
  end

  # Asserts no table of any fixture schema (except `ignore_tables`) and no global row changed.
  defp assert_unchanged(before, ctx, ignore_tables \\ []) do
    after_ = snapshot(ctx)

    table_diffs =
      for {schema, counts} <- before.schemas,
          {table, n} <- counts,
          after_.schemas[schema][table] != n and table not in ignore_tables,
          do: {schema, table, n, after_.schemas[schema][table]}

    global_diffs =
      for key <- [:secrets, :pack_bases, :pack_resolutions, :tenants],
          Map.fetch!(before, key) != Map.fetch!(after_, key),
          do: {key, Map.fetch!(before, key), Map.fetch!(after_, key)}

    assert table_diffs ++ global_diffs == [],
           "state changed: #{inspect(table_diffs ++ global_diffs)}"
  end

  # --- fixtures --------------------------------------------------------------------------------

  defp insert_user!(fixture) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req448-#{Ecto.UUID.generate()}",
      display_name: "REQ-448 User",
      email: "req448-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp insert_group!(fixture) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "req448-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  # instance_projections -> tokens -> tasks FK chain (as tasks_test.exs).
  defp insert_task!(fixture, attrs) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: fixture.schema_name)

    token =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: "review",
        branch_id: "b1"
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    %EngineTask{}
    |> EngineTask.insert_changeset(
      Map.merge(
        %{
          instance_id: instance_id,
          token_id: token.id,
          node_id: "review",
          node_name: "Review",
          assignee_type: nil,
          assignee_ref: nil
        },
        attrs
      )
    )
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_definition!(fixture) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: "req448-def-#{System.unique_integer([:positive])}",
          version: "1.0.0",
          graph: graph_start_end(),
          created_by: Ecto.UUID.generate()
        },
        prefix: fixture.schema_name
      )

    definition
  end

  defp upload!(fixture, instance_id, bytes) do
    {:ok, attachment} =
      Attachments.upload(
        %{
          instance_id: instance_id,
          raw_bytes: bytes,
          file_name: "req448.txt",
          content_type: "text/plain",
          uploaded_by: Ecto.UUID.generate(),
          description: nil
        },
        prefix: fixture.schema_name
      )

    attachment
  end

  defp seed_widget!(fixture, user_id) do
    {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)

    {:ok, definition} =
      EntityDefinitions.create_definition(
        %{
          definition: %{
            name: "widget",
            display_name: "Widget",
            fields: [
              %{name: "title", type: :string, queried: true},
              %{name: "quantity", type: :integer, queried: true}
            ]
          },
          created_by: user_id
        },
        fixture.schema_name
      )

    {:ok, _activated} =
      EntityDefinitions.activate_definition(
        definition.name,
        user_id,
        "req448 go-live",
        fixture.schema_name
      )

    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "widget",
          field_values: %{"title" => "CLEARTEXT TITLE", "quantity" => 3},
          actor_id: user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        fixture.schema_name
      )

    record
  end

  # --- AC2: 200 block --------------------------------------------------------------------------

  describe "AC2: a TENANT_AUDITOR of an ordinary tenant is allowed (200) on the read routes" do
    test "GET /definitions, GET /definitions/:id, GET /instances, GET /audit", ctx do
      definition = create_definition!(ctx.a)

      assert %{status: 200} = call(Letflow.Routers.Definitions, :get, "/", ctx.a, @auditor)

      assert %{status: 200} =
               call(Letflow.Routers.Definitions, :get, "/#{definition.id}", ctx.a, @auditor)

      assert %{status: 200} = call(Letflow.Routers.Instances, :get, "/", ctx.a, @auditor)
      assert %{status: 200} = call(Letflow.Routers.Audit, :get, "/", ctx.a, @auditor)
    end

    test "GET /services is not denied (a read of the service catalogue)", ctx do
      conn = call(Letflow.Routers.Services, :get, "/", ctx.a, @auditor)
      assert conn.status == 200, conn.resp_body
    end

    test "GET /help/resolved reaches its handler (400 without screen_id), it is not a 403", ctx do
      conn = call(Letflow.Routers.Help, :get, "/resolved", ctx.a, @auditor)
      assert conn.status == 400, "#{conn.status} #{conn.resp_body}"
    end

    test "attachment reads: list, one attachment and storage-usage are 200", ctx do
      instance_id = real_instance!(ctx.a)
      attachment = upload!(ctx.a, instance_id, "audit evidence")

      assert %{status: 200} =
               call(
                 Letflow.Routers.Instances,
                 :get,
                 "/#{instance_id}/attachments",
                 ctx.a,
                 @auditor
               )

      assert %{status: 200} =
               call(
                 Letflow.Routers.Instances,
                 :get,
                 "/#{instance_id}/attachments/#{attachment.id}",
                 ctx.a,
                 @auditor
               )

      assert %{status: 200} =
               call(Letflow.Routers.Instances, :get, "/storage-usage", ctx.a, @auditor)
    end
  end

  describe "AC2: GET /tasks and GET /tasks/inbox are UNFILTERED for the auditor (task_scope :all)" do
    test "tasks assigned to other users and groups are all visible; a TASK_WORKER alone sees only its own",
         ctx do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      worker = insert_user!(ctx.a)
      group = insert_group!(ctx.a)

      task_a = insert_task!(ctx.a, %{assignee_type: "USER", assignee_ref: user_a})
      task_b = insert_task!(ctx.a, %{assignee_type: "USER", assignee_ref: user_b})
      task_g = insert_task!(ctx.a, %{assignee_type: "GROUP", assignee_ref: group.id})
      task_own = insert_task!(ctx.a, %{assignee_type: "USER", assignee_ref: worker.id})
      everyone = [task_a.id, task_b.id, task_g.id, task_own.id]

      for path <- ["/?page_size=50", "/inbox?page_size=50"] do
        auditor = call(Letflow.Routers.Tasks, :get, path, ctx.a, @auditor)
        assert auditor.status == 200, path
        assert Enum.sort(ids(auditor)) == Enum.sort(everyone), path

        # OQ-1: the auditor who also holds TASK_WORKER is unfiltered too.
        both =
          call(Letflow.Routers.Tasks, :get, path, ctx.a, ["TENANT_AUDITOR", "TASK_WORKER"],
            user_id: worker.id
          )

        assert both.status == 200, path
        assert Enum.sort(ids(both)) == Enum.sort(everyone), path

        # Control: TASK_WORKER alone is row-filtered, so the unfiltered result above is real.
        only_worker =
          call(Letflow.Routers.Tasks, :get, path, ctx.a, ["TASK_WORKER"], user_id: worker.id)

        assert only_worker.status == 200, path
        assert ids(only_worker) == [task_own.id], path
      end
    end

    test "GET /tasks/:id of a task assigned to someone else is 200 for the auditor", ctx do
      task = insert_task!(ctx.a, %{assignee_type: "USER", assignee_ref: Ecto.UUID.generate()})
      conn = call(Letflow.Routers.Tasks, :get, "/#{task.id}", ctx.a, @auditor)
      assert conn.status == 200, conn.resp_body
    end
  end

  describe "AC2: POST /entities/query and /entities/query/aggregate" do
    test "both are 200 for an existing entity type and return the record", ctx do
      user = insert_user!(ctx.a)
      record = seed_widget!(ctx.a, user.id)

      query =
        call(Letflow.Routers.Entities, :post, "/query", ctx.a, @auditor,
          body: %{"entity_type" => "widget"}
        )

      assert query.status == 200, query.resp_body
      assert [item] = Jason.decode!(query.resp_body)["items"]
      assert item["field_values"]["title"] == "CLEARTEXT TITLE"
      assert item["record_id"] == record.record_id

      aggregate =
        call(Letflow.Routers.Entities, :post, "/query/aggregate", ctx.a, @auditor,
          body: %{"entity_type" => "widget", "aggregates" => [%{"fn" => "count"}]}
        )

      assert aggregate.status == 200, aggregate.resp_body
      assert [%{"values" => %{"count_none" => 1}}] = Jason.decode!(aggregate.resp_body)["results"]
    end

    test "INV-2: a restricted field is redacted for the auditor exactly as for TASK_WORKER and PROCESS_OPERATOR callers",
         ctx do
      user = insert_user!(ctx.a)
      seed_widget!(ctx.a, user.id)

      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "widget",
            field_name: "title",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.a.schema_name
      )

      sentinel = Atom.to_string(FieldGrants.redacted_sentinel())

      for roles <- [@auditor, ["TASK_WORKER"], ["PROCESS_OPERATOR"]] do
        token = Fixture.mint_token!(ctx.a, roles)

        conn =
          api(:post, "/api/v1/entities/query", ctx.a, token, %{"entity_type" => "widget"})

        assert conn.status == 200, "#{inspect(roles)}: #{conn.resp_body}"
        assert [item] = Jason.decode!(conn.resp_body)["items"]
        assert item["field_values"]["title"] == sentinel, inspect(roles)
        # selective: the unrestricted field is still readable
        assert item["field_values"]["quantity"] == 3, inspect(roles)
      end
    end
  end

  describe "AC2: the read-class POSTs persist nothing (design 2.5, state-free by whole-schema snapshot)" do
    test "POST /definitions/:id/validate is 200 and every table of the tenant is unchanged",
         ctx do
      definition = create_definition!(ctx.a)
      before = snapshot(ctx)

      conn =
        call(Letflow.Routers.Definitions, :post, "/#{definition.id}/validate", ctx.a, @auditor,
          body: %{}
        )

      assert conn.status == 200, conn.resp_body
      assert Jason.decode!(conn.resp_body)["status"] == "valid"
      assert_unchanged(before, ctx)
    end

    test "POST /solution-packs/export is 200 and nothing is written", ctx do
      definition = create_definition!(ctx.a)
      before = snapshot(ctx)

      conn =
        call(Letflow.Routers.SolutionPacks, :post, "/export", ctx.a, @auditor,
          body: %{"definition_ids" => [definition.id]}
        )

      assert conn.status == 200, conn.resp_body
      assert_unchanged(before, ctx)
    end

    test "POST /solution-packs/:pack_id/update-review is 200 and writes no base and no resolution",
         ctx do
      pack_id = "req448-pack-#{System.unique_integer([:positive])}"
      artefact_id = Ecto.UUID.generate()

      on_exit(fn ->
        Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id == ^ctx.a.tenant_id))

        Repo.delete_all(
          from(b in SolutionPackArtefactBase, where: b.tenant_id == ^ctx.a.tenant_id)
        )
      end)

      %SolutionPackArtefactBase{}
      |> SolutionPackArtefactBase.upsert_changeset(%{
        tenant_id: ctx.a.tenant_id,
        pack_id: pack_id,
        artefact_type: "process_definition",
        artefact_id: artefact_id,
        base_version: "1.0.0",
        base_content: "base",
        captured_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
      })
      |> Repo.insert!()

      before = snapshot(ctx)
      assert before.pack_bases == 1
      assert before.pack_resolutions == 0

      entry = fn content ->
        %{
          "artefact_type" => "process_definition",
          "artefact_id" => artefact_id,
          "content" => content
        }
      end

      conn =
        call(
          Letflow.Routers.SolutionPacks,
          :post,
          "/#{pack_id}/update-review",
          ctx.a,
          @auditor,
          body: %{
            "target_version" => "2.0.0",
            "theirs_artefacts" => [entry.("base")],
            "incoming_artefacts" => [entry.("changed")]
          }
        )

      assert conn.status == 200, conn.resp_body
      assert [%{"artefact_id" => ^artefact_id}] = Jason.decode!(conn.resp_body)["entries"]
      assert_unchanged(before, ctx)
    end
  end

  describe "AC2: the same decisions through the FULL Letflow.Router pipeline with a real API token" do
    test "auditor token of tenant A: 200 on the read routes incl. /me/memberships and /me/modules; 403 on platform prefixes and a write",
         ctx do
      token = Fixture.mint_token!(ctx.a, @auditor)

      for path <- [
            "/api/v1/definitions",
            "/api/v1/instances",
            "/api/v1/tasks",
            "/api/v1/tasks/inbox",
            "/api/v1/audit",
            "/api/v1/services",
            "/api/v1/me/memberships",
            "/api/v1/me/modules",
            "/api/v1/me/access"
          ] do
        conn = api(:get, path, ctx.a, token, nil)
        assert conn.status == 200, "GET #{path}: #{conn.status} #{conn.resp_body}"
      end

      query = api(:post, "/api/v1/entities/query", ctx.a, token, %{"entity_type" => "nope"})
      refute query.status == 403, query.resp_body

      for {method, path} <- [
            {:get, "/api/v1/tenants"},
            {:get, "/api/v1/onboarding"},
            {:get, "/api/v1/event-retention/summary"},
            {:get, "/api/v1/admin/services"},
            {:post, "/api/v1/definitions"},
            {:get, "/api/v1/identity/no-such-route-req448"}
          ] do
        conn = api(method, path, ctx.a, token, body_for(method))
        assert conn.status == 403, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
      end
    end

    test "the platform tenant's own auditor is a non-operator: tenant routes 200, platform prefixes 403",
         ctx do
      token = Fixture.mint_token!(ctx.p, @auditor)

      for path <- ["/api/v1/definitions", "/api/v1/instances", "/api/v1/audit"] do
        conn = api(:get, path, ctx.p, token, nil)
        assert conn.status == 200, "GET #{path}: #{conn.status} #{conn.resp_body}"
      end

      for path <- [
            "/api/v1/tenants",
            "/api/v1/onboarding",
            "/api/v1/platform-migrations/rollouts/#{@unused_uuid}",
            "/api/v1/admin/services"
          ] do
        conn = api(:get, path, ctx.p, token, nil)
        assert conn.status == 403, path
      end
    end
  end

  # --- AC2: 403 block --------------------------------------------------------------------------

  describe "AC2 completeness guards" do
    test "the routers mounted in ApiPipeline are exactly the 34 named in the table: a new router fails here" do
      mounted = mounted_routers()
      named = Enum.map(@named_routes, &elem(&1, 0))

      assert length(mounted) == length(Enum.uniq(mounted))
      assert Enum.sort(mounted) == Enum.sort(named)
      # REQ-497 PR 1b: 27 with Letflow.Routers.TenantScopeEnforcement; REQ-517 PR 2a: 28 with
      # Letflow.Routers.TenantRoleScopeGrants; REQ-536: 29 with Letflow.Routers.Documents; REQ-552: 30 with Letflow.Routers.TenantConfigBundle; REQ-551: 31 with Letflow.Routers.Labels; REQ-565: 32 with Letflow.Routers.IntegrationMappings; REQ-555: 33 with Letflow.Routers.EntityViews; REQ-563: 34 with Letflow.Routers.NotificationTemplates.
      assert length(named) == 34
    end

    test "every named :route exists in its router and the auditor does NOT hold its permission (a row cannot pass by naming a permitted route)" do
      for {router, _prefix, method, local, kind} <- @named_routes, kind == :route do
        key = route_key!(router, method, local)
        permission = Authorization.required_permission(key)

        refute Authorization.has_permission_in_scope?([:TENANT_AUDITOR], permission, true),
               "#{inspect(router)} #{method} #{local} -> #{inspect(permission)} is held by the auditor"

        refute Authorization.has_permission_in_scope?([:TENANT_AUDITOR], permission, false)
      end

      for {router, method, local} <- @extra_routes do
        key = route_key!(router, method, local)
        permission = Authorization.required_permission(key)

        refute Authorization.has_permission_in_scope?([:TENANT_AUDITOR], permission, true),
               "#{inspect(router)} #{method} #{local} -> #{inspect(permission)} is held by the auditor"
      end
    end

    test "the four read-only routers declare only GET routes (so a non-GET probe is the only write-shaped request there)" do
      for router <- [
            Letflow.Routers.Audit,
            Letflow.Routers.Services,
            Letflow.Routers.Help,
            Letflow.Routers.Me
          ] do
        methods = router.__authz_routes__() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        assert methods == ["GET"], inspect(router)
      end
    end

    test "the non-GET routes the auditor holds are exactly the literal allowlist of design 2.5 (everything else that persists is denied)" do
      held_non_get =
        for router <- authorized_routers(),
            {method, local, key} <- router.__authz_routes__(),
            method != "GET",
            Authorization.has_permission_in_scope?(
              [:TENANT_AUDITOR],
              Authorization.required_permission(key),
              false
            ),
            do: {router, method, local}

      assert Enum.sort(held_non_get) == Enum.sort(@allowed_non_get)
    end
  end

  describe "AC2: one named write route per mounted router answers 403, with no row changed" do
    test "directly into each router (the Modules router is covered through the pipeline below)",
         ctx do
      before = snapshot(ctx)

      for {router, _prefix, method, local, kind} <- @named_routes, kind != :modules do
        conn =
          call(router, method, concrete(local), ctx.a, @auditor, body: body_for(method))

        assert conn.status == 403,
               "#{inspect(router)} #{method} #{local} (#{kind}): #{conn.status} #{conn.resp_body}"

        assert conn.resp_body =~ "insufficient permissions",
               "#{inspect(router)} #{method} #{local}: #{conn.resp_body}"
      end

      assert_unchanged(before, ctx)
    end

    test "through the full pipeline with a real auditor token, all 34 mounts (and the Modules router with the exam module installed)",
         ctx do
      {:ok, _tenant_module} =
        Installs.install("exam", Ecto.UUID.generate(),
          prefix: ctx.a.schema_name,
          rationale: "test: module install"
        )

      # The exam install registers a solution pack: GLOBAL rows with an FK onto the tenant, which
      # must go before the fixture's own teardown deletes the tenant (on_exit runs LIFO).
      on_exit(fn ->
        Repo.delete_all(
          from(i in Letflow.Definitions.SolutionPackInstall,
            where: i.tenant_id == ^ctx.a.tenant_id
          )
        )
      end)

      token = Fixture.mint_token!(ctx.a, @auditor)
      before = snapshot(ctx)

      for {router, prefix, method, local, kind} <- @named_routes do
        local_path = if local == "/", do: "", else: concrete(local)
        path = "/api/v1" <> prefix <> local_path
        conn = api(method, path, ctx.a, token, body_for(method))

        assert conn.status == 403,
               "#{inspect(router)} #{method} #{path} (#{kind}): #{conn.status} #{conn.resp_body}"
      end

      assert_unchanged(before, ctx)
    end

    test "the four probes: the verb is the only difference from an allowed GET, and the GET is not 403",
         ctx do
      token = Fixture.mint_token!(ctx.a, @auditor)

      for {path, query} <- [
            {"/api/v1/audit", ""},
            {"/api/v1/services", ""},
            {"/api/v1/help/resolved", "?screen_id=req448"},
            {"/api/v1/me/memberships", ""}
          ] do
        get = api(:get, path <> query, ctx.a, token, nil)
        refute get.status == 403, "GET #{path}: #{get.status}"

        probe = api(:post, path, ctx.a, token, %{})
        assert probe.status == 403, "POST #{path}: #{probe.status}"
      end
    end

    test "the named extras: identity tokens/roles, cancel, upload, rollback, claim/assign, update-apply, export/import, restrictions import, DLQ and webhooks",
         ctx do
      before = snapshot(ctx)

      for {router, method, local} <- @extra_routes do
        conn = call(router, method, concrete(local), ctx.a, @auditor, body: body_for(method))

        assert conn.status == 403,
               "#{inspect(router)} #{method} #{local}: #{conn.status} #{conn.resp_body}"
      end

      assert_unchanged(before, ctx)
    end

    test "GET /promotions and GET /promotions/platform-events are 200 for the auditor (ISS-1109: :PromotionsRead is granted)",
         ctx do
      assert Authorization.role_allows?(:TENANT_AUDITOR, :PromotionsRead)
      before = snapshot(ctx)

      for path <- ["/", "/platform-events"] do
        conn = call(Letflow.Routers.Promotions, :get, path, ctx.a, @auditor)
        assert conn.status == 200, "GET /promotions#{path}: #{conn.status} #{conn.resp_body}"
      end

      assert_unchanged(before, ctx)

      # through the full pipeline too (a token login JIT-provisions the user, so no snapshot)
      token = Fixture.mint_token!(ctx.a, @auditor)

      for path <- ["/api/v1/promotions", "/api/v1/promotions/platform-events"] do
        conn = api(:get, path, ctx.a, token, nil)
        assert conn.status == 200, "GET #{path}: #{conn.status} #{conn.resp_body}"
      end
    end

    test "every :PromotionsManage route is 403 for the auditor with the generic forbidden problem body",
         ctx do
      refute Authorization.role_allows?(:TENANT_AUDITOR, :PromotionsManage)
      before = snapshot(ctx)

      routes = [
        {:post, "/"},
        {:post, "/plan"},
        {:post, "/#{@unused_uuid}/approve"},
        {:post, "/#{@unused_uuid}/reject"},
        {:post, "/#{@unused_uuid}/apply"},
        {:post, "/#{@unused_uuid}/run-assertions"}
      ]

      for {method, path} <- routes do
        conn = call(Letflow.Routers.Promotions, method, path, ctx.a, @auditor, body: %{})

        assert conn.status == 403,
               "#{method} /promotions#{path}: #{conn.status} #{conn.resp_body}"

        body = Jason.decode!(conn.resp_body)

        assert %{"title" => "Forbidden", "status" => 403, "detail" => "insufficient permissions"} =
                 body,
               "#{method} /promotions#{path}: #{conn.resp_body}"

        assert String.ends_with?(body["type"], "/forbidden"), conn.resp_body
      end

      assert_unchanged(before, ctx)
    end

    test "a non-party auditor gets the SAME 404 on GET /promotions/:id and /:id/context as for a nonexistent id and as a TENANT_ADMIN (ISS-1029 applies to the auditor)",
         ctx do
      # Held in A's schema, naming B and P (neither is A): A is not a party.
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.p.tenant_id)
      absent = Ecto.UUID.generate()
      promotions = Letflow.Routers.Promotions

      for suffix <- ["", "/context"] do
        auditor = call(promotions, :get, "/#{review.id}#{suffix}", ctx.a, @auditor)
        admin = call(promotions, :get, "/#{review.id}#{suffix}", ctx.a, ["TENANT_ADMIN"])
        missing = call(promotions, :get, "/#{absent}#{suffix}", ctx.a, @auditor)

        assert auditor.status == 404, "#{suffix}: #{auditor.status} #{auditor.resp_body}"
        assert Scope.observable(auditor) == Scope.observable(missing), suffix
        assert Scope.observable(auditor) == Scope.observable(admin), suffix
        refute auditor.resp_body =~ review.id
        refute auditor.resp_body =~ ctx.b.tenant_id
        refute auditor.resp_body =~ ctx.p.tenant_id
      end
    end

    test "positive control: the auditor reads a review that names its own tenant on both sides with 200",
         ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id)

      for suffix <- ["", "/context"] do
        conn = call(Letflow.Routers.Promotions, :get, "/#{review.id}#{suffix}", ctx.a, @auditor)
        assert conn.status == 200, "#{suffix}: #{conn.status} #{conn.resp_body}"
      end
    end

    test "exhaustive sweep: for every route of every mounted router the answer is 403 exactly when the auditor lacks the permission",
         ctx do
      before = snapshot(ctx)

      results =
        for router <- authorized_routers(),
            {method, local, key} <- router.__authz_routes__() do
          permission = Authorization.required_permission(key)
          held? = Authorization.has_permission_in_scope?([:TENANT_AUDITOR], permission, false)
          dispatch? = not held? or method == "GET" or {router, method, local} in @allowed_non_get

          status =
            if dispatch? do
              conn =
                call(router, verb(method), concrete(local), ctx.a, @auditor,
                  body: body_for(verb(method))
                )

              conn.status
            end

          {router, method, local, held?, status}
        end

      assert length(results) > 100

      for {router, method, local, held?, status} <- results, status != nil do
        if held? do
          refute status == 403, "#{inspect(router)} #{method} #{local} is held but got 403"
        else
          assert status == 403, "#{inspect(router)} #{method} #{local} not held but got #{status}"
        end
      end

      # Both halves of the sweep are non-vacuous.
      assert Enum.any?(results, fn {_r, _m, _l, held?, _s} -> held? end)
      assert Enum.any?(results, fn {_r, _m, _l, held?, _s} -> not held? end)

      # The only thing the sweep may write is REQ-388's append-only `attachment.access_denied`
      # audit entry (a denied or missing attachment read is itself audited, by design); no
      # business state changes. The entries' actions are asserted, not just tolerated.
      assert_unchanged(before, ctx, ["audit_entries", "audit_chain_locks"])

      actions =
        Repo.all(from(e in Letflow.Audit.Entry, select: e.action), prefix: ctx.a.schema_name)

      assert Enum.uniq(actions) -- ["attachment.access_denied"] == []
    end

    test "an auditor of an INACTIVE tenant is halted by TenantStatus with 403 tenant_inactive",
         ctx do
      token = Fixture.mint_token!(ctx.a, @auditor)
      assert api(:get, "/api/v1/definitions", ctx.a, token, nil).status == 200

      Repo.update_all(from(t in Tenant, where: t.id == ^ctx.a.tenant_id),
        set: [status: :inactive]
      )

      conn = api(:get, "/api/v1/definitions", ctx.a, token, nil)
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "tenant_inactive"
    end
  end

  # --- item L1: the attachment link route ------------------------------------------------------

  describe "item L1: POST /instances/:id/attachments/:attachment_id/link role reach" do
    defp issue_link(fixture, instance_id, attachment_id, roles) do
      call(
        Letflow.Routers.Instances,
        :post,
        "/#{instance_id}/attachments/#{attachment_id}/link",
        fixture,
        roles
      )
    end

    defp secrets_for(fixture),
      do: Repo.aggregate(from(s in Secret, where: s.tenant_id == ^fixture.tenant_id), :count)

    test "every role that reached the route before REQ-448 still gets 200; the auditor, AGENT_RUNNER and CANDIDATE get 403 and no signing secret is written",
         ctx do
      # --- the denied roles first, in tenant B which has never issued a link (no signing key)
      instance_b = Ecto.UUID.generate()
      attachment_b = upload!(ctx.b, instance_b, "denied-link bytes")
      assert secrets_for(ctx.b) == 0

      for role <- ["TENANT_AUDITOR", "AGENT_RUNNER", "CANDIDATE"] do
        conn = issue_link(ctx.b, instance_b, attachment_b.id, [role])
        assert conn.status == 403, "#{role}: #{conn.status} #{conn.resp_body}"
        refute conn.resp_body =~ "token", role
      end

      assert secrets_for(ctx.b) == 0

      # --- the five allowed roles. Literal list (the roles that held :AttachmentsRead before L1),
      # not derived from role_allows?/2.
      instance_a = real_instance!(ctx.a)
      attachment_a = upload!(ctx.a, instance_a, "allowed-link bytes")
      assert secrets_for(ctx.a) == 0

      for role <- ["PROCESS_DESIGNER", "PROCESS_OPERATOR", "TASK_WORKER", "TENANT_ADMIN"] do
        conn = issue_link(ctx.a, instance_a, attachment_a.id, [role])
        assert conn.status == 200, "#{role}: #{conn.status} #{conn.resp_body}"
        assert is_binary(Jason.decode!(conn.resp_body)["token"]), role
      end

      # positive control: the secret counter does move when the link IS issued
      assert secrets_for(ctx.a) == 1

      # PLATFORM_ADMIN is honoured only in the pinned platform tenant (fixture P)
      instance_p = real_instance!(ctx.p)
      attachment_p = upload!(ctx.p, instance_p, "platform link bytes")
      conn = issue_link(ctx.p, instance_p, attachment_p.id, ["PLATFORM_ADMIN"])
      assert conn.status == 200, conn.resp_body

      # and outside the platform tenant PLATFORM_ADMIN confers nothing (unchanged behaviour)
      outside = issue_link(ctx.a, instance_a, attachment_a.id, ["PLATFORM_ADMIN"])
      assert outside.status == 403

      # the auditor of the platform tenant is also denied
      assert issue_link(ctx.p, instance_p, attachment_p.id, @auditor).status == 403
    end

    test "GET .../link-content is still 200 for the auditor, with a token issued by an allowed role",
         ctx do
      instance_id = real_instance!(ctx.a)
      attachment = upload!(ctx.a, instance_id, "auditor can read this")

      issued = issue_link(ctx.a, instance_id, attachment.id, ["TENANT_ADMIN"])
      assert issued.status == 200, issued.resp_body
      token = Jason.decode!(issued.resp_body)["token"]

      conn =
        call(
          Letflow.Routers.Instances,
          :get,
          "/#{instance_id}/attachments/#{attachment.id}/link-content?link_token=#{URI.encode_www_form(token)}",
          ctx.a,
          @auditor
        )

      assert conn.status == 200, conn.resp_body
      assert conn.resp_body == "auditor can read this"
    end

    test "the auditor cannot obtain the link through the full pipeline either", ctx do
      instance_id = Ecto.UUID.generate()
      attachment = upload!(ctx.b, instance_id, "x")
      token = Fixture.mint_token!(ctx.b, @auditor)

      conn =
        api(
          :post,
          "/api/v1/instances/#{instance_id}/attachments/#{attachment.id}/link",
          ctx.b,
          token,
          %{}
        )

      assert conn.status == 403
      assert secrets_for(ctx.b) == 0
    end
  end

  # --- helpers needing the router tables ----------------------------------------------------------

  # The policy key a router declares for {method, local_path}; fails the test if it is not declared.
  defp route_key!(router, method, local) do
    upper = method |> to_string() |> String.upcase()

    case Enum.find(router.__authz_routes__(), fn {m, p, _key} -> m == upper and p == local end) do
      {_m, _p, key} -> key
      nil -> flunk("#{inspect(router)} declares no #{upper} #{local}")
    end
  end
end
