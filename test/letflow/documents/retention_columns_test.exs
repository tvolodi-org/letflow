defmodule Letflow.Documents.RetentionColumnsTest do
  @moduledoc """
  REQ-508 / GH #2675, part (a): the retention policy columns, the hold columns, their CHECKs
  and the column-aware `guard_document_types()` (decision 0063 S3, S5; tests A3, A3b, A5, A7e).
  Design: state/tasks/T-0392/design.md section 7, test IDs C1, H1, T1..T4, T6.
  Raw SQL against a provisioned tenant schema, as in `triggers_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req508-cols")
    %{schema: schema, tenant_id: tenant_id}
  end

  defp insert_type_with(ctx, key, period, from, action) do
    attempt(
      """
      INSERT INTO #{table(ctx.schema, "document_types")}
        (key, tenant_id, owner_module, numbering_scope, number_prefix, number_pad,
         legal_entity_required, declared_fields, inserted_at,
         retention_period_days, retention_from, retention_action)
      VALUES ($1, $2::uuid, 'procurement', 'year', 'PR', 4, false, '{}'::jsonb, now(), $3, $4, $5)
      """,
      [key, ctx.tenant_id, period, from, action]
    )
  end

  defp refused_by?(result, constraint) do
    match?({:refused, %Postgrex.Error{postgres: %{constraint: ^constraint}}}, result)
  end

  describe "C1: type retention columns and CHECKs (A5)" do
    test "a type inserted without the columns reads NULL / issued / keep", ctx do
      key = insert_type!(ctx.schema, ctx.tenant_id)

      assert %{rows: [[nil, "issued", "keep"]]} =
               exec!(
                 "SELECT retention_period_days, retention_from, retention_action FROM #{table(ctx.schema, "document_types")} WHERE key = $1",
                 [key]
               )
    end

    test "each CHECK refuses its violation by name", ctx do
      assert refused_by?(
               insert_type_with(ctx, "t0", 0, "issued", "purge"),
               "document_types_retention_period_chk"
             )

      assert refused_by?(
               insert_type_with(ctx, "t1", -1, "issued", "purge"),
               "document_types_retention_period_chk"
             )

      assert refused_by?(
               insert_type_with(ctx, "t2", 30, "x", "purge"),
               "document_types_retention_from_chk"
             )

      assert refused_by?(
               insert_type_with(ctx, "t3", 30, "issued", "x"),
               "document_types_retention_action_chk"
             )

      assert refused_by?(
               insert_type_with(ctx, "t4", 30, "issued", "keep"),
               "document_types_retention_tie_chk"
             )

      assert refused_by?(
               insert_type_with(ctx, "t5", nil, "issued", "purge"),
               "document_types_retention_tie_chk"
             )

      assert refused_by?(
               insert_type_with(ctx, "t6", nil, "issued", "archive"),
               "document_types_retention_tie_chk"
             )
    end

    test "the legal pairs are accepted", ctx do
      assert :accepted = insert_type_with(ctx, "ok1", 30, "issued", "archive")
      assert :accepted = insert_type_with(ctx, "ok2", 30, "superseded_or_cancelled", "purge")
      assert :accepted = insert_type_with(ctx, "ok3", nil, "issued", "keep")
    end
  end

  describe "H1: document hold columns and CHECKs (A7e)" do
    setup ctx do
      %{type_key: insert_type!(ctx.schema, ctx.tenant_id)}
    end

    defp hold_update(ctx, sets) do
      id = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)

      {assignments, params} =
        sets |> Enum.with_index(2) |> Enum.map(&assignment/1) |> Enum.unzip()

      attempt(
        "UPDATE #{table(ctx.schema, "documents")} SET #{Enum.join(assignments, ", ")} WHERE id = $1::uuid",
        [id | params]
      )
    end

    defp assignment({{column, value}, index}) do
      cast =
        cond do
          column in ~w(hold_set_at hold_cleared_at) -> "timestamptz"
          column in ~w(hold_set_by hold_cleared_by) -> "uuid"
          column == "on_hold" -> "boolean"
          true -> "text"
        end

      {"#{column} = $#{index}::#{cast}", value}
    end

    @now ~U[2026-01-01 00:00:00Z]

    defp set_side do
      [
        {"hold_set_at", @now},
        {"hold_set_by", Ecto.UUID.generate()},
        {"hold_reason_code", "legal"},
        {"hold_reason_note", "note"}
      ]
    end

    defp clear_side do
      [
        {"hold_cleared_at", @now},
        {"hold_cleared_by", Ecto.UUID.generate()},
        {"hold_clear_reason_code", "done"},
        {"hold_clear_reason_note", "note"}
      ]
    end

    test "a new document: on_hold false, the eight columns NULL", ctx do
      id = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)

      assert %{rows: [[false, nil, nil, nil, nil, nil, nil, nil, nil]]} =
               exec!(
                 """
                 SELECT on_hold, hold_set_at, hold_set_by, hold_reason_code, hold_reason_note,
                        hold_cleared_at, hold_cleared_by, hold_clear_reason_code, hold_clear_reason_note
                   FROM #{table(ctx.schema, "documents")} WHERE id = $1::uuid
                 """,
                 [id]
               )
    end

    test "on_hold true with hold_set_at NULL is refused", ctx do
      assert refused_by?(hold_update(ctx, [{"on_hold", true}]), "documents_hold_on_hold_chk")
    end

    test "a set side with only some of its four columns is refused", ctx do
      for missing <- 0..3 do
        partial = set_side() |> List.delete_at(missing)
        assert {:refused, _} = hold_update(ctx, partial), "set side missing #{missing}"
      end
    end

    test "a clear side with only some of its four columns is refused", ctx do
      for missing <- 0..3 do
        partial = set_side() ++ List.delete_at(clear_side(), missing)
        assert {:refused, _} = hold_update(ctx, partial), "clear side missing #{missing}"
      end
    end

    test "hold_cleared_at filled with hold_set_at NULL is refused", ctx do
      assert {:refused, _} = hold_update(ctx, clear_side())
    end

    test "on_hold false with a held shape is refused", ctx do
      assert refused_by?(hold_update(ctx, set_side()), "documents_hold_on_hold_chk")
    end

    test "never held, held and cleared shapes are accepted", ctx do
      assert :accepted = hold_update(ctx, [{"on_hold", false}])
      assert :accepted = hold_update(ctx, [{"on_hold", true} | set_side()])
      assert :accepted = hold_update(ctx, [{"on_hold", false} | set_side() ++ clear_side()])
    end
  end

  describe "T1..T4: guard_document_types() exemption (A3, A3b)" do
    setup ctx do
      key = insert_type!(ctx.schema, ctx.tenant_id)
      set_policy!(ctx.schema, key, 30, "issued", "purge")
      insert_document!(ctx.schema, ctx.tenant_id, key)
      %{type_key: key}
    end

    defp type_update(ctx, set_sql, params \\ []) do
      attempt(
        "UPDATE #{table(ctx.schema, "document_types")} SET #{set_sql} WHERE key = $1",
        [ctx.type_key | params]
      )
    end

    test "T1: each retention column changes alone while a document exists", ctx do
      assert :accepted = type_update(ctx, "retention_from = $2", ["superseded_or_cancelled"])
      assert :accepted = type_update(ctx, "retention_period_days = $2", [60])
      assert :accepted = type_update(ctx, "retention_action = $2", ["archive"])

      assert :accepted =
               type_update(ctx, "retention_period_days = NULL, retention_action = 'keep'")
    end

    @frozen [
      {"key", "key = 'other'"},
      {"tenant_id", "tenant_id = gen_random_uuid()"},
      {"owner_module", "owner_module = 'x'"},
      {"numbering_scope", "numbering_scope = 'none'"},
      {"number_prefix", "number_prefix = 'XX'"},
      {"number_pad", "number_pad = 9"},
      {"legal_entity_required", "legal_entity_required = true"},
      {"restricted_fields_allowed", "restricted_fields_allowed = true"},
      {"declared_fields", "declared_fields = '{\"a\":1}'::jsonb"},
      {"template_ref", "template_ref = 'tpl'"},
      {"inserted_at", "inserted_at = inserted_at + interval '1 day'"}
    ]

    test "T2: each of the eleven frozen columns is refused", ctx do
      for {column, set_sql} <- @frozen do
        result = type_update(ctx, set_sql)
        assert {:refused, _} = result, "#{column} must be refused"

        # restricted_fields_allowed = true also violates the table CHECK; the BEFORE trigger
        # fires first, so the trigger's message is expected for every column.
        assert refusal_message(result) =~ "frozen", "#{column}: #{refusal_message(result)}"
      end
    end

    test "T3: a mixed UPDATE is refused as a whole", ctx do
      assert {:refused, _} =
               type_update(ctx, "retention_from = $2, number_prefix = 'XX'", [
                 "superseded_or_cancelled"
               ])

      assert %{rows: [["issued", "PR"]]} =
               exec!(
                 "SELECT retention_from, number_prefix FROM #{table(ctx.schema, "document_types")} WHERE key = $1",
                 [ctx.type_key]
               )
    end

    test "T4: DELETE and TRUNCATE stay refused", ctx do
      assert {:refused, _} =
               attempt("DELETE FROM #{table(ctx.schema, "document_types")} WHERE key = $1", [
                 ctx.type_key
               ])

      assert {:refused, _} = attempt("TRUNCATE #{table(ctx.schema, "document_types")} CASCADE")
    end

    test "T6: the trigger inventory of the types table is unchanged", ctx do
      %{rows: rows} =
        exec!(
          """
          SELECT tgname FROM pg_trigger
           WHERE tgrelid = $1::text::regclass AND NOT tgisinternal ORDER BY tgname
          """,
          [~s("#{ctx.schema}"."document_types")]
        )

      assert List.flatten(rows) ==
               ~w(document_types_guard_delete document_types_guard_truncate document_types_guard_update)
    end
  end
end
