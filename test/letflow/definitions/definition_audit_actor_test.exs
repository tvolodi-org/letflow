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
end
