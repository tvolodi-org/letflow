defmodule Letflow.Oidc.RealmProbe do
  @moduledoc """
  Existence check for an identity-provider realm before it is bound to a tenant
  (ISS-1030, design `lib/letflow/design/iss1030-onboarding-administrator.md`
  section 3.1 item 5).

  `verify/1` asks the configured Keycloak whether a realm answers its OpenID
  discovery document. The adapter is configurable
  (`config :letflow, :oidc_realm_probe, MyAdapter`); the default adapter is
  `Letflow.Oidc.RealmProbe.Httpc`, which does NOT use the `oidcc` discovery
  loader because the redirect and body-size behaviour below must be enforced by
  code this repository controls.

  Results:

    * `:ok` -- the realm exists (its discovery document names the expected issuer).
    * `{:error, :not_found}` -- the realm does not exist, is outside the allowed
      name alphabet, or its discovery document does not describe it.
    * `{:error, :unreachable}` -- the probe could not decide (transport error,
      timeout, redirect, unexpected status, oversize response, no base URL).

  The probe URL is built ONLY from the configured Keycloak base URL and the
  validated realm name; no host ever comes from a request or a tenant setting
  (INV-9). Nothing here logs a realm name or a response body.
  """

  @doc "Checks that `realm` exists on the configured Keycloak."
  @callback verify(realm :: String.t()) :: :ok | {:error, :not_found} | {:error, :unreachable}

  @doc """
  Delegates to the configured adapter (`config :letflow, :oidc_realm_probe`),
  defaulting to `Letflow.Oidc.RealmProbe.Httpc`.
  """
  @spec verify(realm :: String.t()) :: :ok | {:error, :not_found} | {:error, :unreachable}
  def verify(realm) when is_binary(realm) do
    adapter().verify(realm)
  end

  defp adapter, do: Application.get_env(:letflow, :oidc_realm_probe, __MODULE__.Httpc)
end

defmodule Letflow.Oidc.RealmProbe.Httpc do
  @moduledoc """
  Default `Letflow.Oidc.RealmProbe` adapter: one `:httpc` GET of
  `<keycloak_base_url>/realms/<realm>/.well-known/openid-configuration`.

  Enforced here (design section 3.1 item 5):

    * Redirects are not followed (`autoredirect: false`); a 3xx or any status
      other than 200 and 404 is `{:error, :unreachable}`.
    * The request is asynchronous and streamed, because OTP streams only 200
      and 206 bodies and only in async mode. The `content-length` header is
      checked on `stream_start` and chunk bytes are counted; either exceeding
      64 KiB cancels the request. A `content-range` header (a 206, which OTP
      does not distinguish from a 200 in its stream messages) is treated like
      any non-200. Any non-200 answer arrives as one already-buffered message;
      only its status line is read, its body is discarded unread.
    * The whole exchange runs in a short-lived `Task` (its own mailbox) that
      matches only messages carrying its own request id, enforces a 3 second
      deadline with `receive ... after`, and always cancels the request before
      it ends, so the caller's mailbox is never touched.
    * For an `https` base URL: `verify_peer`, the OS CA store and a host name
      check. No `Accept-Encoding` header is sent, so the capped body is never
      decompressed. A trailing slash of the base URL is stripped once and the
      stripped value is used in both the request URL and the expected issuer.
    * The body must decode as a JSON object whose `issuer` equals
      `<keycloak_base_url>/realms/<realm>` exactly.
  """

  @behaviour Letflow.Oidc.RealmProbe

  @realm_regex ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/
  @max_body_bytes 64 * 1024
  @deadline_ms 3_000
  @connect_timeout_ms 2_000
  # Outer guard only: the task enforces the real deadline itself.
  @task_grace_ms 1_000

  @impl true
  @spec verify(realm :: String.t()) :: :ok | {:error, :not_found} | {:error, :unreachable}
  def verify(realm) when is_binary(realm) do
    with true <- Regex.match?(@realm_regex, realm),
         {:ok, base} <- base_url() do
      segment = URI.encode(realm, &URI.char_unreserved?/1)
      url = base <> "/realms/" <> segment <> "/.well-known/openid-configuration"
      expected_issuer = base <> "/realms/" <> realm
      run_in_task(url, expected_issuer)
    else
      false -> {:error, :not_found}
      :error -> {:error, :unreachable}
    end
  end

  @spec base_url() :: {:ok, String.t()} | :error
  defp base_url do
    case :letflow |> Application.get_env(:oidc, []) |> Keyword.get(:keycloak_base_url) do
      base when is_binary(base) and base != "" -> {:ok, String.replace_suffix(base, "/", "")}
      _unset -> :error
    end
  end

  @spec run_in_task(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, :unreachable}
  defp run_in_task(url, expected_issuer) do
    task = Task.async(fn -> safe_exchange(url, expected_issuer) end)

    case Task.yield(task, @deadline_ms + @task_grace_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_exit -> {:error, :unreachable}
    end
  end

  # The task never raises into the caller (INV-8): any failure is :unreachable.
  defp safe_exchange(url, expected_issuer) do
    exchange(url, expected_issuer)
  rescue
    _exception -> {:error, :unreachable}
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  defp exchange(url, expected_issuer) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    headers = [{~c"accept", ~c"application/json"}]

    http_options =
      [timeout: @deadline_ms, connect_timeout: @connect_timeout_ms, autoredirect: false] ++
        tls_options(url)

    request = {String.to_charlist(url), headers}

    case :httpc.request(:get, request, http_options,
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, request_id} ->
        receive_loop(request_id, deadline, expected_issuer, :awaiting)

      _error ->
        {:error, :unreachable}
    end
  end

  defp tls_options("https://" <> _rest) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp tls_options(_plain_http), do: []

  # state: :awaiting (nothing yet) | {:streaming, bytes_so_far, chunks_reversed}
  defp receive_loop(request_id, deadline, expected_issuer, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http, {^request_id, :stream_start, headers}} ->
        handle_stream_start(request_id, headers, deadline, expected_issuer)

      {:http, {^request_id, :stream, chunk}} ->
        handle_chunk(request_id, chunk, deadline, expected_issuer, state)

      {:http, {^request_id, :stream_end, _headers}} ->
        decide_body(state, expected_issuer)

      {:http, {^request_id, {{_version, status, _reason}, _headers, _body}}} ->
        # One buffered message for a non-streamed answer: status line only.
        if status == 404, do: {:error, :not_found}, else: {:error, :unreachable}

      {:http, {^request_id, {:error, _reason}}} ->
        {:error, :unreachable}
    after
      remaining ->
        cancel(request_id)
        {:error, :unreachable}
    end
  end

  defp handle_stream_start(request_id, headers, deadline, expected_issuer) do
    cond do
      header(headers, "content-range") != nil ->
        cancel(request_id)
        {:error, :unreachable}

      oversize_content_length?(headers) ->
        cancel(request_id)
        {:error, :unreachable}

      true ->
        receive_loop(request_id, deadline, expected_issuer, {:streaming, 0, []})
    end
  end

  defp handle_chunk(request_id, chunk, deadline, expected_issuer, state) do
    {bytes, chunks} =
      case state do
        {:streaming, bytes, chunks} -> {bytes, chunks}
        :awaiting -> {0, []}
      end

    total = bytes + byte_size(chunk)

    if total > @max_body_bytes do
      cancel(request_id)
      {:error, :unreachable}
    else
      receive_loop(request_id, deadline, expected_issuer, {:streaming, total, [chunk | chunks]})
    end
  end

  defp decide_body({:streaming, _bytes, chunks}, expected_issuer) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case Jason.decode(body) do
      {:ok, %{"issuer" => ^expected_issuer}} -> :ok
      _other -> {:error, :not_found}
    end
  end

  defp decide_body(:awaiting, _expected_issuer), do: {:error, :not_found}

  defp oversize_content_length?(headers) do
    case header(headers, "content-length") do
      nil ->
        false

      value ->
        case Integer.parse(value) do
          {length, ""} -> length > @max_body_bytes
          _unparseable -> true
        end
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == name, do: to_string(value)
    end)
  end

  defp cancel(request_id) do
    :httpc.cancel_request(request_id)
    :ok
  end
end
