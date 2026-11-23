defmodule Letflow.Routers.PlatformCallStartRouteTest do
  @moduledoc """
  The START of a definition that calls a platform function, proved through the
  REAL HTTP surface (T-2588, "Register a tenant" pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  The context tests of the rule (`test/letflow/engine/platform_call_start_permission_test.exs`)
  call `Letflow.Engine.create/2` with a hand-built `auth_context`. The ROUTE is
  what hands the caller's own context to that ONE start function
  (`lib/letflow/routers/instances.ex`, `handle_create/1`), and nothing proved
  that line: with the line gone every context test still passed, while the
  pilot's process could never be started at all -- the gate refuses a start whose
  caller is nobody (fail closed).

  This file closes that gap at the surface a caller actually uses:

    * the platform tenant's PLATFORM_ADMIN starts the definition over
      `POST /api/v1/instances` and gets the instance;
    * a platform user WITHOUT the entry's permission gets the answer for an
      UNKNOWN definition (INV-5) and nothing is written;
    * a company tenant's administrator gets the same answer and learns nothing.

  Real Postgres, real tenant schemas, real API tokens through the real
  `Letflow.Router`. `async: false`: the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)

    admin = Fx.user!(tenants.p.schema_name, "admin")
    Fx.platform_admin!(tenants.p.schema_name, admin)

    %{platform: tenants.p, company: tenants.a, admin: admin}
  end

  # START -> HUMAN_TASK -> SERVICE_TASK (the platform call) -> END: the platform
  # call sits BEHIND the human task, so the instance STARTS (the step library of
  # gap G1 does not dispatch the platform call yet -- that is gap G1's work).
  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"const" => "Acme"}
              })
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "call"},
        %{"id" => "e3", "source" => "call", "target" => "end"}
      ]
    }
  end

  defp active_definition(ctx) do
    draft = Fx.definition!(ctx.platform.schema_name, graph(), "pcf-start-route")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.platform.schema_name,
               activator: activator
             )

    draft
  end

  defp start_route(token, slug, definition_id) do
    PlatformFx.api_conn(
      :post,
      "/api/v1/instances",
      token,
      slug,
      %{"definition_id" => definition_id, "initial_variables" => %{"slug" => "acme"}}
    )
    |> PlatformFx.dispatch_api()
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  test "the platform tenant's PLATFORM_ADMIN starts it over the route", ctx do
    definition = active_definition(ctx)
    token = PlatformFx.mint_token!(ctx.platform, ["PLATFORM_ADMIN"])
    before = instance_count(ctx.platform.schema_name)

    conn = start_route(token, ctx.platform.tenant.slug, definition.id)

    assert conn.status == 201, conn.resp_body

    body = Jason.decode!(conn.resp_body)
    assert body["instance_id"]
    assert instance_count(ctx.platform.schema_name) == before + 1
  end

  test "a platform user WITHOUT the entry's permission gets the answer for an unknown definition",
       ctx do
    definition = active_definition(ctx)
    token = PlatformFx.mint_token!(ctx.platform, ["PROCESS_OPERATOR"])
    before = instance_count(ctx.platform.schema_name)

    conn = start_route(token, ctx.platform.tenant.slug, definition.id)

    assert conn.status == 404, conn.resp_body
    assert instance_count(ctx.platform.schema_name) == before
  end

  test "a company tenant's administrator gets the answer for an unknown definition", ctx do
    definition = active_definition(ctx)
    token = PlatformFx.mint_token!(ctx.company, ["TENANT_ADMIN"])
    before = instance_count(ctx.company.schema_name)

    conn = start_route(token, ctx.company.tenant.slug, definition.id)

    assert conn.status == 404, conn.resp_body
    refute conn.resp_body =~ "tenant.create"
    assert instance_count(ctx.company.schema_name) == before
  end
end
