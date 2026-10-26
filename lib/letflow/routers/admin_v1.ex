defmodule Letflow.Routers.AdminV1 do
  @moduledoc """
  REQ-572 / GH #3252 / decision 0072 (QA only): the provisioner mount, `/admin/v1`, forwarded by
  `Letflow.Router` BEFORE its catch-all and OUTSIDE `Letflow.Plugs.ApiPipeline`. The authentication is
  a credential class, not a role (D6 Option B): `Letflow.Plugs.ProvisionerAuth` is the first plug and
  nothing in this module is reachable without it.

  | Route | Class | Answer |
  |---|---|---|
  | `POST /tenants` | write | 201 first time, 200 replay: `{tenant_id, status, server_url, handover}` |
  | `GET /tenants/:id` | write or read | 200 `{tenant_id, status, tier, created_at, expires_at, purged_at}` |
  | `POST /tenants/:id/suspend`, `/resume`, `/expire` | write | 200 `{tenant_id, status}` |
  | anything else | any | 404 `not_found`; `DELETE /tenants/:id` of a provisioned id is 409 `conflict` |

  There is no list, no credential, user or token route here, and no `DELETE`/purge in this slice.

  ## Errors

  Every non-2xx answer of a configured deployment is `{error, message}` with a fixed message, codes
  `invalid_request` (400), `unauthorized` (401, and 403 for a read credential on a route it may not
  call: the contract has no `forbidden` code), `not_found` (404), `conflict` (409), `rate_limited`
  (429 + `retry-after`) and `internal_error` (500). The one exception is the 404 of an UNCONFIGURED
  deployment (no credential hash set): it is the standard problem body of an unmatched path, byte for
  byte, so the mount cannot be told from a missing route.

  ## Body without `Plug.Parsers`

  `Plug.Parsers` is declared in exactly one place (`Letflow.Plugs.ApiPipeline`). Only the create
  handler reads a body, after the credential and the class check (a read credential gets 403 before
  any body is read): a bounded `read_body`, a JSON content type, `Jason.decode`, an object. The decoded
  map goes whole to `Letflow.TenantProvisioner.Request.parse/1`; this module reads no tenant or slug
  key itself.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Plugs.ProvisionerAuth
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Request

  @max_body_bytes 16_384

  plug(Letflow.Plugs.ProvisionerAuth)
  plug(:class_gate)
  plug(:match)
  plug(:dispatch)

  @doc false
  # A read credential may call exactly GET /tenants/:id; everything else is 403 before any body read.
  @spec class_gate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def class_gate(%{assigns: %{provisioner_class: :read}} = conn, _opts) do
    if conn.method == "GET" and match?(["tenants", _id], conn.path_info) do
      conn
    else
      ProvisionerAuth.send_error(
        conn,
        403,
        "unauthorized",
        "credential not permitted for this route"
      )
    end
  end

  def class_gate(conn, _opts), do: conn

  post "/tenants" do
    # The conn returned by read_body is threaded to every response (Bandit tracks the
    # body read state in it; a stale conn makes the server re-read the body after the reply).
    {read, conn} = read_json(conn)

    with {:ok, body} <- read,
         {:ok, request} <- Request.parse(body) do
      case TenantProvisioner.create(request) do
        {:ok, :created, answer} -> Response.send_json(conn, 201, answer)
        {:ok, :existing, answer} -> Response.send_json(conn, 200, answer)
        {:error, reason} -> send_failure(conn, reason)
      end
    else
      {:error, field} when is_binary(field) -> send_failure(conn, {:invalid, field})
    end
  end

  get "/tenants/:id" do
    case TenantProvisioner.get(id) do
      {:ok, answer} -> Response.send_json(conn, 200, answer)
      {:error, reason} -> send_failure(conn, reason)
    end
  end

  post "/tenants/:id/suspend" do
    transition(conn, id, :suspend)
  end

  post "/tenants/:id/resume" do
    transition(conn, id, :resume)
  end

  post "/tenants/:id/expire" do
    transition(conn, id, :expire)
  end

  match _ do
    case {conn.method, conn.path_info} do
      {"DELETE", ["tenants", id]} ->
        if TenantProvisioner.provisioned?(id),
          do: send_failure(conn, :conflict),
          else: send_failure(conn, :not_found)

      _other ->
        send_failure(conn, :not_found)
    end
  end

  defp transition(conn, id, action) do
    case TenantProvisioner.transition(id, action) do
      {:ok, answer} -> Response.send_json(conn, 200, answer)
      {:error, reason} -> send_failure(conn, reason)
    end
  end

  # ── body ────────────────────────────────────────────────────────────────

  defp read_json(conn) do
    case read_bounded(conn) do
      {:ok, body, conn} ->
        with true <- json_content_type?(conn),
             {:ok, %{} = decoded} <- Jason.decode(body) do
          {{:ok, decoded}, conn}
        else
          _malformed -> {{:error, "body"}, conn}
        end

      :error ->
        {{:error, "body"}, conn}
    end
  end

  defp read_bounded(conn) do
    case read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      _more_or_error -> :error
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
          "application/json"

      [] ->
        false
    end
  end

  # ── errors ──────────────────────────────────────────────────────────────

  defp send_failure(conn, {:invalid, field}),
    do: ProvisionerAuth.send_error(conn, 400, "invalid_request", "invalid field: " <> field)

  defp send_failure(conn, :conflict),
    do:
      ProvisionerAuth.send_error(
        conn,
        409,
        "conflict",
        "the request conflicts with the current state"
      )

  defp send_failure(conn, :not_found),
    do: ProvisionerAuth.send_error(conn, 404, "not_found", "no such tenant or route")

  defp send_failure(conn, :internal),
    do: ProvisionerAuth.send_error(conn, 500, "internal_error", "internal error")
end
