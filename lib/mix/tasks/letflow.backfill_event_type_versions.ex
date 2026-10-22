defmodule Mix.Tasks.Letflow.BackfillEventTypeVersions do
  @shortdoc "Backfills event type schema versions for pre-existing tenants (ISS-0332, ISS-0583)"

  @moduledoc """
  Backfills event type schema versions for all tenants provisioned before a
  given bump landed. Sweeps a list of event-type version bumps
  (`event_type_backfills/0`) rather than a single hardcoded one.

  Backfills the DEFINITION_PROMOTED event type to schema_version 2 for all
  tenants provisioned before REQ-077 bumped the seed (ISS-0332).

  Backfills the TASK_COMPLETED event type to the current seed version (4) for all tenants
  provisioned before REQ-292/REQ-391 bumped the seed (ISS-0583, then REQ-391):
  `merged_variable_events` now also carries the `computed_field_disagreement` and
  `visible_when_false_value_discarded` event kinds alongside the original
  `variable_overwritten` (v1->v2), and the payload now also carries
  `attachments_at_decision`, a snapshot of the instance's attachments at
  completion time (v2->v3, REQ-391). `Registry.register_type/2`'s own
  strictly-greater-than-every-existing-version check (`registry.ex`) means a
  tenant still pinned at v1 jumps straight to v3 here rather than needing two
  separate backfill calls -- both bumps are additive/optional fields, so a v1
  or v2 row validates identically against the wider v3 schema for every
  payload either version already produced.

  Decision 0062 R8h-5 (GH #2616): also brings INSTANCE_STARTED, SUB_PROCESS_COMPLETED,
  EXECUTION_ERROR and SCRIPT_TASK_COMPLETED to schema_version 2 and TASK_COMPLETED to 4, the
  versions that declare the optional restriction-label fields. These attrs are read from the
  seed (`Letflow.TenantProvisioning.platform_event_type_seed_attrs/1`), not copied.

  Backfills the two new REQ-391 event types, ATTACHMENT_ATTACHED and
  ATTACHMENT_REMOVED (both schema_version 1), for all tenants provisioned
  before REQ-391 added them to the seed list -- `Letflow.Repository.Attachments`
  `upload/2`/`delete/2` calls append these types post-commit, best-effort;
  without this backfill, an unbackfilled tenant simply never gets the history
  entry (logged via `Logger.warning/2`, never a hard failure -- see
  `lib/letflow/design/req391-attachment-history-approval-attribution.md` §2.3).

  Usage:

      mix letflow.backfill_event_type_versions

  Exits non-zero if any event type fails to backfill for any tenant.
  """

  use Mix.Task

  @definition_promoted_v2_attrs %{
    name: "DEFINITION_PROMOTED",
    schema_version: 2,
    description:
      "Emitted by Letflow.Definitions.Promotion.promote_definition/3 (PRM-01, the " <>
        "review-gated path) AND Letflow.Definitions.Promotion.promote_active_definition/5 " <>
        "(REQ-077 R10/ENV-03, the reviewless test->production path) after a promotion " <>
        "commits, via Letflow.EventStore.PlatformEvents.append_definition_promoted/2. " <>
        "Bumped from schema_version 1 (REQ-140) to 2 (REQ-077 design §9.5): an ENV-03 " <>
        "promotion genuinely has no review, so `review_id` must admit `null` rather than " <>
        "forcing a synthetic id into the audit log.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "review_id" => %{"type" => ["string", "null"]},
        "source_tenant_id" => %{"type" => "string"},
        "target_tenant_id" => %{"type" => "string"},
        "source_definition_id" => %{"type" => "string"},
        "target_definition_id" => %{"type" => "string"},
        "process_key" => %{"type" => "string"}
      },
      "required" => [
        "review_id",
        "source_tenant_id",
        "target_tenant_id",
        "source_definition_id",
        "target_definition_id",
        "process_key"
      ]
    }
  }

  # Event types brought to the CURRENT seed version, read from the seed itself
  # (`TenantProvisioning.platform_event_type_seed_attrs/1`) so no schema is copied here.
  # TASK_COMPLETED: v1->v2 (REQ-292), v2->v3 (REQ-391), v3->v4 (decision 0062 R8h-5); the rest
  # are the decision 0062 R8h-5 bumps (GH #2616): INSTANCE_STARTED, SUB_PROCESS_COMPLETED,
  # EXECUTION_ERROR and SCRIPT_TASK_COMPLETED, each 1->2. All bumps only add optional
  # fields, so a row at an earlier version validates every payload it ever produced.
  @seed_backfilled_types [
    "TASK_COMPLETED",
    "INSTANCE_STARTED",
    "SUB_PROCESS_COMPLETED",
    "EXECUTION_ERROR",
    "SCRIPT_TASK_COMPLETED"
  ]

  @attachment_attached_v1_attrs %{
    name: "ATTACHMENT_ATTACHED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Repository.Attachments.upload/2 (REQ-391) when an " <>
        "attachment is added to an instance.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "attachment_id" => %{"type" => "string"},
        "file_name" => %{"type" => "string"},
        "content_type" => %{"type" => "string"},
        "byte_size" => %{"type" => "integer"},
        "description" => %{"type" => ["string", "null"]}
      },
      "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
    }
  }

  @attachment_removed_v1_attrs %{
    name: "ATTACHMENT_REMOVED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Repository.Attachments.delete/2 (REQ-391) when an " <>
        "attachment is removed from an instance.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "attachment_id" => %{"type" => "string"},
        "file_name" => %{"type" => "string"},
        "content_type" => %{"type" => "string"},
        "byte_size" => %{"type" => "integer"}
      },
      "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
    }
  }

  defp event_type_backfills do
    [@definition_promoted_v2_attrs] ++
      Enum.map(
        @seed_backfilled_types,
        &Letflow.TenantProvisioning.platform_event_type_seed_attrs/1
      ) ++
      [@attachment_attached_v1_attrs, @attachment_removed_v1_attrs]
  end

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    any_failed? =
      Enum.reduce(event_type_backfills(), false, fn attrs, acc_failed? ->
        name = attrs[:name] || attrs["name"]

        case Letflow.TenantProvisioning.Backfill.run(attrs) do
          {:ok, %{updated: u, skipped: s}} ->
            Mix.shell().info("#{name}: backfill complete: #{u} updated, #{s} skipped")
            acc_failed?

          {:error, {:backfill_failed, tenant_id, reason}} ->
            Mix.shell().error(
              "#{name}: backfill failed for tenant #{tenant_id}: #{inspect(reason)}"
            )

            true
        end
      end)

    if any_failed? do
      System.halt(1)
    else
      :ok
    end
  end
end
