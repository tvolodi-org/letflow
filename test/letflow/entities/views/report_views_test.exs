defmodule Letflow.Entities.ReportViewsTest do
  @moduledoc """
  REQ-619 / GH #3453 part A: saved report definitions on the `entity_views` table. Criterion 1
  (migration, INV-1/INV-6; ids R-M1..R-M3, R-S1), criterion 2 (write shape; R-W), criterion 3
  (summary validation with the pivot rules; R-V), criterion 4 (detail validation with the list
  rules; R-D), criterion 5 (name uniqueness and list visibility; R-N).
  """

  use Letflow.DataCase, async: false

  import Letflow.EntityViewsSupport

  alias Letflow.Entities.Views
  alias Letflow.TenantProvisioning

  @version 20_261_028_200_001
  @module Letflow.Repo.Migrations.AddReportToEntityViews

  setup do
    base = tenant!("report-ctx-a")
    a = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    {:ok, a: a, base: base}
  end

  defp create(ctx, body), do: Views.create(ctx.schema_name, ctx.user_id, body)

  defp refused(ctx, body, code) do
    before = {view_count(ctx), audit_count(ctx, "entity_view.create")}
    assert {:error, {:unprocessable, ^code}} = create(ctx, body)
    assert {view_count(ctx), audit_count(ctx, "entity_view.create")} == before
  end

  defp update_refused(ctx, view, body, code) do
    before = audit_count(ctx, "entity_view.update")

    assert {:error, {:unprocessable, ^code}} =
             Views.update(ctx.schema_name, ctx.user_id, view.id, body)

    assert audit_count(ctx, "entity_view.update") == before
    {:ok, reread} = Views.get(ctx.schema_name, ctx.user_id, view.id)
    keys = [:name, :kind, :filter, :group_by, :aggregates, :columns, :sort, :chart_type]
    assert Map.take(reread, keys) == Map.take(view, keys)
  end

  defp sql!(sql, params \\ []), do: Repo.query!(sql, params)

  describe "criterion 1: migration and storage" do
    test "R-M1 registered in the tenant-scoped manifest" do
      assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
    end

    test "R-M2 list, pivot and graph rows are unchanged after the migration replays", %{a: a} do
      {:ok, list} = create(a, valid_view())
      {:ok, pivot} = create(a, pivot_view())
      {:ok, graph} = create(a, graph_view())
      schema = a.schema_name

      sql!(
        ~s(ALTER TABLE "#{schema}".entity_views DROP CONSTRAINT entity_views_kind_check, ) <>
          "ADD CONSTRAINT entity_views_kind_check CHECK (kind IN ('list', 'pivot', 'graph')), " <>
          "DROP CONSTRAINT entity_views_pivot_clauses_chk, " <>
          "ADD CONSTRAINT entity_views_pivot_clauses_chk " <>
          "CHECK (kind IN ('pivot', 'graph') OR (group_by = '[]'::jsonb AND aggregates = '[]'::jsonb))"
      )

      sql!(~s(DELETE FROM "#{schema}".schema_migrations WHERE version = $1), [@version])

      assert {:ok, applied} = TenantProvisioning.replay_migrations(a.tenant_id)
      assert @version in applied

      for before <- [list, pivot, graph] do
        {:ok, reread} = Views.get(schema, a.user_id, before.id)

        keys = [
          :name,
          :kind,
          :columns,
          :filter,
          :sort,
          :group_by,
          :aggregates,
          :chart_type,
          :inserted_at,
          :updated_at
        ]

        assert Map.take(reread, keys) == Map.take(before, keys)
      end

      assert {:ok, %{kind: "report"}} = create(a, report_view())
    end

    test "R-M3 the table checks", %{a: a} do
      schema = a.schema_name
      {:ok, list} = create(a, valid_view())
      {:ok, report} = create(a, report_view())
      list_id = Ecto.UUID.dump!(list.id)
      report_id = Ecto.UUID.dump!(report.id)

      assert_raise Postgrex.Error, ~r/entity_views_kind_check/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET kind = 'other' WHERE id = $1), [list_id])
      end

      assert_raise Postgrex.Error, ~r/entity_views_chart_type_chk/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET chart_type = 'bar' WHERE id = $1), [
          report_id
        ])
      end

      assert_raise Postgrex.Error, ~r/entity_views_pivot_clauses_chk/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET group_by = '[{"field":"x"}]' WHERE id = $1), [
          list_id
        ])
      end

      assert %{rows: []} =
               Repo.query!(
                 "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name LIKE '%report%'",
                 [schema]
               )
    end

    test "R-S1 a report created in tenant A is absent from tenant B", %{a: a} do
      {:ok, view} = create(a, report_view())
      assert view.tenant_id == a.tenant_id

      b = tenant!("report-ctx-b")
      assert view_count(b) == 0
      assert {:error, :not_found} = Views.get(b.schema_name, a.user_id, view.id)
    end
  end

  describe "criterion 2: write shape" do
    test "R-W1 a report is stored and returned with all five clauses", %{a: a} do
      {:ok, view} = create(a, report_view())
      {:ok, reread} = Views.get(a.schema_name, a.user_id, view.id)

      assert reread.kind == "report" and reread.chart_type == nil
      assert reread.group_by == [%{"field" => "question_id"}]
      assert reread.aggregates == [%{"fn" => "count"}]
      assert reread.columns == ["text", "is_correct"]
      assert reread.sort == [%{"field" => "text", "dir" => "asc"}]
      assert reread.filter == [%{"field" => "text", "op" => "neq", "value" => "Z"}]
    end

    test "R-W2 absent, null or empty columns and an absent sort are accepted", %{a: a} do
      without = report_view() |> Map.drop(["columns", "sort"])
      assert {:ok, %{columns: [], sort: []}} = create(a, Map.put(without, "name", "n1"))

      for {columns, n} <- Enum.with_index([nil, []], 2) do
        body = without |> Map.put("columns", columns) |> Map.put("name", "n#{n}")
        assert {:ok, %{columns: [], sort: []}} = create(a, body)
      end
    end

    test "R-W3 columns absent or empty with a sort is sort_invalid", %{a: a} do
      refused(a, report_view() |> Map.delete("columns"), "sort_invalid")
      refused(a, report_view(%{"columns" => []}), "sort_invalid")
      refused(a, report_view(%{"columns" => nil}), "sort_invalid")
    end

    test "R-W4 a join key and a chart_type key are unknown_key", %{a: a} do
      refused(a, report_view(%{"join" => []}), "unknown_key")
      refused(a, report_view(%{"chart_type" => "bar"}), "unknown_key")
      refused(a, report_view(%{"chart_type" => nil}), "unknown_key")
    end

    test "R-W5 list and pivot bodies keep refusing the other shape", %{a: a} do
      refused(a, valid_view(%{"group_by" => [%{"field" => "text"}]}), "unknown_key")
      refused(a, valid_view(%{"aggregates" => [%{"fn" => "count"}]}), "unknown_key")
      refused(a, pivot_view(%{"columns" => ["text"]}), "unknown_key")
      refused(a, pivot_view(%{"sort" => []}), "unknown_key")
    end

    test "R-W6 aggregates are required and non-empty; an empty group_by is accepted", %{a: a} do
      refused(a, report_view() |> Map.delete("aggregates"), "aggregates_invalid")

      for bad <- [nil, [], "count", [%{"fn" => "median"}], [42]] do
        refused(a, report_view(%{"aggregates" => bad}), "aggregates_invalid")
      end

      assert {:ok, %{group_by: []}} = create(a, report_view(%{"group_by" => []}))
    end

    test "R-W7 kind is immutable; other kind values are kind_invalid", %{a: a} do
      {:ok, list} = create(a, valid_view())
      {:ok, pivot} = create(a, pivot_view())
      {:ok, graph} = create(a, graph_view())
      {:ok, report} = create(a, report_view())

      for view <- [list, pivot, graph] do
        update_refused(a, report, Map.put(report_view(), "kind", view.kind), "kind_immutable")
      end

      update_refused(a, list, report_view(), "kind_immutable")
      update_refused(a, pivot, report_view(), "kind_immutable")
      update_refused(a, graph, report_view(), "kind_immutable")

      kindless = report_view(%{"name" => "kept"}) |> Map.delete("kind")

      assert {:ok, %{kind: "report", name: "kept"}} =
               Views.update(a.schema_name, a.user_id, report.id, kindless)

      for bad <- ["Report", "other", nil] do
        refused(a, report_view(%{"kind" => bad}), "kind_invalid")
      end
    end

    test "R-W8 through the real router: create 201, PUT 200, bad body 422, list shows kind", %{
      a: a
    } do
      conn = request(:post, "/api/v1/entity-views", a, report_view())
      assert conn.status == 201, conn.resp_body
      view = body_of(conn)

      assert %{"kind" => "report", "chart_type" => nil, "columns" => ["text", "is_correct"]} =
               view

      list = request(:post, "/api/v1/entity-views", a, valid_view())
      assert Map.keys(body_of(list)) |> Enum.sort() == Map.keys(view) |> Enum.sort()

      put =
        request(
          :put,
          "/api/v1/entity-views/#{view["id"]}",
          a,
          report_view(%{"columns" => ["text"]})
        )

      assert put.status == 200 and body_of(put)["columns"] == ["text"]

      bad =
        request(
          :post,
          "/api/v1/entity-views",
          a,
          report_view(%{"name" => "b", "aggregates" => []})
        )

      assert bad.status == 422
      assert bad.resp_body =~ "aggregates_invalid"

      index = request(:get, "/api/v1/entity-views?entity_type=answer_option", a)

      assert index |> body_of() |> Map.fetch!("items") |> Enum.map(& &1["kind"]) |> Enum.sort() ==
               ["list", "report"]
    end
  end

  @summary_cases [
    {"R-V1", "filter_invalid", %{"filter" => [42]}},
    {"R-V2", "unknown_operator",
     %{"filter" => [%{"field" => "text", "op" => "like", "value" => "A"}]}},
    {"R-V3", "field_not_allowed",
     %{"filter" => [%{"field" => "nope", "op" => "eq", "value" => "A"}]}},
    {"R-V4", "value_arity_mismatch", %{"filter" => [%{"field" => "text", "op" => "eq"}]}},
    {"R-V5", "invalid_in_value",
     %{"filter" => [%{"field" => "text", "op" => "in", "value" => "A"}]}},
    {"R-V6", "invalid_decimal_value",
     %{"filter" => [%{"field" => "score", "op" => "eq", "value" => "abc"}]}},
    {"R-V7", "operator_not_valid_for_type",
     %{"filter" => [%{"field" => "is_correct", "op" => "gt", "value" => true}]}},
    {"R-V8", "aggregates_invalid", %{"aggregates" => [%{"fn" => "sum", "field" => "text"}]}},
    {"R-V9", "group_by_invalid", %{"group_by" => "question_id"}},
    {"R-V9b", "field_not_allowed", %{"group_by" => [%{"field" => "nope"}]}},
    {"R-V9c", "field_not_allowed", %{"aggregates" => [%{"fn" => "max", "field" => "nope"}]}}
  ]

  describe "criterion 3: summary validation" do
    for {id, code, override} <- @summary_cases do
      test "#{id} #{code} on create and on update, nothing stored", %{a: a} do
        override = unquote(Macro.escape(override))
        code = unquote(code)
        refused(a, report_view(override), code)

        {:ok, view} = create(a, report_view(%{"name" => "base"}))
        update_refused(a, view, report_view(Map.put(override, "name", "base")), code)
      end
    end
  end

  describe "criterion 4: detail validation" do
    test "R-D1 a column not on the type is column_not_on_type", %{a: a} do
      refused(a, report_view(%{"columns" => ["nope"]}), "column_not_on_type")
    end

    test "R-D2 a sort field not on the type is field_not_allowed", %{a: a} do
      refused(
        a,
        report_view(%{"sort" => [%{"field" => "nope", "dir" => "asc"}]}),
        "field_not_allowed"
      )
    end

    test "R-D3 an unknown sort dir is unknown_sort_dir", %{a: a} do
      refused(
        a,
        report_view(%{"sort" => [%{"field" => "text", "dir" => "up"}]}),
        "unknown_sort_dir"
      )
    end

    test "R-D4 columns over 100, duplicate or blank are columns_invalid", %{a: a} do
      refused(a, report_view(%{"columns" => Enum.map(1..101, &"c#{&1}")}), "columns_invalid")
      refused(a, report_view(%{"columns" => ["text", "text"]}), "columns_invalid")
      refused(a, report_view(%{"columns" => ["text", ""]}), "columns_invalid")
    end

    test "R-D5 more than ten sort clauses are sort_invalid", %{a: a} do
      sort = for _ <- 1..11, do: %{"field" => "text", "dir" => "asc"}
      refused(a, report_view(%{"sort" => sort}), "sort_invalid")
    end

    test "R-D6 the same detail faults on update store nothing", %{a: a} do
      {:ok, view} = create(a, report_view())
      update_refused(a, view, report_view(%{"columns" => ["nope"]}), "column_not_on_type")

      update_refused(
        a,
        view,
        report_view(%{"sort" => [%{"field" => "nope", "dir" => "asc"}]}),
        "field_not_allowed"
      )

      update_refused(
        a,
        view,
        report_view(%{"sort" => [%{"field" => "text", "dir" => "up"}]}),
        "unknown_sort_dir"
      )

      update_refused(a, view, report_view(%{"columns" => ["text", "text"]}), "columns_invalid")
    end

    test "R-D7 a summary fault wins over a detail fault", %{a: a} do
      refused(
        a,
        report_view(%{
          "aggregates" => [%{"fn" => "sum", "field" => "text"}],
          "columns" => ["nope"]
        }),
        "aggregates_invalid"
      )
    end
  end

  describe "criterion 5: name and visibility" do
    test "R-N1 a name is unique per entity type across kinds", %{a: a} do
      {:ok, _} = create(a, valid_view(%{"name" => "list one"}))
      {:ok, _} = create(a, pivot_view(%{"name" => "pivot one"}))
      {:ok, _} = create(a, graph_view(%{"name" => "graph one"}))
      {:ok, _} = create(a, report_view(%{"name" => "report one"}))

      for name <- ["list one", "pivot one", "graph one", "report one"] do
        assert {:error, :name_taken} = create(a, report_view(%{"name" => name}))
      end

      assert {:error, :name_taken} = create(a, graph_view(%{"name" => "report one"}))

      conn = request(:post, "/api/v1/entity-views", a, report_view(%{"name" => "pivot one"}))
      assert conn.status == 409

      assert {:error, :not_found} =
               create(a, report_view(%{"entity_type" => "no_such_type", "name" => "x"}))
    end

    test "R-N2 a reader who may read the type sees the report; after a restriction nobody does",
         %{
           a: a,
           base: base
         } do
      worker = add_user!(base, ["TASK_WORKER"])
      {:ok, report} = create(a, report_view())

      assert {:ok, [seen]} = Views.list(a.schema_name, worker.user_id, "answer_option")
      assert seen.id == report.id and seen.kind == "report"

      conn = request(:get, "/api/v1/entity-views?entity_type=answer_option", worker)
      assert [%{"kind" => "report"}] = conn |> body_of() |> Map.fetch!("items")

      restrict_type!(a, "answer_option")
      assert {:ok, []} = Views.list(a.schema_name, worker.user_id, "answer_option")
    end
  end
end
