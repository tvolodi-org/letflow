defmodule Letflow.LoginDiscovery.Notifier.SmtpSmokeTest do
  @moduledoc """
  Minimal smoke tests for the REQ-441 SMTP adapter against the in-process sink
  (`Letflow.Test.SmtpSink`). The full suite is TEST-DESIGNER's (step 03); these
  prove the adapter compiles, delivers, and fails closed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.LoginDiscovery.Notifier.Smtp.Message
  alias Letflow.Test.SmtpSink

  @namespace Letflow.LoginDiscovery.Notifier.Smtp
  @user_var "LETFLOW_SMTP_USERNAME"
  @pass_var "LETFLOW_SMTP_PASSWORD"
  # Obviously fake, built at compile time, never written as NAME=value text.
  @user "fake-user-" <> Base.encode16(:crypto.strong_rand_bytes(4))
  @pass "fake-pass-" <> Base.encode16(:crypto.strong_rand_bytes(6))

  @recipient "someone@example.org"
  @tenants [
    %{slug: "acme", display_name: "Acme Corp"},
    %{slug: "globex", display_name: "Globex <b>Ltd</b>"}
  ]

  setup do
    old_env = Application.get_env(:letflow, @namespace)
    old_user = System.get_env(@user_var)
    old_pass = System.get_env(@pass_var)
    System.put_env(@user_var, @user)
    System.put_env(@pass_var, @pass)

    on_exit(fn ->
      restore_app_env(old_env)
      restore_os_env(@user_var, old_user)
      restore_os_env(@pass_var, old_pass)
    end)

    :ok
  end

  defp restore_app_env(nil), do: Application.delete_env(:letflow, @namespace)
  defp restore_app_env(env), do: Application.put_env(:letflow, @namespace, env)
  defp restore_os_env(name, nil), do: System.delete_env(name)
  defp restore_os_env(name, value), do: System.put_env(name, value)

  defp configure(sink, host, tls, extra \\ []) do
    env =
      [
        host: host,
        port: sink.port,
        tls: tls,
        from: "noreply@mail.example.org",
        base_url: "https://app.example.org",
        socket_timeout_ms: 2_000,
        allow_test_cacerts: true
      ] ++ extra

    Application.put_env(:letflow, @namespace, env)
  end

  defp start_sink(script) do
    {:ok, sink} = SmtpSink.start(script)
    on_exit(fn -> SmtpSink.stop(sink) end)
    sink
  end

  test "conforms to the port" do
    assert Enum.sort(Letflow.LoginDiscovery.Notifier.behaviour_info(:callbacks)) ==
             [deliver_message: 1, deliver_tenant_list: 2]

    assert Letflow.LoginDiscovery.Notifier in (Smtp.module_info(:attributes)[:behaviour] || [])
  end

  test "delivers exactly one message to the typed recipient (plaintext loopback)" do
    sink = start_sink(:accept)
    configure(sink, "127.0.0.1", :none)

    assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok

    assert [message] = SmtpSink.messages(sink)
    assert message.rcpts == [@recipient]
    assert message.mail_from == "noreply@mail.example.org"
    assert message.data =~ "Content-Type: text/plain"
    assert message.data =~ "Subject: " <> Message.subject()
    assert message.data =~ "https://app.example.org/?realm=acme"
    assert message.data =~ "https://app.example.org/?realm=globex"
    assert message.data =~ "Acme Corp"

    SmtpSink.await_closed(sink)
    assert [transcript] = SmtpSink.transcripts(sink)
    assert transcript.ehlo == "mail.example.org"
    assert transcript.auth == [{@user, @pass}]
  end

  test "an SMTP rejection of the recipient is a typed error and one connection" do
    sink = start_sink({:refuse_rcpt, "SINKREPLYMARKER"})
    configure(sink, "127.0.0.1", :none)

    assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
    assert SmtpSink.connections(sink) == 1
  end

  test "a refused connection is a typed error" do
    sink = start_sink(:refuse_connection)
    configure(sink, "127.0.0.1", :none)

    assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
  end

  test "missing configuration is a typed error and opens no connection" do
    sink = start_sink(:accept)
    Application.delete_env(:letflow, @namespace)

    assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :not_configured}
    assert SmtpSink.connections(sink) == 0
  end

  test "an invalid recipient is rejected before any connection" do
    sink = start_sink(:accept)
    configure(sink, "127.0.0.1", :none)

    assert Smtp.deliver_tenant_list("a@b.c\r\nBcc: x@y.z", @tenants) ==
             {:error, :invalid_recipient}

    assert SmtpSink.connections(sink) == 0
  end

  describe "STARTTLS" do
    test "verified TLS succeeds with the trusted CA and the AUTH exchange is encrypted" do
      sink = start_sink({:starttls, :trusted})
      configure(sink, "localhost", :starttls, tls_cacerts: [sink.ca_der])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.tls?
      assert transcript.auth == [{@user, @pass}]
      assert [%{rcpts: [@recipient]}] = SmtpSink.messages(sink)
    end

    test "an untrusted certificate fails closed: no AUTH, no MAIL FROM" do
      sink = start_sink({:starttls, :untrusted})
      configure(sink, "localhost", :starttls, tls_cacerts: [sink.ca_der])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
      assert SmtpSink.connections(sink) == 1
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.auth == []
      assert transcript.mail_from == nil
    end

    test "the default (OS) trust store does not trust the test CA" do
      sink = start_sink({:starttls, :trusted})
      configure(sink, "localhost", :starttls, tls_cacerts: [])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.auth == []
      assert transcript.mail_from == nil
    end

    test "a server that does not offer STARTTLS is never downgraded to plaintext" do
      sink = start_sink(:no_starttls_offered)
      configure(sink, "localhost", :starttls)

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
      SmtpSink.await_closed(sink)
      assert [transcript] = SmtpSink.transcripts(sink)
      assert transcript.auth == []
      assert transcript.mail_from == nil
      assert transcript.rcpts == []
    end
  end

  test "no recipient, tenant, credential or reply text reaches a debug log" do
    ok = start_sink(:accept)
    refused = start_sink({:refuse_rcpt, "SINKREPLYMARKER"})
    untrusted = start_sink({:starttls, :untrusted})

    log =
      capture_log([level: :debug], fn ->
        configure(ok, "127.0.0.1", :none)
        assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok

        configure(refused, "127.0.0.1", :none)
        assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}

        configure(untrusted, "localhost", :starttls, tls_cacerts: [untrusted.ca_der])
        assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
      end)

    for secret <- [
          @recipient,
          @user,
          @pass,
          "SINKREPLYMARKER",
          "Acme",
          "Globex",
          "acme",
          "globex"
        ] do
      refute log =~ secret
    end
  end

  describe "retries" do
    test "a transient (4xx) failure is attempted exactly once" do
      sink = start_sink({:tempfail_rcpt, "try later"})
      configure(sink, "127.0.0.1", :none)

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
      Process.sleep(300)
      assert SmtpSink.connections(sink) == 1
    end

    test "a dropped connection after the greeting is attempted exactly once" do
      sink = start_sink(:drop_after_greeting)
      configure(sink, "127.0.0.1", :none)

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == {:error, :failed}
      Process.sleep(300)
      assert SmtpSink.connections(sink) == 1
    end
  end

  test "a brutal kill mid-call closes the socket and leaves no surviving process" do
    sink = start_sink(:hang)
    configure(sink, "127.0.0.1", :none)

    before_pids = MapSet.new(Process.list())
    task = Task.async(fn -> Smtp.deliver_tenant_list(@recipient, @tenants) end)
    Process.sleep(300)
    assert SmtpSink.open_connections(sink) == 1
    Task.shutdown(task, :brutal_kill)

    assert wait_until(fn -> SmtpSink.open_connections(sink) == 0 end)

    assert wait_until(fn ->
             MapSet.difference(MapSet.new(Process.list()), before_pids)
             |> Enum.all?(fn pid -> sink_or_dead?(pid, sink) end)
           end)
  end

  defp sink_or_dead?(pid, sink) do
    pid == sink.pid or pid == sink.acceptor or not Process.alive?(pid)
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && wait_until(fun, attempts - 1)
    end
  end
end
