defmodule Letflow.Test.SmtpSink do
  @moduledoc """
  In-process SMTP sink for the REQ-441 adapter tests (design
  `req441-mail-notifier-adapter.md` s6.1). Test support only; never referenced from
  `lib/`.

  A `:gen_tcp` listener on `127.0.0.1` with an OS-assigned port (no network egress).
  One acceptor process, one handler process per connection. Reads are LINE
  oriented (`packet: :line`), so no bytes read alongside a command can be discarded
  (the buffer-threading hazard in `docs/anti-patterns.md`); the DATA section is read
  line by line up to the `.` terminator.

  Scripts (`start/1`):

    * `:accept` -- greet, EHLO (AUTH PLAIN LOGIN), AUTH, MAIL, RCPT, DATA, queue
    * `{:refuse_rcpt, text}` -- `550 <text> <rcpt>` at RCPT TO
    * `{:tempfail_rcpt, text}` -- `450 <text> <rcpt>` at RCPT TO
    * `:refuse_connection` -- the port is bound but never listening: the OS refuses the
      connection and no other process can take the port number
    * `:drop_after_greeting` -- `220`, then close
    * `{:starttls, :trusted | :untrusted}` -- advertise STARTTLS (AUTH only after the
      upgrade) with a certificate for `localhost`; `ca_der` in the returned map is the
      CA the client must trust: the issuing root for `:trusted`, an unrelated root for
      `:untrusted`
    * `{:implicit_tls, :trusted | :untrusted}` -- TLS from the first byte (no STARTTLS
      step), same certificate rules as `{:starttls, _}`
    * `:no_starttls_offered` -- like `:accept`, STARTTLS never advertised
    * `:hang` -- accept and never reply
    * `:slow_drip` -- every reply one byte at a time with a delay

  Per connection it records the command verbs, EHLO argument, decoded AUTH
  credentials, MAIL FROM, RCPT TO list, the raw DATA and whether TLS was used.
  """

  @type script ::
          :accept
          | {:refuse_rcpt, String.t()}
          | {:tempfail_rcpt, String.t()}
          | :refuse_connection
          | :drop_after_greeting
          | {:starttls, :trusted | :untrusted}
          | {:implicit_tls, :trusted | :untrusted}
          | :no_starttls_offered
          | :hang
          | :slow_drip

  @spec start(script()) :: {:ok, map()}
  def start(:refuse_connection) do
    # T-1996: a listener that is merely closed frees its port number, and on a shared CI host
    # another process (a parallel partition's sink, an outgoing ephemeral connection) can
    # take it, so the "refused" connection hangs until the 10 s hard timeout (the flaky
    # NotifierNoLeakTest case). Keep the port BOUND but never listening instead: the OS
    # answers a connect with RST (ECONNREFUSED) and nobody else can bind it. The store agent
    # owns the socket, so it is released when the sink's store ends.
    {:ok, store} =
      Agent.start_link(fn ->
        {:ok, sock} = :socket.open(:inet, :stream)
        :ok = :socket.bind(sock, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
        {:ok, %{port: port}} = :socket.sockname(sock)
        # held in the agent's process dictionary: the agent state stays the (empty)
        # connection map every reader of the store expects
        Process.put(:reserved_socket, sock)
        Process.put(:reserved_port, port)
        %{}
      end)

    port = Agent.get(store, fn _ -> Process.get(:reserved_port) end)
    {:ok, %{port: port, pid: store, acceptor: nil, lsock: nil, ca_der: nil}}
  end

  def start(script) do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    tls = tls_material(script)

    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true,
        backlog: 128
      ])

    {:ok, port} = :inet.port(lsock)
    ca_der = tls && tls.ca_der

    acceptor = spawn_link(fn -> accept_loop(lsock, script, tls, store, 1) end)
    {:ok, %{port: port, pid: store, acceptor: acceptor, lsock: lsock, ca_der: ca_der}}
  end

  @doc "One record per message-bearing connection: `%{mail_from, rcpts, data}`."
  @spec messages(map()) :: [map()]
  def messages(%{pid: store}) do
    for {_id, %{data: data} = conn} when is_binary(data) <- Agent.get(store, & &1) |> Enum.sort() do
      Map.take(conn, [:mail_from, :rcpts, :data])
    end
  end

  @doc "All per-connection transcripts, oldest first."
  @spec transcripts(map()) :: [map()]
  def transcripts(%{pid: store}) do
    store |> Agent.get(& &1) |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Blocks until every connection the sink has accepted so far has been fully recorded,
  i.e. its handler process has finished (its last command is in `commands`, `open?` is
  `false`). Returns `:ok`; raises with the still-open connections' commands if that does
  not happen within `timeout_ms`.

  Why it exists: a client returns as soon as it has *sent* QUIT, which can be before the
  handler has received and recorded it, so a transcript read straight after a delivery
  may be missing its tail (the ISS-0996 race). No polling and no sleeping: it monitors
  each still-open handler and waits for the `:DOWN`; the handler records `open?: false`
  (synchronously) in its `after` block, before it exits, so the `:DOWN` happens-after
  the final transcript write.

  Do NOT call it for a script whose connection is deliberately left open (`:hang`,
  `:slow_drip` mid-flight): the handler only ends when the client closes.
  """
  @spec await_closed(map(), timeout()) :: :ok
  def await_closed(%{pid: store} = sink, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    pending =
      for {id, %{open?: true, handler: handler}} when is_pid(handler) <- Agent.get(store, & &1),
          do: {id, handler, Process.monitor(handler)}

    # Every record is inserted together with its handler pid (see `accept_loop/5`), so an
    # `open?: true` record always has a pid handler here. A connection the acceptor has
    # accepted but not yet recorded at all is not visible to `open_connections/1` either.
    Enum.each(pending, fn {_id, handler, ref} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^handler, _reason} -> :ok
      after
        remaining ->
          Enum.each(pending, fn {_i, _h, r} -> Process.demonitor(r, [:flush]) end)

          open =
            for {id, %{open?: true} = c} <- Agent.get(store, & &1), do: {id, c.commands}

          raise "SmtpSink.await_closed/2: connection(s) still open after #{timeout_ms}ms " <>
                  "(id, commands newest-first): #{inspect(open)} for sink port #{sink.port}"
      end
    end)

    :ok
  end

  @spec connections(map()) :: non_neg_integer()
  def connections(%{pid: store}), do: Agent.get(store, &map_size/1)

  @spec open_connections(map()) :: non_neg_integer()
  def open_connections(%{pid: store}) do
    Agent.get(store, fn conns -> Enum.count(conns, fn {_id, c} -> c.open? end) end)
  end

  @doc """
  The highest number of connections that were open at the same moment (computed from
  the recorded open/close instants; a still-open connection counts as open until now).
  """
  @spec peak_open_connections(map()) :: non_neg_integer()
  def peak_open_connections(%{pid: store}) do
    now = System.monotonic_time(:millisecond)

    events =
      store
      |> Agent.get(& &1)
      |> Enum.flat_map(fn {_id, c} -> [{c.opened_at, 1}, {c.closed_at || now + 1, -1}] end)
      # at the same instant a close sorts before an open, so back-to-back is not overlap
      |> Enum.sort_by(fn {at, delta} -> {at, delta} end)

    events
    |> Enum.reduce({0, 0}, fn {_at, delta}, {current, peak} ->
      current = current + delta
      {current, max(peak, current)}
    end)
    |> elem(1)
  end

  @spec stop(map()) :: :ok
  def stop(%{pid: store, acceptor: acceptor, lsock: lsock}) do
    if lsock, do: :gen_tcp.close(lsock)
    if acceptor, do: Process.exit(acceptor, :kill)
    if Process.alive?(store), do: Agent.stop(store)
    :ok
  catch
    :exit, _ -> :ok
  end

  # -- acceptor / handler -----------------------------------------------------

  defp accept_loop(lsock, script, tls, store, id) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        handler =
          spawn(fn ->
            receive do
              :go -> handle(sock, script, tls, store, id)
            end
          end)

        # Atomic registration (ISS-1019): the record is inserted already carrying the
        # handler pid, in ONE Agent call, so no reader can ever observe an open record
        # whose handler is `nil`. The handler is parked on `:go` until then, so its
        # `after` write (`open?: false`) always finds the record.
        Agent.update(store, &Map.put(&1, id, %{new_conn() | handler: handler}))
        :gen_tcp.controlling_process(sock, handler)
        send(handler, :go)
        accept_loop(lsock, script, tls, store, id + 1)

      {:error, _closed} ->
        :ok
    end
  end

  defp new_conn do
    %{
      open?: true,
      handler: nil,
      tls?: false,
      ehlo: nil,
      commands: [],
      auth: [],
      mail_from: nil,
      rcpts: [],
      data: nil,
      sni: nil,
      opened_at: System.monotonic_time(:millisecond),
      closed_at: nil
    }
  end

  defp update(store, id, fun), do: Agent.update(store, &Map.update!(&1, id, fun))

  defp handle(sock, script, tls, store, id) do
    t = {:gen_tcp, sock}

    try do
      case script do
        :hang ->
          # Never reply; return when the client gives up and closes.
          :gen_tcp.recv(sock, 0, :infinity)

        :drop_after_greeting ->
          reply(t, script, "220 sink ESMTP\r\n")

        _other ->
          t = implicit_tls(t, script, tls, store, id)
          reply(t, script, "220 sink ESMTP\r\n")

          session(%{
            t: t,
            script: script,
            tls: tls,
            store: store,
            id: id,
            tls?: match?({:ssl, _}, t)
          })
      end
    catch
      _kind, _reason -> :ok
    after
      close(t)
      update(store, id, &%{&1 | open?: false})
    end
  end

  # `{:implicit_tls, kind}`: TLS from the first byte (before the greeting). A failed
  # handshake (a verifying client aborting) ends the handler through the `catch` above.
  defp implicit_tls({:gen_tcp, sock}, {:implicit_tls, _kind}, tls, store, id) do
    :ok = :inet.setopts(sock, packet: :raw)
    opts = [sni_fun: sni_recorder(store, id)] ++ tls.server_opts

    case :ssl.handshake(sock, opts, 5_000) do
      {:ok, ssl} ->
        :ok = :ssl.setopts(ssl, packet: :line)
        update(store, id, &%{&1 | tls?: true})
        {:ssl, ssl}

      {:error, _verify_or_closed} ->
        throw(:tls_handshake_failed)
    end
  end

  defp implicit_tls(t, _script, _tls, _store, _id), do: t

  # Records the TLS server name the client sent (SNI); `:undefined` keeps the default
  # certificate for every name.
  defp sni_recorder(store, id) do
    fn host ->
      update(store, id, &%{&1 | sni: List.to_string(host)})
      :undefined
    end
  end

  defp session(ctx) do
    case recv(ctx.t) do
      {:ok, line} ->
        update(ctx.store, ctx.id, &%{&1 | commands: [verb(line) | &1.commands]})
        command(String.trim_trailing(line), ctx)

      {:error, _closed} ->
        :ok
    end
  end

  defp verb(line),
    do: line |> String.split(" ", parts: 2) |> hd() |> String.trim() |> String.upcase()

  defp command("EHLO " <> arg, ctx) do
    update(ctx.store, ctx.id, &%{&1 | ehlo: arg})
    starttls? = match?({:starttls, _}, ctx.script) and not ctx.tls?
    auth? = not (match?({:starttls, _}, ctx.script) and not ctx.tls?)

    lines =
      ["250-sink"] ++
        if(starttls?, do: ["250-STARTTLS"], else: []) ++
        if(auth?, do: ["250-AUTH PLAIN LOGIN"], else: []) ++ ["250 8BITMIME"]

    reply(ctx.t, ctx.script, Enum.join(lines, "\r\n") <> "\r\n")
    session(ctx)
  end

  defp command("STARTTLS", %{script: {:starttls, _}, tls: tls} = ctx) do
    reply(ctx.t, ctx.script, "220 ready\r\n")
    {:gen_tcp, sock} = ctx.t
    :ok = :inet.setopts(sock, packet: :raw)

    case :ssl.handshake(
           sock,
           [sni_fun: sni_recorder(ctx.store, ctx.id)] ++ tls.server_opts,
           5_000
         ) do
      {:ok, ssl} ->
        :ok = :ssl.setopts(ssl, packet: :line)
        update(ctx.store, ctx.id, &%{&1 | tls?: true})
        session(%{ctx | t: {:ssl, ssl}, tls?: true})

      {:error, _verify_or_closed} ->
        :ok
    end
  end

  defp command("AUTH PLAIN " <> b64, ctx) do
    [_authzid, user, pass] = b64 |> Base.decode64!() |> String.split(<<0>>)
    update(ctx.store, ctx.id, &%{&1 | auth: [{user, pass} | &1.auth]})
    reply(ctx.t, ctx.script, "235 2.7.0 ok\r\n")
    session(ctx)
  end

  defp command("AUTH LOGIN", ctx) do
    reply(ctx.t, ctx.script, "334 VXNlcm5hbWU6\r\n")
    {:ok, user_line} = recv(ctx.t)
    reply(ctx.t, ctx.script, "334 UGFzc3dvcmQ6\r\n")
    {:ok, pass_line} = recv(ctx.t)
    user = user_line |> String.trim() |> Base.decode64!()
    pass = pass_line |> String.trim() |> Base.decode64!()
    update(ctx.store, ctx.id, &%{&1 | auth: [{user, pass} | &1.auth]})
    reply(ctx.t, ctx.script, "235 2.7.0 ok\r\n")
    session(ctx)
  end

  defp command("MAIL FROM:" <> addr, ctx) do
    update(ctx.store, ctx.id, &%{&1 | mail_from: strip_angle(addr)})
    reply(ctx.t, ctx.script, "250 ok\r\n")
    session(ctx)
  end

  defp command("RCPT TO:" <> addr, ctx) do
    addr = strip_angle(addr)

    case ctx.script do
      {:refuse_rcpt, text} ->
        reply(ctx.t, ctx.script, "550 #{text} #{addr}\r\n")

      {:tempfail_rcpt, text} ->
        reply(ctx.t, ctx.script, "450 #{text} #{addr}\r\n")

      _accept ->
        update(ctx.store, ctx.id, &%{&1 | rcpts: &1.rcpts ++ [addr]})
        reply(ctx.t, ctx.script, "250 ok\r\n")
    end

    session(ctx)
  end

  defp command("DATA", ctx) do
    reply(ctx.t, ctx.script, "354 go ahead\r\n")
    data = read_data(ctx.t, [])
    update(ctx.store, ctx.id, &%{&1 | data: data})
    reply(ctx.t, ctx.script, "250 2.0.0 queued\r\n")
    session(ctx)
  end

  defp command("QUIT", ctx), do: reply(ctx.t, ctx.script, "221 bye\r\n")

  defp command(_unknown, ctx) do
    reply(ctx.t, ctx.script, "500 unrecognised\r\n")
    session(ctx)
  end

  defp read_data(t, acc) do
    {:ok, line} = recv(t)

    if line == ".\r\n" do
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    else
      read_data(t, [line | acc])
    end
  end

  defp strip_angle(addr),
    do: addr |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

  # -- wire helpers -----------------------------------------------------------

  defp reply(t, :slow_drip, data) do
    for <<byte <- data>> do
      send_raw(t, <<byte>>)
      Process.sleep(100)
    end

    :ok
  end

  defp reply(t, _script, data), do: send_raw(t, data)

  defp send_raw({:gen_tcp, s}, data), do: :gen_tcp.send(s, data)
  defp send_raw({:ssl, s}, data), do: :ssl.send(s, data)

  defp recv({:gen_tcp, s}), do: :gen_tcp.recv(s, 0, 60_000)
  defp recv({:ssl, s}), do: :ssl.recv(s, 0, 60_000)

  # An upgraded (ssl) socket dies with this handler process, its owner.
  defp close({:gen_tcp, s}), do: :gen_tcp.close(s)

  # -- TLS material -----------------------------------------------------------

  defp tls_material({mode, kind}) when mode in [:starttls, :implicit_tls] do
    served = chain()
    other = chain()

    %{
      server_opts: served.server_config ++ [versions: [:"tlsv1.2", :"tlsv1.3"]],
      ca_der: if(kind == :trusted, do: root(served), else: root(other))
    }
  end

  defp tls_material(_script), do: nil

  # The library default key is a weak EC curve that TLS 1.3 will not use, so every
  # certificate gets an explicit prime256v1 key.
  defp chain do
    :public_key.pkix_test_data(%{
      server_chain: %{
        root: [key: ec_key(), digest: :sha256],
        peer: [
          key: ec_key(),
          digest: :sha256,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}]
        ]
      },
      client_chain: %{
        root: [key: ec_key(), digest: :sha256],
        peer: [key: ec_key(), digest: :sha256]
      }
    })
  end

  defp ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp root(%{client_config: config}), do: hd(Keyword.fetch!(config, :cacerts))
end
