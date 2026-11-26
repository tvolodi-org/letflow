defmodule Letflow.Notifications.OutboundCapTest do
  @moduledoc """
  T-2592 (pilot gap G4): the RESERVATION of the outbound send cap.

  The cap used to be counted over the delivery log, so a delivery row that
  could not be written was a send that was never counted -- and the send had
  already left the platform. The reservation is taken BEFORE the send (committed on its own when the
  caller holds no transaction; see outbound_cap.ex), and it is the counter of the cap.

  Test ids C1..C5.

  `async: false`: committed tenant writes.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Notifications.OutboundCap
  alias Letflow.Notifications.OutboundCounter
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: PCF

  setup do
    fx = PCF.tenant!("t2592-outbound-cap")
    {:ok, fx: fx}
  end

  defp counters(fx), do: Repo.all(OutboundCounter, prefix: fx.schema_name)

  test "C1 a reservation takes a slot of the hour and of the day", %{fx: fx} do
    tenant_id = Ecto.UUID.cast!(fx.tenant_id)

    assert :reserved = OutboundCap.reserve(fx.schema_name, 60, 500)

    assert length(counters(fx)) == 2
    assert Enum.all?(counters(fx), &(&1.send_count == 1))
    assert Enum.all?(counters(fx), &(&1.tenant_id == tenant_id))
    assert Enum.all?(counters(fx), &(&1.channel == "email"))
  end

  test "C2 the reservation over the cap is refused, and the counter does not move", %{fx: fx} do
    assert :reserved = OutboundCap.reserve(fx.schema_name, 1, 500)
    assert {:error, :rate_limited} = OutboundCap.reserve(fx.schema_name, 1, 500)

    # the refused reservation took no slot
    assert Enum.all?(counters(fx), &(&1.send_count == 1))
  end

  test "C3 the day cap and the hour cap are counted separately", %{fx: fx} do
    assert :reserved = OutboundCap.reserve(fx.schema_name, 60, 1)
    assert {:error, :rate_limited} = OutboundCap.reserve(fx.schema_name, 60, 1)
  end

  test "C4 a cap that cannot be reserved at all refuses: nothing is sent", %{fx: _fx} do
    # A schema that holds no counter table: the reservation cannot be read, so
    # the cap is treated as a cap that is OVER (fail closed).
    assert {:error, :cap_unavailable} =
             OutboundCap.reserve("tenant_" <> String.duplicate("0", 32), 60, 500)
  end

  test "C5 the counter of one tenant does not count for another", %{fx: fx} do
    other = PCF.tenant!("t2592-outbound-cap-other")

    assert :reserved = OutboundCap.reserve(fx.schema_name, 1, 500)

    assert {:error, :rate_limited} =
             OutboundCap.reserve(fx.schema_name, 1, 500)

    # the other tenant has its own counter
    assert :reserved =
             OutboundCap.reserve(other.schema_name, 1, 500)
  end
end
