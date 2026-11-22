defmodule Letflow.PlatformFunctions.Impl.SystemCallerTest do
  @moduledoc """
  Who a platform step IS when it runs (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  What the tests prove:

    * the actor a system call writes is the nil UUID -- the codebase's own
      "not a user" literal, never an invented user id;
    * the platform prefix comes from the server's own configuration, and a
      platform tenant that is not configured is refused (the body never
      invents a schema).

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.PlatformFunctions.Impl.SystemCaller
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.TenantFixture

  test "S1 the actor is the system's literal id, never a person" do
    assert SystemCaller.actor_id() == "00000000-0000-0000-0000-000000000000"
  end

  test "S2 the platform prefix is the configured platform tenant's schema" do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-sys")
    PlatformFx.pin!(platform.tenant_id)

    assert {:ok, prefix} = SystemCaller.platform_prefix()
    assert prefix == platform.schema_name
  end

  test "S3 no configured platform tenant is refused" do
    PlatformFx.unpin!()

    assert :error = SystemCaller.platform_prefix()
  end
end
