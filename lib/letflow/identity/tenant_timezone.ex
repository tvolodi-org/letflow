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
    # The IANA alphabet only: a NUL byte or other odd character would make
    # PostgreSQL reject the parameter and abort a surrounding transaction.
    if Regex.match?(~r/\A[A-Za-z0-9_+\-\/]{1,64}\z/, name), do: query_zone(name), else: false
  end

  def known_zone?(_other), do: false

  defp query_zone(name) do
    case SQL.query(
           Repo,
           "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = $1)",
           [name]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

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

  @doc """
  The current local date in `zone` (a bound parameter, INV-7). An unknown zone returns
  `{:error, :invalid_timezone}` before the statement is sent.
  """
  @spec today(String.t()) :: {:ok, Date.t()} | {:error, :invalid_timezone}
  def today(zone) when is_binary(zone) do
    with true <- known_zone?(zone),
         {:ok, %{rows: [[%Date{} = date]]}} <-
           SQL.query(Repo, "SELECT (now() AT TIME ZONE $1)::date", [zone]) do
      {:ok, date}
    else
      _ -> {:error, :invalid_timezone}
    end
  end

  def today(_zone), do: {:error, :invalid_timezone}

  @doc """
  The wall-clock time of the UTC instant `at` in `zone` (T-1640, the fleet upgrade window). Bound
  parameters (INV-7); an unknown zone returns `{:error, :invalid_timezone}` before the statement.
  """
  @spec local_time(DateTime.t(), String.t()) :: {:ok, Time.t()} | {:error, :invalid_timezone}
  def local_time(%DateTime{} = at, zone) when is_binary(zone) do
    with true <- known_zone?(zone),
         {:ok, %{rows: [[%Time{} = time]]}} <-
           SQL.query(Repo, "SELECT (($1::timestamptz) AT TIME ZONE $2)::time", [at, zone]) do
      {:ok, time}
    else
      _ -> {:error, :invalid_timezone}
    end
  end

  def local_time(_at, _zone), do: {:error, :invalid_timezone}
end
