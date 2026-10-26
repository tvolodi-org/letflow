defmodule Letflow.Plugs.ProvisionerAuth do
  @moduledoc """
  REQ-572 / decision 0072 D6 (Option B): the credential plug of `Letflow.Routers.AdminV1`. The
  provisioner is a credential CLASS outside the role system: there is no role, no `auth_context`, no
  user and no tenant behind it. Two classes, each configured only as a SHA-256 hash
  (`config :letflow, Letflow.Plugs.ProvisionerAuth, write_sha256: ..., read_sha256: ...`; the
  variables are in `Letflow.TenantProvisioner.Config`):

    * `:write`: all five routes;
    * `:read`: `GET /tenants/:id` only (the realm reaper's token).

  ## Order (P1, P2, P10)

    1. Neither hash configured: the standard 404 of an unmatched path, byte-identical (P1). No header
       is read first.
    2. `Authorization: Bearer <token>`; missing, malformed or wrong all answer the same 401.
    3. The token's SHA-256 is compared with BOTH hashes by `Plug.Crypto.secure_compare/2` (a missing
       hash compares against an all-zero digest; no short-circuit between the two).
    4. Only an accepted credential is rate limited (`RateLimiter`): 429 `rate_limited` with
       `retry-after`.
    5. `conn.assigns.provisioner_class` is assigned. Nothing else is: `auth_context` is never set, so
       a provisioner credential means nothing to `Letflow.Plugs.ApiPipeline`, and a valid OIDC token
       means nothing here (401).

  Error bodies are `{error, message}` with fixed messages (INV-4). A read token on a write route is
  `403` with code `unauthorized` (the contract's code list has no `forbidden`).
  """

  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Plugs.ProvisionerAuth.RateLimiter

  @zero_hash String.duplicate("0", 64)

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = Application.get_env(:letflow, __MODULE__, [])
    write = Keyword.get(config, :write_sha256)
    read = Keyword.get(config, :read_sha256)

    if is_nil(write) and is_nil(read) do
      conn |> Response.not_found() |> halt()
    else
      authenticate(conn, write, read)
    end
  end

  @doc "Sends the `{error, message}` body of the provisioner API and halts."
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def send_error(conn, status, code, message) do
    conn
    |> Response.send_json(status, %{error: code, message: message})
    |> halt()
  end

  defp authenticate(conn, write, read) do
    with ["Bearer " <> token | _] when token != "" <- get_req_header(conn, "authorization"),
         {:ok, class} <- classify(token, write, read),
         :ok <- RateLimiter.hit(class) do
      assign(conn, :provisioner_class, class)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_error(429, "rate_limited", "too many requests")

      _unauthorized ->
        send_error(conn, 401, "unauthorized", "invalid or missing credential")
    end
  end

  defp classify(token, write, read) do
    digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    write_match? = Plug.Crypto.secure_compare(digest, write || @zero_hash) and not is_nil(write)
    read_match? = Plug.Crypto.secure_compare(digest, read || @zero_hash) and not is_nil(read)

    cond do
      write_match? -> {:ok, :write}
      read_match? -> {:ok, :read}
      true -> :error
    end
  end
end
