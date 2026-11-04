defmodule Letflow.Identity.TenantTimezoneTest do
  use Letflow.DataCase, async: true

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantTimezone

  test "TZ-3a: the default is Asia/Almaty" do
    assert TenantTimezone.default() == "Asia/Almaty"
  end

  test "TZ-3b: of/1 reads the key, and falls back for nil settings, no key, nil value" do
    assert TenantTimezone.of(%Tenant{settings: nil}) == "Asia/Almaty"
    assert TenantTimezone.of(%Tenant{settings: %{"app_name" => "x"}}) == "Asia/Almaty"
    assert TenantTimezone.of(%Tenant{settings: %{"timezone" => nil}}) == "Asia/Almaty"
    assert TenantTimezone.of(%Tenant{settings: %{"timezone" => "Asia/Tokyo"}}) == "Asia/Tokyo"
  end

  test "TZ-3d: the default literal appears once in lib/" do
    files = Path.wildcard("lib/**/*.ex") |> Enum.filter(&(File.read!(&1) =~ "\"Asia/Almaty\""))
    assert files == ["lib/letflow/identity/tenant_timezone.ex"]
  end

  test "TZ-4a..d: start of the next local day as a UTC instant" do
    assert {:ok, ~U[2026-11-03 15:00:00.000000Z]} =
             TenantTimezone.start_of_next_day(~D[2026-11-03], "Asia/Tokyo")

    assert {:ok, ~U[2026-11-04 00:00:00.000000Z]} =
             TenantTimezone.start_of_next_day(~D[2026-11-03], "UTC")

    assert {:ok, ~U[2026-10-24 22:00:00.000000Z]} =
             TenantTimezone.start_of_next_day(~D[2026-10-24], "Europe/Berlin")

    # 2026-10-25 is the 25-hour day in Berlin: next local midnight is 23:00 UTC
    assert {:ok, ~U[2026-10-25 23:00:00.000000Z]} =
             TenantTimezone.start_of_next_day(~D[2026-10-25], "Europe/Berlin")
  end

  test "TZ-4g: a NUL-byte zone name is refused before any query, transaction stays usable" do
    {:ok, :done} =
      Repo.transaction(fn ->
        refute TenantTimezone.known_zone?("UTC\u0000x")

        assert {:error, :invalid_timezone} =
                 TenantTimezone.start_of_next_day(~D[2026-11-03], "UTC\u0000x")

        changeset =
          Tenant.settings_changeset(%Tenant{}, %{"settings" => %{"timezone" => "UTC\u0000x"}})

        refute changeset.valid?
        assert {:ok, _} = TenantTimezone.start_of_next_day(~D[2026-11-03], "UTC")
        :done
      end)
  end

  test "TZ-4e: an unknown zone errors before the conversion and keeps the transaction usable" do
    test_pid = self()
    id = {:tz_probe, make_ref()}

    :telemetry.attach(
      id,
      [:letflow, :repo, :query],
      fn _e, _m, meta, _c -> send(test_pid, {:q, meta[:query]}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    Repo.transaction(fn ->
      assert {:error, :invalid_timezone} =
               TenantTimezone.start_of_next_day(~D[2026-11-03], "Mars/Olympus")

      assert {:ok, _} = TenantTimezone.start_of_next_day(~D[2026-11-03], "UTC")
    end)

    assert_received {:q, "SELECT EXISTS" <> _}
    # exactly one conversion statement: the one for UTC
    assert Enum.count(
             Stream.repeatedly(fn -> receive_q() end) |> Enum.take_while(& &1),
             &(&1 =~ "AT TIME ZONE")
           ) == 1
  end

  test "TZ-4f: bad argument types return the error, not a crash" do
    assert {:error, :invalid_timezone} = TenantTimezone.start_of_next_day("2026-11-03", "UTC")
    assert {:error, :invalid_timezone} = TenantTimezone.start_of_next_day(~D[2026-11-03], nil)
    refute TenantTimezone.known_zone?(nil)
  end

  defp receive_q do
    receive do
      {:q, q} -> q
    after
      0 -> nil
    end
  end
end
