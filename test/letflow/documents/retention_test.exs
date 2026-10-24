defmodule Letflow.Documents.RetentionTest do
  @moduledoc """
  REQ-508 / GH #2675, part (a): `Letflow.Documents.Retention` -- the eligibility query and the
  policy write function (decision 0063 S1, S2, S4, S5, S6; tests A1, A2, A4, A5, A6, A7d, A10).
  Design: state/tasks/T-0392/design.md section 7, test IDs E1..E8, P1..P5.
  Dates are fixed literals and an injected `now`; no wall clock.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents.Retention

  @day 86_400
  @far ~U[2030-01-01 00:00:00Z]
  @d0 ~U[2026-01-01 00:00:00Z]

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req508-ret")
    key = insert_type!(schema, tenant_id)
    %{schema: schema, tenant_id: tenant_id, key: key}
  end

  defp doc(ctx), do: insert_document!(ctx.schema, ctx.tenant_id, ctx.key)

  # A superseded version (issued at `issued`) whose successor was issued at `closed`.
  defp superseded(ctx, doc_id, issued, closed) do
    next = insert_version_at!(ctx.schema, ctx.tenant_id, doc_id, 2, "issued", closed)

    insert_version_at!(ctx.schema, ctx.tenant_id, doc_id, 1, "superseded", issued,
      superseded_by: next
    )
  end

  defp cancelled(ctx, doc_id, issued, cancelled_at) do
    insert_version_at!(ctx.schema, ctx.tenant_id, doc_id, 1, "cancelled", issued,
      cancelled_at: cancelled_at
    )
  end

  defp ids(ctx, now) do
    {:ok, ids} = Retention.eligible_version_ids(ctx.schema, now)
    ids
  end

  describe "eligibility" do
    test "E1: the default policy returns nothing for any status", ctx do
      d = doc(ctx)
      superseded(ctx, d, @d0, @d0)
      cancelled(ctx, doc(ctx), @d0, @d0)
      assert ids(ctx, @far) == []

      set_policy!(ctx.schema, ctx.key, nil, "superseded_or_cancelled", "keep")
      assert ids(ctx, @far) == []
    end

    test "E2: superseded and cancelled are returned, the other statuses are not", ctx do
      set_policy!(ctx.schema, ctx.key, 30, "issued", "purge")
      sup = superseded(ctx, doc(ctx), @d0, DateTime.add(@d0, @day))
      can = cancelled(ctx, doc(ctx), @d0, DateTime.add(@d0, @day))

      # a current issued version, an issued version with no current pointer, a draft, a discarded one
      cur_doc = doc(ctx)
      cur = insert_version_at!(ctx.schema, ctx.tenant_id, cur_doc, 1, "issued", @d0)
      set_current!(ctx.schema, cur_doc, cur)
      insert_version_at!(ctx.schema, ctx.tenant_id, doc(ctx), 1, "issued", @d0)
      insert_version_at!(ctx.schema, ctx.tenant_id, doc(ctx), 1, "draft", nil)
      insert_version_at!(ctx.schema, ctx.tenant_id, doc(ctx), 1, "discarded", nil)

      expected = Enum.sort([sup, can])
      assert Enum.sort(Enum.map(ids(ctx, @far), &Ecto.UUID.cast!/1)) == expected

      set_policy!(ctx.schema, ctx.key, 30, "issued", "archive")
      assert ids(ctx, @far) |> Enum.sort() == expected
    end

    test "E3: closing time is cancelled_at, or the successor's issued_at", ctx do
      set_policy!(ctx.schema, ctx.key, 30, "superseded_or_cancelled", "purge")
      closed = ~U[2026-03-01 00:00:00Z]
      can = cancelled(ctx, doc(ctx), @d0, closed)
      boundary = DateTime.add(closed, 30 * @day)
      assert ids(ctx, boundary) == [can]
      assert ids(ctx, DateTime.add(boundary, -1)) == []

      sup = superseded(ctx, doc(ctx), @d0, DateTime.add(closed, 100 * @day))
      later = DateTime.add(closed, 130 * @day)
      assert sup in ids(ctx, later)
      refute sup in ids(ctx, DateTime.add(later, -1))

      assert %{rows: []} =
               exec!(
                 "SELECT 1 FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'document_versions' AND column_name = 'superseded_at'",
                 [ctx.schema]
               )
    end

    test "E4: D15 reading of a version issued 31 days and closed 5 days before now", ctx do
      now = ~U[2026-06-01 00:00:00Z]
      closed = DateTime.add(now, -5 * @day)
      v = superseded(ctx, doc(ctx), DateTime.add(now, -31 * @day), closed)

      set_policy!(ctx.schema, ctx.key, 30, "issued", "purge")
      assert ids(ctx, now) == [v]

      set_policy!(ctx.schema, ctx.key, 30, "superseded_or_cancelled", "purge")
      assert ids(ctx, now) == []
      assert ids(ctx, DateTime.add(closed, 29 * @day)) == []
      assert ids(ctx, DateTime.add(closed, 30 * @day)) == [v]
    end

    test "E5: a superseded version whose successor is a draft is not returned", ctx do
      set_policy!(ctx.schema, ctx.key, 30, "superseded_or_cancelled", "purge")
      d = doc(ctx)
      draft = insert_version_at!(ctx.schema, ctx.tenant_id, d, 2, "draft", nil)
      insert_version_at!(ctx.schema, ctx.tenant_id, d, 1, "superseded", @d0, superseded_by: draft)
      assert ids(ctx, @far) == []
    end

    test "E6: a held document is excluded, a cleared one is returned", ctx do
      set_policy!(ctx.schema, ctx.key, 30, "issued", "purge")
      d = doc(ctx)
      v = superseded(ctx, d, @d0, DateTime.add(@d0, @day))
      assert ids(ctx, @far) == [v]

      exec!(
        """
        UPDATE #{table(ctx.schema, "documents")}
           SET on_hold = true, hold_set_at = now(), hold_set_by = $2::uuid,
               hold_reason_code = 'legal', hold_reason_note = 'n'
         WHERE id = $1::uuid
        """,
        [d, Ecto.UUID.generate()]
      )

      assert ids(ctx, @far) == []

      exec!(
        """
        UPDATE #{table(ctx.schema, "documents")}
           SET on_hold = false, hold_cleared_at = now(), hold_cleared_by = $2::uuid,
               hold_clear_reason_code = 'done', hold_clear_reason_note = 'n'
         WHERE id = $1::uuid
        """,
        [d, Ecto.UUID.generate()]
      )

      assert ids(ctx, @far) == [v]
    end

    test "E7: the query writes nothing", ctx do
      set_policy!(ctx.schema, ctx.key, 30, "issued", "purge")
      superseded(ctx, doc(ctx), @d0, DateTime.add(@d0, @day))

      snapshot = fn ->
        for t <- ~w(document_types documents document_versions audit_entries) do
          exec!(
            "SELECT coalesce(md5(string_agg(to_jsonb(x)::text, '|' ORDER BY to_jsonb(x)::text)), '') FROM #{table(ctx.schema, t)} x"
          ).rows
        end
      end

      before = snapshot.()
      assert [_] = ids(ctx, @far)
      assert snapshot.() == before
    end

    test "E8: each tenant sees only its own versions; a bad prefix is refused", ctx do
      set_policy!(ctx.schema, ctx.key, 30, "issued", "purge")
      mine = superseded(ctx, doc(ctx), @d0, DateTime.add(@d0, @day))

      %{schema_name: other, tenant_id: other_tenant} = provisioned_tenant!("req508-oth")
      other_key = insert_type!(other, other_tenant)
      set_policy!(other, other_key, 30, "issued", "purge")
      od = insert_document!(other, other_tenant, other_key)
      next = insert_version_at!(other, other_tenant, od, 2, "issued", DateTime.add(@d0, @day))

      theirs =
        insert_version_at!(other, other_tenant, od, 1, "superseded", @d0, superseded_by: next)

      assert ids(ctx, @far) == [mine]
      assert {:ok, [^theirs]} = Retention.eligible_version_ids(other, @far)
      assert {:error, :invalid_schema_name} = Retention.eligible_version_ids("public", @far)
      assert {:error, :invalid_schema_name} = Retention.eligible_version_ids("tenant_x", @far)
    end
  end

  describe "change_policy/5" do
    @actor "11111111-1111-4111-8111-111111111111"
    @new %{
      retention_period_days: 60,
      retention_from: "superseded_or_cancelled",
      retention_action: "purge"
    }

    defp type_row(ctx) do
      exec!(
        "SELECT retention_period_days, retention_from, retention_action FROM #{table(ctx.schema, "document_types")} WHERE key = $1",
        [ctx.key]
      ).rows
    end

    defp audit_rows(ctx) do
      exec!(
        "SELECT actor_id::text, resource_type, resource_id, before_state, after_state FROM #{table(ctx.schema, "audit_entries")} WHERE action = 'document.retention_policy_changed'"
      ).rows
    end

    test "P1: a change updates the columns and writes one audit entry", ctx do
      doc(ctx)

      assert {:ok, %{changed: true, before: before, after: after_}} =
               Retention.change_policy(ctx.schema, ctx.key, @new, @actor, "contract_review")

      assert before == %{
               retention_period_days: nil,
               retention_from: "issued",
               retention_action: "keep"
             }

      assert after_ == @new
      assert type_row(ctx) == [[60, "superseded_or_cancelled", "purge"]]

      assert [[@actor, "document_type", key, b, a]] = audit_rows(ctx)
      assert key == ctx.key

      assert b == %{
               "type_key" => ctx.key,
               "retention_period_days" => nil,
               "retention_from" => "issued",
               "retention_action" => "keep"
             }

      assert a == %{
               "type_key" => ctx.key,
               "retention_period_days" => 60,
               "retention_from" => "superseded_or_cancelled",
               "retention_action" => "purge",
               "reason_code" => "contract_review"
             }
    end

    test "P2: a broken tie or bad input is refused before the database", ctx do
      call = fn attrs, actor, code ->
        Retention.change_policy(ctx.schema, ctx.key, attrs, actor, code)
      end

      mismatch = {:error, {:unprocessable, :period_action_mismatch}}
      base = %{retention_period_days: 30, retention_from: "issued", retention_action: "keep"}

      {results, queries} =
        Letflow.TestSupport.QueryCount.count_statements(fn ->
          [
            call.(base, @actor, "ok"),
            call.(%{base | retention_period_days: nil, retention_action: "purge"}, @actor, "ok"),
            call.(%{base | retention_period_days: nil, retention_action: "archive"}, @actor, "ok")
          ]
        end)

      assert results == [mismatch, mismatch, mismatch]
      assert queries == 0

      assert {:error, {:unprocessable, :invalid_period}} =
               call.(%{@new | retention_period_days: 0}, @actor, "ok")

      assert {:error, {:unprocessable, :invalid_period}} =
               call.(%{@new | retention_period_days: -1}, @actor, "ok")

      assert {:error, {:unprocessable, :invalid_period}} =
               call.(%{@new | retention_period_days: "30"}, @actor, "ok")

      assert {:error, {:unprocessable, :invalid_retention_from}} =
               call.(%{@new | retention_from: "x"}, @actor, "ok")

      assert {:error, {:unprocessable, :invalid_retention_action}} =
               call.(%{@new | retention_action: "x"}, @actor, "ok")

      for code <- ["", "Free text!", String.duplicate("a", 65), nil] do
        assert {:error, {:unprocessable, :invalid_reason_code}} = call.(@new, @actor, code)
      end

      assert {:error, {:unprocessable, :invalid_actor}} = call.(@new, "nope", "ok")

      assert type_row(ctx) == [[nil, "issued", "keep"]]
      assert audit_rows(ctx) == []
    end

    test "P3: an unknown key, or a key of another tenant, is not found", ctx do
      assert {:error, :not_found} =
               Retention.change_policy(ctx.schema, "nope", @new, @actor, "ok")

      %{schema_name: other, tenant_id: other_tenant} = provisioned_tenant!("req508-oth")
      other_key = insert_type!(other, other_tenant, "only_in_b")

      assert {:error, :not_found} =
               Retention.change_policy(ctx.schema, other_key, @new, @actor, "ok")

      assert exec!(
               "SELECT retention_action FROM #{table(other, "document_types")} WHERE key = $1",
               [other_key]
             ).rows == [["keep"]]

      assert audit_rows(ctx) == []

      assert {:error, :invalid_schema_name} =
               Retention.change_policy("public", ctx.key, @new, @actor, "ok")
    end

    test "P4: the column change and the audit entry roll back together", ctx do
      exec!(
        "ALTER TABLE #{table(ctx.schema, "audit_entries")} ADD CONSTRAINT force_fail CHECK (false) NOT VALID"
      )

      assert_raise Ecto.ConstraintError, fn ->
        Retention.change_policy(ctx.schema, ctx.key, @new, @actor, "ok")
      end

      assert type_row(ctx) == [[nil, "issued", "keep"]]
      assert audit_rows(ctx) == []
    end

    test "P5: an unchanged policy is a no-op", ctx do
      same = %{retention_period_days: nil, retention_from: "issued", retention_action: "keep"}

      assert {:ok, %{changed: false}} =
               Retention.change_policy(ctx.schema, ctx.key, same, @actor, "ok")

      assert audit_rows(ctx) == []
    end
  end
end
