defmodule Letflow.Modules.LedgerRegistrationTest do
  @moduledoc """
  REQ-684 / GH #3698, criteria 1 to 3: the `:ledger` manifest key (Catalog rule 18), its closed
  reasons, the permission and alias rules and `Catalog.fetch_ledger/2`. Pure: no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Ledger.Digest
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureLedgerPost, as: Entry
  alias Letflow.Modules.LedgerRegistration

  @entry Entry
  @policy Letflow.Modules.FixtureLedgerPost.LedgerPolicy

  defp base, do: Entry.manifest()
  defp alpha, do: base().ledger["alpha"]

  defp with_alpha(changes) when is_map(changes) do
    manifest = base()
    put_in(manifest, [:ledger, "alpha"], Map.merge(alpha(), changes))
  end

  defp without_alpha_key(key) do
    manifest = base()
    put_in(manifest, [:ledger, "alpha"], Map.delete(alpha(), key))
  end

  defp check(manifest, others \\ []),
    do: LedgerRegistration.validate(manifest, [manifest | others], @entry)

  defp reason(manifest, others \\ []) do
    assert {:error, {:invalid_ledger_registration, "alpha", reason}} = check(manifest, others)
    reason
  end

  describe "T-LR-01/02 the valid cases" do
    test "T-LR-01 an absent :ledger key is valid" do
      assert check(Map.delete(base(), :ledger)) == :ok
      assert Catalog.validate(Letflow.Modules.FixtureLedgerOther.manifest()) == :ok
    end

    test "T-LR-02 the fixture passes through Catalog.validate/2 with two registrations" do
      assert Catalog.validate(base()) == :ok
      assert Enum.sort(Map.keys(base().ledger)) == ["alpha", "beta"]
    end
  end

  describe "T-LR-03..13 one reason per check" do
    test "ledger_ids: instances mode is refused" do
      assert reason(with_alpha(%{ledger_ids: {:instances, %{max: 4}}})) == :instances_not_enabled
    end

    test "ledger_id_form" do
      for ids <- [
            {:fixed, ["fixture_ledger_post:Bad"]},
            {:fixed, ["fixture_ledger_post:" <> String.duplicate("a", 33)]},
            {:fixed, ["fixture_ledger_post:" <> String.duplicate("a", 45)]},
            {:fixed, ["other_module"]},
            {:fixed, ["fixture_ledger_post:a:b"]},
            {:fixed, ["fixture_ledger_post", "fixture_ledger_post"]},
            {:fixed, []},
            {:fixed, [:fixture_ledger_post]},
            {:fixed, "fixture_ledger_post"},
            ["fixture_ledger_post"],
            nil
          ] do
        assert reason(with_alpha(%{ledger_ids: ids})) == :ledger_id_form, inspect(ids)
      end

      assert byte_size("fixture_ledger_post:" <> String.duplicate("a", 45)) > 64
    end

    test "ledger_id_overlap with another known manifest and with a sibling registration" do
      other = %{
        id: "elsewhere",
        ledger: %{"x" => %{ledger_ids: {:fixed, ["fixture_ledger_post"]}}}
      }

      assert reason(base(), [other]) == :ledger_id_overlap

      clash = %{id: "fixture_ledger_post:beta"}

      assert reason(with_alpha(%{ledger_ids: {:fixed, ["fixture_ledger_post:beta"]}}), [clash]) ==
               :ledger_id_overlap

      shared = with_alpha(%{ledger_ids: {:fixed, ["fixture_ledger_post:beta"]}})
      assert reason(shared) == :ledger_id_overlap
    end

    test "slots" do
      good = %{name: "k1", format: :token, required: true}

      for slots <- [
            [],
            for(i <- 1..9, do: %{good | name: "k#{i}"}),
            [good, good],
            [%{good | format: :int}],
            [%{good | required: "yes"}],
            [Map.put(good, :extra, 1)],
            [Map.delete(good, :required)],
            [%{good | name: :k1}],
            "slots"
          ] do
        assert reason(with_alpha(%{slots: slots})) == :slots, inspect(slots)
      end

      eight = for i <- 1..8, do: %{good | name: "k#{i}"}
      assert check(with_alpha(%{slots: eight})) == :ok
    end

    test "causes" do
      for causes <- [
            %{},
            %{"a" => %{sign_rule: :sideways, reason_required: false}},
            %{"a" => %{sign_rule: :any, reason_required: "no"}},
            %{"a" => %{sign_rule: :any}},
            %{"a" => %{sign_rule: :any, reason_required: false, extra: 1}},
            %{a: %{sign_rule: :any, reason_required: false}},
            [{"a", :any}]
          ] do
        assert reason(with_alpha(%{causes: causes})) == :causes, inspect(causes)
      end

      for rule <- [:positive, :negative, :zero_sum_by_slot_1, :any] do
        causes = %{"a" => %{sign_rule: rule, reason_required: true}}
        assert check(with_alpha(%{causes: causes})) == :ok
      end
    end

    test "key_bounds" do
      bound = fn slot, max -> [%{when_slot_nonempty: slot, max_on_hand: max}] end

      for bounds <- [
            bound.("nope", "1"),
            bound.("k2", "0"),
            bound.("k2", "-1"),
            bound.("k2", "1e3"),
            bound.("k2", "01"),
            bound.("k2", "1.0000000001"),
            bound.("k2", String.duplicate("9", 22)),
            bound.("k2", "NaN"),
            bound.("k2", "Infinity"),
            bound.("k2", 1),
            bound.("k2", ""),
            [%{when_slot_nonempty: "k2"}],
            :bounds
          ] do
        assert reason(with_alpha(%{key_bounds: bounds})) == :key_bounds, inspect(bounds)
      end

      for max <- ["1", "0.5", "1.000000001", String.duplicate("9", 21)] do
        assert check(with_alpha(%{key_bounds: bound.("k2", max)})) == :ok, max
      end

      assert check(without_alpha_key(:key_bounds)) == :ok
    end

    test "key bound verdicts equal Letflow.Ledger.post/1's own registration check" do
      # the same limit as `Letflow.Ledger.check_bounds/2`: positive, canonical, numeric(30,9)
      samples = %{
        "1" => true,
        "0.000000001" => true,
        "0" => false,
        "1.0000000001" => false,
        String.duplicate("9", 21) => true,
        String.duplicate("9", 22) => false
      }

      for {text, expected} <- samples do
        verdict =
          check(with_alpha(%{key_bounds: [%{when_slot_nonempty: "k2", max_on_hand: text}]})) ==
            :ok

        assert verdict == expected, text
      end
    end

    test "scope_slot" do
      assert reason(with_alpha(%{scope_slot: "zz"})) == :scope_slot
      assert reason(with_alpha(%{scope_slot: :k1})) == :scope_slot
      assert check(with_alpha(%{scope_slot: "k1"})) == :ok
      assert check(with_alpha(%{scope_slot: nil})) == :ok
      assert check(without_alpha_key(:scope_slot)) == :ok
    end

    test "lateness" do
      for hours <- [0, -1, 721, 1.5, "96", nil] do
        assert reason(with_alpha(%{max_event_lateness_hours: hours})) == :lateness, inspect(hours)
      end

      for hours <- [1, 96, 720],
          do: assert(check(with_alpha(%{max_event_lateness_hours: hours})) == :ok)

      assert check(without_alpha_key(:max_event_lateness_hours)) == :ok
    end

    test "units" do
      for units <- ["ea", [:ea], ["Bad Unit"], [""], [String.duplicate("a", 33)], %{}] do
        assert reason(with_alpha(%{units: units})) == :units, inspect(units)
      end

      assert check(with_alpha(%{units: ["ea", "kg", "m.2:x-y"]})) == :ok
      assert check(with_alpha(%{units: nil})) == :ok
    end

    test "policy" do
      assert reason(with_alpha(%{policy: {Letflow.Modules.FixtureLedgerPost.Handlers, :declare}})) ==
               :policy

      assert reason(with_alpha(%{policy: {@policy, :other}})) == :policy
      assert reason(with_alpha(%{policy: :nope})) == :policy
      assert reason(with_alpha(%{policy: {"x", :declare}})) == :policy
      assert reason(with_alpha(%{policy: {Nope.Missing, :declare}})) == :policy
      # inside the policy namespace only: a policy of another module's namespace is refused
      assert {:error, {:invalid_ledger_registration, "alpha", :policy}} =
               LedgerRegistration.validate(base(), [base()], Letflow.Modules.Fixture)

      assert {:error, {:invalid_ledger_registration, "alpha", :policy}} =
               LedgerRegistration.validate(base(), [base()], nil)
    end

    test "shape" do
      m = base()

      for ledger <- [
            :nope,
            [],
            %{"alpha" => :nope},
            %{"Bad Name" => alpha()},
            %{alpha: alpha()},
            %{"alpha" => Map.put(alpha(), :extra, 1)},
            %{"alpha" => Map.delete(alpha(), :policy)},
            %{"alpha" => Map.delete(alpha(), :ledger_ids)},
            %{"alpha" => struct(URI)}
          ] do
        assert {:error, {:invalid_ledger_registration, _name, :shape}} =
                 check(Map.put(m, :ledger, ledger)),
               inspect(ledger)
      end

      assert {:error, {:invalid_ledger_registration, nil, :shape}} =
               check(Map.put(m, :ledger, :nope))
    end
  end

  describe "T-LR-14/15 position and totality" do
    test "T-LR-14 the rule runs last: an earlier rule's error wins" do
      manifest = with_alpha(%{slots: []}) |> Map.put(:migrations, :bad)
      assert {:error, {:invalid_migrations, :bad}} = Catalog.validate(manifest, [manifest])

      assert {:error, {:invalid_ledger_registration, "alpha", :slots}} =
               Catalog.validate(with_alpha(%{slots: []}), [with_alpha(%{slots: []})])
    end

    test "T-LR-15 arbitrary terms never raise" do
      terms = [
        nil,
        :a,
        1,
        1.5,
        "s",
        [],
        [1],
        %{},
        %{1 => 2},
        {},
        {1},
        self(),
        %URI{},
        fn -> 1 end
      ]

      keys = [
        :ledger_ids,
        :slots,
        :causes,
        :permissions,
        :policy,
        :key_bounds,
        :scope_slot,
        :units,
        :error_aliases
      ]

      for term <- terms, key <- keys do
        case check(with_alpha(%{key => term})) do
          :ok -> :ok
          {:error, {:invalid_ledger_registration, "alpha", reason}} -> assert is_atom(reason)
        end
      end

      for term <- terms do
        assert {:error, {:invalid_ledger_registration, _, :shape}} =
                 check(Map.put(base(), :ledger, %{"alpha" => term}))
      end

      assert {:error, _} = LedgerRegistration.validate(:not_a_map, [], nil)
    end
  end

  describe "T-LR-20..22 permissions, grants and aliases" do
    test "T-LR-20 permissions: missing key, extra key, reverse == post, undeclared atom" do
      perms = alpha().permissions

      for changed <- [
            Map.delete(perms, :read),
            Map.put(perms, :extra, :FxlpPost),
            %{perms | reverse: perms.post},
            %{perms | read: :FxlpUndeclared},
            %{perms | read: "FxlpRead"},
            %{perms | read: nil},
            :perms
          ] do
        assert reason(with_alpha(%{permissions: changed})) == :permissions, inspect(changed)
      end
    end

    test "T-LR-20b a core permission atom is refused by the existing core collision rule" do
      core = hd(Letflow.Api.Authorization.core_permissions())
      manifest = %{base() | permissions: [core | base().permissions]}
      manifest = put_in(manifest, [:ledger, "alpha", :permissions, :read], core)

      assert Catalog.validate(manifest, [manifest]) ==
               {:error, {:core_permission_collision, core}}
    end

    test "T-LR-21 auditor and candidate may not hold post or reverse; others may" do
      for role <- [:TENANT_AUDITOR, :CANDIDATE], atom <- [:FxlpPost, :FxlpReverse] do
        manifest = %{base() | role_grants: %{role => [atom]}}
        assert reason(manifest) == :auditor_or_candidate_post, "#{role} #{atom}"
      end

      for role <- [:TENANT_AUDITOR, :CANDIDATE] do
        assert check(%{base() | role_grants: %{role => [:FxlpRead, :FxlpReconcile]}}) == :ok
      end

      assert check(%{base() | role_grants: %{TENANT_ADMIN: [:FxlpPost, :FxlpReverse]}}) == :ok
      assert check(Map.delete(base(), :role_grants)) == :ok
    end

    test "T-LR-22 aliases" do
      for aliases <- [
            %{"idempotency_key_reuse" => "fxlp_x"},
            %{"insufficient_balance" => "Bad"},
            %{"insufficient_balance" => "write_not_permitted"},
            %{"insufficient_balance" => "validation_failed"},
            %{"insufficient_balance" => "insufficient_balance"},
            %{"insufficient_balance" => "a", "unit_mismatch" => "a"},
            %{"insufficient_balance" => String.duplicate("a", 49)},
            %{"insufficient_balance" => :atom},
            %{"insufficient_balance" => "with1digit"},
            [{"insufficient_balance", "x"}]
          ] do
        assert reason(with_alpha(%{error_aliases: aliases})) == :error_aliases, inspect(aliases)
      end

      other = %{
        id: "elsewhere",
        ledger: %{"x" => %{error_aliases: %{"unit_mismatch" => "fxlp_short"}}}
      }

      assert reason(base(), [other]) == :error_aliases

      sibling =
        put_in(base(), [:ledger, "beta", :error_aliases], %{"unit_mismatch" => "fxlp_short"})

      assert {:error, {:invalid_ledger_registration, name, :error_aliases}} = check(sibling)
      assert name in ["alpha", "beta"]

      for core <- Letflow.Ledger.Codes.aliasable() do
        assert check(with_alpha(%{error_aliases: %{core => "fxlp_" <> "renamed"}})) == :ok
      end
    end
  end

  describe "T-LR-30 Catalog.fetch_ledger/2" do
    test "returns the plain-data shape that hashes and carries the defaults" do
      assert {:ok, reg} = Catalog.fetch_ledger("fixture_ledger_post", "alpha")
      assert reg.ledger_ids == ["fixture_ledger_post"]
      assert reg.policy == %{module: @policy, function: :declare}
      assert reg.max_event_lateness_hours == 96
      assert reg.error_aliases == %{"insufficient_balance" => "fxlp_short"}
      assert reg.key_bounds == [%{when_slot_nonempty: "k2", max_on_hand: "1"}]
      refute Map.has_key?(reg, :units)

      for key <- [:slots, :causes, :key_bounds, :max_event_lateness_hours],
          do: assert(Map.has_key?(reg, key))

      assert is_binary(Digest.registration_hash(reg))

      assert {:ok, beta} = Catalog.fetch_ledger("fixture_ledger_post", "beta")
      assert beta.ledger_ids == ["fixture_ledger_post:beta"]
      assert beta.error_aliases == %{}
      assert beta.scope_slot == nil
    end

    test "not_found for an unknown module, name or a non-binary argument" do
      for args <- [
            {"nope", "alpha"},
            {"fixture_ledger_post", "ghost"},
            {"fixture_ledger", "alpha"},
            {:fixture_ledger_post, "alpha"},
            {"fixture_ledger_post", :alpha},
            {nil, nil}
          ] do
        assert Catalog.fetch_ledger(elem(args, 0), elem(args, 1)) == {:error, :not_found},
               inspect(args)
      end
    end

    test "creates no atom for an unknown name" do
      name = "never_seen_" <> Base.encode16(:crypto.strong_rand_bytes(8))
      # Warm-up: the first call loads every entry module (and its policy) lazily, which creates
      # atoms of its own; the test is about the unknown name, not about code loading.
      assert {:ok, _} = Catalog.fetch_ledger("fixture_ledger_post", "alpha")
      before = :erlang.system_info(:atom_count)
      assert Catalog.fetch_ledger("fixture_ledger_post", name) == {:error, :not_found}
      assert Catalog.fetch_ledger(name, name) == {:error, :not_found}
      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "T-FX-01 the fixture" do
    test "two registrations, distinct ids, own atoms, one alias, policy under its own directory" do
      manifest = base()
      assert Catalog.validate(manifest) == :ok
      {:fixed, a} = manifest.ledger["alpha"].ledger_ids
      {:fixed, b} = manifest.ledger["beta"].ledger_ids
      assert a != b
      atoms = manifest.ledger["alpha"].permissions |> Map.values()
      assert length(Enum.uniq(atoms)) == 4
      assert Enum.all?(atoms, &(&1 in manifest.permissions))
      assert map_size(manifest.ledger["alpha"].error_aliases) == 1
      assert {@policy, :declare} == manifest.ledger["alpha"].policy

      assert File.regular?(
               "test/support/modules/fixture_ledger_post/ledger_policy/ledger_policy.ex"
             )
    end

    test "T-FX-02 the other registered modules still validate" do
      for entry <- Catalog.entry_modules() do
        assert Catalog.validate(entry.manifest()) == :ok, inspect(entry)
      end
    end

    test "no new lib file touches the database" do
      for path <- [
            "lib/letflow/modules/ledger_registration.ex",
            "lib/letflow/ledger/codes.ex",
            "lib/letflow/ledger/policy.ex"
          ] do
        refute File.read!(path) =~ ~r/\bRepo\b/, path
      end
    end
  end
end
