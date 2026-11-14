defmodule Letflow.TenantDate do
  @moduledoc """
  Time-zone-aware date helpers for tests.

  `today/1` returns the current local date in the tenant's configured zone by
  querying PostgreSQL (via `TenantTimezone.today/1`), so a checked-out database
  connection must be available.

  `default_today/0` uses the default tenant zone (Asia/Almaty, UTC+5, fixed
  offset — no DST since 2024) via arithmetic, with no DB connection needed. Use
  it in router or export tests that receive a dynamic context map, where the
  Elixir type checker cannot confirm the tenant value is a `%Tenant{}` struct.

  Both functions are correct alternatives to `Date.utc_today()`, which fails
  between 15:00 and 23:00 UTC when the tenant's local day is already the
  following day.
  """

  alias Letflow.Identity.{Tenant, TenantTimezone}

  # Asia/Almaty is a fixed +05:00 (no DST since 2024).
  @almaty_offset_seconds 5 * 3600

  @doc "The current date in the tenant's configured time zone. Requires a DB connection."
  @spec today(Tenant.t()) :: Date.t()
  def today(%Tenant{} = tenant) do
    zone = TenantTimezone.of(tenant)
    {:ok, date} = TenantTimezone.today(zone)
    date
  end

  @doc "The current date in the default tenant zone (Asia/Almaty, UTC+5), via arithmetic."
  @spec default_today() :: Date.t()
  def default_today do
    DateTime.utc_now() |> DateTime.add(@almaty_offset_seconds) |> DateTime.to_date()
  end
end
