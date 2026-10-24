defmodule Letflow.Documents.HoldTest do
  @moduledoc """
  REQ-536 / GH #3106, part (b): `Letflow.Documents.Hold` -- hold set and clear (decision 0063 S5,
  tests A7, A7a, A7b, A7c, A7d, A7f). Design: state/tasks/T-0393/design.md section 6, IDs H1..H11.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents.Hold
  alias Letflow.Documents.Retention

  @actor "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @attrs %{reason_code: "legal_matter", reason_note: "  freeze for case 17  "}
  @far ~U[2030-01-01 00:00:00Z]

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req536-hold")
    key = insert_type!(schema, tenant_id)
    %{schema: schema, tenant_id: tenant_id, key: key}
  end

  defp doc(ctx, opts \\ []), do: insert_document!(ctx.schema, ctx.tenant_id, ctx.key, opts)

  defp row(ctx, id) do
    exec!(
      """
      SELECT on_hold, hold_set_at IS NOT NULL, hold_set_by::text, hold_reason_code, hold_reason_note,
             hold_cleared_at IS NOT NULL, hold_cleared_by::text, hold_clear_reason_code,
             hold_clear_reason_note
      FROM #{table(ctx.schema, "documents")} WHERE id = $1
      """,
      [id]
    ).rows
  end

  defp events(ctx, id) do
    Letflow.Repo.query!(
      """
      SELECT action, after_state FROM #{table(ctx.schema, "audit_entries")}
      WHERE resource_type = 'document' AND resource_id = $1 ORDER BY timestamp, id
      """,
      [id]
    ).rows
  end

  defp event_count(ctx) do
    [[n]] = exec!("SELECT count(*) FROM #{table(ctx.schema, "audit_entries")}").rows
    n
  end

  defp set(ctx, id, attrs \\ @attrs, scope \\ :all),
    do: Hold.set(ctx.schema, id, scope, attrs, @actor)

  defp release(ctx, id, attrs \\ @attrs, scope \\ :all),
    do: Hold.release(ctx.schema, id, scope, attrs, @actor)

  describe "set" do
    test "H1: fills the set side, NULLs the clear side, one event without the note", ctx do
      id = doc(ctx)

      assert {:ok, %{document_id: ^id, on_hold: true, reason_code: "legal_matter"}} = set(ctx, id)

      assert [
               [
                 true,
                 true,
                 @actor,
                 "legal_matter",
                 "  freeze for case 17  ",
                 false,
                 nil,
                 nil,
                 nil
               ]
             ] =
               row(ctx, id)

      assert [["document.hold_set", payload]] = events(ctx, id)
      assert payload == %{"document_id" => id, "reason_code" => "legal_matter", "actor" => @actor}
      refute inspect(payload) =~ "freeze"
    end

    test "H2: a missing or blank code or note is 422", ctx do
      id = doc(ctx)

      for bad <- [
            %{reason_note: "n"},
            %{reason_code: "", reason_note: "n"},
            %{reason_code: "Bad Code", reason_note: "n"},
            %{reason_code: 5, reason_note: "n"},
            %{reason_code: "legal_matter"},
            %{reason_code: "legal_matter", reason_note: "   "},
            %{reason_code: "legal_matter", reason_note: nil},
            %{reason_code: "legal_matter", reason_note: String.duplicate("x", 2001)}
          ] do
        assert {:error, {:unprocessable, _}} = set(ctx, id, bad)
      end

      assert [[false | _]] = row(ctx, id)
      assert event_count(ctx) == 0
    end

    test "H2b: the 422 wins over the state check on an already-held document", ctx do
      id = doc(ctx)
      {:ok, _} = set(ctx, id)
      before = row(ctx, id)

      assert {:error, {:unprocessable, :invalid_reason_note}} =
               set(ctx, id, %{reason_code: "legal_matter", reason_note: " "})

      assert {:error, {:unprocessable, :invalid_reason_code}} = set(ctx, id, %{})
      assert row(ctx, id) == before
      assert length(events(ctx, id)) == 1
    end
  end

  describe "release" do
    test "H3: fills the clear side, keeps the set side, one event", ctx do
      id = doc(ctx)
      {:ok, _} = set(ctx, id)
      attrs = %{reason_code: "case_closed", reason_note: "released"}

      assert {:ok, %{on_hold: false, reason_code: "case_closed"}} = release(ctx, id, attrs)

      assert [[false, true, @actor, "legal_matter", _, true, @actor, "case_closed", "released"]] =
               row(ctx, id)

      assert [["document.hold_set", _], ["document.hold_cleared", payload]] = events(ctx, id)
      assert payload == %{"document_id" => id, "reason_code" => "case_closed", "actor" => @actor}
      refute inspect(payload) =~ "released"
    end

    test "H4: a missing or blank code or note is 422", ctx do
      id = doc(ctx)
      {:ok, _} = set(ctx, id)
      before = row(ctx, id)

      for bad <- [
            %{reason_note: "n"},
            %{reason_code: "x"},
            %{reason_code: "legal_matter", reason_note: ""}
          ] do
        assert {:error, {:unprocessable, _}} = release(ctx, id, bad)
      end

      assert row(ctx, id) == before
      assert length(events(ctx, id)) == 1
    end
  end

  describe "conflicts" do
    test "H5: set on a held document is 409, nothing changes", ctx do
      id = doc(ctx)
      {:ok, _} = set(ctx, id)
      before = row(ctx, id)
      count = event_count(ctx)

      assert {:error, :conflict} = set(ctx, id)
      assert row(ctx, id) == before
      assert event_count(ctx) == count
    end

    test "H6: release on a never-held and on an already-cleared document is 409", ctx do
      never = doc(ctx)
      before = row(ctx, never)
      assert {:error, :conflict} = release(ctx, never)
      assert row(ctx, never) == before
      assert event_count(ctx) == 0

      cleared = doc(ctx)
      {:ok, _} = set(ctx, cleared)
      {:ok, _} = release(ctx, cleared)
      before = row(ctx, cleared)
      count = event_count(ctx)

      assert {:error, :conflict} = release(ctx, cleared)
      assert row(ctx, cleared) == before
      assert event_count(ctx) == count
    end

    test "H7: set after clear overwrites the set side; audit order set, cleared, set", ctx do
      id = doc(ctx)
      {:ok, _} = set(ctx, id)
      {:ok, _} = release(ctx, id)

      assert {:ok, %{on_hold: true}} =
               set(ctx, id, %{reason_code: "second_matter", reason_note: "again"})

      assert [[true, true, @actor, "second_matter", "again", false, nil, nil, nil]] = row(ctx, id)

      assert ["document.hold_set", "document.hold_cleared", "document.hold_set"] =
               Enum.map(events(ctx, id), &hd/1)
    end
  end

  describe "atomicity and eligibility" do
    test "H8: a failing audit insert rolls the columns back", ctx do
      id = doc(ctx)

      exec!(
        "ALTER TABLE #{table(ctx.schema, "audit_entries")} ADD CONSTRAINT force_fail CHECK (false) NOT VALID"
      )

      assert_raise Ecto.ConstraintError, fn -> set(ctx, id) end
      assert [[false, false, nil, nil, nil, false, nil, nil, nil]] = row(ctx, id)
    end

    test "H9: FOR UPDATE precedes the on_hold read and the event write in both functions" do
      path = Path.expand("../../../lib/letflow/documents/hold.ex", __DIR__)
      assert File.exists?(path)
      src = File.read!(path)

      # both public functions go through the one transition path ...
      assert src =~ ~r/def set\(.*\n\s+do: transition\(:set,/
      assert src =~ ~r/def release\(.*\n\s+do: transition\(:release,/

      # ... whose order is: lock, then on_hold, then columns, then the audit event
      {lock, _} = :binary.match(src, ~s(lock: "FOR UPDATE"))
      {call, _} = :binary.match(src, "case lock_document(")
      {on_hold, _} = :binary.match(src, "%Document{on_hold: on_hold}")
      {columns, _} = :binary.match(src, "write_columns(kind,")
      {event, _} = :binary.match(src, "write_event(kind,")
      assert lock < call and call < on_hold and on_hold < columns and columns < event

      # the locking query is the only reader of the documents row
      assert length(Regex.scan(~r/Repo\.one\(/, src)) == 1
    end

    test "H10: a held document is not eligible; eligible again after release", ctx do
      exec!(
        "UPDATE #{table(ctx.schema, "document_types")} SET retention_period_days = 1, retention_from = 'issued', retention_action = 'purge' WHERE key = $1",
        [ctx.key]
      )

      id = doc(ctx)

      v =
        insert_version_at!(
          ctx.schema,
          ctx.tenant_id,
          id,
          1,
          "cancelled",
          ~U[2026-01-01 00:00:00Z],
          cancelled_at: ~U[2026-01-02 00:00:00Z]
        )

      assert {:ok, [^v]} = Retention.eligible_version_ids(ctx.schema, @far)
      {:ok, _} = set(ctx, id)
      assert {:ok, []} = Retention.eligible_version_ids(ctx.schema, @far)
      {:ok, _} = release(ctx, id)
      assert {:ok, [^v]} = Retention.eligible_version_ids(ctx.schema, @far)
    end
  end

  describe "scope" do
    test "H11: the caller's node set filters inside the locked query", ctx do
      own = Ecto.UUID.generate()
      other = Ecto.UUID.generate()
      mine = doc(ctx, issuing_org_unit_id: own)
      theirs = doc(ctx, issuing_org_unit_id: other)

      assert {:error, :not_found} = set(ctx, theirs, @attrs, {:nodes, [own]})
      assert [[false | _]] = row(ctx, theirs)
      assert {:error, :not_found} = set(ctx, mine, @attrs, :none)
      assert {:error, :not_found} = set(ctx, mine, @attrs, {:nodes, []})
      assert {:error, :not_found} = set(ctx, mine, @attrs, {:nodes, ["r"]})

      # a non-UUID node in the set does not raise
      assert {:error, :not_found} = set(ctx, theirs, @attrs, {:nodes, ["r", own]})
      assert {:ok, %{on_hold: true}} = set(ctx, mine, @attrs, {:nodes, ["r", own]})
      assert {:ok, %{on_hold: false}} = release(ctx, mine, @attrs, {:nodes, [own, other]})
      assert event_count(ctx) == 2
    end

    test "H12: an absent or malformed id is not_found; a bad schema is refused", ctx do
      assert {:error, :not_found} = set(ctx, Ecto.UUID.generate())
      assert {:error, :not_found} = set(ctx, "not-a-uuid")
      assert {:error, :not_found} = set(ctx, nil)

      assert {:error, {:unprocessable, :invalid_actor}} =
               Hold.set(ctx.schema, Ecto.UUID.generate(), :all, @attrs, "nope")

      assert {:error, :invalid_schema_name} =
               Hold.set("public", Ecto.UUID.generate(), :all, @attrs, @actor)
    end
  end
end
