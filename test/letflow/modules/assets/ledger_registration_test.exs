Code.require_file("register_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.LedgerRegistrationTest do
  @moduledoc """
  REQ-749 / GH #3893 criterion 1 and the conservation rule (A8-REG-1, A8-REG-2, A8-CONS-1): the
  `:ledger` registration of module assets as one literal map, the catalog answer, the storage made
  at install on a committed tenant (Sandbox `:auto`, hence `async: false`), a commission posting,
  `unit_not_allowed` for another unit, and the per-asset conservation of the four causes.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Ledger.Storage
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Catalog
  alias Letflow.Repo

  @asset1 "11111111-1111-4111-8111-111111111111"
  @asset2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @u2 "46464646-4646-4646-8646-464646464646"
  @l1 "33333333-3333-4333-8333-333333333333"
  @r1 "55555555-5555-4555-8555-555555555555"
  @r2 "56565656-5656-4656-8656-565656565656"

  test "A8-REG-1 the manifest registration, as one literal map, and the catalog answer" do
    m = Assets.manifest()
    assert m.permissions == [:AssetsPost, :AssetsReverse, :AssetsRead, :AssetsReconcile]
    assert m.role_grants == %{}

    assert m.ledger == %{
             "assets" => %{
               ledger_ids: {:fixed, ["assets"]},
               slots: [
                 %{name: "asset", format: :uuid, required: true},
                 %{name: "org_unit", format: :uuid, required: true},
                 %{name: "location", format: :uuid, required: false},
                 %{name: "material_responsible", format: :uuid, required: true},
                 %{name: "actual_user", format: :uuid, required: false}
               ],
               causes: %{
                 "commission" => %{sign_rule: :positive, reason_required: false},
                 "change" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
                 "handover" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
                 "writeoff" => %{sign_rule: :negative, reason_required: true}
               },
               key_bounds: [],
               permissions: %{
                 post: :AssetsPost,
                 reverse: :AssetsReverse,
                 read: :AssetsRead,
                 reconcile: :AssetsReconcile
               },
               scope_slot: "org_unit",
               max_event_lateness_hours: 96,
               error_aliases: %{},
               units: ["pcs"],
               policy: {Letflow.Modules.Assets.LedgerPolicy, :declare}
             }
           }

    assert Catalog.validate(m, Catalog.all_manifests()) == :ok
    assert {:ok, registration} = Catalog.fetch_ledger("assets", "assets")
    assert registration.scope_slot == "org_unit"

    assert Map.has_key?(Catalog.ledger_registry(), "assets")
  end

  describe "on a committed tenant" do
    setup do
      ctx = S.setup_oidc!([:a])
      %{a: S.tenant!("ast-reg", ctx.names.a), ctx: ctx}
    end

    defp partitions(schema) do
      Repo.query!(
        "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = $1 AND c.relispartition AND c.relkind = 'r'",
        [schema]
      ).rows
      |> List.flatten()
    end

    defp sums(schema) do
      balance =
        Repo.query!(
          ~s|SELECT k1, sum(on_hand) FROM "#{schema}".ledger_balance WHERE ledger_id = 'assets' GROUP BY k1|
        ).rows

      legs =
        Repo.query!(
          ~s|SELECT k1, sum(quantity) FROM "#{schema}".ledger_leg WHERE ledger_id = 'assets' GROUP BY k1|
        ).rows

      {Map.new(balance, fn [k, v] -> {k, Decimal.normalize(v)} end),
       Map.new(legs, fn [k, v] -> {k, Decimal.normalize(v)} end)}
    end

    defp expected(map),
      do: Map.new(map, fn {k, v} -> {k, v |> Decimal.new() |> Decimal.normalize()} end)

    test "A8-REG-2 install makes the storage; a commission posts; another unit is refused", ctx do
      schema = ctx.a.schema_name
      names = Map.values(Storage.partition_names("assets"))
      assert names != [] and Enum.all?(names, &(&1 in partitions(schema)))

      posted =
        S.post!(schema, "commission", %{
          document_id: "d1",
          lines: [S.line(@asset1, "3", %{to: S.side(@u1, @r1)})]
        })

      assert posted.ledger_id == "assets" and posted.posting_seq == 1

      {:ok, posting} =
        Assets.LedgerPolicy.declare(
          %{
            cause: "commission",
            lines: [S.line(@asset1, "1", %{to: S.side(@u1, @r1)})]
          },
          S.registration()
        )

      box = Enum.map(posting.legs, &%{&1 | unit_ref: "box"})

      cap =
        Letflow.LedgerFixture.capability(schema, "commission", box,
          ledger_id: "assets",
          registration: S.registration(),
          ensure_storage: false,
          posting: %{posting | legs: box}
        )

      assert {:error, {:ledger_refused, :invalid_posting, _, %{reason: :unit_not_allowed}}} =
               Letflow.LedgerFixture.post_tx(cap)
    end

    test "A8-CONS-1 conservation per asset over the four causes", ctx do
      schema = ctx.a.schema_name
      here = S.side(@u1, @r1, %{location: @l1})

      S.post!(schema, "commission", %{lines: [S.line(@asset1, "5", %{to: here})]})
      S.post!(schema, "commission", %{lines: [S.line(@asset2, "2", %{to: here})]})
      assert {bal, legs} = sums(schema)
      assert bal == expected(%{@asset1 => "5", @asset2 => "2"}) and legs == bal

      # change of the responsible: same place, quantity moves between keys, the sum stays
      S.post!(schema, "change", %{
        lines: [S.line(@asset1, "2", %{from: here, to: S.side(@u1, @r2, %{location: @l1})})]
      })

      assert {bal, legs} = sums(schema)
      assert bal == expected(%{@asset1 => "5", @asset2 => "2"}) and legs == bal

      # handover to another unit
      S.post!(schema, "handover", %{
        lines: [S.line(@asset1, "1", %{from: here, to: S.side(@u2, @r1)})]
      })

      assert {bal, legs} = sums(schema)
      assert bal == expected(%{@asset1 => "5", @asset2 => "2"}) and legs == bal

      # writeoff of 1 asset1 lowers that asset only
      S.post!(schema, "writeoff", %{
        reason_code: "lost",
        lines: [S.line(@asset1, "1", %{from: here})]
      })

      assert {bal, legs} = sums(schema)
      assert bal == expected(%{@asset1 => "4", @asset2 => "2"}) and legs == bal
    end
  end
end
