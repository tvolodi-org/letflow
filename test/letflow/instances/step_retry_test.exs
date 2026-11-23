defmodule Letflow.Instances.StepRetryTest do
  @moduledoc """
  The RETRY of a failed step (pilot gap G7, T-2603 -- the "Register a tenant"
  pilot, owner item 7: "step failures visible and retryable").

  What the tests prove:

    * the failed step of an instance is FOUND (the platform step whose row
      carries the failure);
    * the retry RUNS the step again and the row advances (the outputs are
      written, the failure kind is cleared);
    * a retry of a step that ALREADY did its work changes NOTHING (the
      idempotency: the call is not run a second time, the attempt count does
      not grow);
    * the DLQ retry is WIRED: `Letflow.Dlq.retry/2` on an entry that names a
      failed platform step re-dispatches that step, and the entry is RESOLVED
      when the step ran;
    * a DLQ retry whose step cannot be run again leaves the entry `:retrying`
      and its history carries the CODE of the refusal (never a text);
    * an entry of another type keeps the old behaviour (the row's own state
      transition and nothing else);
    * a DLQ entry of ANOTHER tenant is invisible (INV-5);
    * a notification step that ALREADY sent is not sent again (the delivery
      log is the witness), and one that never sent is sent again;
    * the AUTHORITY: a company tenant may not re-dispatch a platform call
      (INV-10) -- the fence refuses it and the body does not run.

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Dlq
  alias Letflow.Instances.StepRetry
  alias Letflow.NotificationSteps.Dispatcher, as: NotifyDispatcher
  alias Letflow.Notifications.Delivery
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @function "platform.validate_registration"
  @template_key "tenant_registered"

  setup do
    tenant = Fx.tenant!("t2603-retry")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  # ── the helpers ────────────────────────────────────────────────────────────

  defp call do
    Fx.call(@function, %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
  end

  defp inputs do
    %{"slug" => "acme", "display_name" => "Acme Ltd", "email" => "admin@acme.test"}
  end

  defp activated(ctx, schema_name \\ nil) do
    schema = schema_name || ctx.tenant.schema_name
    draft = Fx.definition!(schema, Fx.graph(call()), "pcf-t2603-#{Ecto.UUID.generate()}")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id, prefix: schema, activator: activator)

    Repo.get!(Definitions.ProcessDefinition, draft.id, prefix: schema)
  end

  defp arm(ctx, definition, schema_name \\ nil) do
    schema = schema_name || ctx.tenant.schema_name

    {:ok, %{status: :armed, dispatch: row}} =
      Dispatcher.arm(
        prefix: schema,
        instance_id: Ecto.UUID.generate(),
        definition_id: definition.id,
        node_id: "call",
        function: @function,
        inputs: inputs()
      )

    row
  end

  # The step failed: the row carries the failure kind. This is the state the
  # engine slice that RUNS the step leaves behind (it also puts the instance
  # in ERROR and lands the DLQ entry).
  defp fail!(schema_name, row, kind \\ "platform_call_invalid_slug") do
    row
    |> Ecto.Changeset.change(status: :given_up, last_failure_kind: kind)
    |> Repo.update!(prefix: schema_name)
  end

  defp enqueue!(schema_name, attrs) do
    {:ok, entry} = Dlq.enqueue(attrs, prefix: schema_name)
    entry
  end

  defp delivery_count(schema_name) do
    Delivery
    |> Repo.aggregate(:count, prefix: schema_name)
  end

  # ── the tests ──────────────────────────────────────────────────────────────

  describe "the failed step of an instance" do
    test "is found and the retry runs the call again", ctx do
      definition = activated(ctx)
      row = arm(ctx, definition)
      failed = fail!(ctx.tenant.schema_name, row)

      assert {:ok, step} =
               StepRetry.failed_step(failed.instance_id, prefix: ctx.tenant.schema_name)

      assert step.kind == :platform
      assert step.node_id == "call"

      assert {:ok, result} =
               StepRetry.retry_step(failed.instance_id, prefix: ctx.tenant.schema_name)

      assert result.kind == :platform
      assert result.status == "advanced"
      assert result.outputs["normalized_slug"] == "acme"

      reloaded = Repo.get!(StepDispatch, failed.id, prefix: ctx.tenant.schema_name)
      assert reloaded.status == :advanced
      assert reloaded.last_failure_kind == nil
      assert reloaded.attempt_index == 1
    end

    test "an instance without a failed step has none to retry", ctx do
      definition = activated(ctx)
      row = arm(ctx, definition)

      assert {:error, :no_failed_step} =
               StepRetry.failed_step(row.instance_id, prefix: ctx.tenant.schema_name)

      assert {:error, :no_failed_step} =
               StepRetry.retry_step(row.instance_id, prefix: ctx.tenant.schema_name)
    end

    test "an id that is not an id is refused", ctx do
      assert {:error, :invalid_instance_id} =
               StepRetry.failed_step("not-a-uuid", prefix: ctx.tenant.schema_name)
    end
  end

  describe "the idempotency of a retry" do
    test "a step that already did its work is not run again", ctx do
      definition = activated(ctx)
      row = arm(ctx, definition)

      assert {:ok, {:advanced, outputs}} =
               Dispatcher.attempt_dispatch(row.id, ctx.tenant.schema_name)

      assert outputs["normalized_slug"] == "acme"

      entry =
        enqueue!(ctx.tenant.schema_name, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: row.instance_id,
          reference_id: "call"
        })

      assert {:ok, retried} = Dlq.retry(entry.id, prefix: ctx.tenant.schema_name)
      assert retried.status == :resolved

      reloaded = Repo.get!(StepDispatch, row.id, prefix: ctx.tenant.schema_name)
      # The body did NOT run a second time: the attempt count did not grow.
      assert reloaded.attempt_index == 1
      assert reloaded.status == :advanced
      assert reloaded.outputs == outputs
    end
  end

  describe "the DLQ retry wiring" do
    test "re-dispatches the failed platform step and resolves the entry", ctx do
      definition = activated(ctx)
      row = arm(ctx, definition)
      failed = fail!(ctx.tenant.schema_name, row)

      entry =
        enqueue!(ctx.tenant.schema_name, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: failed.instance_id,
          reference_id: "call"
        })

      assert {:ok, retried} = Dlq.retry(entry.id, prefix: ctx.tenant.schema_name)

      assert retried.status == :resolved
      assert retried.retry_count == 1
      assert [%{outcome: "resolved", error_message: nil}] = retried.retry_history

      reloaded = Repo.get!(StepDispatch, failed.id, prefix: ctx.tenant.schema_name)
      assert reloaded.status == :advanced
      assert reloaded.outputs["normalized_slug"] == "acme"
    end

    test "a step that cannot be run again leaves the entry retrying with a code", ctx do
      entry =
        enqueue!(ctx.tenant.schema_name, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: Ecto.UUID.generate(),
          reference_id: "call"
        })

      assert {:ok, retried} = Dlq.retry(entry.id, prefix: ctx.tenant.schema_name)

      assert retried.status == :retrying
      assert [%{outcome: "failed", error_message: "step_not_found"}] = retried.retry_history
    end

    test "an entry of another type keeps the old behaviour", ctx do
      entry =
        enqueue!(ctx.tenant.schema_name, %{
          entry_type: "event",
          instance_id: Ecto.UUID.generate()
        })

      assert {:ok, retried} = Dlq.retry(entry.id, prefix: ctx.tenant.schema_name)

      # The row's own state transition and NOTHING else: no re-dispatch, so
      # the entry is not resolved.
      assert retried.status == :retrying
      assert retried.retry_count == 1
      assert [%{outcome: "failed"}] = retried.retry_history
    end

    test "an entry of another tenant is invisible", ctx do
      other = Fx.tenant!("t2603-other")

      entry =
        enqueue!(other.schema_name, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: Ecto.UUID.generate(),
          reference_id: "call"
        })

      assert {:error, :not_found} = Dlq.retry(entry.id, prefix: ctx.tenant.schema_name)
    end
  end

  describe "the notification step" do
    test "a step that already sent is not sent again", ctx do
      instance_id = Ecto.UUID.generate()

      # The step already sent: the delivery log carries the sent row.
      %Delivery{}
      |> Delivery.changeset(%{
        tenant_id: ctx.tenant.tenant_id,
        template_key: @template_key,
        locale: "en",
        recipient_user_id: nil,
        status: "sent",
        reason: nil,
        trigger_ref: instance_id
      })
      |> Repo.insert!(prefix: ctx.tenant.schema_name)

      assert {:ok, %{status: "already_done"}} =
               NotifyDispatcher.retry(declaration(), variables(),
                 prefix: ctx.tenant.schema_name,
                 trigger_ref: instance_id,
                 labels: %{}
               )

      # Nothing was sent again: the delivery log still holds exactly one row.
      assert delivery_count(ctx.tenant.schema_name) == 1
    end

    test "a step that never sent is sent again", ctx do
      instance_id = Ecto.UUID.generate()

      assert {:ok, %{status: status}} =
               NotifyDispatcher.retry(declaration(), variables(),
                 prefix: ctx.tenant.schema_name,
                 trigger_ref: instance_id,
                 labels: %{}
               )

      # The test adapter is the Noop one: the attempt is recorded as skipped.
      assert status in ["sent", "skipped"]
      assert delivery_count(ctx.tenant.schema_name) == 1
    end
  end

  describe "the authority of a retry" do
    test "a company tenant may not re-dispatch a platform call", _ctx do
      company = Fx.tenant!("t2603-company")

      # A FORGED definition row in the COMPANY's schema: the dispatcher's own
      # load finds it, so the refusal that follows is the platform-tenant
      # fence (INV-10) and not a missing definition. `Definitions.create/2`
      # refuses a company tenant's draft that carries a platform call, so the
      # write path cannot produce one -- a forged row needs the database.
      company_definition = forged_definition!(company.schema_name, "pcf-t2603-company")

      {:ok, %{status: :armed, dispatch: row}} =
        Dispatcher.arm(
          prefix: company.schema_name,
          instance_id: Ecto.UUID.generate(),
          definition_id: company_definition.id,
          node_id: "call",
          function: @function,
          inputs: inputs()
        )

      failed = fail!(company.schema_name, row, "platform_call_tenant_not_allowed")

      assert {:error, :platform_call_tenant_not_allowed} =
               StepRetry.retry_step(failed.instance_id, prefix: company.schema_name)

      reloaded = Repo.get!(StepDispatch, failed.id, prefix: company.schema_name)
      # The body did not run: the row carries no outputs.
      assert reloaded.outputs == nil
      assert reloaded.status == :given_up
    end
  end

  # A definition row written straight into the schema: the write path refuses
  # a company tenant's draft that carries a platform call, so only the
  # database itself can produce one.
  defp forged_definition!(schema_name, name) do
    %Definitions.ProcessDefinition{}
    |> Definitions.ProcessDefinition.create_changeset(%{
      name: name,
      version: "1",
      graph: Fx.graph(call()),
      created_by: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # The notification step's declaration and the variables it reads.
  defp declaration do
    %{
      "template_key" => @template_key,
      "recipient" => %{"var" => "admin_email"},
      "values" => %{
        "tenant_name" => %{"var" => "tenant_name"},
        "tenant_slug" => %{"var" => "tenant_slug"},
        "registered_by" => %{"const" => "admin"}
      }
    }
  end

  defp variables do
    %{"admin_email" => "admin@acme.test", "tenant_name" => "Acme Ltd", "tenant_slug" => "acme"}
  end
end
