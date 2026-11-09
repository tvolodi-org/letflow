defmodule Letflow.Ledger.DocumentPostedAuditTest do
  @moduledoc """
  T-1557 (B2 #5): a completion that posts a ledger entry for a document also writes one
  `document.posted` / `document.reversed` / `document.written_off` audit entry keyed by the
  document id (T1..T3). `ledger.posted` itself is covered unchanged by `LedgerAuditTest` (T4).
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.Audit.LedgerPosted
  alias Letflow.LedgerPostFixture, as: Fx

  defp summary(cause, doc_id) do
    %{
      entry_id: Ecto.UUID.generate(),
      ledger_id: "l1",
      posting_seq: 1,
      cause: cause,
      leg_count: 1,
      chain_hash: "h",
      document_type: "doc",
      document_id: doc_id
    }
  end

  test "T1 a completion writes one document.posted entry keyed by the document id" do
    ctx =
      Fx.case!("t1557-t1", [
        Fx.line("post_alpha", %{"posting" => Fx.posting("receipt", "a", "5")})
      ])

    assert {:ok, _} = Fx.complete(ctx)

    %{rows: rows} =
      Repo.query!(
        ~s|SELECT resource_type, resource_id, actor_id::text, after_state FROM "#{ctx.schema}".audit_entries WHERE action = 'document.posted'|
      )

    assert [["document", "d1", actor, state]] = rows
    assert actor == ctx.completer.id
    assert state["cause"] == "receipt" and state["document_type"] == "doc"
    assert Enum.sort(Map.keys(state)) == ~w(actor_id cause document_type entry_id ledger_id)
  end

  test "T2 a reversal cause maps to document.reversed" do
    attrs = LedgerPosted.document_attrs(summary("reversal", "d9"), "u1")
    assert attrs.action == "document.reversed"
    assert attrs.resource_type == "document" and attrs.resource_id == "d9"
  end

  test "T3 a writeoff cause maps to document.written_off" do
    assert LedgerPosted.document_attrs(summary("writeoff", "d9"), "u1").action ==
             "document.written_off"
  end

  test "T4 no document id writes no document entry; ledger.posted bytes unchanged" do
    assert LedgerPosted.document_attrs(summary("receipt", nil), "u1") == nil
    assert LedgerPosted.document_attrs(summary("receipt", ""), "u1") == nil

    assert Map.keys(LedgerPosted.attrs(summary("receipt", "d"), "u1").after_state) |> length() ==
             7
  end
end
