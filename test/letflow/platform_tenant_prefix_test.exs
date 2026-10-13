defmodule Letflow.PlatformTenantPrefixTest do
  @moduledoc """
  ISS-1030 (design section 7a, "One source for the platform prefix", N6):
  `Letflow.PlatformTenant.platform_prefix/0` derives the platform tenant's schema
  name from the configured id alone, purely, and fails closed.

  `async: false`: the platform tenant pin is VM-global application config.
  """

  use ExUnit.Case, async: false

  alias Letflow.PlatformTenant
  alias Letflow.Support.PlatformTenantFixture

  test "platform_prefix returns the schema name of the configured platform tenant" do
    tenant_id = Ecto.UUID.generate()
    PlatformTenantFixture.pin!(tenant_id)

    assert {:ok, schema_name} = PlatformTenant.platform_prefix()
    assert schema_name == "tenant_" <> String.replace(tenant_id, "-", "")
  end

  test "platform_prefix returns error when no platform tenant is configured" do
    PlatformTenantFixture.unpin!()

    assert PlatformTenant.platform_prefix() == :error
  end

  test "platform_prefix returns error when the configured value is not a valid tenant id" do
    PlatformTenantFixture.pin!("not-a-uuid")

    {result, queries} =
      PlatformTenantFixture.capture_repo_queries(fn -> PlatformTenant.platform_prefix() end)

    assert result == :error
    # The derivation is pure: it never reads the registration table.
    assert queries == []
  end

  test "platform_prefix issues no database query for a valid configured id either" do
    PlatformTenantFixture.pin!(Ecto.UUID.generate())

    {result, queries} =
      PlatformTenantFixture.capture_repo_queries(fn -> PlatformTenant.platform_prefix() end)

    assert {:ok, _schema_name} = result
    assert queries == []
  end
end
