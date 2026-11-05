defmodule Letflow.Voice.Http do
  @moduledoc """
  REQ-740: the one outbound POST shared by `Letflow.Voice.SpeechClient` and
  `Letflow.Voice.ModelClient` (a fourth file so the URL check, the `:httpc` call and the
  error classification exist once).

  - INV-9: `Letflow.Webhooks.UrlValidator.validate/1` runs on the URL inside every call (no
    memo) unless the app env `:voice_url_validation_enabled` (default true) is false, which
    only the client tests with a local http server do. A refusal answers
    `{:error, :provider_error}` before any socket opens. Redirects are NOT followed
    (`autoredirect: false`): a 3xx would otherwise reach a host nobody validated. Residual,
    as in `Letflow.Webhooks`: DNS may change between the check and the connect; the base URL
    is set by the platform operator.
  - INV-4: errors are bare atoms; the transport reason term (which may carry the URL or
    headers) and the provider's body are dropped, never logged or returned.
  - No retry.
  """

  alias Letflow.Webhooks.UrlValidator

  @spec post(String.t(), [{String.t(), String.t()}], String.t(), binary(), pos_integer()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :provider_timeout | :provider_error}
  def post(url, headers, content_type, body, timeout_ms) do
    if validate(url) == :ok do
      request(url, headers, content_type, body, timeout_ms)
    else
      {:error, :provider_error}
    end
  end

  defp validate(url) do
    if Application.get_env(:letflow, :voice_url_validation_enabled, true) do
      UrlValidator.validate(url)
    else
      :ok
    end
  end

  defp request(url, headers, content_type, body, timeout_ms) do
    charlist_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    req = {String.to_charlist(url), charlist_headers, String.to_charlist(content_type), body}

    http_opts =
      [{:timeout, timeout_ms}, {:connect_timeout, timeout_ms}, {:autoredirect, false}] ++
        ssl_opts(url)

    case :httpc.request(:post, req, http_opts, body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, resp_body}} when is_binary(resp_body) ->
        {:ok, status, resp_body}

      {:ok, _other} ->
        {:error, :provider_error}

      {:error, :timeout} ->
        {:error, :provider_timeout}

      {:error, _reason} ->
        {:error, :provider_error}
    end
  catch
    _kind, _reason -> {:error, :provider_error}
  end

  defp ssl_opts("https://" <> _) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl_opts(_url), do: []
end
