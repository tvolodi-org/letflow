# Letflow.Repo.Migrations.AddTestCasesToProcessDefinitions
#
# T-2604 (the "Register a tenant" pilot, gap G16): the DECLARED TEST CASES of a
# definition version -- the guardrail that runs them before the version may be
# activated (owner decision D-176's "automatic test run before activation", listed
# in D-179 (c)).
#
# `test_cases` is NULLABLE and NULL for every existing row: a definition that
# declares no case activates exactly as it did before this guardrail existed. The
# value is a JSON array of case objects -- see `Letflow.Definitions.TestCases` for
# the shape, the runner and the bounds.
#
# D-180 EXTENSION POINT (not built here): the later fork/binding slice of owner
# decision D-180 adds the lineage of a tenant's own copy of a standard definition
# -- a `custom` marker and a `based_on: <standard key>@<version>` reference -- to
# THIS table, as further NULLABLE columns beside this one. Nothing here assumes
# that a definition is editable by whoever can see it, nor that a tenant has
# exactly one definition per key: the declared cases are read from the
# definition's OWN row, and a tenant's copy would carry its own.
#
# TENANT-SCOPED MIGRATION -- the `if prefix()` guard is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0`.
defmodule Letflow.Repo.Migrations.AddTestCasesToProcessDefinitions do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:process_definitions, prefix: schema) do
        add :test_cases, :map
      end
    end
  end
end
