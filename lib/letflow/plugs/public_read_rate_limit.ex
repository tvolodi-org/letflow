defmodule Letflow.Plugs.PublicReadRateLimit do
  @moduledoc """
  REQ-352 (design §11) -- the mounting precondition for
  `/api/public`: keyed on `conn.remote_ip` (from the actual socket peer,
  never a forwarded header absent trusted-proxy config) plus a separate,
  tighter global bucket. Enforced as the FIRST plug inside
  `Letflow.Routers.PublicRead`'s own chain, ahead of `plug(:match)`, so a
  `429` is input-independent -- it fires identically whether `:handle` in
  the request would otherwise have resolved or not, and no resolution work
  ever begins for a rate-limited request.

  **OQ-2 resolved: this is a new module, not built on `Letflow.Plugs.RateLimit`**
  -- that module does not exist in the tree (it is only a deferred-plugs
  table row, `lib/letflow/plugs/api_pipeline.ex:59`, reserved for the
  general `/api/v1` limiter with no owning requirement). Building a new,
  narrower module here does not discharge that deferred row.

  The per-address key is the resolved visitor (`conn.assigns.client_ip`, set by
  `Letflow.Plugs.ClientIp` on mounts behind a trusted proxy), falling back to the
  socket peer where no such plug runs (SF-13: behind a proxy the peer is shared).

  Capacities/refill rates are sourced from application config
  (`config :letflow, Letflow.Plugs.PublicReadRateLimit, ...`), not hardcoded,
  so they are tunable per environment without a code change.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Plugs.PublicReadRateLimit.Bucket

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    config = Application.get_env(:letflow, __MODULE__, [])
    global_capacity = Keyword.get(config, :global_capacity, 200)
    global_refill_per_sec = Keyword.get(config, :global_refill_per_sec, 50)
    ip_capacity = Keyword.get(config, :ip_capacity, 20)
    ip_refill_per_sec = Keyword.get(config, :ip_refill_per_sec, 2)

    with :ok <- Bucket.consume(:global, global_capacity, global_refill_per_sec),
         :ok <-
           Bucket.consume(
             {:ip, Map.get(conn.assigns, :client_ip) || conn.remote_ip},
             ip_capacity,
             ip_refill_per_sec
           ) do
      conn
    else
      :rate_limited ->
        conn
        |> put_resp_header("retry-after", "1")
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("x-robots-tag", "noindex, nofollow")
        |> Response.rate_limited("rate limit exceeded")
        |> halt()
    end
  end
end
