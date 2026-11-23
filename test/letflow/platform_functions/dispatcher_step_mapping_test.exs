defmodule Letflow.PlatformFunctions.DispatcherStepMappingTest do
  @moduledoc """
  The RUNTIME half of the typed step mapping (T-2594, "Register a tenant" pilot,
  gap G13): a step writes ONLY the outputs it declares.

  The fence of gap G13 is a design-time rule -- activation refuses a mapping
  that does not agree with the definition's variable schemas. This is the other
  half: when the function has run, the outputs the step did NOT declare are not
  written. A function therefore cannot write a variable the definition did not
  ask for, and the reserved engine namespace is never among the declared
  writes.

  A step that declares no writes at all is refused before the body runs: the
  dispatcher does not guess what a step writes.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.Activator
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @function "platform.validate_registration"

  setup do
    tenant = Fx.tenant!("t2594-disp-mapping")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "mapping-admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  # The step declares only ONE of the two outputs the function produces.
  defp narrowed_call do
    Fx.call(@function, %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
    |> Map.put("writes", %{"normalized_slug" => "string"})
  end

  defp inputs do
    %{"slug" => "acme", "display_name" => "Acme Ltd", "email" => "admin@acme.test"}
  end

  defp activator(ctx) do
    Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)
  end

  defp activated(ctx, graph, name) do
    draft = Fx.definition!(ctx.tenant.schema_name, graph, name)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    Repo.get!(Definitions.ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  defp arm(ctx, definition) do
    Dispatcher.arm(
      prefix: ctx.tenant.schema_name,
      instance_id: Ecto.UUID.generate(),
      definition_id: definition.id,
      node_id: "call",
      function: @function,
      inputs: inputs()
    )
  end

  test "a step writes only the outputs it declares: the other output of the function is not written",
       ctx do
    definition = activated(ctx, Fx.graph(narrowed_call()), "t2594-disp-narrow")

    {:ok, %{dispatch: dispatch}} = arm(ctx, definition)

    assert {:ok, {:advanced, outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    assert outputs == %{"normalized_slug" => "acme"}

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.outputs == %{"normalized_slug" => "acme"}
    refute Map.has_key?(stored.outputs, "email_domain")
  end

  test "a step that declares no writes at all is refused before the body runs", ctx do
    definition =
      activated(
        ctx,
        Fx.graph(
          Fx.call(@function, %{
            "slug" => %{"var" => "slug"},
            "display_name" => %{"const" => "Acme Ltd"},
            "email" => %{"const" => "admin@acme.test"}
          })
        ),
        "t2594-disp-no-writes"
      )

    # the stored graph is changed into one that declares no writes at all (the
    # activation fence would refuse such a version; a forged row reaches the
    # dispatcher, and the dispatcher refuses it too)
    call =
      Map.delete(
        Fx.call(@function, %{
          "slug" => %{"var" => "slug"},
          "display_name" => %{"const" => "Acme Ltd"},
          "email" => %{"const" => "admin@acme.test"}
        }),
        "writes"
      )

    new_graph = Fx.graph(call)

    # the signed document covers the graph, so a forged graph is re-signed with
    # the same document: the fence that proves WHO may run the call still
    # passes, and the binding (WHAT the call is) is what refuses the step
    row = Repo.get!(Definitions.ProcessDefinition, definition.id, prefix: ctx.tenant.schema_name)

    {:ok, signed} =
      ActivatedBy.sign(
        Map.delete(row.activated_by, "signature"),
        %{row | graph: new_graph},
        ctx.tenant.schema_name
      )

    {1, _} =
      Repo.update_all(
        from(d in Definitions.ProcessDefinition, where: d.id == ^definition.id),
        [set: [graph: new_graph, activated_by: signed]],
        prefix: ctx.tenant.schema_name
      )

    {:ok, %{dispatch: dispatch}} = arm(ctx, definition)

    assert {:error, :platform_call_mapping_not_declared} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.outputs == nil
    assert stored.last_failure_kind == "platform_call_mapping_not_declared"
  end
end
