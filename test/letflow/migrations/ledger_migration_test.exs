defmodule Letflow.LedgerMigrationTest do
  @moduledoc """
  REQ-620 / GH #3463 part C, criterion 11 (the REQ-503 criterion 2 test): adding a nullable column
  to `ledger_leg` leaves every stored byte of the seeded rows alone, fires no append-only trigger and
  keeps the deferred triggers accepting a correct posting. Real commits in a throwaway tenant,
  `async: false`. Raw SQL on purpose: no `Letflow.Ledger` module exists yet.
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture

  @t0 "2026-10-31T10:00:00Z"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r620c-mig")
    {:ok, schema: tenant.schema_name}
  end

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)
  defp hex(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp lit(nil), do: "NULL"
  defp lit({:raw, sql}), do: sql
  defp lit(n) when is_integer(n), do: Integer.to_string(n)
  defp lit(s) when is_binary(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp insert_sql(schema, table, row) do
    cols = row |> Map.keys() |> Enum.sort()

    ~s|INSERT INTO "#{schema}".#{table} (#{Enum.join(cols, ", ")}) VALUES | <>
      "(#{Enum.map_join(cols, ", ", &lit(row[&1]))})"
  end

  # One transaction: counter bump to `seq`, entry, legs (k1, quantity, extra columns), balance rows.
  defp post(schema, seq, legs, balances) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.transaction(fn ->
        q!(
          insert_sql(schema, "ledger_counter", %{
            ledger_id: "wh",
            last_seq: 0,
            last_chain_hash: ""
          }) <>
            " ON CONFLICT DO NOTHING"
        )

        q!(~s|SELECT 1 FROM "#{schema}".ledger_counter WHERE ledger_id = 'wh' FOR UPDATE|)

        q!(
          ~s|UPDATE "#{schema}".ledger_counter SET last_seq = #{seq}, last_chain_hash = #{lit(hex(seq))} | <>
            "WHERE ledger_id = 'wh'"
        )

        q!(
          insert_sql(schema, "ledger_entry", %{
            id: id,
            ledger_id: "wh",
            posting_seq: seq,
            cause: "receipt",
            sign_rule: "any",
            actor_id: "22222222-2222-2222-2222-222222222222",
            subject_id: "33333333-3333-3333-3333-333333333333",
            correlation_id: "corr-1",
            event_time: @t0,
            posting_time: @t0,
            client_op_id: "op-#{seq}",
            origin_key: "origin-" <> id,
            payload_hash: hex(seq),
            entry_digest: hex(seq),
            chain_hash: hex(seq),
            registration_hash: hex(seq),
            leg_count: length(legs)
          })
        )

        legs
        |> Enum.with_index(1)
        |> Enum.each(fn {leg, no} ->
          row =
            Map.merge(
              %{
                id: Ecto.UUID.generate(),
                entry_id: id,
                ledger_id: "wh",
                posting_seq: seq,
                event_time: @t0,
                leg_no: no,
                quantity: {:raw, to_string(leg.q)},
                unit_ref: "pcs",
                quantity_scale: 0
              },
              Map.delete(leg, :q)
            )

          q!(insert_sql(schema, "ledger_leg", row))
        end)

        for {k1, on_hand} <- balances do
          q!(
            insert_sql(schema, "ledger_balance", %{
              ledger_id: "wh",
              k1: k1,
              on_hand: 0,
              unit_ref: "pcs",
              last_posting_seq: 0
            }) <> " ON CONFLICT DO NOTHING"
          )

          q!(
            ~s|UPDATE "#{schema}".ledger_balance SET on_hand = #{on_hand}, last_posting_seq = #{seq} | <>
              "WHERE ledger_id = 'wh' AND k1 = #{lit(k1)}"
          )
        end
      end)

    id
  end

  # Per row: the primary-key text and the jsonb form of the row (extra_dim removed), plus xmin.
  defp rows(schema, table, order, with_extra?) do
    expr = if with_extra?, do: "(to_jsonb(t) - 'extra_dim')", else: "to_jsonb(t)"

    q!(~s|SELECT #{expr}::text, xmin::text FROM "#{schema}".#{table} t ORDER BY #{order}|).rows
  end

  defp key_sums(schema) do
    q!(
      ~s|SELECT k1, k2, k3, k4, k5, k6, k7, k8, sum(quantity)::text FROM "#{schema}".ledger_leg | <>
        "GROUP BY k1, k2, k3, k4, k5, k6, k7, k8 ORDER BY k1"
    ).rows
  end

  defp on_hand(schema) do
    q!(~s|SELECT k1, on_hand::text FROM "#{schema}".ledger_balance ORDER BY k1|).rows
  end

  test "T-MIG-1 a nullable column on ledger_leg leaves seeded rows and balances alone", %{
    schema: s
  } do
    post(s, 1, [%{k1: "a", q: 5}, %{k1: "b", q: 3}], [{"a", 5}, {"b", 3}])

    # T-MIG-2 (first half): the unused slot k8 is the empty string in the seeded legs
    assert q!(~s|SELECT DISTINCT k8 FROM "#{s}".ledger_leg|).rows == [[""]]

    legs_before = rows(s, "ledger_leg", "leg_no", false)
    bal_before = rows(s, "ledger_balance", "k1", false)
    sums_before = key_sums(s)
    on_hand_before = on_hand(s)
    assert on_hand_before == [["a", "5.000000000"], ["b", "3.000000000"]]

    q!(~s|ALTER TABLE "#{s}".ledger_leg ADD COLUMN extra_dim text NULL|)

    assert legs_before == rows(s, "ledger_leg", "leg_no", true)
    assert bal_before == rows(s, "ledger_balance", "k1", true)
    assert q!(~s|SELECT count(*) FROM "#{s}".ledger_leg WHERE extra_dim IS NULL|).rows == [[2]]
    assert sums_before == key_sums(s)
    assert on_hand_before == on_hand(s)

    # the deferred triggers still accept a new correct posting
    post(s, 2, [%{k1: "a", q: 2}], [{"a", 7}])

    assert q!(~s|SELECT posting_seq FROM "#{s}".ledger_entry ORDER BY posting_seq|).rows ==
             [[1], [2]]

    assert on_hand(s) == [["a", "7.000000000"], ["b", "3.000000000"]]
    assert q!(~s|SELECT last_seq FROM "#{s}".ledger_counter|).rows == [[2]]
  end

  test "T-MIG-2 a posting that uses another dimension slot needs no DDL", %{schema: s} do
    post(s, 1, [%{k1: "a", k3: "lot-x", q: 4}], [{"a", 4}])

    assert q!(~s|SELECT k1, k3, k8 FROM "#{s}".ledger_leg|).rows == [["a", "lot-x", ""]]
  end
end
