defmodule Letflow.Oidc.RealmProbeTest do
  @moduledoc """
  ISS-1030 PR 1 -- `Letflow.Oidc.RealmProbe` and its default adapter
  `Letflow.Oidc.RealmProbe.Httpc` (design
  `lib/letflow/design/iss1030-onboarding-administrator.md` sections 3.1 item 5
  and 10.1, plus the SECURITY-REVIEWER additions listed in
  `test/specs/ISS-1030-PR1.md`).

  The adapter is driven directly (`Httpc.verify/1`, bypassing the
  `config/test.exs` double) against a scripted local server
  (`Letflow.Support.RealmProbeTestServer`: raw `:gen_tcp` / `:ssl`, OS-assigned
  ports). `async: false`: the Keycloak base URL and the CA store are VM-global.

  Exactly one test waits for the 3 s probe deadline (the hang case in "no stray
  http message ..."); every other path decides without waiting.

  """

  use ExUnit.Case, async: false

  alias Letflow.Oidc.RealmProbe
  alias Letflow.Oidc.RealmProbe.Httpc
  alias Letflow.Support.RealmProbeTestServer, as: Server

  @discovery_suffix "/.well-known/openid-configuration"
  @cap 64 * 1024

  # --- helpers ---------------------------------------------------------------

  defp realm, do: "probe-" <> String.replace(Ecto.UUID.generate(), "-", "")

  # The realm named by a request path ("/<optional prefix>/realms/<realm>/.well-known/...").
  defp realm_from(path) do
    path
    |> String.split("/realms/")
    |> List.last()
    |> String.replace_suffix(@discovery_suffix, "")
  end

  # The issuer a correct Keycloak would put in the discovery document for this request.
  defp issuer_from(request) do
    {"host", host} = List.keyfind(request.headers, "host", 0)
    [scheme, _rest] = String.split(request.base_url, "://", parts: 2)
    scheme <> "://" <> host <> String.replace_suffix(request.path, @discovery_suffix, "")
  end

  defp json_response(body), do: Server.response(200, [{"content-type", "application/json"}], body)

  defp ok_doc(request), do: Jason.encode!(%{"issuer" => issuer_from(request)})

  defp ok_responder, do: fn request -> {:respond, [json_response(ok_doc(request))]} end

  defp start_server!(responder) do
    server = Server.start(responder, [])
    Server.put_base_url!(server.base_url)
    server
  end

  # Messages in the test mailbox that are not the scripted server's own.
  defp stray_messages do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.reject(messages, &match?({:realm_probe_server, _kind, _data}, &1))
  end

  # --- the behaviour wrapper -------------------------------------------------

  test "RealmProbe.verify/1 delegates to the configured adapter" do
    # config/test.exs installs the double: the unknown/unreachable prefixes are its contract.
    assert RealmProbe.verify("some-realm") == :ok
    assert RealmProbe.verify("unknown-x") == {:error, :not_found}
    assert RealmProbe.verify("unreachable-x") == {:error, :unreachable}
    assert_received {:realm_probe, "some-realm"}
  end

  # --- design 10.1 -----------------------------------------------------------

  test "accepts a realm whose discovery issuer equals the expected issuer" do
    start_server!(ok_responder())
    probed = realm()

    assert Httpc.verify(probed) == :ok

    assert_received {:realm_probe_server, :request, %{method: "GET", path: path}}
    assert path == "/realms/#{probed}#{@discovery_suffix}"
  end

  test "does not follow a redirect: a 3xx answer is unreachable and the Location target is never requested" do
    start_server!(fn request ->
      case request.path do
        "/trap" ->
          {:respond, [json_response("{}")]}

        _discovery ->
          location = request.base_url <> "/trap"
          {:respond, [Server.head(302, [{"location", location}, {"content-length", "0"}])]}
      end
    end)

    assert Httpc.verify(realm()) == {:error, :unreachable}

    # The server writes a request message before it answers, so a followed
    # redirect would already be in the mailbox by the time verify/1 returned.
    assert_received {:realm_probe_server, :request, %{path: "/realms/" <> _rest}}
    refute_received {:realm_probe_server, :request, %{path: "/trap"}}
  end

  test "refuses a 200 response whose content-length exceeds 64 KiB, cancelling before reading the body" do
    start_server!(fn _request ->
      # Head only: the announced body never arrives. A probe that waited for
      # it would sit until its 3 s deadline.
      {:hold,
       [
         Server.head(200, [
           {"content-type", "application/json"},
           {"content-length", Integer.to_string(@cap + 1)}
         ])
       ]}
    end)

    assert Httpc.verify(realm()) == {:error, :unreachable}
    # The probe cancelled the request: the server saw its connection close.
    assert_receive {:realm_probe_server, :closed, _path}, 5_000
  end

  test "no stray http message remains in the caller mailbox after a cancel or a timeout" do
    # (1) A cancel: a chunked 200 that keeps sending far past the cap, so
    # messages for the cancelled request are still in flight afterwards.
    over_cap = Jason.encode!(%{"issuer" => "x", "pad" => String.duplicate("a", 320 * 1024)})

    start_server!(fn _request ->
      {:respond,
       [Server.head(200, [{"transfer-encoding", "chunked"}])] ++
         Enum.map(Server.split_binary_every(over_cap, 8 * 1024), &Server.chunk/1) ++
         [Server.last_chunk()]}
    end)

    assert Httpc.verify(realm()) == {:error, :unreachable}

    # (2) A timeout: the head is never answered.
    start_server!(fn _request -> {:hold, []} end)

    assert Httpc.verify(realm()) == {:error, :unreachable}

    assert stray_messages() == []
  end

  test "ignores http messages that carry another request id and never decides from them" do
    start_server!(fn request ->
      owner = request.owner

      # The probe runs in a Task linked to (and called from) the test process.
      task =
        Enum.find(Process.info(owner, :links) |> elem(1), fn pid ->
          is_pid(pid) and
            case Process.info(pid, :dictionary) do
              {:dictionary, dictionary} ->
                match?([^owner | _rest], Keyword.get(dictionary, :"$callers"))

              _gone ->
                false
            end
        end)

      true = is_pid(task)

      # Foreign request ids: an oversize stream start, an error, a huge chunk.
      send(task, {:http, {make_ref(), :stream_start, [{~c"content-length", ~c"9999999"}]}})
      send(task, {:http, {make_ref(), {:error, :boom}}})
      send(task, {:http, {make_ref(), :stream, String.duplicate("x", 4 * @cap)}})

      {:respond, [json_response(ok_doc(request))]}
    end)

    assert Httpc.verify(realm()) == :ok
    assert stray_messages() == []
  end

  test "rejects a server certificate whose host name does not match the base URL host" do
    matching = tls_material!("localhost")
    mismatched = tls_material!("other.example")

    # Control: a certificate for the right host, issued by a trusted CA, is accepted.
    # (Proves the failure below is the host name check and not an untrusted CA.)
    trust!(matching.root_ders)
    good = Server.start(ok_responder(), tls: matching.server, host: "localhost")
    Server.put_base_url!(good.base_url)
    assert Httpc.verify(realm()) == :ok

    # Same trusted-CA situation, but the certificate names another host.
    trust!(mismatched.root_ders)
    bad = Server.start(ok_responder(), tls: mismatched.server, host: "localhost")
    Server.put_base_url!(bad.base_url)
    assert Httpc.verify(realm()) == {:error, :unreachable}
  end

  test "an upper-case URL scheme is normalised and still gets peer and host name verification" do
    matching = tls_material!("localhost")
    mismatched = tls_material!("other.example")

    trust!(matching.root_ders)
    good = Server.start(ok_responder(), tls: matching.server, host: "localhost")
    Server.put_base_url!(String.replace_prefix(good.base_url, "https://", "HTTPS://"))
    assert Httpc.verify(realm()) == :ok

    trust!(mismatched.root_ders)
    bad = Server.start(ok_responder(), tls: mismatched.server, host: "localhost")
    Server.put_base_url!(String.replace_prefix(bad.base_url, "https://", "HTTPS://"))
    assert Httpc.verify(realm()) == {:error, :unreachable}
  end

  test "sends no Accept-Encoding header" do
    start_server!(ok_responder())

    assert Httpc.verify(realm()) == :ok

    assert_received {:realm_probe_server, :request, %{headers: headers}}
    refute List.keymember?(headers, "accept-encoding", 0)
    assert {"accept", "application/json"} in headers
  end

  test "strips a trailing slash of the base URL in both the request URL and the expected issuer" do
    server = Server.start(ok_responder(), [])
    Server.put_base_url!(server.base_url <> "/")
    probed = realm()

    # The responder derives the issuer from the path it was asked for: a
    # double slash in the URL would show up in the path AND break the match.
    assert Httpc.verify(probed) == :ok

    assert_received {:realm_probe_server, :request, %{path: path}}
    assert path == "/realms/#{probed}#{@discovery_suffix}"
  end

  test "a document whose issuer keeps the doubled slash of an unstripped base URL is not accepted" do
    server =
      Server.start(
        fn request ->
          naive = request.base_url <> "//realms/" <> realm_from(request.path)
          {:respond, [json_response(Jason.encode!(%{"issuer" => naive}))]}
        end,
        []
      )

    Server.put_base_url!(server.base_url <> "/")

    assert Httpc.verify(realm()) == {:error, :not_found}
  end

  test "refuses a chunked 200 response that grows past 64 KiB, cancelling the request without decoding" do
    base_doc_size = byte_size(Jason.encode!(%{"issuer" => "", "pad" => ""}))

    chunked_doc = fn request, total_size ->
      issuer = issuer_from(request)
      pad = String.duplicate("a", total_size - base_doc_size - byte_size(issuer))
      doc = Jason.encode!(%{"issuer" => issuer, "pad" => pad})

      {:respond,
       [Server.head(200, [{"transfer-encoding", "chunked"}])] ++
         Enum.map(Server.split_binary_every(doc, 8 * 1024), &Server.chunk/1) ++
         [Server.last_chunk()]}
    end

    # Control, exactly at the cap: accepted (the cap is "more than 64 KiB").
    start_server!(fn request -> chunked_doc.(request, @cap) end)
    assert Httpc.verify(realm()) == :ok

    # One byte over: refused, although the document is otherwise valid and
    # carries the right issuer (it must be cancelled, not decoded).
    start_server!(fn request -> chunked_doc.(request, @cap + 1) end)
    assert Httpc.verify(realm()) == {:error, :unreachable}

    # Far over, in many chunks.
    start_server!(fn request -> chunked_doc.(request, 4 * @cap) end)
    assert Httpc.verify(realm()) == {:error, :unreachable}
  end

  test "maps a 404, a 500 and a 206 to not_found, unreachable and unreachable and never decodes their bodies" do
    # Every body is a VALID discovery document with the right issuer: a probe
    # that decoded it would answer :ok.
    answer = fn request, status, extra_headers ->
      {:respond, [Server.response(status, extra_headers, ok_doc(request))]}
    end

    start_server!(fn request -> answer.(request, 404, []) end)
    assert Httpc.verify(realm()) == {:error, :not_found}

    start_server!(fn request -> answer.(request, 500, []) end)
    assert Httpc.verify(realm()) == {:error, :unreachable}

    start_server!(fn request ->
      answer.(request, 206, [{"content-range", "bytes 0-9/100"}])
    end)

    assert Httpc.verify(realm()) == {:error, :unreachable}
  end

  test "refuses a 200 response that is not a JSON object" do
    for body <- ["[1,2,3]", "\"just a string\"", "null", "not json {{"] do
      start_server!(fn _request -> {:respond, [json_response(body)]} end)

      assert Httpc.verify(realm()) == {:error, :not_found}, "body #{inspect(body)}"
    end
  end

  test "rejects a discovery document whose issuer differs" do
    start_server!(fn request ->
      realm_name = realm_from(request.path)
      other = String.replace_suffix(issuer_from(request), realm_name, "someone-else")
      {:respond, [json_response(Jason.encode!(%{"issuer" => other}))]}
    end)

    assert Httpc.verify(realm()) == {:error, :not_found}

    # A document with no issuer at all.
    no_issuer = ~s({"authorization_endpoint": "x"})
    start_server!(fn _request -> {:respond, [json_response(no_issuer)]} end)

    assert Httpc.verify(realm()) == {:error, :not_found}
  end

  test "maps a 404 to not_found and a closed or refused connection to unreachable" do
    start_server!(fn _request -> {:respond, [Server.response(404, [], "")]} end)
    assert Httpc.verify(realm()) == {:error, :not_found}

    # Connection closed without an answer.
    start_server!(fn _request -> {:respond, []} end)
    assert Httpc.verify(realm()) == {:error, :unreachable}

    # Connection refused. (The timeout branch is exercised, with its mailbox
    # check, in "no stray http message ...".)
    Server.put_base_url!(Server.refused_base_url())
    assert Httpc.verify(realm()) == {:error, :unreachable}
  end

  test "refuses a realm name outside the allowed alphabet before any request is made" do
    start_server!(ok_responder())

    outside = [
      "",
      "a/b",
      "a.b",
      ".",
      "..",
      "a b",
      "a%2Fb",
      "-x",
      "_x",
      String.duplicate("a", 65),
      "réalm",
      "a?b",
      "a#b"
    ]

    for bad <- outside do
      assert Httpc.verify(bad) == {:error, :not_found}, "realm #{inspect(bad)}"
    end

    refute_received {:realm_probe_server, :request, _request}
  end

  test "refuses a realm name with a trailing newline before any request is made" do
    # `$` in the probe's own alphabet regex also matches before a final "\n":
    # the layered defence must not rely on the router having trimmed first.
    start_server!(ok_responder())

    assert Httpc.verify("realm\n") == {:error, :not_found}
    refute_received {:realm_probe_server, :request, _request}
  end

  test "builds the URL only from the configured Keycloak base URL and the validated realm" do
    server = Server.start(ok_responder(), [])
    Server.put_base_url!(server.base_url <> "/auth")
    probed = "Realm_9-x"

    assert Httpc.verify(probed) == :ok

    assert_received {:realm_probe_server, :request, %{path: path, headers: headers}}
    assert path == "/auth/realms/#{probed}#{@discovery_suffix}"
    assert {"host", "127.0.0.1:#{server.port}"} in headers
  end

  # --- SECURITY-REVIEWER additions --------------------------------------------

  test "an unknown URL scheme and an unset base URL are unreachable and no request is made" do
    server = start_server!(ok_responder())

    # The live server's own port is used, so a probe that ignored the scheme or the
    # missing scheme would reach it and the refute below would fail.
    Server.put_base_url!("ftp://127.0.0.1:#{server.port}")
    assert Httpc.verify(realm()) == {:error, :unreachable}

    Server.put_base_url!("127.0.0.1:#{server.port}")
    assert Httpc.verify(realm()) == {:error, :unreachable}

    Server.put_base_url!(nil)
    assert Httpc.verify(realm()) == {:error, :unreachable}

    refute_received {:realm_probe_server, :request, _request}
  end

  test "an upper-case http scheme is normalised and probed over plain http" do
    server = Server.start(ok_responder(), [])
    Server.put_base_url!(String.replace_prefix(server.base_url, "http://", "HTTP://"))

    assert Httpc.verify(realm()) == :ok
    assert_received {:realm_probe_server, :request, _request}
  end

  # --- TLS fixtures ------------------------------------------------------------

  # A fresh root + server certificate whose only subjectAltName is `san_host`.
  defp tls_material!(san_host) do
    extension = {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(san_host)]}

    # The library default key is a weak EC curve that TLS 1.3 will not use, so every
    # certificate gets an explicit prime256v1 key (same fixture rule as smtp_sink.ex).
    %{server_config: server_config, client_config: client_config} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: ec_key(), digest: :sha256],
          peer: [key: ec_key(), digest: :sha256, extensions: [extension]]
        },
        client_chain: %{
          root: [key: ec_key(), digest: :sha256],
          peer: [key: ec_key(), digest: :sha256]
        }
      })

    %{
      server: server_config ++ [versions: [:"tlsv1.2", :"tlsv1.3"]],
      root_ders: Keyword.fetch!(client_config, :cacerts)
    }
  end

  defp ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  # Makes `:public_key.cacerts_get/0` (what the probe trusts) return exactly these roots.
  # The CA store is VM-global, so the previous contents are restored on exit instead
  # of being cleared (other modules read it through the default TLS options).
  defp trust!(root_ders) do
    previous = :public_key.cacerts_get()
    # Registered before the install, so a failing install still restores the store.
    ExUnit.Callbacks.on_exit(fn -> install_cacerts!(previous) end)
    install_cacerts!(root_ders)
  end

  defp install_cacerts!(entries) do
    # `cacerts_get/0` returns `{:cert, der, meta}` tuples on current OTP; plain DER is also accepted.
    ders =
      Enum.map(entries, fn
        {:cert, der, _meta} -> der
        der -> der
      end)

    path = Path.join(System.tmp_dir!(), "realm_probe_ca_#{Ecto.UUID.generate()}.pem")
    pem = :public_key.pem_encode(Enum.map(ders, &{:Certificate, &1, :not_encrypted}))
    File.write!(path, pem)
    :public_key.cacerts_clear()
    :ok = :public_key.cacerts_load(path)
    File.rm(path)
  end
end
