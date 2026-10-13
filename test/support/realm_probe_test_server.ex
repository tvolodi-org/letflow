defmodule Letflow.Support.RealmProbeTestServer do
  @moduledoc """
  Scripted local HTTP/1.1 (optionally TLS) server for the
  `Letflow.Oidc.RealmProbe.Httpc` tests (ISS-1030,
  `test/letflow/oidc/realm_probe_test.exs`) and the router test that drives the
  real adapter.

  Raw `:gen_tcp` / `:ssl`, same precedent as `Letflow.WebhookTestServer` and
  `Letflow.Support.MockOidcProvider`: no new dependency, and the test controls
  every byte, which the probe's properties (redirect refusal, 64 KiB cap by
  content-length and by chunks, `content-range`, request id matching) need.

  `start/2` takes a responder `fn request -> spec end` that runs in the
  per-connection handler process. `request` is
  `%{method:, path:, headers: [{lower_case_name, value}], base_url:, owner:}`;
  `spec` is

    * `{:respond, parts}` -- send each binary of `parts` in order, then close;
    * `{:hold, parts}` -- send `parts`, then keep the connection open until the
      client closes it (a body that never arrives, a hang).

  Messages sent to the test (owner) process, in this order per connection:

    * `{:realm_probe_server, :request, request}` -- BEFORE the responder runs and
      before any byte is written, so by the time the probe has an answer every
      request it ever made is already in the owner's mailbox;
    * `{:realm_probe_server, :closed, path}` -- the client closed a `:hold`
      connection (proves a cancel really closed the socket).

  Every listener binds `127.0.0.1` on an OS-assigned port and is closed by an
  `on_exit` callback registered here; no fixed ports.
  """

  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          base_url: String.t(),
          owner: pid()
        }
  @type response_spec :: {:respond, [binary()]} | {:hold, [binary()]}
  @type started :: %{base_url: String.t(), port: pos_integer(), listen: term()}

  @read_timeout_ms 10_000

  # --- Start -----------------------------------------------------------------

  @doc """
  Starts a plain-HTTP server (`opts == []`) or a TLS server
  (`opts == [tls: ssl_server_options, host: "localhost"]`; the base URL then
  names `host` over `https`).
  """
  @spec start((request() -> response_spec()), keyword()) :: started()
  def start(responder, opts) when is_function(responder, 1) and is_list(opts) do
    owner = self()
    tls = Keyword.get(opts, :tls)
    host = Keyword.get(opts, :host, "127.0.0.1")

    {transport, listen, port} = listen(tls)
    scheme = if tls, do: "https", else: "http"
    base_url = "#{scheme}://#{host}:#{port}"

    acceptor =
      spawn_link(fn -> accept_loop(transport, listen, responder, owner, base_url) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      transport.close(listen)
    end)

    %{base_url: base_url, port: port, listen: listen}
  end

  @doc """
  A base URL pointing at a port that was bound and immediately closed, so a
  connection attempt is refused (a transport error, no server involved).
  """
  @spec refused_base_url() :: String.t()
  def refused_base_url do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}"
  end

  defp listen(nil) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    {:gen_tcp, listen, port}
  end

  defp listen(ssl_options) when is_list(ssl_options) do
    {:ok, listen} =
      :ssl.listen(
        0,
        [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ ssl_options
      )

    {:ok, {_ip, port}} = :ssl.sockname(listen)
    {:ssl, listen, port}
  end

  # --- Accept / handle -------------------------------------------------------

  defp accept_loop(transport, listen, responder, owner, base_url) do
    case accept(transport, listen) do
      {:ok, socket} ->
        handler =
          spawn(fn ->
            receive do
              :go -> handle(transport, socket, responder, owner, base_url)
            end
          end)

        _ = transport.controlling_process(socket, handler)
        send(handler, :go)
        accept_loop(transport, listen, responder, owner, base_url)

      {:error, _reason} ->
        :ok
    end
  end

  defp accept(:gen_tcp, listen), do: :gen_tcp.accept(listen)
  defp accept(:ssl, listen), do: :ssl.transport_accept(listen)

  defp handle(transport, socket, responder, owner, base_url) do
    with {:ok, socket} <- handshake(transport, socket),
         {:ok, head} <- read_head(transport, socket, ""),
         {:ok, request} <- parse_head(head, owner, base_url) do
      send(owner, {:realm_probe_server, :request, request})

      case responder.(request) do
        {:respond, parts} ->
          write(transport, socket, parts)
          transport.close(socket)

        {:hold, parts} ->
          write(transport, socket, parts)
          await_close(transport, socket, request.path, owner)
      end
    else
      _handshake_or_read_failed -> :ok
    end
  end

  defp handshake(:gen_tcp, socket), do: {:ok, socket}

  defp handshake(:ssl, socket) do
    case :ssl.handshake(socket, @read_timeout_ms) do
      {:ok, ssl_socket} -> {:ok, ssl_socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_head(transport, socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case transport.recv(socket, 0, @read_timeout_ms) do
        {:ok, data} -> read_head(transport, socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_head(head, owner, base_url) do
    [head_text | _body] = String.split(head, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head_text, "\r\n")

    case String.split(request_line, " ", parts: 3) do
      [method, path, _version] ->
        headers =
          for line <- header_lines,
              [name, value] <- [String.split(line, ":", parts: 2)],
              do: {String.downcase(name), String.trim(value)}

        {:ok, %{method: method, path: path, headers: headers, base_url: base_url, owner: owner}}

      _malformed ->
        {:error, :malformed_request}
    end
  end

  # A cancelled/closed client makes `send` fail: that is expected, ignore it.
  defp write(transport, socket, parts) do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      case transport.send(socket, part) do
        :ok -> {:cont, :ok}
        {:error, _closed} -> {:halt, :closed}
      end
    end)
  end

  defp await_close(transport, socket, path, owner) do
    case transport.recv(socket, 0, @read_timeout_ms) do
      {:error, :closed} ->
        send(owner, {:realm_probe_server, :closed, path})

      {:ok, _unexpected_data} ->
        await_close(transport, socket, path, owner)

      {:error, _other} ->
        transport.close(socket)
    end
  end

  # --- Response builders -----------------------------------------------------

  @doc "A complete response with a `content-length` computed from `body`."
  @spec response(pos_integer(), [{String.t(), String.t()}], iodata()) :: binary()
  def response(status, headers, body) do
    body = IO.iodata_to_binary(body)

    head(status, [{"content-length", Integer.to_string(byte_size(body))} | headers]) <> body
  end

  @doc "A status line plus headers and the blank line (the caller supplies any length header)."
  @spec head(pos_integer(), [{String.t(), String.t()}]) :: binary()
  def head(status, headers) do
    lines =
      ["HTTP/1.1 #{status} #{reason(status)}"] ++
        Enum.map(headers ++ [{"connection", "close"}], fn {k, v} -> "#{k}: #{v}" end)

    Enum.join(lines, "\r\n") <> "\r\n\r\n"
  end

  @doc "One `Transfer-Encoding: chunked` chunk."
  @spec chunk(binary()) :: binary()
  def chunk(data) when is_binary(data) do
    Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"
  end

  @doc "The terminating chunk."
  @spec last_chunk() :: binary()
  def last_chunk, do: "0\r\n\r\n"

  @doc "Splits `binary` into pieces of at most `size` bytes."
  @spec split_binary_every(binary(), pos_integer()) :: [binary()]
  def split_binary_every(<<>>, _size), do: []

  def split_binary_every(binary, size) when byte_size(binary) <= size, do: [binary]

  def split_binary_every(binary, size) do
    <<piece::binary-size(^size), rest::binary>> = binary
    [piece | split_binary_every(rest, size)]
  end

  defp reason(200), do: "OK"
  defp reason(206), do: "Partial Content"
  defp reason(302), do: "Found"
  defp reason(404), do: "Not Found"
  defp reason(500), do: "Internal Server Error"
  defp reason(_other), do: "Response"

  # --- Config seams ----------------------------------------------------------

  @doc """
  Points `config :letflow, :oidc, :keycloak_base_url` at `base_url` for the rest
  of the calling test (restored by `on_exit`). Application config is VM-global:
  every module using this must be `async: false`.
  """
  @spec put_base_url!(String.t() | nil) :: :ok
  def put_base_url!(base_url) do
    original = Application.fetch_env!(:letflow, :oidc)
    Application.put_env(:letflow, :oidc, Keyword.put(original, :keycloak_base_url, base_url))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)
    :ok
  end

  @doc """
  Replaces the configured realm probe adapter with the real
  `Letflow.Oidc.RealmProbe.Httpc` for the rest of the calling test (restored by
  `on_exit`).
  """
  @spec use_real_probe!() :: :ok
  def use_real_probe! do
    original = Application.fetch_env(:letflow, :oidc_realm_probe)
    Application.put_env(:letflow, :oidc_realm_probe, Letflow.Oidc.RealmProbe.Httpc)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:letflow, :oidc_realm_probe, value)
        :error -> Application.delete_env(:letflow, :oidc_realm_probe)
      end
    end)

    :ok
  end
end
