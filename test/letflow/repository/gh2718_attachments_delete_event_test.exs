defmodule Letflow.Repository.GH2718AttachmentsDeleteEventTest do
  @moduledoc """
  GH #2718, design section 6 A17: `Letflow.Repository.Attachments.delete/3` and the removal
  event (D6 option 2).

    * (a) [RED] a synthetic parent: `{:ok, _}` and NOTHING appended to the synthetic instance;
    * (b) [GUARD] a real parent: exactly one removal event, idempotency key
      `attachment_removed:<id>` (REQ-391);
    * (c) [RED] read-before-delete ordering (kills M3g). A failure is injected into ONLY the
      `synthetic?` read by dropping `entity_type_instances` in this test's sandboxed tenant schema;
      `get/2` reads only `instance_attachments`, so the lookup still succeeds and the only
      statement that can fail is the registry read. The row must still be present afterwards.

  Why the DROP is safe: this file provisions through `SandboxAutoMode.provision!/2`, which leaves the
  test in a per-test sandbox transaction, so the DDL is rolled back with it (same idiom as
  `test/letflow/audit_dispositions_test.exs`). Outside an explicit `Repo.transaction`, each sandbox
  statement runs under its own savepoint, so the read-back after the raise works; `delete/3` must
  therefore not wrap its statements in a transaction. `async: false` (DDL on a tenant schema).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.EventStore.Event
  alias Letflow.Identity.Tenant
  alias Letflow.Repository.Attachment
  alias Letflow.Repository.Attachments
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @removed_type "ATTACHMENT_REMOVED"

  defp provisioned_tenant do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "gh2718-del",
          display_name: "GH2718 Attachment Delete Event Tenant",
          teardown: false
        )

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      %{tenant_id: tenant_id, schema_name: schema_name}
    end)
  end

  defp upload!(schema_name, instance_id, label) do
    {:ok, attachment} =
      Attachments.upload(
        %{
          instance_id: instance_id,
          raw_bytes: "gh2718 delete bytes " <> label,
          file_name: label <> ".txt",
          content_type: "text/plain",
          uploaded_by: Ecto.UUID.generate(),
          description: nil
        },
        prefix: schema_name
      )

    attachment
  end

  defp event_rows(schema_name, instance_id),
    do: Repo.all(from(e in Event, where: e.instance_id == ^instance_id), prefix: schema_name)

  defp removed_rows(schema_name, instance_id),
    do:
      Repo.all(
        from(e in Event, where: e.instance_id == ^instance_id and e.event_type == ^@removed_type),
        prefix: schema_name
      )

  setup do
    tenant = provisioned_tenant()
    {:ok, _} = EventTypes.seed!(tenant.schema_name)
    {:ok, tenant: tenant}
  end

  describe "A17 Attachments.delete/3" do
    test "[RED] (a) a synthetic parent returns {:ok, _} and appends nothing", %{tenant: tenant} do
      schema = tenant.schema_name
      {:ok, synthetic} = EntityTypeInstance.get_or_create("widget", schema)
      attachment = upload!(schema, synthetic, "a17a")
      before_events = event_rows(schema, synthetic)

      assert {:ok, %Attachment{id: id}} =
               Attachments.delete(attachment.id, Ecto.UUID.generate(), prefix: schema)

      assert id == attachment.id
      assert Attachments.get(attachment.id, prefix: schema) == {:error, :not_found}
      assert event_rows(schema, synthetic) == before_events
      assert removed_rows(schema, synthetic) == []
    end

    test "[GUARD] (b) a real parent appends exactly one removal event with the REQ-391 key", %{
      tenant: tenant
    } do
      schema = tenant.schema_name
      instance_id = real_instance!(tenant)
      attachment = upload!(schema, instance_id, "a17b")
      actor = Ecto.UUID.generate()

      assert {:ok, _} = Attachments.delete(attachment.id, actor, prefix: schema)

      assert [%Event{actor_id: ^actor, idempotency_key: key}] = removed_rows(schema, instance_id)
      assert key == "attachment_removed:" <> attachment.id
    end

    test "[RED] (c) the synthetic? read happens BEFORE the row delete: a failing read leaves the row intact",
         %{tenant: tenant} do
      schema = tenant.schema_name
      {:ok, synthetic} = EntityTypeInstance.get_or_create("widget", schema)
      attachment = upload!(schema, synthetic, "a17c")

      Repo.query!(~s(DROP TABLE "#{schema}".entity_type_instances))

      assert_raise Postgrex.Error, fn ->
        Attachments.delete(attachment.id, Ecto.UUID.generate(), prefix: schema)
      end

      # the lookup (instance_attachments only) was untouched by the DROP and the delete never ran
      assert {:ok, %Attachment{id: id}} = Attachments.get(attachment.id, prefix: schema)
      assert id == attachment.id
    end
  end
end
