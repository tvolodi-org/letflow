# Letflow.Repo.Migrations.WidenTenantsDisplayName
#
# T-2704 (register-tenant routes): the routes and `tenant.validate` cap a display name at
# 255 CHARACTERS (graphemes) after a byte bound, but `tenants.display_name` was
# `varchar(255)`, which counts CODE POINTS. A valid name of 255 graphemes with combining
# marks has more than 255 code points and could not be stored. The column becomes `text`;
# the length rule lives in `Letflow.PlatformFunctions.Impl.TenantCreate.bounded/1`.
#
# PUBLIC-schema migration (the tenants registry); not tenant-scoped.
defmodule Letflow.Repo.Migrations.WidenTenantsDisplayName do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE tenants ALTER COLUMN display_name TYPE text")
  end

  def down do
    execute("ALTER TABLE tenants ALTER COLUMN display_name TYPE varchar(255)")
  end
end
