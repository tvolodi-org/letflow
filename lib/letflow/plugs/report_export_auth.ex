defmodule Letflow.Plugs.ReportExportAuth do
  @moduledoc """
  T-1948 (maintenance slice 1): the credential plug of `Letflow.Routers.MaintenanceV1`, the read-only
  problem-report export for the PM handoff. Same shape as `Letflow.Plugs.ProvisionerAuth`, one class.
  The credential is configured only as a SHA-256 hash
  (`config :letflow, Letflow.Plugs.ReportExportAuth, sha256: hex | nil`, from
  `LETFLOW_PROBLEM_REPORT_EXPORT_SHA256`, parsed by `Letflow.ProblemReports.ExportConfig`).

  ## Order

    1. Hash not configured: the standard 404 of an unmatched path, byte-identical. No header is read.
    2. `Authorization: Bearer <token>`; missing, malformed or wrong all answer the same 401.
    3. `sha256(token)` is compared with `Plug.Crypto.secure_compare/2`.
    4. Only an accepted credential is rate limited (`ProvisionerAuth.RateLimiter`, class `:report_export`).
    5. `conn.assigns.report_export` is set. `auth_context` is never set: an OIDC or API token means nothing
       here (401), and this credential means nothing to `Letflow.Plugs.ApiPipeline`.

  Error bodies are `{error, message}` with fixed messages (INV-4).
  """

  import Plug.Conn

  alias Letflow.Api.Response
  alias Letflow.Plugs.ProvisionerAuth.RateLimiter

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = Application.get_env(:letflow, __MODULE__, [])

    case Keyword.get(config, :sha256) do
      hash when is_binary(hash) -> authenticate(conn, hash)
      _unset -> conn |> Response.not_found() |> halt()
    end
  end

  @doc "Sends the `{error, message}` body of the export mount and halts."
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def send_error(conn, status, code, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> Response.send_json(status, %{error: code, message: message})
    |> halt()
  end

  defp authenticate(conn, hash) do
    with ["Bearer " <> token | _] when token != "" <- get_req_header(conn, "authorization"),
         true <- token_matches?(token, hash),
         :ok <- RateLimiter.hit(:report_export) do
      assign(conn, :report_export, true)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_error(429, "rate_limited", "too many requests")

      _unauthorized ->
        send_error(conn, 401, "unauthorized", "invalid or missing credential")
    end
  end

  defp token_matches?(token, hash) do
    digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(digest, hash)
  end
end
