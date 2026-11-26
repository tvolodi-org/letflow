# G-09 seeded failing case: a manifest-position pin that names a migration the tenant manifest
# does NOT hold at that position. It is the shape of the T-2588 breakage (a migration appended to
# the manifest shifts every positional pin) with a version that can never be in the manifest, so
# the case stays broken whatever the manifest grows to.
#
# The file is a fixture, not a test: it is not named `*_test.exs`, so `mix test` never runs it. The
# probe (test/letflow/security_probe/g09_migration_impact_test.exs) reads it with the migration
# impact runner and requires the runner to report it as stale.
defmodule Letflow.SecurityProbe.Fixtures.StalePositionPin do
  @moduledoc """
  G-09 seeded failing case: the pin names a migration that is not at the position it claims.
  """

  use ExUnit.Case, async: true

  alias Letflow.TenantProvisioning

  @version 1_999_991_231_245_999

  test "the seeded pin names a migration the manifest does not hold last" do
    assert {@version, Letflow.Repo.Migrations.CreateTenantModuleUpgrades} =
             List.last(TenantProvisioning.tenant_scoped_migrations())
  end
end
