defmodule Letflow.TenantProvisioner.LimitMessagesTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.TenantProvisioner.LimitMessages

  test "LM1 every limit has a distinct non-empty sentence in en, ru and kk; unknown falls back to en" do
    for which <- [:demo_cap, :source_budget, :email_domain_budget] do
      code = LimitMessages.code(which)
      texts = for l <- ~w(en ru kk), do: LimitMessages.text(code, l)
      assert Enum.all?(texts, &(&1 != ""))
      assert length(Enum.uniq(texts)) == 3
      assert LimitMessages.text(code, "de") == hd(texts)
    end

    assert LimitMessages.code(:demo_cap) == "demo_cap_reached"
  end
end
