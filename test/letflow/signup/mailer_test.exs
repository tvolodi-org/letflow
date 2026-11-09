defmodule Letflow.Signup.MailerTest do
  @moduledoc "T-1579 M1, M2, M4: the verification mail through the existing notifier adapter."

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Letflow.Test.SignupHelpers

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.Repo
  alias Letflow.Signup.Request

  setup do
    enable!()
    :ok
  end

  for lang <- ~w(ru kk en) do
    test "M1 one message in #{lang} with the base URL link" do
      assert post_signup(%{"language" => unquote(lang)}).status == 202
      assert_receive {:deliver_message, message}, 2_000
      refute_receive {:deliver_message, _}, 100
      assert message.to == "owner@example.test"
      assert message.body =~ base_url() <> "/signup/verify?token="
      assert message.subject == Letflow.Signup.Messages.verification(unquote(lang), "x").subject
    end
  end

  for {label, behaviour} <- [error: :error, raise: :raise, exit: :exit, timeout: {:sleep, 3_000}] do
    test "M2 adapter #{label}: 202 unchanged, last_error mail_failed" do
      Double.set_behaviour(unquote(Macro.escape(behaviour)))
      assert post_signup().status == 202
      assert await_mail(6_000) == :ok
      assert Repo.one!(Request).last_error == "mail_failed"
    end
  end

  test "M4 the shipped Noop adapter: 202, no crash" do
    previous = Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)

    Application.put_env(:letflow, Letflow.LoginDiscovery.Notifier,
      adapter: Letflow.LoginDiscovery.Notifier.Noop
    )

    on_exit(fn -> Application.put_env(:letflow, Letflow.LoginDiscovery.Notifier, previous) end)

    assert post_signup().status == 202
    assert await_mail() == :ok
    assert Repo.one!(Request).last_error == nil
  end
end
