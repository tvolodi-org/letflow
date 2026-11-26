# G-09 seeded failing case for the completeness check: positional reads of the tenant manifest
# that the runner CANNOT judge as a pin.
#
# Two shapes, both of them the shape the T-2588 breakage takes when a test wraps its manifest
# access in a helper:
#
#   1. the manifest arrives as a function parameter -- the runner cannot resolve the read to the
#      manifest, so it cannot say which migration the read names;
#   2. the position arrives as a function parameter -- the runner cannot read which position the
#      read names, so it cannot say which migration the read names.
#
# In both cases the runner sees the positional read and reports it as unjudged instead of
# skipping it. A class that counted the reads it saw and the pins it judged would pass this file
# if it dropped the reads -- the seeded case proves it does not.
#
# The file is a fixture, not a test: it is not named `*_test.exs`, so `mix test` never runs it. The
# probe (test/letflow/security_probe/g09_migration_impact_test.exs) reads it with the migration
# impact runner and requires the runner to report the reads as unjudged.
defmodule Letflow.SecurityProbe.Fixtures.UnresolvedPositionRead do
  @moduledoc """
  G-09 seeded failing case: positional manifest reads the runner cannot judge.
  """

  use ExUnit.Case, async: true

  alias Letflow.TenantProvisioning

  test "the helper reads the manifest by position" do
    assert {version, module} = read_at(TenantProvisioning.tenant_scoped_migrations())

    assert is_integer(version)
    assert is_atom(module)
  end

  test "the helper reads the manifest at the position it is given" do
    assert {version, module} = read_at_index(-2)

    assert is_integer(version)
    assert is_atom(module)
  end

  # The manifest arrives as a parameter: the runner cannot resolve this read to the manifest, so
  # it cannot say which migration the read names.
  defp read_at(manifest) do
    Enum.at(manifest, -2)
  end

  # The position arrives as a parameter: the runner cannot read which position is read, so it
  # cannot say which migration the read names.
  defp read_at_index(index) do
    Enum.at(TenantProvisioning.tenant_scoped_migrations(), index)
  end
end
