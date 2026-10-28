defmodule Letflow.LoginDiscovery.Notifier.SmtpTest do
  @moduledoc """
  REQ-441 AC1 (behaviour conformance to the notifier port) and AC2 (delivery against an
  in-process SMTP sink), plus the design's TLS obligations (spec `test/specs/REQ-441.md`).

  The sink (`Letflow.Test.SmtpSink`) binds loopback only: no network egress. Every test
  that selects the `Smtp` adapter sets `timeout_ms` explicitly through
  `SmtpHelpers.configure_smtp!/2` (`config/test.exs` sets 1000, design s6.1 G3).
  `async: false`: application env, OS env and the sink.
  """

  use ExUnit.Case, async: false

  alias Letflow.LoginDiscovery.Notifier
  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.LoginDiscovery.Notifier.Smtp.Message
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink
  alias Letflow.Test.LoginDiscoveryHelpers, as: H

  @recipient "typed.address+tag@example.org"
  @tenants [
    %{slug: "acme-co", display_name: "Acme Corp"},
    %{slug: "globex", display_name: "Globex Ltd"}
  ]
  @closed_reasons [:not_configured, :invalid_recipient, :invalid_message, :failed]

  # ── AC1 ─────────────────────────────────────────────────────────────────

  describe "AC1: conformance to the Notifier port" do
    test "the port has the REQ-437 callback unchanged in shape plus the REQ-584 deliver_message/1" do
      assert Notifier.behaviour_info(:callbacks) |> Enum.sort() ==
               [deliver_message: 1, deliver_tenant_list: 2]

      assert Notifier.behaviour_info(:optional_callbacks) == []

      src = File.read!("lib/letflow/login_discovery/notifier.ex")
      assert length(Regex.scan(~r/^\s*@callback\b/m, src)) == 2
      refute src =~ "@optional_callbacks"
      assert src =~ "recipient_email :: String.t()"
      assert src =~ ":: :ok | {:error, term()}"
    end

    test "Smtp declares the behaviour, exports the callback and carries a matching @spec" do
      assert Notifier in (Smtp.module_info(:attributes)[:behaviour] || [])
      assert function_exported?(Smtp, :deliver_tenant_list, 2)

      {:ok, specs} = Code.Typespec.fetch_specs(Smtp)
      assert Enum.any?(specs, &match?({{:deliver_tenant_list, 2}, _}, &1))

      {:ok, callbacks} = Code.Typespec.fetch_callbacks(Notifier)

      assert callbacks |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               [{:deliver_message, 1}, {:deliver_tenant_list, 2}]
    end

    test "Smtp, Noop and the test double all implement exactly the port's callbacks" do
      for module <- [Smtp, Notifier.Noop, Letflow.LoginDiscoveryNotifierDouble] do
        assert Notifier in (module.module_info(:attributes)[:behaviour] || [])
        assert function_exported?(module, :deliver_tenant_list, 2)
      end
    end

    test "return shape :ok against an accepting sink" do
      S.configure_smtp!(S.start_sink!(:accept), [])
      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok
    end

    for {label, script} <- [
          rejected_recipient: {:refuse_rcpt, "REJECTED"},
          temporary_failure: {:tempfail_rcpt, "LATER"},
          refused_connection: :refuse_connection,
          dropped_after_greeting: :drop_after_greeting,
          untrusted_certificate: {:starttls, :untrusted},
          no_starttls: :no_starttls_offered
        ] do
      test "return shape {:error, reason} (reason in the closed set) against: #{label}" do
        sink = S.start_sink!(unquote(Macro.escape(script)))

        case unquote(Macro.escape(script)) do
          {:starttls, _} -> S.configure_smtp!(sink, host: "localhost", tls: :starttls)
          :no_starttls_offered -> S.configure_smtp!(sink, host: "localhost", tls: :starttls)
          _plain -> S.configure_smtp!(sink, [])
        end

        assert {:error, reason} = Smtp.deliver_tenant_list(@recipient, @tenants)
        assert reason in @closed_reasons
      end
    end

    test "pre-connection failures are typed errors from the closed set and open no connection" do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])

      assert Smtp.deliver_tenant_list("not an address", @tenants) == {:error, :invalid_recipient}

      assert Smtp.deliver_tenant_list(@recipient, [%{slug: "x", display_name: <<0xFF, 0xFE>>}]) ==
               {:error, :invalid_message}

      S.delete_os_env!(S.pass_var())
      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :not_configured}

      S.delete_app_env!(Smtp)
      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :not_configured}

      assert SmtpSink.connections(sink) == 0
    end

    test "a non-binary recipient or a malformed tenant list is an {:error, _}, never a raise" do
      S.configure_smtp!(S.start_sink!(:accept), [])

      assert {:error, reason} = Smtp.deliver_tenant_list(nil, @tenants)
      assert reason in @closed_reasons
      assert {:error, reason} = Smtp.deliver_tenant_list(@recipient, :not_a_list)
      assert reason in @closed_reasons
      assert {:error, reason} = Smtp.deliver_tenant_list(@recipient, [:not_a_map])
      assert reason in @closed_reasons
    end
  end

  # ── AC2 ─────────────────────────────────────────────────────────────────

  describe "AC2: delivery against the local sink" do
    test "a multi-tenant address's notifier task sends exactly one message to the typed address" do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])
      event = S.attach_notifier!()
      H.setup_limiter!([])

      assert S.submit_multi(@recipient, S.tenants()) == :ok
      assert {%{count: 1}, %{outcome: :delivered}} = S.next_event(event, 15_000)

      assert [message] = SmtpSink.messages(sink)
      assert message.rcpts == [@recipient]
      assert message.mail_from == S.sender()

      # the sink saw no other recipient on ANY connection, and one connection in total
      assert SmtpSink.connections(sink) == 1
      SmtpSink.await_closed(sink)
      assert SmtpSink.transcripts(sink) |> Enum.flat_map(& &1.rcpts) == [@recipient]

      # plain text, fixed subject, every active tenant's slug, name and base-URL link
      assert message.data =~ "Content-Type: text/plain"
      refute message.data =~ ~r/text\/html/i
      assert message.data =~ "Subject: " <> Message.subject() <> "\r\n"

      for tenant <- S.tenants() do
        assert message.data =~ ~s(Organisation: "#{tenant.display_name}")
        assert message.data =~ "Code: #{tenant.slug}"
        assert message.data =~ "Sign in: #{S.base_url()}/?realm=#{tenant.slug}"
      end

      # exactly the tenants given, nothing else listed
      assert length(Regex.scan(~r/^Code: /m, message.data)) == 2
    end

    test "the client presented the credentials to the SERVER and the EHLO identity is the sender's domain" do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok

      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      # this makes the "no password in any log" tests non-vacuous: the secret really was used
      assert transcript.auth == [{S.user(), S.pass()}]
      assert transcript.ehlo == "mail.example.org"
      refute transcript.ehlo =~ to_string(node())
    end

    test "a direct Smtp.deliver_tenant_list/2 call sends exactly one message and QUITs" do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok
      assert [%{rcpts: [@recipient]}] = SmtpSink.messages(sink)
      SmtpSink.await_closed(sink)
      assert [%{commands: commands}] = SmtpSink.transcripts(sink)
      assert List.first(commands) == "QUIT"
      assert Enum.count(commands, &(&1 == "DATA")) == 1
      assert Enum.count(commands, &(&1 == "RCPT")) == 1
    end

    test "the link is built from the configured base URL: a different base URL changes the link" do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])
      S.put_app_env!(Smtp, base_url: "https://login.other.example/app")

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok
      assert [message] = SmtpSink.messages(sink)
      assert message.data =~ "Sign in: https://login.other.example/app/?realm=acme-co"
      refute message.data =~ "app.example.org"
    end
  end

  # ── TLS obligations (design s6.2 "additional tests") ────────────────────

  describe "TLS" do
    test "STARTTLS with a trusted CA: delivered over TLS, the AUTH exchange is encrypted, SNI is the host" do
      sink = S.start_sink!({:starttls, :trusted})
      S.configure_smtp!(sink, host: "localhost", tls: :starttls, tls_cacerts: [sink.ca_der])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok

      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.tls?
      assert transcript.sni == "localhost"
      assert transcript.auth == [{S.user(), S.pass()}]
      assert [%{rcpts: [@recipient]}] = SmtpSink.messages(sink)
    end

    test "implicit TLS with a trusted CA: delivered, SNI is the host" do
      sink = S.start_sink!({:implicit_tls, :trusted})
      S.configure_smtp!(sink, host: "localhost", tls: :tls, tls_cacerts: [sink.ca_der])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.tls?
      assert transcript.sni == "localhost"
      assert transcript.auth == [{S.user(), S.pass()}]
    end

    test "implicit TLS with an untrusted certificate fails closed: no AUTH, no MAIL FROM" do
      sink = S.start_sink!({:implicit_tls, :untrusted})
      S.configure_smtp!(sink, host: "localhost", tls: :tls, tls_cacerts: [sink.ca_der])

      assert {:error, :failed} = Smtp.deliver_tenant_list(@recipient, @tenants)
      assert SmtpSink.messages(sink) == []

      SmtpSink.await_closed(sink)

      for transcript <- SmtpSink.transcripts(sink) do
        assert transcript.auth == []
        assert transcript.mail_from == nil
      end
    end

    test "verification is ON by default: the same trusted server fails without the test CA override" do
      sink = S.start_sink!({:starttls, :trusted})
      S.configure_smtp!(sink, host: "localhost", tls: :starttls)

      assert {:error, :failed} = Smtp.deliver_tenant_list(@recipient, @tenants)
      assert SmtpSink.messages(sink) == []
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.auth == []
      assert transcript.mail_from == nil
    end

    test "an untrusted certificate fails closed even when a (different) CA is supplied" do
      sink = S.start_sink!({:starttls, :untrusted})
      S.configure_smtp!(sink, host: "localhost", tls: :starttls, tls_cacerts: [sink.ca_der])

      assert {:error, :failed} = Smtp.deliver_tenant_list(@recipient, @tenants)
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.auth == []
      assert transcript.mail_from == nil
    end

    test "a hostname that does not match the certificate fails closed (hostname verification)" do
      sink = S.start_sink!({:starttls, :trusted})
      # reachable by address, but the certificate names `localhost`: the name check must fail
      S.configure_smtp!(sink,
        host: "127.0.0.1",
        tls: :starttls,
        tls_cacerts: [sink.ca_der]
      )

      assert {:error, :failed} = Smtp.deliver_tenant_list(@recipient, @tenants)
      assert SmtpSink.messages(sink) == []
    end

    test "fail-closed STARTTLS: a server that never offers it gets no MAIL FROM, no AUTH, no password" do
      sink = S.start_sink!(:no_starttls_offered)
      S.configure_smtp!(sink, host: "localhost", tls: :starttls)

      assert {:error, :failed} = Smtp.deliver_tenant_list(@recipient, @tenants)

      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.auth == []
      assert transcript.mail_from == nil
      assert transcript.rcpts == []
      refute "AUTH" in transcript.commands
      refute "MAIL" in transcript.commands
      refute "DATA" in transcript.commands
    end
  end
end
