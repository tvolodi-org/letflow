defmodule Letflow.PlatformProcesses.SystemStartTest do
  @moduledoc """
  The system-authority start (T-2727, pilot gap G17c; decision record 0094, Update "The
  system-authority start"; design `docs/platform-register-tenant-v2.md` section 6.2).

  V4 (conditions C1, C2, C3 as far as the start goes): the synthetic start is admitted for the ONE
  registration definition at v2 in the platform prefix, audited `actor_kind = system` with the route,
  and refused (the answer for an unknown definition, nothing written) for every other definition,
  for v1, for a company prefix and for a route outside the closed list.

  `async: false`: the platform tenant pin is application configuration.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.PlatformProcesses
  alias Letflow.PlatformProcesses.Definition
  alias Letflow.PlatformProcesses.Seed
  alias Letflow.PlatformProcesses.SystemStart
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)

    admin = Fx.user!(tenants.p.schema_name, "admin")
    Fx.platform_admin!(tenants.p.schema_name, admin)

    {:ok, system_start} = SystemStart.for_route(:admin_v1_tenants_create)

    %{platform: tenants.p, company: tenants.a, admin: admin, system_start: system_start}
  end

  defp request do
    id = Ecto.UUID.generate()
    %{tenant_id: id, name: "Pilot Co", hostname: nil, idp_realm_id: nil, email_key: nil}
  end

  defp seed!(ctx) do
    assert {:ok, %{outcome: :created}} =
             Seed.seed(prefix: ctx.platform.schema_name, activator_user_id: ctx.admin.id)
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  defp activate_other!(ctx, name, graph, schemas, version \\ "1") do
    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: name,
          version: version,
          graph: graph,
          created_by: ctx.admin.id,
          start_permission: "TenantsManage"
        },
        schemas,
        prefix: ctx.platform.schema_name
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    {:ok, _} =
      Definitions.activate(definition.id, prefix: ctx.platform.schema_name, activator: activator)

    definition
  end

  test "the closed route list: any other route has no start authority" do
    assert {:ok, %SystemStart{route: :signup_provisioning}} =
             SystemStart.for_route(:signup_provisioning)

    assert {:error, :unknown_route} = SystemStart.for_route(:anything_else)
    assert {:error, :unknown_route} = SystemStart.for_route("admin_v1_tenants_create")
    assert {:error, :unknown_route} = SystemStart.for_route(nil)
  end

  # `tenant.validate` has no body on main until the route slice (T-2704) lands, so the shipped v2
  # cannot START yet. The authority is proved with a document of the same NAME that carries the v2
  # contract and only calls a function that has a body.
  defp activate_contract_document!(ctx) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "create",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"var" => "name"}
              })
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "create"},
        %{"id" => "e2", "source" => "create", "target" => "end"}
      ]
    }

    schemas =
      Enum.map(
        ~w(slug name requested_tenant_id tenant_type hostname realm_id admin_email tenant_id),
        &%{variable_key: &1, json_schema: %{"type" => "string"}}
      ) ++ [%{variable_key: "notify_admin", json_schema: %{"type" => "boolean"}}]

    activate_other!(ctx, "platform.register_tenant", graph, schemas, "3")
  end

  test "C1+C2: v2 starts with the system authority; the audit row says system and the route",
       ctx do
    activate_contract_document!(ctx)

    assert {:ok, %{instance_id: instance_id}} =
             PlatformProcesses.start_register_tenant_system(request(), ctx.system_start, [])

    assert instance_count(ctx.platform.schema_name) == 1

    audit =
      Repo.one!(
        from(e in Entry, where: e.action == "instance.create" and e.resource_id == ^instance_id),
        prefix: ctx.platform.schema_name
      )

    assert audit.actor_kind == "system"
    assert audit.actor_id == nil
    assert audit.after_state["started_via"] == "admin_v1_tenants_create"
  end

  test "the start variables are chosen by the builder: no request key names an authority" do
    id = Ecto.UUID.generate()

    vars =
      PlatformProcesses.register_tenant_system_variables(%{
        tenant_id: id,
        name: "N",
        email_key: "a@b.kz",
        actor_id: "x",
        roles: ["PLATFORM_ADMIN"],
        route: :other,
        tier: "demo"
      })

    assert Map.keys(vars) |> Enum.sort() ==
             Enum.sort(~w(slug name requested_tenant_id notify_admin admin_email))

    assert vars["slug"] == "t-" <> String.replace(id, "-", "")
    assert vars["notify_admin"] == false
  end

  test "C1: v1 (no v2 contract) is refused, nothing is written", ctx do
    {:ok, draft} =
      Definitions.create_with_variable_schemas(
        Map.put(Definition.attrs(), :created_by, ctx.admin.id),
        Definition.variable_schemas(),
        prefix: ctx.platform.schema_name
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    Letflow.OutboundDestinations.open_channels(
      ctx.platform.schema_name,
      ctx.admin.id,
      draft.graph
    )

    {:ok, _} =
      Definitions.activate(draft.id, prefix: ctx.platform.schema_name, activator: activator)

    assert {:error, :register_tenant_v2_missing} =
             PlatformProcesses.start_register_tenant_system(request(), ctx.system_start, [])

    # the engine refuses it too, when the contract check of the caller is bypassed
    assert {:error, :definition_not_found} =
             Engine.create(
               %{
                 definition_name: "platform.register_tenant",
                 initial_variables: %{"slug" => "t-x", "name" => "N"},
                 actor_id: Letflow.EventStore.platform_actor_id(),
                 idempotency_key: "register-tenant:t-x"
               },
               prefix: ctx.platform.schema_name,
               system_start: ctx.system_start
             )

    assert instance_count(ctx.platform.schema_name) == 0
  end

  test "C1: another definition that calls tenant.create is refused for the system start", ctx do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"var" => "name"}
              })
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }

    schemas =
      Enum.map(
        ~w(slug name requested_tenant_id tenant_type notify_admin tenant_id),
        &%{variable_key: &1, json_schema: %{"type" => "string"}}
      )

    activate_other!(ctx, "platform.other_register", graph, schemas)

    assert {:error, :definition_not_found} =
             Engine.create(
               %{
                 definition_name: "platform.other_register",
                 initial_variables: %{"slug" => "t-x", "name" => "N"},
                 actor_id: Letflow.EventStore.platform_actor_id(),
                 idempotency_key: "other:t-x"
               },
               prefix: ctx.platform.schema_name,
               system_start: ctx.system_start
             )

    assert instance_count(ctx.platform.schema_name) == 0
  end

  test "C1: a company prefix is refused; so is a start with no person and no system authority",
       ctx do
    seed!(ctx)

    attrs = %{
      definition_name: "platform.register_tenant",
      initial_variables: %{"slug" => "t-x", "name" => "N"},
      actor_id: Letflow.EventStore.platform_actor_id(),
      idempotency_key: "register-tenant:t-x"
    }

    assert {:error, :definition_not_found} =
             Engine.create(attrs, prefix: ctx.company.schema_name, system_start: ctx.system_start)

    # no system start and no auth_context: today's refusal stays
    assert {:error, :definition_not_found} =
             Engine.create(attrs, prefix: ctx.platform.schema_name)

    assert instance_count(ctx.platform.schema_name) == 0
    assert instance_count(ctx.company.schema_name) == 0
  end

  test "a forged system-start value is not a start authority", ctx do
    seed!(ctx)

    attrs = %{
      definition_name: "platform.register_tenant",
      initial_variables: %{"slug" => "t-x", "name" => "N"},
      actor_id: Letflow.EventStore.platform_actor_id(),
      idempotency_key: "register-tenant:t-x"
    }

    for forged <- [%{definition_name: "platform.register_tenant", route: :x}, "system", true] do
      assert {:error, :definition_not_found} =
               Engine.create(attrs, prefix: ctx.platform.schema_name, system_start: forged)
    end

    assert instance_count(ctx.platform.schema_name) == 0
  end

  defp v2_schemas do
    Enum.map(
      ~w(slug name requested_tenant_id tenant_type hostname realm_id admin_email tenant_id),
      &%{variable_key: &1, json_schema: %{"type" => "string"}}
    ) ++ [%{variable_key: "notify_admin", json_schema: %{"type" => "boolean"}}]
  end

  defp create_call_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "create",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"var" => "name"}
              })
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "create"},
        %{"id" => "e2", "source" => "create", "target" => "end"}
      ]
    }
  end

  defp refused_start(ctx) do
    Engine.create(
      %{
        definition_name: "platform.register_tenant",
        initial_variables: %{"slug" => "t-x", "name" => "N"},
        actor_id: Letflow.EventStore.platform_actor_id(),
        idempotency_key: "register-tenant:t-x"
      },
      prefix: ctx.platform.schema_name,
      system_start: ctx.system_start
    )
  end

  test "C1(c): a register_tenant version with a SUB_PROCESS is refused (child exists)", ctx do
    # the child EXISTS and resolves, so the refusal is the SUB_PROCESS rule, not a vacuous skip
    activate_other!(ctx, "platform.child_register", create_call_graph(), v2_schemas())

    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => "platform.child_register"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }

    activate_other!(ctx, "platform.register_tenant", graph, v2_schemas(), "3")

    assert {:error, :definition_not_found} = refused_start(ctx)
    assert instance_count(ctx.platform.schema_name) == 0
  end

  test "C1(c): a SUB_PROCESS whose child cannot be resolved is refused, not skipped", ctx do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => "platform.no_such_child"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }

    with {:ok, _} <-
           (try do
              {:ok, activate_other!(ctx, "platform.register_tenant", graph, v2_schemas(), "3")}
            rescue
              _error -> {:ok, :not_activatable}
            catch
              _kind, _reason -> {:ok, :not_activatable}
            end) do
      assert {:error, :definition_not_found} = refused_start(ctx)
      assert instance_count(ctx.platform.schema_name) == 0
    end
  end

  test "C1(d): a version whose required permission set is not exactly TenantsManage is refused",
       ctx do
    # every catalogue function needs TenantsManage, so the other-permission case is the version
    # that calls NO function (required set empty, declared TenantsManage): the set differs.
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }

    activate_other!(ctx, "platform.register_tenant", graph, v2_schemas(), "3")

    assert {:error, :definition_not_found} = refused_start(ctx)
    assert instance_count(ctx.platform.schema_name) == 0
  end

  test "C2: a person start keeps actor_kind user with the person's id", ctx do
    activate_contract_document!(ctx)

    assert {:ok, %{instance_id: instance_id}} =
             Engine.create(
               %{
                 definition_name: "platform.register_tenant",
                 initial_variables: %{"slug" => "t-person", "name" => "N"},
                 actor_id: ctx.admin.id,
                 idempotency_key: "register-tenant:t-person"
               },
               prefix: ctx.platform.schema_name,
               auth_context: %{
                 user_id: ctx.admin.id,
                 tenant_id: ctx.platform.tenant_id,
                 roles: ["PLATFORM_ADMIN"]
               }
             )

    audit =
      Repo.one!(
        from(e in Entry, where: e.action == "instance.create" and e.resource_id == ^instance_id),
        prefix: ctx.platform.schema_name
      )

    assert audit.actor_kind == "user"
    assert audit.actor_id == ctx.admin.id
    refute Map.has_key?(audit.after_state || %{}, "started_via")
  end

  test "C2: the signup route is audited actor_kind system with its own route", ctx do
    activate_contract_document!(ctx)
    {:ok, signup} = SystemStart.for_route(:signup_provisioning)

    assert {:ok, %{instance_id: instance_id}} =
             PlatformProcesses.start_register_tenant_system(request(), signup, [])

    audit =
      Repo.one!(
        from(e in Entry, where: e.action == "instance.create" and e.resource_id == ^instance_id),
        prefix: ctx.platform.schema_name
      )

    assert audit.actor_kind == "system"
    assert audit.actor_id == nil
    assert audit.after_state["started_via"] == "signup_provisioning"
  end
end
