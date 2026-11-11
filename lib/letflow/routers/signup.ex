defmodule Letflow.Routers.Signup do
  @moduledoc """
  T-1579 (TA-SL2a; decision 0084) -- the public, credential-free tenant sign-up mount, part 1.

  Mounted by `Letflow.Router` via `forward("/api/signup", ...)` before `/api/v1`, so it never enters
  `Letflow.Plugs.AuthPipeline`. Public by mount position. **Off by default:** unless
  `config :letflow, Letflow.Signup, enabled: true` (`LETFLOW_SIGNUP_ENABLED=true`), every method and path
  answers the standard 404 before anything else runs.

  | Handler | Method/path                   | Auth                  | Response |
  |---------|-------------------------------|-----------------------|----------|
  | config  | `GET /api/signup/config`      | **none**              | `200` |
  | submit  | `POST /api/signup`            | **none**              | `202` neutral for every well-formed request, `422` field errors / refused e-mail domain / failed captcha (T-1620), `429` per-IP or per-domain cap, `503` pending cap or captcha adapter down; every refusal body has `error` + localised `message` |
  | verify  | `POST /api/signup/verify`     | none (token is the credential) | `200`, or one generic `400` |
  | catch-all | `match _`                   | none                  | standard `404` |

  Verification is a POST so a mail scanner or link prefetch cannot consume the token; the mailed link
  opens the SPA page, which posts it. The endpoint holds no Keycloak credential and creates no tenant:
  it can only record a request (see `Letflow.Signup`).

  ## Telemetry / logging (INV-4)

  One `[:letflow, :signup, :outcome]` event per request, metadata `%{outcome: atom}` only. No e-mail,
  address, token or company name is logged or put in telemetry.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Signup

  @max_body 4_096
  @read_timeout 2_000
  @retry_after 3600

  plug(:enabled_gate)
  plug(Letflow.Plugs.ClientIp)
  plug(:match)
  plug(:dispatch)

  @doc "Mount switch: 404 for every method/path unless the flag is exactly `true`."
  @spec enabled_gate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def enabled_gate(conn, _opts) do
    if Signup.enabled?() do
      conn
    else
      emit(:disabled)

      conn
      |> not_found()
      |> halt()
    end
  end

  get "/config" do
    emit(:config)

    respond(conn, 200, %{
      enabled: true,
      languages: Signup.Messages.languages(),
      terms_version: Signup.terms_version(),
      captcha_required: Signup.Captcha.required?(Signup.config())
    })
  end

  post "/" do
    {conn, params} = read_json(conn)

    case Signup.submit(params, conn.assigns.client_ip) do
      :accepted ->
        emit(:accepted)
        respond(conn, 202, %{status: "check_your_mail"})

      {:error, {:invalid, fields}} ->
        emit(:invalid)
        refuse(conn, 422, "invalid_request", params, fields: fields)

      {:error, :email_not_accepted} ->
        emit(:email_not_accepted)
        refuse(conn, 422, "email_not_accepted", params)

      {:error, :captcha_failed} ->
        emit(:captcha_failed)
        refuse(conn, 422, "captcha_failed", params)

      {:error, :rate_limited} ->
        emit(:rate_limited_ip)
        rate_limited(conn, params)

      {:error, :rate_limited_domain} ->
        emit(:rate_limited_domain)
        rate_limited(conn, params)

      {:error, :unavailable} ->
        emit(:unavailable)
        refuse(conn, 503, "signup_unavailable", params)
    end
  end

  post "/verify" do
    {conn, params} = read_json(conn)

    case Signup.verify(Map.get(params, "token")) do
      :ok ->
        emit(:verified)
        respond(conn, 200, %{status: "verified"})

      {:error, :invalid} ->
        emit(:verify_invalid)
        respond(conn, 400, %{error: "invalid_or_expired_link"})
    end
  end

  match _ do
    emit(:not_found)
    not_found(conn)
  end

  # SU-A05-1: the disabled and catch-all 404s carry the same three headers as every other answer here.
  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> Response.not_found()
  end

  defp rate_limited(conn, params) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after))
    |> refuse(429, "rate_limited", params)
  end

  # T-1620: every refusal carries `error` (the code) and `message` (ru/kk/en from the body `language`, else en).
  defp refuse(conn, status, code, params, extra \\ []) do
    language = Map.get(params, "language")
    message = Signup.Messages.refusal(code, language)
    respond(conn, status, Map.merge(%{error: code, message: message}, Map.new(extra)))
  end

  # Bounded read; any failure is an empty map (the field validation then answers 422).
  defp read_json(conn) do
    case read_body(conn, length: @max_body, read_length: @max_body, read_timeout: @read_timeout) do
      {:ok, body, conn} -> {conn, decode(conn, body)}
      {:more, _partial, conn} -> {conn, %{}}
      {:error, _reason} -> {conn, %{}}
    end
  end

  defp decode(conn, body) do
    with true <- json_content_type?(conn),
         {:ok, %{} = map} <- Jason.decode(body) do
      map
    else
      _malformed -> %{}
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

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> Response.send_json(status, body)
  end

  defp emit(outcome) do
    :telemetry.execute([:letflow, :signup, :outcome], %{count: 1}, %{outcome: outcome})
  end
end
