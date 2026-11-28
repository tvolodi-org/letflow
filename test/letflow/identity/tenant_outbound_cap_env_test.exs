defmodule Letflow.Identity.TenantOutboundCapEnvTest do
  @moduledoc """
  T-3259: the platform value of the outbound caps comes from the application env
  (`:letflow, :outbound_caps`, set by config/runtime.exs from the two LETFLOW_OUTBOUND_CAP_*
  variables). `async: false`: the test mutates the application env.
  """

  use ExUnit.Case, async: false

  alias Letflow.Identity.Tenant

  test "T-3259 CAP-6: platform override, tenant lower wins, tenant cannot raise" do
    old = Application.get_env(:letflow, :outbound_caps)
    Application.put_env(:letflow, :outbound_caps, per_hour: 600, per_day: 5000)

    on_exit(fn ->
      if old,
        do: Application.put_env(:letflow, :outbound_caps, old),
        else: Application.delete_env(:letflow, :outbound_caps)
    end)

    assert Tenant.outbound_cap_ceiling() == %{per_hour: 600, per_day: 5000}
    assert Tenant.outbound_caps(%{}) == {600, 5000}

    assert Tenant.outbound_caps(%{
             "notifications.outbound_cap_per_hour" => 10,
             "notifications.outbound_cap_per_day" => 100
           }) == {10, 100}

    assert Tenant.outbound_caps(%{"notifications.outbound_cap_per_hour" => 601}) ==
             {600, 5000}
  end
end
