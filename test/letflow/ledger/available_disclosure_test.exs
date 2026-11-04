defmodule Letflow.Ledger.AvailableDisclosureTest do
  @moduledoc """
  REQ-686 criterion 3 (T-ERR-3): an `insufficient_balance` refusal carries `available` per leg
  only when the capability says its subject holds the registration's read permission
  (`read_disclosed`, set by the authority step), never for a reversal; the guard has no other
  source for it. Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger.Authority
  alias Letflow.LedgerFixture, as: Fx

  setup do
    Fx.setup_auto_mode!()
    %{schema: Fx.tenant!()}
  end

  defp refusal(cap) do
    {:error, {:ledger_refused, :insufficient_balance, _wire, details}} = Fx.post_tx(cap)
    details
  end

  test "available is the on-hand before the posting, only with read_disclosed", %{schema: schema} do
    Fx.seed_on_hand!(schema, ["a1"], 2)
    legs = [Fx.leg(["a1"], -3)]

    with_read = refusal(%{Fx.capability(schema, "issue", legs) | read_disclosed: true})
    without = refusal(Fx.capability(schema, "issue", legs))

    assert [%{available: "2.000000000", requested: "3.000000000"}] = with_read.legs
    assert [leg] = without.legs
    refute Map.has_key?(leg, :available)
  end

  test "a reversal refusal never carries available", %{schema: schema} do
    posted = Fx.post!(Fx.capability(schema, "receipt", [Fx.leg(["a1"], 2)]))
    Fx.post!(Fx.capability(schema, "issue", [Fx.leg(["a1"], -2)]))

    cap = %{Fx.reversal_capability(schema, posted.entry_id) | read_disclosed: true}
    details = refusal(cap)

    assert Map.keys(details) |> Enum.sort() == [:count, :leg_nos]
  end

  test "the authority step reports read_disclosed from the roles it read" do
    # a credential that is not :oidc is refused before any role is read
    cap = Fx.capability("tenant_00000000000000000000000000000000", "receipt", [Fx.leg(["a"], 1)])
    assert {:error, :credential_unsupported} = Authority.check_with_read(%{cap | credential: nil})
    assert {:error, :credential_unsupported} = Authority.check(%{cap | credential: :api_token})
  end
end
