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

  # Golden hashes live one file per module in test/letflow/modules/pins/ (T-1900).
  @pins Letflow.TestSupport.ModulePins.all()

  defp base, do: FixtureLedgerPost.manifest()
  defp hash(manifest), do: ManifestHash.compute(manifest)

  defp put_alpha(manifest, key, value), do: put_in(manifest, [:ledger, "alpha", key], value)

  test "T-MH-20 every module without :ledger and posts_ledger keeps its origin/main hash" do
    registered = for entry <- Catalog.entry_modules(), do: entry.manifest().id
    ids = Map.new(Catalog.entry_modules(), fn entry -> {inspect(entry), entry.manifest().id} end)

    golden = for {name, %{hash: expected}} <- @pins, do: {name, expected}

    for {name, expected} <- golden do
      id = Map.fetch!(ids, "Letflow.Modules." <> name)
      assert id in registered
      assert Catalog.manifest_hash(id) == {:ok, expected}, name
    end

    # Modules with a :ledger key, :reference_targets or a release-dependent version carry
    # `exempt:` in their pin file instead of a hash. Every registered module has exactly one pin
    # file, so a new module cannot be forgotten and a stale file is caught.
    assert Enum.sort(Map.keys(@pins)) ==
             Enum.sort(
               for {name, _} <- ids, do: String.replace_prefix(name, "Letflow.Modules.", "")
             )

    assert map_size(@pins) == length(registered)
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
