# Letflow.Repo.Migrations.AddRateLimitedNotificationReason
#
# T-2592 (pilot gap G4, the "Register a tenant" pilot): the delivery log's reason
# set grows by ONE value, `rate_limited`. The notification step's send cap refuses a
# send over the cap and records that refusal in the log; nothing is sent.
#
# The row still holds no subject, no body, no recipient address and no error text
# (INV-4): the reason is a closed code, not a text.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7);
# the statements in the DO block use format() and %I.
#
# The column check on `reason` was created by CreateNotificationDeliveries as an unnamed
# column constraint, so its name is not pinned by the code. The DO block finds it by its
# COLUMNS: the check that constrains the `reason` column ALONE. The sibling constraint on
# the row (`(status = 'sent') = (reason IS NULL)`) constrains two columns and must NOT be
# dropped. The definition is not matched on its text: Postgres normalizes `IN (...)` into
# `= ANY (ARRAY[...])`, so the text of the constraint is not what the code wrote.
#
# No row is rewritten: the rows written before this migration keep their reason, which is
# still in the new set. Replay is a no-op.
defmodule Letflow.Repo.Migrations.AddRateLimitedNotificationReason do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      DO $rate_limited$
      DECLARE
        s constant text := '#{schema}';
        c record;
      BEGIN
        FOR c IN
          SELECT con.conname
            FROM pg_constraint con
            JOIN pg_attribute att
              ON att.attrelid = con.conrelid
             AND att.attnum = con.conkey[1]
           WHERE con.conrelid = format('%I.%I', s, 'notification_deliveries')::regclass
             AND con.contype = 'c'
             AND att.attname = 'reason'
             AND array_length(con.conkey, 1) = 1
        LOOP
          EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I',
                         s, 'notification_deliveries', c.conname);
        END LOOP;
      END
      $rate_limited$
      """)

      execute("""
      ALTER TABLE "#{schema}".notification_deliveries
        ADD CONSTRAINT notification_deliveries_reason_check
        CHECK (reason IN ('no_email', 'adapter_noop', 'adapter_error', 'rate_limited'))
      """)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute("""
      ALTER TABLE "#{schema}".notification_deliveries
        DROP CONSTRAINT IF EXISTS notification_deliveries_reason_check
      """)

      execute("""
      ALTER TABLE "#{schema}".notification_deliveries
        ADD CONSTRAINT notification_deliveries_reason_check
        CHECK (reason IN ('no_email', 'adapter_noop', 'adapter_error'))
      """)
    end
  end
end
