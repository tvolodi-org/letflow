defmodule Letflow.Support.RegisterTenantProcessFixture do
  @moduledoc """
  The active `platform.register_tenant` definition in a platform tenant fixture
  (T-2704, pilot gap G17b), for the route tests that start it.

  It writes the SHIPPED document through the shipped seed
  (`Letflow.PlatformProcesses.Seed`), signed by a platform administrator made for
  the purpose, so a route test starts exactly the definition production runs.
  """

  alias Letflow.PlatformProcesses.Seed
  alias Letflow.Support.PlatformCallFixture, as: Fx

  @doc """
  Seeds and activates the registration definition in `schema_name`, which must
  be the pinned platform tenant. Returns the seeded definition row.
  """
  @spec seed!(String.t()) :: map()
  def seed!(schema_name) do
    admin = Fx.user!(schema_name, "reg-activator")
    Fx.platform_admin!(schema_name, admin)

    {:ok, %{definition: definition}} =
      Seed.seed(prefix: schema_name, activator_user_id: admin.id)

    definition
  end
end
