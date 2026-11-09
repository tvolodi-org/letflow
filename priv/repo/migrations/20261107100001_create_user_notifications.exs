# Letflow.Repo.Migrations.CreateUserNotifications
#
# T-1561 -- in-app notification list (the bell). Table `user_notifications`, one row per
# notification of one user.
#
# PLACEMENT: per-tenant (schema-per-tenant via `prefix()`); `tenant_id` is kept inside the row too.
# No foreign key to `users`: users live in the public schema; an orphan row is invisible because
# every read filters by the caller's id.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is registered
# in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7). `kind` has NO CHECK: the closed
# list lives in `Letflow.UserNotifications` so a new kind needs no migration. The table starts empty.
defmodule Letflow.Repo.Migrations.CreateUserNotifications do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:user_notifications, primary_key: false, prefix: schema) do
        add :id, :binary_id, primary_key: true
        add :tenant_id, :binary_id, null: false
        add :user_id, :binary_id, null: false
        add :kind, :string, size: 64, null: false
        add :ref_id, :binary_id
        add :title, :string, size: 200, null: false
        add :read_at, :utc_datetime_usec

        timestamps(type: :utc_datetime_usec, updated_at: false)
      end

      create constraint(:user_notifications, :user_notifications_title_len,
               check: "char_length(title) <= 200",
               prefix: schema
             )

      execute(
        ~s|CREATE INDEX user_notifications_user_inserted_idx ON "#{schema}".user_notifications (user_id, inserted_at DESC, id DESC)|,
        ~s|DROP INDEX IF EXISTS "#{schema}".user_notifications_user_inserted_idx|
      )
    end
  end
end
