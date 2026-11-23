defmodule Letflow.PlatformFunctions.PlatformCallIdempotentReplayTest do
  @moduledoc """
  S8 of the platform-call authority rule (T-2589, "Register a tenant" pilot,
  gap G1a; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`): the replay of a
  platform call.

  The threat S8 names: the same start or step runs twice -- a retry, a double
  click, a poller restart -- and creates two tenants or two mails.

  The rule: every call has an idempotency KEY, composed by the dispatcher from
  the catalogue entry's declared key inputs. The key is unique per tenant
  schema, so

    * the same key with the SAME arguments is the SAME call: the first result
      is returned and the function does not run a second time;
    * the same key with DIFFERENT arguments is a key reuse: the dispatch is
      refused with `idempotency_key_reuse` and nothing runs.

  The function under test is the harmless `platform.validate_registration`
  (the registration family): it reads and writes nothing, so the test proves
  the MECHANISM (one call, one result, one row) and not a side effect.

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
    tenant = Fx.tenant!("t2589-s8")
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
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(call()), "pcf-t2589-s8")

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
    StepDispatch
    |> where([d], d.tenant_id == ^ctx.tenant.tenant_id)
    |> Repo.all(prefix: ctx.tenant.schema_name)
  end

  test "S8-a: the same key twice is ONE call and returns the same output", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: first}} = arm(ctx, definition)

    assert {:ok, {:advanced, outputs}} =
             Dispatcher.attempt_dispatch(first.id, ctx.tenant.schema_name)

    # The very same call again: the first result is returned, nothing runs.
    assert {:ok, %{status: :replayed, dispatch: replay, outputs: replayed}} =
             arm(ctx, definition)

    assert replay.id == first.id
    assert replayed == outputs

    # One row, one attempt: the function ran exactly once.
    assert length(rows(ctx)) == 1
    stored = Repo.get!(StepDispatch, first.id, prefix: ctx.tenant.schema_name)
    assert stored.attempt_index == 1
    assert stored.status == :advanced
  end

  test "S8-b: a repeated dispatch of a call that already ran does not run it again", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm(ctx, definition)

    assert {:ok, {:advanced, _outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    # A second dispatch attempt of the same row: the row is final, the stored
    # result is returned.
    assert {:ok, {:already_final, outputs}} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    assert outputs == %{"normalized_slug" => "acme", "email_domain" => "acme.test"}

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.attempt_index == 1
  end

  test "S8-c: a different input with the same key is refused (idempotency_key_reuse)", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: first}} = arm(ctx, definition)

    assert {:ok, {:advanced, outputs}} =
             Dispatcher.attempt_dispatch(first.id, ctx.tenant.schema_name)

    # The same slug (the key), different data: a key reuse, refused.
    assert {:error, :idempotency_key_reuse} =
             arm(ctx, definition, %{"display_name" => "Another Ltd"})

    # The first call keeps its result and its row.
    stored = Repo.get!(StepDispatch, first.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :advanced
    assert stored.outputs == outputs
    assert length(rows(ctx)) == 1
  end

  test "S8-d: a key reuse is refused before the call runs, not after", ctx do
    definition = activated(ctx)

    assert {:ok, %{status: :armed, dispatch: first}} = arm(ctx, definition)

    # The first call has NOT run yet, and the reuse is refused all the same.
    assert {:error, :idempotency_key_reuse} =
             arm(ctx, definition, %{"email" => "other@acme.test"})

    stored = Repo.get!(StepDispatch, first.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :pending
    assert stored.attempt_index == 0
    assert stored.outputs == nil
  end
end
