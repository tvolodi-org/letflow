defmodule Letflow.PlatformFunctions.Impl.TenantSetScriptPolicyTest do
  @moduledoc """
  The catalogue entry and the body of `tenant.set_script_policy` (T-3020, BP-PLATFORM-04 G1;
  `docs/design-bp-platform-04.md` section 8, PM answers Q1 option A, Q2, Q3).

  `async: false`: the platform-tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.PlatformFunctions.Impl.TenantSetScriptPolicy, as: Body
  alias Letflow.PlatformFunctions.{Catalog, Registry}
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP

  @kill_tenant "script_policy.platform_kill_switch_set"
  @kill_platform "platform.tenant_script_kill_switch.set"
  @solo_tenant "script_policy.platform_solo_audited_set"
  @solo_platform "platform.tenant_script_solo_audited.set"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    starter = Ecto.UUID.generate()
    instance_id = start_instance!(tenants.p.schema_name, starter)
    {:ok, Map.merge(tenants, %{starter: starter, instance_id: instance_id})}
  end

  # A real instance in the platform tenant, started by `starter`: the body reads the starter from
  # the engine's own INSTANCE_STARTED event.
  defp start_instance!(schema, starter) do
    n = System.unique_integer([:positive])

    {:ok, definition} =
      Definitions.create(
        %{
          name: "t3020-def-#{n}",
          version: "1.0.0",
          graph: %{
            "nodes" => [
              %{"id" => "start", "node_type" => "START"},
              %{
                "id" => "task",
                "node_type" => "HUMAN_TASK",
                "attributes" => %{"role" => "approver"}
              },
              %{"id" => "end", "node_type" => "END"}
            ],
            "edges" => [
              %{"id" => "e1", "source" => "start", "target" => "task"},
              %{"id" => "e2", "source" => "task", "target" => "end"}
            ]
          },
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)

    {:ok, result} =
      Engine.create(
        %{
          definition_id: active.id,
          initial_variables: %{},
          actor_id: starter,
          idempotency_key: "t3020-start-#{n}"
        },
        prefix: schema
      )

    result.instance_id
  end

  defp call(ctx, target, overrides \\ %{}, instance_id \\ nil) do
    inputs =
      Map.merge(
        %{
          "tenant_id" => target.tenant_id,
          "setting" => "kill_switch",
          "value" => true,
          "reason" => "t3020 reason"
        },
        overrides
      )

    Body.run(%{
      inputs: inputs,
      dispatch: %{instance_id: instance_id || ctx.instance_id, tenant_id: ctx.p.tenant_id}
    })
  end

  defp stored(f), do: Repo.get!(ScriptPolicy, 1, prefix: f.schema_name)

  describe "catalogue, registry, vocabulary" do
    test "G1-1 the entry is declared, platform-only, keyed by target and value, with a body" do
      assert {:ok, entry} = Catalog.fetch("tenant.set_script_policy")
      assert entry.platform_tenant_only
      assert entry.permission == :TenantsManage
      assert entry.idempotency_key == ["tenant_id", "setting", "value"]

      assert Enum.map(entry.inputs, &{&1.name, &1.type}) == [
               {"tenant_id", :uuid},
               {"setting", :string},
               {"value", :boolean},
               {"reason", :string}
             ]

      assert Enum.all?(entry.inputs, &(&1.source_class == :start))
      assert {:ok, {Body, :run, 1}} = Registry.fetch("tenant.set_script_policy")
    end
  end

  describe "the write" do
    test "G1-2 kill switch on: policy flips, tenant row has no operator id, platform row has the starter",
         ctx do
      assert {:ok, %{"kill_switch_on" => "true", "solo_audited_allowed" => "false"}} =
               call(ctx, ctx.a)

      assert stored(ctx.a).platform_kill_switch

      assert [tenant_row] = SP.entries(ctx.a.schema_name, @kill_tenant)
      assert tenant_row.actor_id == nil
      assert tenant_row.after_state["actor_class"] == "platform_operator"

      assert [platform_row] = SP.entries(ctx.p.schema_name, @kill_platform)
      assert platform_row.actor_id == ctx.starter
      assert platform_row.resource_id == ctx.a.tenant_id
    end

    test "G1-3 a retry of the same call writes and audits nothing", ctx do
      assert {:ok, first} = call(ctx, ctx.a)
      assert {:ok, ^first} = call(ctx, ctx.a)
      assert length(SP.entries(ctx.a.schema_name, @kill_tenant)) == 1
      assert length(SP.entries(ctx.p.schema_name, @kill_platform)) == 1
    end

    test "G1-4 solo_audited allowed and forbidden, same audit split", ctx do
      assert {:ok, %{"solo_audited_allowed" => "true"}} =
               call(ctx, ctx.a, %{"setting" => "solo_audited"})

      assert stored(ctx.a).platform_solo_audited_allowed

      assert {:ok, %{"solo_audited_allowed" => "false"}} =
               call(ctx, ctx.a, %{"setting" => "solo_audited", "value" => false})

      refute stored(ctx.a).platform_solo_audited_allowed
      assert [t1, t2] = SP.entries(ctx.a.schema_name, @solo_tenant)
      assert t1.actor_id == nil and t2.actor_id == nil
      assert [p1, p2] = SP.entries(ctx.p.schema_name, @solo_platform)
      assert p1.actor_id == ctx.starter and p2.actor_id == ctx.starter
    end
  end

  describe "refusals write nothing" do
    test "G1-5 non-boolean value, unknown setting, empty or bad reason", ctx do
      for overrides <- [
            %{"value" => "yes"},
            %{"value" => nil},
            %{"setting" => "tenant_latch"},
            %{"setting" => 5},
            %{"reason" => ""},
            %{"reason" => "   "},
            %{"reason" => 7}
          ] do
        assert {:error, :platform_call_arg_invalid} = call(ctx, ctx.a, overrides)
      end

      refute stored(ctx.a).platform_kill_switch
      assert SP.entries(ctx.a.schema_name, @kill_tenant) == []
      assert SP.entries(ctx.p.schema_name, @kill_platform) == []
    end

    test "G1-6 unknown tenant, malformed id and the platform tenant itself", ctx do
      assert {:error, :platform_call_tenant_not_found} =
               call(ctx, %{tenant_id: Ecto.UUID.generate()})

      assert {:error, :platform_call_arg_invalid} = call(ctx, %{tenant_id: "not-a-uuid"})
      assert {:error, :platform_call_arg_invalid} = call(ctx, %{tenant_id: nil})
      assert {:error, :platform_call_tenant_not_allowed} = call(ctx, ctx.p)
      refute stored(ctx.p).platform_kill_switch
      assert SP.entries(ctx.p.schema_name, @kill_platform) == []
    end

    test "G1-7 no recorded starter: refused, nothing written", ctx do
      assert {:error, :platform_call_permission_required} =
               call(ctx, ctx.a, %{}, Ecto.UUID.generate())

      assert {:error, :platform_call_permission_required} =
               Body.run(%{
                 inputs: %{
                   "tenant_id" => ctx.a.tenant_id,
                   "setting" => "kill_switch",
                   "value" => true,
                   "reason" => "r"
                 },
                 dispatch: %{}
               })

      refute stored(ctx.a).platform_kill_switch
    end

    test "G1-8 a missing policy row is a typed failure, not a raise", ctx do
      schema = ctx.a.schema_name
      Repo.query!(~s(ALTER TABLE "#{schema}".script_policy DISABLE TRIGGER script_policy_guard))
      Repo.delete_all(ScriptPolicy, prefix: schema)

      try do
        assert {:error, :platform_call_script_policy_failed} = call(ctx, ctx.a)
      after
        Repo.query!(
          ~s|INSERT INTO "#{schema}".script_policy (id, inserted_at, updated_at) VALUES (1, now(), now()) ON CONFLICT DO NOTHING|
        )

        Repo.query!(~s(ALTER TABLE "#{schema}".script_policy ENABLE TRIGGER script_policy_guard))
      end
    end

    test "G1-9 bad context shapes never raise" do
      assert {:error, :platform_call_arg_invalid} = Body.run(nil)
      assert {:error, :platform_call_arg_invalid} = Body.run(%{inputs: %{}})
      assert {:error, :platform_call_arg_invalid} = Body.run(%{inputs: 5, dispatch: %{}})
    end
  end

  describe "INV-10 and the credential class" do
    test "G1-10 setting tenant A changes only A: tenant B and the platform tenant keep their policy",
         ctx do
      assert {:ok, _} = call(ctx, ctx.a)
      refute stored(ctx.b).platform_kill_switch
      refute stored(ctx.p).platform_kill_switch
      assert SP.entries(ctx.b.schema_name, @kill_tenant) == []
    end

    test "G1-11 the process credential works only on the two platform setters", ctx do
      process = %{user_id: ctx.starter, credential: :platform_process, trace_id: nil}

      assert {:error, :api_token_not_allowed} =
               Policy.set_tenant_kill_switch(ctx.a.schema_name, true, "r", process)

      assert {:error, :api_token_not_allowed} =
               Policy.set_sod(ctx.a.schema_name, "strict", "r", process)

      assert {:error, :api_token_not_allowed} =
               Policy.set_platform_kill_switch(
                 ctx.a.schema_name,
                 ctx.a.tenant_id,
                 true,
                 "r",
                 %{
                   user_id: ctx.starter,
                   credential: :api_token,
                   platform_prefix: ctx.p.schema_name
                 }
               )

      refute stored(ctx.a).platform_kill_switch
    end
  end
end
