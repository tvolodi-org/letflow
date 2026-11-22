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
      name are both refused, with different codes;
    * the SECURITY GATE's findings: a repeated arming of the same call does
      not raise (the idempotency key is enforced by the index, and the
      dispatcher replays the first row), the row's tenant is derived from the
      schema it is written into, a prefix that names no tenant schema is
      refused instead of crashing, a row is bound to the definition's node,
      another tenant's row is never touched, and a call that reaches the
      attempt cap is dead-lettered.

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
      instance_id: Ecto.UUID.generate(),
      definition_id: definition.id,
      node_id: "call",
      function: @function,
      inputs: inputs(overrides)
    )
  end

  defp rows(ctx) do
    rows_in(ctx.tenant.schema_name, ctx.tenant.tenant_id)
  end

  defp rows_in(schema_name, tenant_id) do
    StepDispatch
    |> where([d], d.tenant_id == ^tenant_id)
    |> Repo.all(prefix: schema_name)
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
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: %{"slug" => "acme"}
             )

    assert {:error, :platform_call_arg_unknown} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
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

    # Another tenant, with its own schema and its own rows.
    other = Fx.tenant!("t2589-other")

    # The dispatch of the platform tenant's row id under the other tenant's
    # prefix finds nothing: the row lives in another schema, so the answer is
    # the uniform "not found" -- never the row itself, never a partial read.
    assert {:error, :platform_step_not_found} =
             Dispatcher.attempt_dispatch(dispatch.id, other.schema_name)

    # Neither tenant's rows changed: the platform tenant's row is untouched
    # and still pending, the other tenant has no row at all.
    assert length(rows(ctx)) == 1
    assert length(rows_in(other.schema_name, other.tenant_id)) == 0

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :pending
    assert stored.attempt_index == 0
    assert stored.outputs == nil
  end

  test "D8: a prefix that names no tenant schema is refused before any I/O", ctx do
    definition = activated(ctx)

    for bad_prefix <- ["public", nil, "tenant_not-a-uuid", "tenant_ZZZ"] do
      assert {:error, :invalid_schema_name} =
               Dispatcher.arm(
                 prefix: bad_prefix,
                 instance_id: Ecto.UUID.generate(),
                 definition_id: definition.id,
                 node_id: "call",
                 function: @function,
                 inputs: inputs(%{})
               )
    end

    # Nothing was written, and the real tenant's rows are untouched.
    assert rows(ctx) == []
  end

  test "D9: the row's tenant is DERIVED from the schema, not taken from the caller", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               tenant_id: Ecto.UUID.generate(),
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function: @function,
               inputs: inputs(%{})
             )

    # The caller's tenant id is ignored: the row sits in the schema of
    # `ctx.tenant`, so that is the tenant it claims to belong to (decision
    # 0003's addendum).
    assert dispatch.tenant_id == ctx.tenant.tenant_id
  end

  test "D10: a repeated arming of the same call does not raise -- the first row wins", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: first}} = arm(ctx, definition)

    # The unique index on the idempotency key really is enforced, and the
    # changeset really declares it: a raw second insert of the same key is a
    # CHANGESET error, not an `Ecto.ConstraintError` (INV-8).
    assert {:error, %Ecto.Changeset{}} =
             StepDispatch.arm_changeset(%StepDispatch{id: Ecto.UUID.generate()}, %{
               id: Ecto.UUID.generate(),
               tenant_id: ctx.tenant.tenant_id,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "call",
               function_name: @function,
               call_key: first.call_key,
               input_fingerprint: first.input_fingerprint,
               inputs: first.inputs,
               status: :pending,
               attempt_index: 0,
               next_attempt_at: DateTime.utc_now(),
               created_at: DateTime.utc_now()
             })
             |> Repo.insert(prefix: ctx.tenant.schema_name)

    # The dispatcher's own arming of the same call does not raise either: it
    # writes with ON CONFLICT DO NOTHING and hands back the row that carries
    # the key (the double click, the retry, the poller restart of S8).
    assert {:ok, %{status: :armed, dispatch: replay}} = arm(ctx, definition)
    assert replay.id == first.id

    # One row, one attempt: the function ran exactly once.
    assert length(rows(ctx)) == 1
    stored = Repo.get!(StepDispatch, first.id, prefix: ctx.tenant.schema_name)
    assert stored.attempt_index == 0
    assert stored.status == :pending
  end

  test "D11: the row is bound to the definition's node", ctx do
    definition = activated(ctx)

    # A row that names a node the definition does not have.
    assert {:ok, %{status: :armed, dispatch: unknown_node}} =
             Dispatcher.arm(
               prefix: ctx.tenant.schema_name,
               instance_id: Ecto.UUID.generate(),
               definition_id: definition.id,
               node_id: "not_a_node_of_this_definition",
               function: @function,
               inputs: inputs(%{})
             )

    assert {:error, :platform_call_node_missing} =
             Dispatcher.attempt_dispatch(unknown_node.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, unknown_node.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_node_missing"
    assert stored.outputs == nil

    # A row whose argument contradicts the node's DECLARED constant: the node
    # declares `display_name` as the constant "Acme Ltd", the row carries
    # another value. (The slug differs too, so this is a different call and
    # not a reuse of the first one's idempotency key.)
    assert {:ok, %{status: :armed, dispatch: other_args}} =
             arm(ctx, definition, %{"slug" => "another-co", "display_name" => "Another Ltd"})

    assert {:error, :platform_call_arg_mismatch} =
             Dispatcher.attempt_dispatch(other_args.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, other_args.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_arg_mismatch"
    assert stored.outputs == nil
  end

  test "D12: a call that reaches the attempt cap is dead-lettered and the body never runs",
       ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    # The row is at the cap: the run that held it was killed uncatchably, and
    # the lease has expired, so the next claim takes it over -- for the last
    # time.
    dispatch
    |> StepDispatch.claim_changeset(%{
      status: :running,
      attempt_index: Dispatcher.max_attempts(),
      next_attempt_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update(prefix: ctx.tenant.schema_name)

    assert {:error, :platform_step_max_attempts} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_step_max_attempts"
    assert stored.outputs == nil

    # The row left the queue for good: it is not due any more.
    refute dispatch.id in Dispatcher.due_dispatch_ids(ctx.tenant.schema_name)
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
