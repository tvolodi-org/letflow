defmodule Letflow.Plugs.AuthAttemptLimit do
  @moduledoc """
  GH T-1558 (BA batch 2, item 6, part 1): 429 with `Retry-After` on the credential-guessing
  and public-bootstrap routes that had no limit. Letflow has no login route (Keycloak signs
  users in); the guessable surfaces are a failed bearer or `lf_tok_` API token at
  `Letflow.Plugs.AuthPipeline`, and the credential-free `/api/tenant-config` and
  `/api/mobile/tenant-config` lookups (slug enumeration).

  Two modes (plug option `mode:`):

    * `:failures` -- mounted in `Letflow.Plugs.ApiPipeline` right after the global admission
      gate and BEFORE `Plug.Parsers`, so a refused request costs no body read. It PEEKS the
      per-address bucket (no spend); empty -> 429 and halt. Otherwise it registers a
      before-send hook: when `AuthPipeline` marked the request `conn.private[:auth_failed]`,
      one token is spent. Successful requests spend nothing, so good traffic from a shared
      address is never throttled by its own volume. A halted 429 is never counted.
    * `:requests` -- mounted first in the two public tenant-config routers; one token per
      request.

  Key: `{:auth_attempt, mode, ip_bucket_id}` -- address only (IPv6 as /64), resolved by
  `Letflow.Plugs.ClientIp` (applied by this plug, as the main router chain does not run it), never a raw forwarded header. No token, slug or email is ever part of a
  key, a log line or telemetry (INV-4). All refusals go through `send_rate_limited/2`: status,
  headers and body carry nothing cause- or tenant-dependent (INV-5).

  Behind a proxy that is not in the `ClientIp` trusted list every user shares one address;
  the failures-only counting keeps good traffic unaffected, but see
  `docs/runbooks/auth-rate-limits.md`.

  Configuration: `config :letflow, Letflow.Plugs.AuthAttemptLimit, ...` (keys in
  `defaults/0`), read per call. The numbers are UAT assumptions; the production values are the
  process owner's. Telemetry: `[:letflow, :auth_attempt_limit, :outcome]` with
  `%{outcome: :rate_limited, mode: mode}`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Discovery

  @cache_control "private, no-store"

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts) do
    mode = Keyword.get(opts, :mode)

    if mode in [:failures, :requests],
      do: opts,
      else: raise(ArgumentError, "mode must be :failures or :requests")
  end

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts),
    do: run(conn, Keyword.fetch!(opts, :mode), System.monotonic_time(:millisecond))

  @doc false
  @spec run(Plug.Conn.t(), :failures | :requests, integer()) :: Plug.Conn.t()
  def run(conn, :requests, now_ms) do
    {capacity, refill} = params(:requests)
    key = key(:requests, conn)

    case Bucket.consume(key, capacity, refill, now_ms) do
      :ok -> conn
      :rate_limited -> refuse(conn, :requests, key, now_ms)
    end
  end

  def run(conn, :failures, now_ms) do
    {capacity, refill} = params(:failures)
    key = key(:failures, conn)

    case Bucket.peek(key, capacity, refill, now_ms) do
      :rate_limited ->
        refuse(conn, :failures, key, now_ms)

      :ok ->
        register_before_send(conn, fn conn ->
          if conn.private[:auth_failed] == true do
            Bucket.consume(key, capacity, refill, System.monotonic_time(:millisecond))
          end

          conn
        end)
    end
  end

  @doc """
  The single 429 constructor: constant body, `retry-after` (whole seconds until one token
  refills, at least 1), `cache-control: private, no-store`, halts.
  """
  @spec send_rate_limited(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def send_rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_header("cache-control", @cache_control)
    |> Response.rate_limited("rate limit exceeded")
    |> halt()
  end

  defp refuse(conn, mode, key, now_ms) do
    {capacity, refill} = params(mode)

    :telemetry.execute([:letflow, :auth_attempt_limit, :outcome], %{count: 1}, %{
      outcome: :rate_limited,
      mode: mode
    })

    send_rate_limited(conn, Bucket.retry_after(key, capacity, refill, now_ms))
  end

  # `ClientIp` is not part of the main router chain, so it is applied here (key derivation only):
  # trusted-proxy aware, falls back to `conn.remote_ip`, never reads a raw forwarded header.
  defp key(mode, conn) do
    address = conn |> Letflow.Plugs.ClientIp.call([]) |> Discovery.client_address()
    {:auth_attempt, mode, Discovery.ip_bucket_id(address)}
  end

  defp params(:failures), do: {config().failure_capacity, config().failure_refill_per_sec}
  defp params(:requests), do: {config().request_capacity, config().request_refill_per_sec}

  @doc "Default configuration."
  @spec defaults() :: keyword()
  def defaults do
    [
      failure_capacity: 10,
      failure_refill_per_sec: 10 / 60,
      request_capacity: 60,
      request_refill_per_sec: 1,
      max_keys: 100_000,
      sweep_interval_ms: 30_000
    ]
  end

  @doc "Defaults merged with application env, as a map (read per call)."
  @spec config() :: map()
  def config do
    defaults() |> Keyword.merge(Application.get_env(:letflow, __MODULE__, [])) |> Map.new()
  end

  @doc "Validates overrides over `defaults/0`; raises `ArgumentError` naming the key."
  @spec validate_config!(keyword()) :: :ok
  def validate_config!(overrides) do
    c = defaults() |> Keyword.merge(overrides) |> Map.new()

    for k <- [:failure_capacity, :request_capacity, :max_keys, :sweep_interval_ms],
        not (is_integer(c[k]) and c[k] > 0) do
      raise ArgumentError, "#{inspect(k)} must be a positive integer"
    end

    for k <- [:failure_refill_per_sec, :request_refill_per_sec] do
      v = c[k]

      unless is_number(v) and v > 0 and round(v * 1_000_000) >= 1 do
        raise ArgumentError, "#{inspect(k)} must be a positive number"
      end
    end

    :ok
  end

  @doc """
  Parses `LETFLOW_AUTH_FAILURES_PER_MIN`: `:unset` for nil or blank, `{:ok, n}` for a positive
  integer, `{:error, :invalid}` otherwise. The value is never echoed.
  """
  @spec parse_failures_per_min(String.t() | nil) ::
          :unset | {:ok, pos_integer()} | {:error, :invalid}
  def parse_failures_per_min(nil), do: :unset

  def parse_failures_per_min(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        :unset

      s ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, :invalid}
        end
    end
  end
end
