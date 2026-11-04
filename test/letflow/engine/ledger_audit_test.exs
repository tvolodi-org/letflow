defmodule Letflow.Engine.LedgerAuditTest do
  @moduledoc """
  REQ-686 criterion 5 (decision 0073 D8): every ledger entry a completion writes has one
  `ledger.posted` audit entry in the same transaction, written after the counter (lock class 5b
  before the audit chain row of class 6), with exactly seven keys and no quantity or free text.
  A failure after the counter rolls back the counter, the entry, the legs, the balances and the
  audit together. T-AU-1, T-AU-2.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.LedgerFixture, as: LF
  alias Letflow.LedgerPostFixture, as: Fx

  @keys ~w(actor_id cause chain_hash entry_id ledger_id leg_count posting_seq)

  defp posted_audits(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT resource_id, after_state FROM "#{schema}".audit_entries WHERE action = 'ledger.posted' ORDER BY after_state->>'ledger_id'|
      )

    rows
  end

  defp two_lines do
    [
      Fx.line("post_alpha", %{"posting" => Fx.posting("receipt", "a", "5")}),
      Fx.line("post_beta", %{"posting" => Fx.posting("receipt", "b", "7")})
    ]
  end

  test "T-AU-1 one audit entry per written entry, exactly the seven keys, in one transaction" do
    ctx = Fx.case!("req686-au1", two_lines())
    {result, statements} = LF.record(fn -> Fx.complete(ctx) end)
    assert {:ok, _} = result

    assert [[id_a, state_a], [id_b, state_b]] = posted_audits(ctx.schema)
    assert Enum.sort(Map.keys(state_a)) == @keys
    assert Enum.sort(Map.keys(state_b)) == @keys
    assert state_a["ledger_id"] == "fixture_ledger_post"
    assert state_b["ledger_id"] == "fixture_ledger_post:beta"
    assert state_a["entry_id"] == id_a and state_b["entry_id"] == id_b
    assert state_a["leg_count"] == 1 and state_a["cause"] == "receipt"
    assert state_a["actor_id"] == ctx.completer.id

    # the chain hash is the stored one; no quantity, slot value or text is in the entry
    %{rows: [[stored]]} =
      Repo.query!(
        ~s|SELECT chain_hash FROM "#{ctx.schema}".ledger_entry WHERE id = $1|,
        [Ecto.UUID.dump!(id_a)]
      )

    assert state_a["chain_hash"] == stored
    refute Jason.encode!(state_a) =~ "u1"

    # class 5b before class 6: the first counter update precedes the first audit chain lock
    sql = Enum.map(statements, &elem(&1, 0))
    counter = Enum.find_index(sql, &(&1 =~ ~r/UPDATE "[^"]+"\."ledger_counter"/))
    audit_lock = Enum.find_index(sql, &(&1 =~ ~r/INSERT INTO "[^"]+"\."audit_chain_locks"/))
    assert counter && audit_lock && counter < audit_lock
  end

  test "T-AU-1 a refusal, an API token and a replayed completion write none" do
    ctx =
      Fx.case!("req686-au1b", [
        Fx.line("post_beta", %{"posting" => Fx.posting("issue", "b", "-3")})
      ])

    assert {:error, {:entity_write_refused_detailed, 0, :insufficient_balance, _, _}} =
             Fx.complete(ctx)

    assert posted_audits(ctx.schema) == []

    ctx2 = Fx.case!("req686-au1c", two_lines())

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx2, credential: :api_token)

    assert posted_audits(ctx2.schema) == []

    assert {:ok, _} = Fx.complete(ctx2, idempotency_key: "req686-au1c-key")
    assert length(posted_audits(ctx2.schema)) == 2
    _ = Fx.complete(ctx2, idempotency_key: "req686-au1c-key")
    assert length(posted_audits(ctx2.schema)) == 2
    assert {2, 2, 2, 2} = Fx.ledger_counts(ctx2.schema)
  end

  test "T-AU-2 a failure after the counter rolls back counter, entry, legs, balances and audit" do
    ctx = Fx.case!("req686-au2", two_lines())
    schema = ctx.schema

    Repo.query!("""
    CREATE FUNCTION "#{schema}".req686_fail() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'req686 injected failure' USING ERRCODE = 'unique_violation';
    END
    $$
    """)

    # TASK_COMPLETED is the last write of the completion tail, after the counter and the audits
    Repo.query!("""
    CREATE TRIGGER req686_fail BEFORE INSERT ON "#{schema}".events
    FOR EACH ROW WHEN (NEW.event_type = 'TASK_COMPLETED')
    EXECUTE FUNCTION "#{schema}".req686_fail()
    """)

    {result, statements} =
      LF.record(fn ->
        try do
          Fx.complete(ctx)
        rescue
          e in [Postgrex.Error] -> {:raised, e.postgres.code}
        end
      end)

    assert match?({:error, _}, result) or match?({:raised, :unique_violation}, result)
    sql = Enum.map(statements, &elem(&1, 0))

    assert Enum.any?(sql, &(&1 =~ ~r/UPDATE "[^"]+"\."ledger_counter"/)),
           "failed before the counter"

    assert {0, 0, 0, 0} = Fx.ledger_counts(schema)
    assert posted_audits(schema) == []

    %{rows: [[last_seq]]} =
      Repo.query!(~s|SELECT coalesce(max(last_seq), 0) FROM "#{schema}".ledger_counter|)

    assert last_seq == 0
  end
end
