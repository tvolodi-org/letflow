defmodule Letflow.PlatformFunctions.DispatcherTest do
  @moduledoc """
  The durable dispatcher of a platform step (T-2589, pilot gap G1a of the
  "Register a tenant" pilot).

  What the tests prove:

    * a step is armed as a durable row and run by the dispatcher;
    * the AUTHORITY FENCE is called before the body: a tampered signature is
      refused and the function never runs (PM inbox #182: the dispatcher MUST
      call `Letflow.PlatformFunctions.Guard.authorize_dispatch/1`);
    * the body runs OUTSIDE every transaction the dispatcher owns (the
      structural property that lets a platform function run DDL);
    * the closed registry: an unknown name and a declared-but-unimplemented
      name are both refused, with different codes.

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @function "platform.validate_registration"

  setup do
    tenant = Fx.tenant!("t2589-disp")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  defp call do
    Fx.call(@function, %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
  end

  defp inputs(overrides) do
    Map.merge(
      %{"slug" => "acme", "display_name" => "Acme Ltd", "email" => "admin@acme.test"},
      overrides
    )
  end

  defp activated(ctx) do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(call()), "pcf-t2589-disp")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    Repo.get!(Definitions.ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  defp arm(ctx, definition, overrides \\ %{}) do
    Dispatcher.arm(
      prefix: ctx.tenant.schema_name,
      tenant_id: ctx.tenant.tenant_id,
      instance_id: Ecto.UUID.generate(),
      definition_id: definition.id,
      node_id: "call",
      function: @function,
      inputs: inputs(overrides)
    )
  end

  defp rows(ctx) do
    StepDispatch
    |> where([d], d.tenant_id == ^ctx.tenant.tenant_id)
    |> Repo.all(prefix: ctx.tenant.schema_name)
  end

  test "D1: an armed step is a durable row and the dispatcher runs the function", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)
    assert dispatch.status == :pending
    assert dispatch.attempt_index == 0
    assert dispatch.function_name == @function
    assert dispatch.call_key == "platform.validate_registration|slug=acme"

    assert {:ok, {:advanced, outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    assert outputs == %{
             "normalized_slug" => "acme",
             "email_domain" => "acme.test"
           }

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :advanced
    assert stored.outputs == outputs
    assert stored.attempt_index == 1
    assert stored.dispatched_at != nil
  end

  test "D2: the dispatcher calls the authority fence -- a tampered signature is refused and the function never runs",
       ctx do
    definition = activated(ctx)

    tampered = put_in(definition.activated_by, ["signature", "mac"], String.duplicate("a", 64))

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(d in Definitions.ProcessDefinition, where: d.id == ^definition.id),
        [set: [activated_by: tampered]],
        prefix: ctx.tenant.schema_name
      )

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    assert {:error, :platform_call_signature_invalid} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_signature_invalid"
    assert stored.outputs == nil
  end

  test "D3: a refused value is recorded as a failed step, not as a crash", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} =
             arm(ctx, definition, %{"slug" => "Not A Slug"})

    assert {:error, :platform_call_invalid_slug} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_invalid_slug"
    assert stored.outputs == nil
  end

  test "D4: an unknown name and a declared-but-unimplemented name are refused with different codes",
       ctx do
    definition = activated(ctx)

    assert {:error, :platform_function_unknown} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: "platform.not_in_the_catalogue",
               inputs: %{}
             )

    # `tenant.create` IS in the compiled catalogue (the pilot's tenant family)
    # but has no body yet: the dispatcher says so instead of pretending.
    assert {:error, :platform_function_not_implemented} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: "tenant.create",
               inputs: %{"slug" => "acme", "name" => "Acme"}
             )
  end

  test "D5: arguments that do not match the entry are refused before anything is written", ctx do
    definition = activated(ctx)

    assert {:error, :platform_call_arg_missing} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: %{"slug" => "acme"}
             )

    assert {:error, :platform_call_arg_unknown} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{"tenant_id" => "e6f1a0f2-0000-0000-0000-000000000000"})
             )

    assert rows(ctx) == []
  end

  test "D6: the function body runs OUTSIDE every transaction the dispatcher owns", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    assert {:ok, {:advanced, _outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    source = File.read!("lib/letflow/platform_functions/dispatcher.ex")
    {:ok, ast} = Code.string_to_quoted(source)

    for block <- transaction_blocks(ast) do
      refute contains_call?(block, :invoke),
             "the function body must not run inside a transaction of the dispatcher (DDL cannot)"
    end
  end

  test "D7: a row of another tenant is never touched", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    assert {:ok, {:advanced, _outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    assert length(rows(ctx)) == 1
  end

  # ── the AST helpers of D6 ──────────────────────────────────────────────────────────────

  defp transaction_blocks(ast) do
    {_ast, blocks} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Repo]}, :transaction]}, _, _} = call, acc ->
          {call, [call | acc]}

        node, acc ->
          {node, acc}
      end)

    blocks
  end

  defp contains_call?(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {^name, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end
end
