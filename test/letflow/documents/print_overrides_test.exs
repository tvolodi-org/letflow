defmodule Letflow.Documents.PrintOverridesTest do
  @moduledoc """
  REQ-579 / GH #3289, part 1: `Letflow.Documents.PrintOverrides` (context level; the HTTP halves
  are part 2). Design: state/tasks/T-0650/design.md, IDs S1-store, S2-save-*, S2-sod-*,
  S2-audit-*, D5-redact-*, C3-manage-ctx.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents.Canonical
  alias Letflow.Documents.PrintOverrides

  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @bob "1e6a7a66-6b4d-4c3f-8b38-7b8e8b5b2d22"
  @sentinel "SENTINEL-9f3c-literal"
  @declared ~s({"order": ["number", "total"], "line": ["sku"]})
  @actions ~w(document.print_override_saved document.print_override_activated document.print_override_retired)

  defp layout(extra \\ []) do
    %{
      "layout_schema_version" => 1,
      "blocks" =>
        [
          %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"},
          %{"type" => "text", "text" => "Order"},
          %{"type" => "field", "entity_type" => "order", "field_name" => "number"},
          %{
            "type" => "table",
            "entity_type" => "line",
            "columns" => [%{"field_name" => "sku", "header" => "SKU", "width" => 40}]
          },
          %{"type" => "spacer", "height_mm" => 5}
        ] ++ extra
    }
  end

  defp insert_invoice_type!(schema, tenant_id) do
    exec!(
      """
      INSERT INTO #{table(schema, "document_types")}
        (key, tenant_id, owner_module, numbering_scope, number_prefix, number_pad,
         legal_entity_required, declared_fields, inserted_at)
      VALUES ('invoice', $1::uuid, 'procurement', 'year', 'IN', 4, false, '#{@declared}'::jsonb, now())
      """,
      [tenant_id]
    )

    "invoice"
  end

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req579-po")
    key = insert_invoice_type!(schema, tenant_id)
    %{schema: schema, tenant_id: tenant_id, key: key}
  end

  defp attrs(ctx, extra \\ %{}),
    do: Map.merge(%{type_key: ctx.key, locale: "ru", layout: layout()}, extra)

  defp save!(ctx, extra \\ %{}, actor \\ @alice) do
    {:ok, row} = PrintOverrides.save_draft(ctx.schema, attrs(ctx, extra), actor)
    row
  end

  defp active!(ctx, extra \\ %{}) do
    row = save!(ctx, extra)
    {:ok, row} = PrintOverrides.activate(ctx.schema, row.id, %{reason_code: "go_live"}, @bob)
    row
  end

  defp count(ctx, what) do
    [[n]] = exec!("SELECT count(*) FROM #{table(ctx.schema, what)}").rows
    n
  end

  defp audit_rows(ctx) do
    exec!(
      """
      SELECT action, after_state, before_state FROM #{table(ctx.schema, "audit_entries")}
      WHERE action = ANY($1) ORDER BY timestamp, id
      """,
      [@actions]
    ).rows
  end

  defp statuses(ctx) do
    exec!(
      "SELECT version_no, status FROM #{table(ctx.schema, "document_print_overrides")} ORDER BY version_no"
    ).rows
  end

  defp force_audit_fail(ctx) do
    exec!(
      "ALTER TABLE #{table(ctx.schema, "audit_entries")} ADD CONSTRAINT force_fail CHECK (false) NOT VALID"
    )
  end

  describe "S1-store / C3-manage-ctx" do
    test "S1-store: a provisioned tenant has the table and the row carries tenant_id", ctx do
      row = save!(ctx)
      assert row.tenant_id == ctx.tenant_id

      [[n]] =
        exec!(
          "SELECT count(*) FROM #{table(ctx.schema, "document_print_overrides")} WHERE tenant_id = $1::uuid",
          [ctx.tenant_id]
        ).rows

      assert n == 1
    end

    test "S1-store: CHECKs refuse a bad locale, a bad status and activated_by = created_by",
         ctx do
      ins = fn locale, status, act ->
        attempt(
          """
          INSERT INTO #{table(ctx.schema, "document_print_overrides")}
            (id, tenant_id, type_key, locale, version_no, status, layout, layout_hash,
             layout_schema_version, created_by, activated_by, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1::uuid, 'invoice', $2, 1, $3, '{}'::jsonb, $4, 1, $5::uuid, $6::uuid, now(), now())
          """,
          [ctx.tenant_id, locale, status, String.duplicate("a", 64), @alice, act]
        )
      end

      assert {:refused, e} = ins.("fr", "draft", nil)
      assert e.postgres.code == :check_violation
      assert {:refused, e} = ins.("ru", "x", nil)
      assert e.postgres.code == :check_violation
      assert {:refused, e} = ins.("ru", "draft", @alice)
      assert e.postgres.constraint == "document_print_overrides_sod_chk"
    end

    test "C3-manage-ctx: another tenant's prefix sees nothing and gets not_found", ctx do
      %{schema_name: other, tenant_id: other_id} = provisioned_tenant!("req579-po-b")
      insert_invoice_type!(other, other_id)
      mine = save!(ctx)
      {:ok, theirs} = PrintOverrides.save_draft(other, attrs(ctx), @alice)

      assert {:ok, [%{id: id}]} = PrintOverrides.list(ctx.schema)
      assert id == mine.id

      for fun <- [
            fn id -> PrintOverrides.get(ctx.schema, id) end,
            fn id -> PrintOverrides.activate(ctx.schema, id, %{reason_code: "x"}, @bob) end,
            fn id -> PrintOverrides.retire(ctx.schema, id, %{reason_code: "x"}, @bob) end
          ] do
        assert {:error, :not_found} = fun.(theirs.id)
        assert {:error, :not_found} = fun.(Ecto.UUID.generate())
        assert {:error, :not_found} = fun.("not-a-uuid")
      end

      assert {:ok, %{status: "draft"}} = PrintOverrides.get(other, theirs.id)
    end
  end

  describe "save_draft" do
    test "S2-save-1: all block types save; versions are server-side; hash is independent", ctx do
      first = save!(ctx)
      second = save!(ctx)
      other_locale = save!(ctx, %{locale: "kk"})

      assert {first.status, first.version_no, first.created_by} == {"draft", 1, @alice}
      assert second.version_no == 2
      assert other_locale.version_no == 1
      {:ok, bytes} = Canonical.canonicalize(layout())
      assert first.layout_hash == :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      assert first.layout_schema_version == 1
    end

    test "S2-save-2: server-owned keys in attrs are ignored", ctx do
      row =
        save!(ctx, %{
          tenant_id: Ecto.UUID.generate(),
          version_no: 99,
          status: "active",
          created_by: @bob
        })

      assert {row.tenant_id, row.version_no, row.status, row.created_by} ==
               {ctx.tenant_id, 1, "draft", @alice}
    end

    test "S2-save-3: unknown type, bad locale and bad layouts are refused and store nothing",
         ctx do
      assert {:error, {:unprocessable, :unknown_type_key}} =
               PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{type_key: "nope"}), @alice)

      assert {:error, {:unprocessable, :invalid_locale}} =
               PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{locale: "fr"}), @alice)

      bad_field = layout([%{"type" => "field", "entity_type" => "order", "field_name" => "zzz"}])

      assert {:error, {:invalid_layout, [_ | _]}} =
               PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{layout: bad_field}), @alice)

      bad_block = layout([%{"type" => "video"}])

      assert {:error, {:invalid_layout, [_ | _]}} =
               PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{layout: bad_block}), @alice)

      assert {:error, {:invalid_layout, _}} =
               PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{layout: "x"}), @alice)

      assert count(ctx, "document_print_overrides") == 0
      assert audit_rows(ctx) == []
    end

    test "S2-save-float: a float layout number is refused and stores nothing", ctx do
      page = %{"type" => "page", "size" => "A4", "margin_mm" => 12.5, "font" => "dejavu-sans"}
      l = %{"layout_schema_version" => 1, "blocks" => [page]}

      assert {:error, {:unprocessable, :invalid_layout}} =
               PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{layout: l}), @alice)

      assert count(ctx, "document_print_overrides") == 0
      assert audit_rows(ctx) == []
    end
  end

  describe "activate / retire" do
    test "S2-sod-1: creator is refused; a second user activates and supersedes the previous",
         ctx do
      old = active!(ctx)
      draft = save!(ctx)

      assert {:error, {:conflict, :needs_second_admin}} =
               PrintOverrides.activate(ctx.schema, draft.id, %{reason_code: "go_live"}, @alice)

      assert statuses(ctx) == [[1, "active"], [2, "draft"]]

      assert {:ok, row} =
               PrintOverrides.activate(ctx.schema, draft.id, %{reason_code: "go_live"}, @bob)

      assert {row.status, row.activated_by, row.reason_code} == {"active", @bob, "go_live"}
      assert statuses(ctx) == [[1, "retired"], [2, "active"]]
      {:ok, previous} = PrintOverrides.get(ctx.schema, old.id)
      assert previous.reason_code == "superseded"
      assert previous.retired_at
    end

    test "S2-sod-2: the creator may retire an active row", ctx do
      row = active!(ctx)

      assert {:ok, %{status: "retired", reason_code: "obsolete"}} =
               PrintOverrides.retire(ctx.schema, row.id, %{reason_code: "obsolete"}, @alice)
    end

    test "S2-sod-3: wrong-status calls are fixed 409s and change nothing", ctx do
      active = active!(ctx)
      draft = save!(ctx, %{locale: "kk"})
      {:ok, retired} = PrintOverrides.retire(ctx.schema, active.id, %{reason_code: "old"}, @bob)
      before = statuses(ctx)
      a = %{reason_code: "x"}
      other = active!(ctx, %{locale: "default"})

      assert {:error, {:conflict, :not_a_draft}} =
               PrintOverrides.activate(ctx.schema, other.id, a, @alice)

      assert {:error, {:conflict, :not_a_draft}} =
               PrintOverrides.activate(ctx.schema, retired.id, a, @bob)

      assert {:error, {:conflict, :not_active}} =
               PrintOverrides.retire(ctx.schema, draft.id, a, @bob)

      assert {:error, {:conflict, :not_active}} =
               PrintOverrides.retire(ctx.schema, retired.id, a, @bob)

      assert Enum.take(statuses(ctx), length(before)) == before

      assert PrintOverrides.conflict_reason(:not_a_draft) ==
               "override is not in a status that allows this action"

      assert PrintOverrides.conflict_reason(:not_active) ==
               PrintOverrides.conflict_reason(:not_a_draft)

      assert PrintOverrides.conflict_reason(:needs_second_admin) ==
               "activation needs a second administrator"
    end
  end

  describe "D5-redact" do
    test "D5-redact-1: activate re-validates against a restriction added after the save", ctx do
      page = %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"}
      lit = %{"type" => "text", "text" => @sentinel}
      field = %{"type" => "field", "entity_type" => "order", "field_name" => "total"}

      draft =
        save!(ctx, %{layout: %{"layout_schema_version" => 1, "blocks" => [page, lit, field]}})

      exec!(
        "INSERT INTO #{table(ctx.schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), 'order', 'total', now(), now())"
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:res, PrintOverrides.activate(ctx.schema, draft.id, %{reason_code: "x"}, @bob)}
          )
        end)

      assert_received {:res, res}
      assert {:error, {:invalid_layout, [%{rule: :field_restricted, path: _}]}} = res
      refute inspect(res) =~ @sentinel
      refute log =~ @sentinel
      assert statuses(ctx) == [[1, "draft"]]
      refute inspect(audit_rows(ctx)) =~ @sentinel
    end

    test "D5-redact-2: undeclared and restricted fields are refused on save", ctx do
      exec!(
        "INSERT INTO #{table(ctx.schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), 'order', 'total', now(), now())"
      )

      for name <- ["zzz", "total"] do
        l = layout([%{"type" => "field", "entity_type" => "order", "field_name" => name}])

        assert {:error, {:invalid_layout, [%{rule: rule, path: path}]}} =
                 PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{layout: l}), @alice)

        assert is_atom(rule) and is_list(path)
      end

      assert count(ctx, "document_print_overrides") == 0
    end
  end

  describe "audit" do
    test "S2-audit-1/2: one row per call, exact seven keys, no layout content", ctx do
      page = %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"}
      lit = %{"type" => "text", "text" => @sentinel}
      draft = save!(ctx, %{layout: %{"layout_schema_version" => 1, "blocks" => [page, lit]}})
      assert length(audit_rows(ctx)) == 1
      {:ok, _} = PrintOverrides.activate(ctx.schema, draft.id, %{reason_code: "go_live"}, @bob)
      assert length(audit_rows(ctx)) == 2
      {:ok, _} = PrintOverrides.retire(ctx.schema, draft.id, %{reason_code: "obsolete"}, @bob)
      rows = audit_rows(ctx)

      assert Enum.map(rows, &hd/1) == @actions

      for [_, after_state, before_state] <- rows do
        assert after_state |> Map.keys() |> Enum.sort() ==
                 ~w(actor_id layout_hash locale override_id reason_code type_key version_no)

        assert after_state["override_id"] == draft.id
        assert after_state["layout_hash"] == draft.layout_hash
        refute inspect({after_state, before_state}) =~ @sentinel
      end

      assert [_, %{"reason_code" => nil}, _] = Enum.at(rows, 0)
      assert [_, %{"reason_code" => "go_live", "actor_id" => @bob}, _] = Enum.at(rows, 1)
    end

    test "S2-audit-3: refusals write no audit row", ctx do
      row = save!(ctx)
      n = length(audit_rows(ctx))

      PrintOverrides.save_draft(ctx.schema, attrs(ctx, %{locale: "fr"}), @alice)
      PrintOverrides.activate(ctx.schema, row.id, %{reason_code: "x"}, @alice)
      PrintOverrides.activate(ctx.schema, row.id, %{reason_code: "BAD CODE"}, @bob)
      PrintOverrides.activate(ctx.schema, Ecto.UUID.generate(), %{reason_code: "x"}, @bob)
      PrintOverrides.retire(ctx.schema, row.id, %{reason_code: "x"}, @bob)

      assert length(audit_rows(ctx)) == n
    end

    test "S2-audit-4: a forced audit failure leaves no change", ctx do
      old = active!(ctx)
      draft = save!(ctx)
      before = statuses(ctx)
      force_audit_fail(ctx)

      assert_raise Ecto.ConstraintError, fn ->
        PrintOverrides.save_draft(ctx.schema, attrs(ctx), @alice)
      end

      assert_raise Ecto.ConstraintError, fn ->
        PrintOverrides.activate(ctx.schema, draft.id, %{reason_code: "x"}, @bob)
      end

      assert_raise Ecto.ConstraintError, fn ->
        PrintOverrides.retire(ctx.schema, old.id, %{reason_code: "x"}, @bob)
      end

      assert statuses(ctx) == before
      assert before == [[1, "active"], [2, "draft"]]
    end
  end

  describe "get / list" do
    test "list is metadata only and filterable; get carries the layout", ctx do
      a = save!(ctx)
      save!(ctx, %{locale: "kk"})

      assert {:ok, [_, _]} = PrintOverrides.list(ctx.schema)
      assert {:ok, [row]} = PrintOverrides.list(ctx.schema, %{locale: "kk"})
      refute Map.has_key?(row, :layout)
      assert {:ok, %{layout: l}} = PrintOverrides.get(ctx.schema, a.id)
      assert l["layout_schema_version"] == 1
      assert {:error, :invalid_schema_name} = PrintOverrides.list("public")
    end
  end
end
