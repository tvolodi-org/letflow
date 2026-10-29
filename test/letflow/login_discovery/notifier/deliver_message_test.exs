defmodule Letflow.LoginDiscovery.Notifier.DeliverMessageTest do
  @moduledoc """
  REQ-584 criterion 1: `deliver_message/1` on the notifier port (P1..P4) and the pure
  `Smtp.Message.compose_message/2`. `async: false`: application env, OS env and the sink.
  """

  use ExUnit.Case, async: false

  alias Letflow.LoginDiscovery.Notifier
  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.LoginDiscovery.Notifier.Smtp.Message
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @to "ann@example.org"
  @msg %{to: @to, subject: "Task assigned: Review", body: "Hello Ann\nline two"}

  test "P1 the port declares deliver_message/1 and every implementer exports it" do
    assert {:deliver_message, 1} in Notifier.behaviour_info(:callbacks)
    assert {:deliver_tenant_list, 2} in Notifier.behaviour_info(:callbacks)

    for mod <- [Smtp, Notifier.Noop, Letflow.LoginDiscoveryNotifierDouble] do
      Code.ensure_loaded!(mod)
      assert function_exported?(mod, :deliver_message, 1)
    end

    assert Notifier.Noop.deliver_message(@msg) == :ok
  end

  test "P2 only transport.ex names the mail library" do
    hits =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn file ->
        src = File.read!(file)
        src =~ ":gen_smtp_client" or src =~ ":mimemail"
      end)

    assert hits == ["lib/letflow/login_discovery/notifier/smtp/transport.ex"]
  end

  describe "Smtp.deliver_message/1" do
    test "P4 delivers one message to the sink with the body newlines kept" do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])

      assert Smtp.deliver_message(@msg) == :ok
      assert [%{rcpts: [@to], data: data}] = SmtpSink.messages(sink)
      assert data =~ "Subject: Task assigned: Review"
      assert data =~ "Hello Ann\r\nline two"
    end

    test "P4 not configured, bad recipient, bad message, transport failure" do
      S.delete_app_env!(Smtp)
      S.delete_os_env!(S.user_var())
      S.delete_os_env!(S.pass_var())
      assert Smtp.deliver_message(@msg) == {:error, :not_configured}

      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])
      assert Smtp.deliver_message(%{@msg | to: "bad address"}) == {:error, :invalid_recipient}

      assert Smtp.deliver_message(%{@msg | subject: String.duplicate("x", 201)}) ==
               {:error, :invalid_message}

      assert Smtp.deliver_message(%{@msg | body: ""}) == {:error, :invalid_message}
      assert Smtp.deliver_message(%{@msg | body: <<255, 254>>}) == {:error, :invalid_message}

      refuse = S.start_sink!(:refuse_connection)
      S.configure_smtp!(refuse, [])
      assert Smtp.deliver_message(@msg) == {:error, :failed}
    end
  end

  describe "Message.compose_message/2" do
    @opts %{from: "noreply@example.org"}

    test "keeps newlines, normalises CRLF, neutralises controls and bidi" do
      {:ok, composed} =
        Message.compose_message(
          %{
            to: @to,
            subject: "A\r\nBcc: x",
            body: "one\r\ntwo\rthree\u0000\u{202E}four a@b.c http://x"
          },
          @opts
        )

      assert composed.subject == "A  Bcc: x"
      assert composed.body == "one\ntwo\nthree four a@b.c http://x"
    end

    test "refuses non-binary or malformed input without raising" do
      assert {:error, :invalid_recipient} = Message.compose_message(%{@msg | to: nil}, @opts)
      assert {:error, :invalid_message} = Message.compose_message(@msg, %{from: "bad"})
      assert {:error, :invalid_message} = Message.compose_message(%{@msg | subject: "  "}, @opts)
      assert {:error, :invalid_message} = Message.compose_message(%{to: @to}, @opts)
    end
  end
end
