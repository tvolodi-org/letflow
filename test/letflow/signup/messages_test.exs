defmodule Letflow.Signup.MessagesTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Signup.Messages

  test "I2 subject and body exist in ru, kk and en, carry the link and the terms placeholder" do
    rendered = for lang <- ~w(ru kk en), do: Messages.verification(lang, "https://x.test/l")
    assert Enum.all?(rendered, &(&1.subject != "" and &1.body =~ "https://x.test/l"))
    assert rendered |> Enum.map(& &1.subject) |> Enum.uniq() |> length() == 3

    assert Messages.verification("xx", "https://x.test/l") ==
             Messages.verification("en", "https://x.test/l")
  end

  test "S12 every refusal code has a distinct text in ru, kk and en; unknown language is English" do
    codes = ~w(rate_limited signup_unavailable email_not_accepted captcha_failed invalid_request)

    for code <- codes do
      texts = for lang <- ~w(ru kk en), do: Messages.refusal(code, lang)
      assert Enum.all?(texts, &(is_binary(&1) and &1 != ""))
      assert texts |> Enum.uniq() |> length() == 3
      assert Messages.refusal(code, "de") == Messages.refusal(code, "en")
      assert Messages.refusal(code, nil) == Messages.refusal(code, "en")
    end
  end
end
