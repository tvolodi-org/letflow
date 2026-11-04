defmodule Letflow.Identity.TenantTimezone do
  @moduledoc """
  The tenant time zone (REQ-703): one IANA name per tenant in
  `tenants.settings["timezone"]`, default `Asia/Almaty` (assumption, owner may
  change at GATE B).

  There is no Elixir tz database in this project (no new dependency): PostgreSQL
  decides which names exist and what offset applies on a date. `known_zone?/1`
  asks `pg_catalog.pg_timezone_names`; `start_of_next_day/2` asks PostgreSQL for
  the UTC instant at which the local day after a date begins, which is the upper
  bound of an as-of-date read (REQ-704). All values reach SQL as bound
  parameters (INV-7); failures return tuples and never raise (INV-8).
  """

  alias Ecto.Adapters.SQL
  alias Letflow.Identity.Tenant
  alias Letflow.Repo

  @default "Asia/Almaty"

  @doc "The default tenant time zone name."
  @spec default() :: String.t()
  def default, do: @default

  @doc "The tenant's time zone; a missing settings map, key or a cleared (`nil`) value gives the default."
  @spec of(Tenant.t()) :: String.t()
  def of(%Tenant{settings: settings}) do
    case settings do
      %{"timezone" => zone} when is_binary(zone) -> zone
      _ -> default()
    end
  end

  @doc "True when PostgreSQL knows `name` as a time zone (exact, case-sensitive match)."
  @spec known_zone?(term()) :: boolean()
  def known_zone?(name) when is_binary(name) do
    case SQL.query(
           Repo,
           "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = $1)",
           [name]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  def known_zone?(_other), do: false

  @doc """
  The UTC instant at which the local day after `date` begins in `zone`.
  An unknown zone returns `{:error, :invalid_timezone}` before the conversion
  statement is sent, so a surrounding transaction stays usable.
  """
  @spec start_of_next_day(Date.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :invalid_timezone}
  def start_of_next_day(%Date{} = date, zone) when is_binary(zone) do
    with true <- known_zone?(zone),
         {:ok, %{rows: [[%DateTime{} = dt]]}} <-
           SQL.query(Repo, "SELECT (($1::date + 1)::timestamp AT TIME ZONE $2)", [date, zone]) do
      {:ok, %{dt | microsecond: {elem(dt.microsecond, 0), 6}}}
    else
      _ -> {:error, :invalid_timezone}
    end
  end

  def start_of_next_day(_date, _zone), do: {:error, :invalid_timezone}
end
