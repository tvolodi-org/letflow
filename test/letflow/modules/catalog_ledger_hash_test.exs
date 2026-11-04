defmodule Letflow.Modules.CatalogLedgerHashTest do
  @moduledoc """
  REQ-684 criterion 4: `Letflow.Modules.ManifestHash` covers the whole `:ledger` key and each
  handler's `posts_ledger`, only when present. The golden values below were computed by the
  origin/main code (556470996) before this change. Pure: no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureLedgerPost
  alias Letflow.Modules.ManifestHash

  @golden %{
    "Exam" => "992e5266d1b81a138684f50228c5a3429393dcb90fdd0bb0dfb1fa9646252d8a",
    "Org" => "caba62b2f3060c99ae03b3dcc2cdee841fded125aa92719f8ce74c77f39b9b11",
    "CatalogItems" => "d0e4882ffd3c14833715727d94bdc188897ca84e73a74c927048d19cb610eb9a",
    "Procurement" => "265b5841f1705989bacfdf2ca82385fa0c9d83ad462e3f257f0ac87060f8dd61",
    "Locations" => "a9f6b26a8d6df340267381c4a3025b7a8848eb0f02d288167b66d9134ba96116",
    "Codes" => "e572003cee0f261c8cd5ace7021ab5420ecb558aa0e15d571ef0ccf8d2928eb6",
    "Fixture" => "469c50f3420bc652af6afb8e24c202c8f455d486fb9524b6ca2c1fb61caa0b59",
    "FixtureDependent" => "42e4637c9404ced4a6545a77bc7334c2ca7f6fb7d1b50f747a71a9d7484b06b6",
    "FixtureFailingInstall" => "33e53980998a1ca1ce3cd6269ee9dd0e258b83c71317fdce3557de37c8ada7fe",
    "FixtureFkPack" => "4153467de65bdd4213a0be4c2454fd14ef107010aba975f0fafa7902027d7e73",
    "FixtureFkPackFailing" => "09c83c8ee15a697438a143786a7dcbf35a4a4d398f258f4a3cf64f3b84b5f978",
    "FixtureCtxRecorder" => "75a3f1581939926d14eaf520826688d00a6ebc5d1329b8d57f6067c99d4510d0",
    "FixtureManaged" => "84866adc83eee01abb7888c6ea98e12b7d22d4c98c1865a1b527f0b2b355f6b0",
    "FixtureManagedNoPack" => "47f329b517fdf6e1ed7e32822dae6d9756fbb0a53d5a74c76a2faab2bb04781f",
    "FixtureLedger" => "6394cff92f1f30f14e74d59a45bb7e272087160c7596e6078571fbfb6d8d866d",
    "FixtureLedgerOther" => "24aff18970d1b5c2629f71b46f7858a2fb2789e85d505710a2360a15353c9b22",
    "FixtureLedgerRogue" => "20f7d07cb2aa08e4e916cf3bde4fe0dcc4e73d73342d5a42edc2e64b6fae9b98",
    "FixtureScoped" => "073fb6684c0a502600271bc0c257da0899a3c11090abf96ceb371e6bccfa9495",
    "FixtureDdlFailing" => "49e667a456679e3f5112affb142659f6953bd14952a8845e8e4501136ab8c7c5",
    "FixturePoints" => "a25427d0c523854a0ab5fb9fd847b7cd441fe2662fe32639025fb1b417b7e65f"
  }

  defp base, do: FixtureLedgerPost.manifest()
  defp hash(manifest), do: ManifestHash.compute(manifest)

  defp put_alpha(manifest, key, value), do: put_in(manifest, [:ledger, "alpha", key], value)

  test "T-MH-20 every module without :ledger and posts_ledger keeps its origin/main hash" do
    registered = for entry <- Catalog.entry_modules(), do: entry.manifest().id
    ids = Map.new(Catalog.entry_modules(), fn entry -> {inspect(entry), entry.manifest().id} end)

    for {name, expected} <- @golden do
      id = Map.fetch!(ids, "Letflow.Modules." <> name)
      assert id in registered
      assert Catalog.manifest_hash(id) == {:ok, expected}, name
    end

    # the modules with a :ledger key (FixtureLedgerPost, FixtureLedgerStorage from REQ-711, and Stock from REQ-687) are not in @golden
    assert map_size(@golden) == length(registered) - 3
  end

  test "T-MH-21 equal inputs, equal hash; the fixture is covered" do
    assert hash(base()) == hash(base())
    assert hash(base()) =~ ~r/\A[0-9a-f]{64}\z/
    refute hash(base()) == hash(Map.delete(base(), :ledger))
  end

  test "T-MH-01..12 each ledger surface change moves the hash" do
    reference = hash(base())
    alpha = base().ledger["alpha"]

    changes = [
      ledger_id: fn m -> put_alpha(m, :ledger_ids, {:fixed, ["fixture_ledger_post:other"]}) end,
      slot_name: fn m ->
        put_alpha(m, :slots, [%{hd(alpha.slots) | name: "z1"} | tl(alpha.slots)])
      end,
      slot_format: fn m ->
        put_alpha(m, :slots, [%{hd(alpha.slots) | format: :uuid} | tl(alpha.slots)])
      end,
      slot_required: fn m ->
        put_alpha(m, :slots, [%{hd(alpha.slots) | required: false} | tl(alpha.slots)])
      end,
      slot_order: fn m -> put_alpha(m, :slots, Enum.reverse(alpha.slots)) end,
      cause_name: fn m ->
        put_alpha(
          m,
          :causes,
          Map.put(alpha.causes, "extra", %{sign_rule: :any, reason_required: false})
        )
      end,
      sign_rule: fn m ->
        put_alpha(m, :causes, put_in(alpha.causes, ["receipt", :sign_rule], :any))
      end,
      reason_required: fn m ->
        put_alpha(m, :causes, put_in(alpha.causes, ["receipt", :reason_required], true))
      end,
      key_bound: fn m ->
        put_alpha(m, :key_bounds, [%{when_slot_nonempty: "k2", max_on_hand: "2"}])
      end,
      permission_post: fn m ->
        put_alpha(m, :permissions, %{alpha.permissions | post: :FxlpRead})
      end,
      permission_reverse: fn m ->
        put_alpha(m, :permissions, %{alpha.permissions | reverse: :FxlpRead})
      end,
      permission_read: fn m ->
        put_alpha(m, :permissions, %{alpha.permissions | read: :FxlpPost})
      end,
      permission_reconcile: fn m ->
        put_alpha(m, :permissions, %{alpha.permissions | reconcile: :FxlpPost})
      end,
      scope_slot: fn m -> put_alpha(m, :scope_slot, "k1") end,
      lateness: fn m -> put_alpha(m, :max_event_lateness_hours, 97) end,
      alias_value: fn m ->
        put_alpha(m, :error_aliases, %{"insufficient_balance" => "fxlp_other"})
      end,
      alias_key: fn m -> put_alpha(m, :error_aliases, %{"unit_mismatch" => "fxlp_short"}) end,
      units: fn m -> put_alpha(m, :units, ["ea"]) end,
      policy_module: fn m ->
        put_alpha(m, :policy, {Letflow.Modules.FixtureLedgerPost.Handlers, :declare})
      end,
      policy_function: fn m ->
        put_alpha(m, :policy, {Letflow.Modules.FixtureLedgerPost.LedgerPolicy, :other})
      end,
      registration_name: fn m ->
        update_in(m, [:ledger], &Map.new(&1, fn {k, v} -> {k <> "_", v} end))
      end,
      posts_ledger: fn m ->
        update_in(m, [:write_handlers], fn [first | rest] ->
          [%{first | posts_ledger: "beta"} | rest]
        end)
      end,
      posts_ledger_removed: fn m ->
        update_in(m, [:write_handlers], fn [first | rest] ->
          [%{first | posts_ledger: nil} | rest]
        end)
      end
    ]

    hashes = for {label, change} <- changes, do: {label, hash(change.(base()))}

    for {label, value} <- hashes do
      assert value != reference, "#{label} did not change the hash"
    end

    # every single change gives its own value (no two surfaces collapse into one)
    distinct = hashes |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert length(distinct) == length(hashes)
  end

  test "a handler without posts_ledger hashes as before the field existed" do
    plain = Enum.find(base().write_handlers, &(&1.name == "plain"))
    manifest = base() |> Map.delete(:ledger) |> Map.put(:write_handlers, [plain])
    with_nil = %{manifest | write_handlers: [%{plain | posts_ledger: nil}]}
    assert hash(manifest) == hash(with_nil)
  end
end
