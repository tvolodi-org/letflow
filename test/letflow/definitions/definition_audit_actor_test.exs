defmodule Letflow.Definitions.DefinitionAuditActorTest do
  @moduledoc """
  Decision (d) of the platform-call authority rule (T-2588, "Register a tenant"
  pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`): the definition
  lifecycle audit row carries the actor.

  REQ-195 gave the `actor_id: nil` disposition a reason -- its AC11 forbade
  touching `lib/letflow/routers/definitions.ex`, the one place that knows the
  user. That reason has lapsed: the router now passes the caller's user id into
  the lifecycle functions, and the row carries it.

  A caller that is not a person (module code, a seed task) passes no actor, and
  the row keeps the `actor_id: nil` disposition -- "nobody" is still told apart
  from "a person", which is what the disposition was about.

  `async: false`: the tenant fixture switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.Reactivation
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.FixtureLedger
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx

  setup do
    tenant = Fx.tenant!("t2588-audit")
    user = Fx.user!(tenant.schema_name, "actor")

    %{tenant: tenant, user: user}
  end

  defp rows(schema_name, action) do
    Audit.Entry
    |> where([e], e.action == ^action)
    |> Repo.all(prefix: schema_name)
  end

  # One request through the REAL definition router, as the caller the auth
  # context describes. `body` is nil for the routes that carry no body.
  defp http_call(ctx, method, path, body \\ nil) do
    conn = conn(method, path)

    conn =
      case body do
        nil ->
          conn

        body ->
          conn
          |> Map.put(:body_params, body)
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "fixed-test-trace-id")
    |> Letflow.Routers.Definitions.call(Letflow.Routers.Definitions.init([]))
  end

  defp trivial_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  test "the create row carries the actor the caller passed", ctx do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: "pcf-audit-1",
                 version: "1",
                 graph: trivial_graph(),
                 created_by: ctx.user.id
               },
               prefix: ctx.tenant.schema_name,
               actor_id: ctx.user.id
             )

    assert [entry] = rows(ctx.tenant.schema_name, "definition.create")
    assert entry.actor_id == ctx.user.id
    assert entry.actor_kind == "user"
    assert entry.resource_id == definition.id
  end

  test "the deactivate and archive rows carry the actor", ctx do
    {:ok, definition} =
      Definitions.create(
        %{
          name: "pcf-audit-2",
          version: "1",
          graph: trivial_graph(),
          created_by: ctx.user.id
        },
        prefix: ctx.tenant.schema_name,
        actor_id: ctx.user.id
      )

    assert {:ok, _} =
             Definitions.activate(definition.id,
               prefix: ctx.tenant.schema_name,
               activator:
                 Activator.from_auth_context(
                   %{user_id: ctx.user.id, roles: ["TENANT_ADMIN"]},
                   false
                 )
             )

    assert {:ok, _} =
             Definitions.deprecate(definition.id,
               prefix: ctx.tenant.schema_name,
               actor_id: ctx.user.id
             )

    assert {:ok, _} =
             Definitions.archive(definition.id,
               prefix: ctx.tenant.schema_name,
               actor_id: ctx.user.id
             )

    assert [deprecate] = rows(ctx.tenant.schema_name, "definition.deprecate")
    assert deprecate.actor_id == ctx.user.id
    assert deprecate.actor_kind == "user"

    assert [archive] = rows(ctx.tenant.schema_name, "definition.archive")
    assert archive.actor_id == ctx.user.id
    assert archive.actor_kind == "user"
  end

  test "the activation row carries the activator", ctx do
    {:ok, definition} =
      Definitions.create(
        %{
          name: "pcf-audit-3",
          version: "1",
          graph: trivial_graph(),
          created_by: ctx.user.id
        },
        prefix: ctx.tenant.schema_name
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.user.id, roles: ["TENANT_ADMIN"]}, false)

    assert {:ok, _} =
             Definitions.activate(definition.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    assert [entry] = rows(ctx.tenant.schema_name, "definition.activate")
    assert entry.actor_id == ctx.user.id
  end

  test "a caller that is not a person writes no actor (the REQ-195 disposition survives)", ctx do
    assert {:ok, _} =
             Definitions.create(
               %{
                 name: "pcf-audit-4",
                 version: "1",
                 graph: trivial_graph(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: ctx.tenant.schema_name
             )

    assert [entry] = rows(ctx.tenant.schema_name, "definition.create")
    assert entry.actor_id == nil
    # D-179 (d): "nobody" and "the system" are told apart by the row itself.
    assert entry.actor_kind == "system"
  end

  test "an actor that is not a UUID is read as nil, not as a crash (INV-8)", ctx do
    assert {:ok, _} =
             Definitions.create(
               %{
                 name: "pcf-audit-5",
                 version: "1",
                 graph: trivial_graph(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: ctx.tenant.schema_name,
               actor_id: "not-a-uuid"
             )

    assert [entry] = rows(ctx.tenant.schema_name, "definition.create")
    assert entry.actor_id == nil
    # An actor that cannot be resolved to a person is not a person: the row
    # says so rather than leaving the kind empty.
    assert entry.actor_kind == "system"
  end

  test "an HTTP lifecycle route writes the caller's kind (S11)", ctx do
    body = %{
      "name" => "pcf-audit-http",
      "version" => "1",
      "graph" => trivial_graph()
    }

    conn =
      conn("POST", "/")
      |> Map.put(:body_params, body)
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: ctx.user.id,
        tenant_id: ctx.tenant.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "fixed-test-trace-id")
      |> Letflow.Routers.Definitions.call(Letflow.Routers.Definitions.init([]))

    assert conn.status == 201

    assert [entry] = rows(ctx.tenant.schema_name, "definition.create")
    assert entry.actor_id == ctx.user.id
    assert entry.actor_kind == "user"
  end

  # The IMPORT route is the second HTTP lifecycle route that creates a definition
  # row (REQ-034's import path, driven through `Definitions.create/2` by
  # `ExportImport.import_with_variable_schemas/4`). Its handler passes the caller's
  # user id as the separate `imported_by` argument, which reaches only the
  # definition's `created_by` column -- the lifecycle audit row's actor comes from
  # the `opts` the handler hands over, so the handler must carry the caller there
  # too, or the row names nobody and claims the system did it.
  test "the import route writes the caller's kind on the definition.create row (S11)", ctx do
    body = %{
      "bpm_export_schema_version" => "bpm/definition/v1",
      "name" => "pcf-audit-import",
      "version" => "1",
      "graph" => trivial_graph()
    }

    conn =
      conn("POST", "/import")
      |> Map.put(:body_params, body)
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: ctx.user.id,
        tenant_id: ctx.tenant.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "fixed-test-trace-id")
      |> Letflow.Routers.Definitions.call(Letflow.Routers.Definitions.init([]))

    assert conn.status == 201

    assert [entry] = rows(ctx.tenant.schema_name, "definition.create")
    assert entry.actor_id == ctx.user.id
    assert entry.actor_kind == "user"
  end

  # ── the rest of the HTTP lifecycle routes ───────────────────────────────────
  #
  # S11 (T-2598, pilot gap G15): "each HTTP lifecycle route writes the caller's
  # user id". The create and import routes are covered above; the four routes
  # below write the other three rows of the definition lifecycle
  # (`definition.activate`, `definition.reactivate`, `definition.deprecate`,
  # `definition.archive`), and DELETE writes two of them. A row that names
  # nobody is the hidden actor the threat names: the change is visible, but not
  # who made it.

  test "the HTTP activate, deprecate and archive routes write the caller's kind (S11)", ctx do
    create_conn =
      http_call(ctx, "POST", "/", %{
        "name" => "pcf-audit-lifecycle",
        "version" => "1",
        "graph" => trivial_graph()
      })

    assert create_conn.status == 201
    assert [create] = rows(ctx.tenant.schema_name, "definition.create")
    assert create.actor_id == ctx.user.id
    assert create.actor_kind == "user"

    definition_id = create.resource_id

    activate_conn = http_call(ctx, "POST", "/#{definition_id}/activate")
    assert activate_conn.status == 200

    assert [activate] = rows(ctx.tenant.schema_name, "definition.activate")
    assert activate.actor_id == ctx.user.id
    assert activate.actor_kind == "user"

    deprecate_conn = http_call(ctx, "POST", "/#{definition_id}/deprecate")
    assert deprecate_conn.status == 200

    assert [deprecate] = rows(ctx.tenant.schema_name, "definition.deprecate")
    assert deprecate.actor_id == ctx.user.id
    assert deprecate.actor_kind == "user"

    archive_conn = http_call(ctx, "POST", "/#{definition_id}/archive")
    assert archive_conn.status == 200

    assert [archive] = rows(ctx.tenant.schema_name, "definition.archive")
    assert archive.actor_id == ctx.user.id
    assert archive.actor_kind == "user"
  end

  test "the HTTP reactivate route writes the caller's kind (S11)", ctx do
    create_conn =
      http_call(ctx, "POST", "/", %{
        "name" => "pcf-audit-reactivate",
        "version" => "1",
        "graph" => trivial_graph()
      })

    assert create_conn.status == 201
    [create] = rows(ctx.tenant.schema_name, "definition.create")
    definition_id = create.resource_id

    activate_conn = http_call(ctx, "POST", "/#{definition_id}/activate")
    assert activate_conn.status == 200

    # The definition is flagged by the SYSTEM (module code, never a person).
    assert {:ok, [_flagged]} =
             Reactivation.mark_definition(
               definition_id,
               :activator_absent,
               ctx.tenant.schema_name
             )

    reactivate_conn = http_call(ctx, "POST", "/#{definition_id}/reactivate")
    assert reactivate_conn.status == 200

    assert [reactivate] = rows(ctx.tenant.schema_name, "definition.reactivate")
    assert reactivate.actor_id == ctx.user.id
    assert reactivate.actor_kind == "user"
  end

  test "the HTTP delete route writes the caller's kind on the rows it writes (S11)", ctx do
    create_conn =
      http_call(ctx, "POST", "/", %{
        "name" => "pcf-audit-delete",
        "version" => "1",
        "graph" => trivial_graph()
      })

    assert create_conn.status == 201
    [create] = rows(ctx.tenant.schema_name, "definition.create")
    definition_id = create.resource_id

    activate_conn = http_call(ctx, "POST", "/#{definition_id}/activate")
    assert activate_conn.status == 200

    # DELETE on an ACTIVE definition deprecates it and archives it (two rows).
    delete_conn = http_call(ctx, "DELETE", "/#{definition_id}")
    assert delete_conn.status == 200

    assert [deprecate] = rows(ctx.tenant.schema_name, "definition.deprecate")
    assert deprecate.actor_id == ctx.user.id
    assert deprecate.actor_kind == "user"

    assert [archive] = rows(ctx.tenant.schema_name, "definition.archive")
    assert archive.actor_id == ctx.user.id
    assert archive.actor_kind == "user"
  end

  # The second half of S11: "system callers write `actor_kind: system`". The
  # caller is module code -- the reactivation marker, which runs inside the
  # writer's own transaction and has no person behind it. Its row must say
  # "the system", not leave the kind empty (the `actor_id: nil` alone cannot
  # tell "nobody" from "the system").
  test "a system caller writes the system kind, not a silent nil (S11)", ctx do
    {:ok, definition} =
      Definitions.create(
        %{
          name: "pcf-audit-system",
          version: "1",
          graph: trivial_graph(),
          created_by: ctx.user.id
        },
        prefix: ctx.tenant.schema_name
      )

    {:ok, _activated} =
      Definitions.activate(definition.id,
        prefix: ctx.tenant.schema_name,
        activator:
          Activator.from_auth_context(
            %{user_id: ctx.user.id, roles: ["TENANT_ADMIN"]},
            false
          )
      )

    assert {:ok, [_flagged]} =
             Reactivation.mark_definition(
               definition.id,
               :activator_absent,
               ctx.tenant.schema_name
             )

    assert [mark] = rows(ctx.tenant.schema_name, "definition.mark_needs_reactivation")
    assert mark.actor_id == nil
    assert mark.actor_kind == "system"
  end

  # Decision (d) of the authority rule: "Module installs and other non-HTTP
  # callers pass `nil` and an `actor_kind: "system"` WITH THE MODULE ID". The
  # module id is in the row itself -- the stamped `owner_module` of the
  # definition the install created -- so "the system" is never an unnamed
  # stranger.
  test "a module install writes the system kind and names the module in the row (S11)", ctx do
    owner = ManagedTypes.module_owner(FixtureLedger)

    assert {:ok, definition} =
             Definitions.create_owned(
               %{
                 name: "pcf-audit-module",
                 version: "1",
                 graph: trivial_graph(),
                 created_by: Ecto.UUID.generate()
               },
               [prefix: ctx.tenant.schema_name],
               owner
             )

    assert [entry] = rows(ctx.tenant.schema_name, "definition.create")
    assert entry.actor_id == nil
    assert entry.actor_kind == "system"
    assert entry.after_state["owner_module"] == "fixture_ledger"
    assert entry.after_state["owner_module"] == definition.owner_module
  end
end
