defmodule Letflow.Definitions.StepMappingActivationTest do
  @moduledoc """
  The TYPED STEP MAPPING at ACTIVATION (T-2594, "Register a tenant" pilot, gap
  G13; owner acceptance item 2: "each node declares its reads and writes, and
  activation refuses an undeclared variable or a write to a protected
  variable").

  A `platform_call` step declares what it reads and what it writes. Activation
  refuses a version whose declaration does not agree with the definition's own
  `variable_schemas`, whose write lands in the reserved engine namespace, or
  whose write lands in a variable a person may write.

  The fence runs on EVERY path that switches a version on -- activate,
  reactivate, version rollback, promotion apply -- so a mapping that activation
  would refuse cannot be reached by another path either.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2594-mapping")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "mapping-admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin, prefix: tenant.schema_name}
  end

  defp activator(user, roles) do
    Activator.from_auth_context(%{user_id: user.id, roles: roles}, true)
  end

  defp platform_activator(ctx), do: activator(ctx.admin, ["PLATFORM_ADMIN"])

  # The call of the step: the function, its arguments and the step's typed
  # mapping. `mapping` is the `reads`/`writes` pair the step declares.
  defp call(mapping \\ %{}) do
    Map.merge(
      %{
        "function" => "tenant.create",
        "args" => %{"slug" => %{"var" => "slug"}, "name" => %{"const" => "Acme"}}
      },
      mapping
    )
  end

  # START -> the platform-call SERVICE_TASK -> END, with an optional HUMAN_TASK
  # before it whose form names the variables a person may write.
  defp graph(call, human_task \\ nil) do
    nodes = [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "call",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{"platform_call" => call}
      },
      %{"id" => "end", "node_type" => "END"}
    ]

    {nodes, edges} =
      if human_task do
        task = %{
          "id" => "ht",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER", "completer_inputs" => human_task}
        }

        {[
           %{"id" => "start", "node_type" => "START"},
           task,
           %{
             "id" => "call",
             "node_type" => "SERVICE_TASK",
             "attributes" => %{"platform_call" => call}
           },
           %{"id" => "end", "node_type" => "END"}
         ],
         [
           %{"id" => "e1", "source" => "start", "target" => "ht"},
           %{"id" => "e2", "source" => "ht", "target" => "call"},
           %{"id" => "e3", "source" => "call", "target" => "end"}
         ]}
      else
        {nodes,
         [
           %{"id" => "e1", "source" => "start", "target" => "call"},
           %{"id" => "e2", "source" => "call", "target" => "end"}
         ]}
      end

    %{"nodes" => nodes, "edges" => edges}
  end

  defp schemas(entries) do
    Enum.map(entries, fn {key, type} ->
      %{variable_key: key, json_schema: %{"type" => type}}
    end)
  end

  defp activate(ctx, definition) do
    Definitions.activate(definition.id,
      prefix: ctx.prefix,
      activator: platform_activator(ctx)
    )
  end

  test "a step that declares a variable the definition does not declare is refused", ctx do
    call = call(%{"reads" => %{"slug" => "string", "ghost" => "string"}, "writes" => %{}})

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(call),
        "t2594-undeclared",
        schemas(%{"slug" => "string"})
      )

    assert {:error, {:step_mappings_invalid, violations}} = activate(ctx, draft)
    assert :step_mapping_variable_undeclared in Enum.map(violations, & &1.code)

    row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.prefix)
    assert row.status == :draft
    assert row.activated_by == nil
  end

  test "a step that declares NO mapping at all is refused", ctx do
    draft = Fx.definition_with_schemas!(ctx.prefix, graph(call()), "t2594-no-mapping", [])

    assert {:error, {:step_mappings_invalid, violations}} = activate(ctx, draft)
    assert :step_mapping_declaration_missing in Enum.map(violations, & &1.code)
  end

  test "a step that writes the reserved engine namespace is refused", ctx do
    call =
      call(%{
        "reads" => %{"slug" => "string"},
        "writes" => %{"_sys" => "string"}
      })

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(call),
        "t2594-reserved",
        schemas(%{"slug" => "string", "_sys" => "string"})
      )

    assert {:error, {:step_mappings_invalid, violations}} = activate(ctx, draft)

    assert :step_mapping_reserved_refused in Enum.map(violations, & &1.code)
  end

  test "a step that writes a variable a person may write is refused", ctx do
    call =
      call(%{
        "reads" => %{"slug" => "string"},
        "writes" => %{"tenant_id" => "string"}
      })

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(call, ["tenant_id"]),
        "t2594-protected",
        schemas(%{"slug" => "string", "tenant_id" => "string"})
      )

    assert {:error, {:step_mappings_invalid, violations}} = activate(ctx, draft)
    assert :step_mapping_write_refused in Enum.map(violations, & &1.code)
  end

  test "a step that declares a type the schema does not agree with is refused", ctx do
    call = call(%{"reads" => %{"slug" => "number"}, "writes" => %{}})

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(call),
        "t2594-type",
        schemas(%{"slug" => "string"})
      )

    assert {:error, {:step_mappings_invalid, violations}} = activate(ctx, draft)
    assert :step_mapping_type_mismatch in Enum.map(violations, & &1.code)
  end

  test "a step whose mapping agrees with the schemas is activated", ctx do
    call = call(%{"reads" => %{"slug" => "string"}, "writes" => %{"tenant_id" => "string"}})

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(call),
        "t2594-valid",
        schemas(%{"slug" => "string", "tenant_id" => "string"})
      )

    assert {:ok, %{already_active: false}} = activate(ctx, draft)

    row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.prefix)
    assert row.status == :active
  end

  test "the rollback path runs the same check", ctx do
    key = "t2594-rollback"

    # v1 writes a variable a person may write: the fence refuses it, so it is
    # never activated. The rollback path accepts an active OR a deprecated
    # target, so a raw row carries it there.
    bad = call(%{"reads" => %{"slug" => "string"}, "writes" => %{"tenant_id" => "string"}})

    v1 =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(bad, ["tenant_id"]),
        key,
        schemas(%{"slug" => "string", "tenant_id" => "string"})
      )

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^v1.id),
        [set: [status: :deprecated]],
        prefix: ctx.prefix
      )

    good = call(%{"reads" => %{"slug" => "string"}, "writes" => %{"tenant_id" => "string"}})
    v2 = Fx.version!(ctx.prefix, graph(good), key, "2")

    assert {:ok, _} = activate(ctx, v2)

    assert {:error, {:step_mappings_invalid, violations}} =
             Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
               prefix: ctx.prefix,
               activator: platform_activator(ctx),
               permission_checker: fn _actor, _tenant -> true end,
               event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
             )

    assert :step_mapping_write_refused in Enum.map(violations, & &1.code)
  end

  test "the reactivate path runs the same check", ctx do
    good = call(%{"reads" => %{"slug" => "string"}, "writes" => %{"tenant_id" => "string"}})

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph(good),
        "t2594-reactivate",
        schemas(%{"slug" => "string", "tenant_id" => "string"})
      )

    assert {:ok, _} = activate(ctx, draft)

    # the stored graph is changed into one the fence refuses, and the version
    # is flagged for reactivation (the path a lost permission takes)
    bad = call(%{"reads" => %{"slug" => "string"}, "writes" => %{"_sys" => "string"}})

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^draft.id),
        [set: [graph: graph(bad)]],
        prefix: ctx.prefix
      )

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^draft.id),
        [
          set: [
            needs_reactivation_at: DateTime.utc_now(),
            needs_reactivation_reason: "test"
          ]
        ],
        prefix: ctx.prefix
      )

    assert {:error, {:step_mappings_invalid, violations}} =
             Definitions.reactivate(draft.id,
               prefix: ctx.prefix,
               activator: platform_activator(ctx)
             )

    assert :step_mapping_reserved_refused in Enum.map(violations, & &1.code)
  end

  test "the promotion path runs the same check in the target tenant", ctx do
    company = Fx.tenant!("t2594-promo-company")
    key = "t2594-promotion"

    # a source definition in a company tenant, written straight into the schema
    # (the write path refuses a platform_call there, so the row is forged)
    source =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: key,
        version: "1",
        graph: graph(call(%{"reads" => %{"slug" => "string"}, "writes" => %{}})),
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: company.schema_name)

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^source.id),
        [set: [status: :active]],
        prefix: company.schema_name
      )

    plan = %{
      source_tenant_id: company.tenant_id,
      target_tenant_id: ctx.tenant.tenant_id,
      process_key: key,
      source_definition_id: source.id,
      target_definition_id: nil,
      base_version: nil,
      entries: []
    }

    review =
      struct(PromotionReview, %{
        id: Ecto.UUID.generate(),
        plan_digest: PromotionDigest.compute_plan_digest(plan),
        def_id: key,
        serialised_plan: Jason.encode!(plan),
        requested_by: Ecto.UUID.generate(),
        status: :approved,
        row_version: 2
      })

    assert {:error, {:step_mappings_invalid, violations}} =
             Promotion.promote_definition(Ecto.UUID.generate(), review,
               activator: platform_activator(ctx),
               permission_checker: fn _actor, _tenant -> true end,
               event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
             )

    assert :step_mapping_variable_undeclared in Enum.map(violations, & &1.code)
  end
end
