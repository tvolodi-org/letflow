defmodule Letflow.Signup.EmailPolicyTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Signup.EmailPolicy

  @cfg %{disposable_domains: [], allow_domains: []}

  test "S6 seed domain, subdomain, case and trailing dot are blocked" do
    assert {:error, :email_not_accepted} = EmailPolicy.check("a@mailinator.com", @cfg)
    assert {:error, :email_not_accepted} = EmailPolicy.check("a@x.y.mailinator.com", @cfg)
    assert {:error, :email_not_accepted} = EmailPolicy.check("a@MAILINATOR.com.", @cfg)
  end

  test "S6 a look-alike suffix and ordinary domains pass" do
    assert :ok = EmailPolicy.check("a@notmailinator.com", @cfg)
    assert :ok = EmailPolicy.check("a@example.test", @cfg)
    assert :ok = EmailPolicy.check("not-an-address", @cfg)
  end

  test "S6 disposable_domains adds and allow_domains removes (allow wins)" do
    assert :ok = EmailPolicy.check("a@bad.test", @cfg)

    assert {:error, :email_not_accepted} =
             EmailPolicy.check("a@sub.bad.test", %{@cfg | disposable_domains: ["bad.test"]})

    assert :ok =
             EmailPolicy.check("a@mailinator.com", %{@cfg | allow_domains: ["mailinator.com"]})

    assert :ok =
             EmailPolicy.check("a@bad.test", %{
               disposable_domains: ["bad.test"],
               allow_domains: ["bad.test"]
             })
  end

  test "the seed is non-empty and lower-case" do
    assert MapSet.size(EmailPolicy.seed()) > 20
    assert Enum.all?(EmailPolicy.seed(), &(&1 == String.downcase(&1)))
  end
end
