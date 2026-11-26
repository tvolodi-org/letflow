defmodule Letflow.Definitions.RegisterTenantStartInv5Test do
  @moduledoc """
  S4 of the pilot's authority rule, proved for the pilot's own process
  (T-2591, "Register a tenant" pilot, gap G3; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  **Threat.** A company user starts the platform's registration definition by
  id or by name, or probes whether it exists.

  **Mitigation.** The start permission and the platform tenant (INV-10); the
  answer of an unknown definition (INV-5). A company tenant's administrator
  gets BYTE-IDENTICAL answers for the known id, the known name and a random
  id -- so the probe learns nothing about the platform's process.

  The test drives the REAL HTTP surface (`POST /api/v1/instances`) and the ONE
  start function behind it, with the company tenant's own token.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
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

  defp schemas do
    [
      %{variable_key: "slug", json_schema: %{"type" => "string"}},
      %{variable_key: "tenant_id", json_schema: %{"type" => "string"}}
    ]
  end

  # The pilot's registration definition, in the PLATFORM tenant, with the
  # declared start permission.
  defp platform_definition(ctx) do
    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: "platform.register_tenant",
          version: "1",
          graph: graph(),
          created_by: Ecto.UUID.generate(),
          start_permission: "TenantsManage"
        },
        schemas(),
        prefix: ctx.platform.schema_name
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(definition.id,
               prefix: ctx.platform.schema_name,
               activator: activator
             )

    definition
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  defp start_route(token, slug, body) do
    PlatformFx.api_conn(
      :post,
      "/api/v1/instances",
      token,
      slug,
      Map.put(body, "initial_variables", %{"slug" => "acme"})
    )
    |> PlatformFx.dispatch_api()
  end

  # The body WITHOUT the request's own trace id: the trace id differs from
  # request to request and says nothing about the answer.
  defp answer_body(conn) do
    conn.resp_body
    |> Jason.decode!()
    |> Map.delete("trace_id")
  end

  test "S4-a: the company's administrator gets the SAME answer for the known id as for a random id",
       ctx do
    definition = platform_definition(ctx)
    token = PlatformFx.mint_token!(ctx.company, ["TENANT_ADMIN"])

    known = start_route(token, ctx.company.tenant.slug, %{"definition_id" => definition.id})

    random =
      start_route(token, ctx.company.tenant.slug, %{"definition_id" => Ecto.UUID.generate()})

    assert known.status == random.status
    assert answer_body(known) == answer_body(random)
    assert known.status == 404

    # Nothing was written in either tenant.
    assert instance_count(ctx.platform.schema_name) == 0
    assert instance_count(ctx.company.schema_name) == 0
  end

  test "S4-b: the company's administrator gets the SAME answer for the known name as for a random name",
       ctx do
    platform_definition(ctx)
    token = PlatformFx.mint_token!(ctx.company, ["TENANT_ADMIN"])

    known =
      start_route(token, ctx.company.tenant.slug, %{
        "definition_name" => "platform.register_tenant"
      })

    random =
      start_route(token, ctx.company.tenant.slug, %{
        "definition_name" => "platform.no_such_process"
      })

    assert known.status == random.status
    assert answer_body(known) == answer_body(random)
    assert known.status == 404

    assert instance_count(ctx.platform.schema_name) == 0
    assert instance_count(ctx.company.schema_name) == 0
  end

  test "S4-c: the ONE start function refuses a company caller by id and by name alike", ctx do
    definition = platform_definition(ctx)

    company_context = %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.company.tenant_id,
      roles: ["TENANT_ADMIN"]
    }

    by_id =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{"slug" => "acme"},
          actor_id: company_context.user_id,
          idempotency_key: "rt-inv5-by-id"
        },
        prefix: ctx.platform.schema_name,
        auth_context: company_context
      )

    by_name =
      Engine.create(
        %{
          definition_name: "platform.register_tenant",
          initial_variables: %{"slug" => "acme"},
          actor_id: company_context.user_id,
          idempotency_key: "rt-inv5-by-name"
        },
        prefix: ctx.platform.schema_name,
        auth_context: company_context
      )

    random_id =
      Engine.create(
        %{
          definition_id: Ecto.UUID.generate(),
          initial_variables: %{"slug" => "acme"},
          actor_id: company_context.user_id,
          idempotency_key: "rt-inv5-random"
        },
        prefix: ctx.platform.schema_name,
        auth_context: company_context
      )

    assert by_id == random_id
    assert by_name == random_id
    assert {:error, :definition_not_found} = random_id
  end
end
