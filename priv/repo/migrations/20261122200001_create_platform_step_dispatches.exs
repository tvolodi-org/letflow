# Letflow.Repo.Migrations.CreatePlatformStepDispatches
#
# T-2589 (pilot gap G1a, "Register a tenant"): the durable queue of a PLATFORM
# STEP -- one row per platform function call a running instance asked for.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY
# (Decision 0003 Decision B: schema-per-tenant is the isolation boundary).
# Registered in Letflow.TenantProvisioning.@tenant_scoped_migration_manifest --
# both halves are mandatory: a guarded-but-unregistered migration is inert
# forever, a registered-but-unguarded one corrupts `public` on a plain
# `mix ecto.migrate` run.
#
# Why a table of its own (and not a `service_task_dispatches` row): a platform
# step runs OUTSIDE the engine's transaction (it may run DDL -- creating a
# tenant schema and replaying its migrations), so it needs its own durable
# record with its own idempotency key and its own result. The row IS the
# per-step result row: it carries the status, the attempt count, the outputs
# and the failure kind.
#
# `call_key` -- the IDEMPOTENCY KEY of the call, composed by the dispatcher from
# the catalogue entry's declared key inputs (for the tenant family: the tenant
# id; for a registration: the slug). The unique index below is what makes a
# repeated dispatch the SAME call: the first result is returned, and a repeat
# with DIFFERENT inputs is refused (`idempotency_key_reuse`) instead of
# running the function a second time.
#
# `input_fingerprint` -- the fingerprint of the whole resolved argument set.
# Same key + same fingerprint = the same call (a replay); same key + different
# fingerprint = a key reuse, refused.
#
# `status` -- plain :string with a DB CHECK, mirroring `service_task_dispatches`
# (design of that table: no application-layer enum duplication). The four
# values: `pending` (armed, waiting), `running` (claimed by a dispatcher; the
# lease is `next_attempt_at`, so a crashed run is re-claimed after the lease
# expires), `advanced` (the function returned its outputs), `given_up` (the call
# failed and is not retried).
#
# `definition_id` -- the ACTIVE definition version the step belongs to. The
# dispatcher reads that row to check the authority of the call (the signed
# `activated_by` document, the activator's current permission, INV-10).
#
# EXTENSION POINT (owner decision D-180, not built here): a tenant may later
# FORK a standard definition into its own copy (`custom`, `based_on`). This
# table needs NO column for that: the row references the definition row by id,
# and a forked copy is a different definition row. The same is true of a
# per-tenant binding of "which definition runs".
#
# `id`/`instance_id`/`definition_id` carry no FK: a dispatch row may outlive
# the referenced rows' own lifecycle, and no acceptance criterion requires
# referential integrity here (the same rationale as `timers` and
# `service_task_dispatches`).
defmodule Letflow.Repo.Migrations.CreatePlatformStepDispatches do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:platform_step_dispatches, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false

        add :instance_id, :binary_id, null: false
        add :definition_id, :binary_id, null: false
        add :node_id, :string, null: false

        add :function_name, :string, null: false
        add :call_key, :string, null: false
        add :input_fingerprint, :string, null: false
        add :inputs, :map, null: false, default: %{}
        add :outputs, :map

        add :status, :string, null: false, default: "pending"
        add :attempt_index, :integer, null: false, default: 0
        add :next_attempt_at, :utc_datetime_usec, null: false

        add :last_failure_kind, :string
        add :dispatched_at, :utc_datetime_usec

        add :created_at, :utc_datetime_usec, null: false
      end

      # The idempotency key of a call: ONE row per key, so a repeated dispatch
      # is the same row and the first result is returned.
      create unique_index(:platform_step_dispatches, [:call_key],
               name: :uniq_platform_step_dispatches_call_key,
               prefix: prefix()
             )

      # The dispatcher's hot query: the rows that are due (armed, or a running
      # row whose lease expired).
      create index(:platform_step_dispatches, [:next_attempt_at],
               name: :idx_platform_step_dispatches_due,
               where: "status IN ('pending', 'running')",
               prefix: prefix()
             )

      create constraint(:platform_step_dispatches, :chk_platform_step_dispatches_status,
               check: "status IN ('pending', 'running', 'advanced', 'given_up')",
               prefix: prefix()
             )

      create constraint(:platform_step_dispatches, :chk_platform_step_dispatches_attempt_index,
               check: "attempt_index >= 0",
               prefix: prefix()
             )
    end
  end
end
