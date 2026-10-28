defmodule Letflow.Entities.GraphViewsTest do
  @moduledoc """
  REQ-613 / GH #3432 part A: saved graph views on the `entity_views` table. Criterion 1 (migration,
  write shape, INV-1/INV-6; ids G-M1..G-M3, G-S1, G-W1..G-W7), criterion 2 (validation with the
  aggregate route's rules; ids G-A, G-F, G-V), criterion 3 (kinds; ids G-K, G-L).
  """

  use Letflow.DataCase, async: false

  import Letflow.EntityViewsSupport

  alias Letflow.Entities.Views
  alias Letflow.TenantProvisioning

  @version 20_261_028_100_001
  @module Letflow.Repo.Migrations.AddGraphToEntityViews

  setup do
    base = tenant!("graph-ctx-a")
    a = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    {:ok, a: a}
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

    assert Map.take(reread, [:name, :kind, :filter, :group_by, :aggregates, :chart_type]) ==
             Map.take(view, [:name, :kind, :filter, :group_by, :aggregates, :chart_type])
  end

  defp sql!(sql, params \\ []), do: Repo.query!(sql, params)

  describe "criterion 1: migration and storage" do
    test "G-M1 registered in the tenant-scoped manifest" do
      assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
    end

    test "G-M2 list and pivot rows are unchanged after the migration replays", %{a: a} do
      {:ok, list} = create(a, valid_view())
      {:ok, pivot} = create(a, pivot_view())
      schema = a.schema_name

      sql!(
        ~s(ALTER TABLE "#{schema}".entity_views DROP CONSTRAINT entity_views_chart_type_chk, DROP COLUMN chart_type)
      )

      sql!(
        ~s(ALTER TABLE "#{schema}".entity_views DROP CONSTRAINT entity_views_kind_check, ) <>
          "ADD CONSTRAINT entity_views_kind_check CHECK (kind IN ('list', 'pivot'))"
      )

      sql!(~s(DELETE FROM "#{schema}".schema_migrations WHERE version = $1), [@version])

      assert {:ok, applied} = TenantProvisioning.replay_migrations(a.tenant_id)
      assert @version in applied

      for before <- [list, pivot] do
        {:ok, reread} = Views.get(schema, a.user_id, before.id)

        keys = [
          :name,
          :kind,
          :columns,
          :filter,
          :sort,
          :group_by,
          :aggregates,
          :inserted_at,
          :updated_at
        ]

        assert Map.take(reread, keys) == Map.take(before, keys)
        assert reread.chart_type == nil
      end

      assert {:ok, %{kind: "graph"}} = create(a, graph_view())
    end

    test "G-M3 chart_type column and the table checks", %{a: a} do
      schema = a.schema_name

      %{rows: rows} =
        Repo.query!(
          "SELECT data_type, is_nullable, column_default FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'entity_views' AND column_name = 'chart_type'",
          [schema]
        )

      assert rows == [["text", "YES", nil]]

      {:ok, list} = create(a, valid_view())
      {:ok, graph} = create(a, graph_view())
      list_id = Ecto.UUID.dump!(list.id)
      graph_id = Ecto.UUID.dump!(graph.id)

      assert_raise Postgrex.Error, ~r/entity_views_chart_type_chk/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET chart_type = NULL WHERE id = $1), [graph_id])
      end

      assert_raise Postgrex.Error, ~r/entity_views_chart_type_chk/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET chart_type = 'donut' WHERE id = $1), [
          graph_id
        ])
      end

      assert_raise Postgrex.Error, ~r/entity_views_chart_type_chk/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET chart_type = 'bar' WHERE id = $1), [list_id])
      end

      assert_raise Postgrex.Error, ~r/entity_views_pivot_clauses_chk/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET group_by = '[{"field":"x"}]' WHERE id = $1), [
          list_id
        ])
      end

      assert_raise Postgrex.Error, ~r/entity_views_kind_check/, fn ->
        sql!(~s(UPDATE "#{schema}".entity_views SET kind = 'other' WHERE id = $1), [list_id])
      end

      assert %{rows: []} =
               Repo.query!(
                 "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name LIKE '%graph%'",
                 [schema]
               )
    end

    test "G-S1 a graph created in tenant A is absent from tenant B", %{a: a} do
      {:ok, view} = create(a, graph_view())
      assert view.tenant_id == a.tenant_id
      assert view_count(a) == 1

      b = tenant!("graph-ctx-b")
      assert view_count(b) == 0
      assert {:error, :not_found} = Views.get(b.schema_name, a.user_id, view.id)
    end
  end

  describe "criterion 1: write shape" do
    test "G-W1 a graph is stored and returned with its clauses", %{a: a} do
      {:ok, view} = create(a, graph_view())
      {:ok, reread} = Views.get(a.schema_name, a.user_id, view.id)

      assert reread.kind == "graph"
      assert reread.group_by == [%{"field" => "question_id"}]
      assert reread.aggregates == [%{"fn" => "count"}]
      assert reread.chart_type == "bar"
      assert reread.columns == [] and reread.sort == []
      assert reread.filter == [%{"field" => "text", "op" => "neq", "value" => "Z"}]
    end

    test "G-W2 a graph body with columns is unknown_key and stores nothing", %{a: a} do
      refused(a, graph_view(%{"columns" => ["text"]}), "unknown_key")
    end

    test "G-W3 a graph body with sort is unknown_key and stores nothing", %{a: a} do
      refused(a, graph_view(%{"sort" => [%{"field" => "text", "dir" => "asc"}]}), "unknown_key")
    end

    test "G-W4 a list body with chart_type is unknown_key and stores nothing", %{a: a} do
      refused(a, valid_view(%{"chart_type" => "bar"}), "unknown_key")
      refused(a, valid_view(%{"kind" => "list", "chart_type" => nil}), "unknown_key")
    end

    test "G-W5 a list body with group_by or aggregates is unknown_key", %{a: a} do
      refused(a, valid_view(%{"group_by" => [%{"field" => "text"}]}), "unknown_key")
      refused(a, valid_view(%{"aggregates" => [%{"fn" => "count"}]}), "unknown_key")
    end

    test "G-W6 a pivot body with chart_type is unknown_key and stores nothing", %{a: a} do
      refused(a, pivot_view(%{"chart_type" => "bar"}), "unknown_key")
    end

    test "G-W7 through the real router: create 201, PUT 200, bad body 422, lists show null", %{
      a: a
    } do
      conn = request(:post, "/api/v1/entity-views", a, graph_view())
      assert conn.status == 201, conn.resp_body
      view = body_of(conn)
      assert %{"kind" => "graph", "chart_type" => "bar", "columns" => [], "sort" => []} = view

      put =
        request(
          :put,
          "/api/v1/entity-views/#{view["id"]}",
          a,
          graph_view(%{"chart_type" => "line"})
        )

      assert put.status == 200 and body_of(put)["chart_type"] == "line"

      bad = request(:post, "/api/v1/entity-views", a, graph_view(%{"chart_type" => "donut"}))
      assert bad.status == 422
      assert bad.resp_body =~ "chart_type_invalid"

      list = request(:post, "/api/v1/entity-views", a, valid_view())
      pivot = request(:post, "/api/v1/entity-views", a, pivot_view())
      assert body_of(list)["chart_type"] == nil
      assert body_of(pivot)["chart_type"] == nil
    end
  end

  describe "criterion 2: validation" do
    test "G-A1 one group_by, one aggregate, bar is accepted", %{a: a} do
      assert {:ok, %{chart_type: "bar"}} = create(a, graph_view())
    end

    test "G-A2 one group_by, three aggregates, line is accepted; a one-aggregate pie too", %{a: a} do
      aggregates = [
        %{"fn" => "count"},
        %{"fn" => "sum", "field" => "score"},
        %{"fn" => "max", "field" => "text"}
      ]

      assert {:ok, %{chart_type: "line", aggregates: ^aggregates}} =
               create(a, graph_view(%{"aggregates" => aggregates, "chart_type" => "line"}))

      assert {:ok, %{chart_type: "pie"}} =
               create(a, graph_view(%{"name" => "pie", "chart_type" => "pie"}))
    end

    @filter_cases [
      {"G-F1", "field_not_allowed", [%{"field" => "nope", "op" => "eq", "value" => "A"}]},
      {"G-F2", "unknown_operator", [%{"field" => "text", "op" => "like", "value" => "A"}]},
      {"G-F3", "value_arity_mismatch", [%{"field" => "text", "op" => "eq"}]},
      {"G-F4", "invalid_in_value", [%{"field" => "text", "op" => "in", "value" => "A"}]},
      {"G-F5", "invalid_decimal_value", [%{"field" => "score", "op" => "eq", "value" => "abc"}]},
      {"G-F6", "operator_not_valid_for_type",
       [%{"field" => "is_correct", "op" => "gt", "value" => true}]},
      {"G-F7", "filter_invalid", [42]}
    ]

    for {id, code, filter} <- @filter_cases do
      test "#{id} filter error #{code} equals the code a list view gets", %{a: a} do
        filter = unquote(Macro.escape(filter))
        code = unquote(code)
        refused(a, valid_view(%{"filter" => filter}), code)
        refused(a, graph_view(%{"filter" => filter}), code)
      end
    end

    test "G-V1 a group_by field not on the type is field_not_allowed", %{a: a} do
      refused(a, graph_view(%{"group_by" => [%{"field" => "nope"}]}), "field_not_allowed")
    end

    test "G-V2 an aggregate field not on the type is field_not_allowed", %{a: a} do
      body = graph_view(%{"aggregates" => [%{"fn" => "max", "field" => "nope"}]})
      refused(a, body, "field_not_allowed")
    end

    test "G-V3 a join key is unknown_key", %{a: a} do
      refused(a, graph_view(%{"join" => [%{"entity_type" => "x", "on" => %{}}]}), "unknown_key")
    end

    test "G-V4 an absent group_by is group_by_invalid", %{a: a} do
      refused(a, Map.delete(graph_view(), "group_by"), "group_by_invalid")
    end

    test "G-V5 a null or empty group_by is group_by_invalid", %{a: a} do
      refused(a, graph_view(%{"group_by" => []}), "group_by_invalid")
      refused(a, graph_view(%{"group_by" => nil}), "group_by_invalid")
    end

    test "G-V6 two group_by elements are group_by_invalid", %{a: a} do
      two = [%{"field" => "question_id"}, %{"field" => "text"}]
      refused(a, graph_view(%{"group_by" => two}), "group_by_invalid")
    end

    test "G-V7 a group_by element without a string field is group_by_invalid", %{a: a} do
      for bad <- [[%{"name" => "text"}], [%{"field" => 1}], [7], "text"] do
        refused(a, graph_view(%{"group_by" => bad}), "group_by_invalid")
      end
    end

    test "G-V8 absent aggregates are aggregates_invalid", %{a: a} do
      refused(a, Map.delete(graph_view(), "aggregates"), "aggregates_invalid")
    end

    test "G-V9 empty or null aggregates are aggregates_invalid", %{a: a} do
      refused(a, graph_view(%{"aggregates" => []}), "aggregates_invalid")
      refused(a, graph_view(%{"aggregates" => nil}), "aggregates_invalid")
    end

    test "G-V10 four aggregates are aggregates_invalid", %{a: a} do
      four = List.duplicate(%{"fn" => "count"}, 4)
      refused(a, graph_view(%{"aggregates" => four}), "aggregates_invalid")
    end

    test "G-V11 an unknown fn is aggregates_invalid", %{a: a} do
      refused(a, graph_view(%{"aggregates" => [%{"fn" => "median"}]}), "aggregates_invalid")
    end

    test "G-V12 a pie with two aggregates is aggregates_invalid", %{a: a} do
      two = [%{"fn" => "count"}, %{"fn" => "max", "field" => "text"}]
      refused(a, graph_view(%{"aggregates" => two, "chart_type" => "pie"}), "aggregates_invalid")
    end

    test "G-V13 an absent, null, unknown or non-string chart_type is chart_type_invalid", %{a: a} do
      refused(a, Map.delete(graph_view(), "chart_type"), "chart_type_invalid")

      for bad <- [nil, "donut", "Bar", 5, ["bar"]] do
        refused(a, graph_view(%{"chart_type" => bad}), "chart_type_invalid")
      end
    end

    test "G-V14 fn and field arity and type are aggregates_invalid", %{a: a} do
      for bad <- [
            %{"fn" => "sum"},
            %{"fn" => "count", "field" => "text"},
            %{"fn" => "sum", "field" => "text"}
          ] do
        refused(a, graph_view(%{"aggregates" => [bad]}), "aggregates_invalid")
      end
    end

    test "G-V15 an invalid update stores nothing", %{a: a} do
      {:ok, view} = create(a, graph_view())

      update_refused(
        a,
        view,
        graph_view(%{"chart_type" => "donut", "name" => "x"}),
        "chart_type_invalid"
      )

      update_refused(a, view, graph_view(%{"group_by" => [], "name" => "x"}), "group_by_invalid")
    end
  end

  describe "criterion 3: kinds" do
    test "G-K1 other kinds are kind_invalid", %{a: a} do
      for bad <- ["other", nil, "Graph"] do
        refused(a, graph_view(%{"kind" => bad}), "kind_invalid")
      end
    end

    test "G-K2 any kind change is kind_immutable and stores nothing", %{a: a} do
      {:ok, list} = create(a, valid_view())
      {:ok, pivot} = create(a, pivot_view())
      {:ok, graph} = create(a, graph_view())

      update_refused(a, list, graph_view(), "kind_immutable")
      update_refused(a, pivot, graph_view(), "kind_immutable")
      update_refused(a, graph, valid_view(%{"kind" => "list"}), "kind_immutable")
      update_refused(a, graph, pivot_view(), "kind_immutable")

      kindless = graph_view(%{"name" => "kept"}) |> Map.delete("kind")

      assert {:ok, %{kind: "graph", name: "kept"}} =
               Views.update(a.schema_name, a.user_id, graph.id, kindless)
    end

    test "G-K3 an update replaces name, filter, group_by, aggregates and chart_type", %{a: a} do
      {:ok, graph} = create(a, graph_view())

      body =
        graph_view(%{
          "name" => "Renamed",
          "filter" => [],
          "group_by" => [%{"field" => "text"}],
          "aggregates" => [%{"fn" => "count"}, %{"fn" => "sum", "field" => "score"}],
          "chart_type" => "line"
        })

      assert {:ok, updated} = Views.update(a.schema_name, a.user_id, graph.id, body)
      assert updated.name == "Renamed" and updated.filter == []
      assert updated.group_by == [%{"field" => "text"}]
      assert length(updated.aggregates) == 2
      assert updated.chart_type == "line"
    end

    test "G-L1 the list returns list, pivot and graph views, each with kind", %{a: a} do
      {:ok, _} = create(a, valid_view())
      {:ok, _} = create(a, pivot_view())
      {:ok, _} = create(a, graph_view())

      conn = request(:get, "/api/v1/entity-views?entity_type=answer_option", a)
      assert conn.status == 200, conn.resp_body
      body = body_of(conn)
      rows = body["items"]
      assert rows |> Enum.map(& &1["kind"]) |> Enum.sort() == ["graph", "list", "pivot"]

      assert {:ok, views} = Views.list(a.schema_name, a.user_id, "answer_option")
      assert views |> Enum.map(& &1.kind) |> Enum.sort() == ["graph", "list", "pivot"]
    end
  end
end
