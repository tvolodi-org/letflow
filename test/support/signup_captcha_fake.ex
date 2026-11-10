defmodule Letflow.Test.SignupCaptchaFake do
  @moduledoc "T-1620 test-only `Letflow.Signup.Captcha` adapter: the answer is read from the process dictionary-free app env."
  @behaviour Letflow.Signup.Captcha

  @impl true
  def verify(token, _ip) do
    send(Application.get_env(:letflow, :signup_captcha_fake_owner), {:captcha_token, token})

    case Application.get_env(:letflow, :signup_captcha_fake_answer, :ok) do
      :raise -> raise "boom"
      :exit -> exit(:timeout)
      answer -> answer
    end
  end
end
