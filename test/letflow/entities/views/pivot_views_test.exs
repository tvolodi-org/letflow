defmodule Letflow.Entities.PivotViewsTest do
  @moduledoc """
  REQ-598 / GH #3367 part A: saved pivot views on the `entity_views` table. Criterion 1 (migration,
  write shape, INV-1/INV-6; ids M1-M3, S1, W1-W9) and criterion 2 (validation with the aggregate
  route's rules; ids V1-V19).
  """

  use Letflow.DataCase, async: false

  import Letflow.EntityViewsSupport

  alias Letflow.Entities.Views
  alias Letflow.TenantProvisioning

  @version 20_261_027_400_001
  @module Letflow.Repo.Migrations.AddPivotToEntityViews
  @aggregate_path "/api/v1/entities/query/aggregate"

  setup do
    base = tenant!("pivot-ctx-a")
    a = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    {:ok, a: a}
  end

  defp create(ctx, body), do: Views.create(ctx.schema_name, ctx.user_id, body)

  defp refused(ctx, body, code) do
    before = {view_count(ctx), audit_count(ctx, "entity_view.create")}
    assert {:error, {:unprocessable, ^code}} = create(ctx, body)
    assert {view_count(ctx), audit_count(ctx, "entity_view.create")} == before
  end

  defp columns_of(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'entity_views' " <>
          "AND column_name IN ('kind', 'group_by', 'aggregates') ORDER BY column_name",
        [schema]
      )

    rows
  end

  describe "criterion 1: migration and storage" do
    test "M1 registered in the tenant-scoped manifest" do
      assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
    end

    test "M2 an existing list row is unchanged after the migration replays", %{a: a} do
      {:ok, view} = create(a, valid_view())
      schema = a.schema_name

      Repo.query!(
        ~s(ALTER TABLE "#{schema}".entity_views DROP CONSTRAINT entity_views_pivot_clauses_chk, ) <>
          "DROP COLUMN kind, DROP COLUMN group_by, DROP COLUMN aggregates"
      )

      Repo.query!(~s(DELETE FROM "#{schema}".schema_migrations WHERE version = $1), [@version])
      assert columns_of(schema) == []

      assert {:ok, applied} = TenantProvisioning.replay_migrations(a.tenant_id)
      assert @version in applied

      {:ok, reread} = Views.get(schema, a.user_id, view.id)
      assert reread.kind == "list"
      assert reread.group_by == [] and reread.aggregates == []

      assert Map.take(reread, [:name, :columns, :filter, :sort, :inserted_at, :updated_at]) ==
               Map.take(view, [:name, :columns, :filter, :sort, :inserted_at, :updated_at])
    end

    test "M3 columns carry the defaults and a list row cannot hold pivot clauses", %{a: a} do
      assert [
               ["aggregates", "jsonb", "NO", "'[]'::jsonb"],
               ["group_by", "jsonb", "NO", "'[]'::jsonb"],
               ["kind", "text", "NO", "'list'::text"]
             ] = columns_of(a.schema_name)

      {:ok, view} = create(a, valid_view())

      assert_raise Postgrex.Error, ~r/entity_views_pivot_clauses_chk/, fn ->
        Repo.query!(
          ~s(UPDATE "#{a.schema_name}".entity_views SET group_by = '[{"field":"x"}]' WHERE id = $1),
          [Ecto.UUID.dump!(view.id)]
        )
      end
    end

    test "S1 a pivot created in tenant A is absent from tenant B", %{a: a} do
      {:ok, view} = create(a, pivot_view())
      assert view.tenant_id == a.tenant_id
      assert view_count(a) == 1

      b = tenant!("pivot-ctx-b")
      assert view_count(b) == 0
      assert {:error, :not_found} = Views.get(b.schema_name, a.user_id, view.id)
    end
  end

  describe "criterion 1: write shape" do
    test "W1 a pivot is stored and returned under kind, group_by and aggregates", %{a: a} do
      {:ok, view} = create(a, pivot_view())
      {:ok, reread} = Views.get(a.schema_name, a.user_id, view.id)

      assert reread.kind == "pivot"
      assert reread.group_by == [%{"field" => "question_id"}]
      assert reread.aggregates == [%{"fn" => "count"}, %{"fn" => "max", "field" => "text"}]
      assert reread.columns == [] and reread.sort == []
      assert reread.filter == [%{"field" => "text", "op" => "neq", "value" => "Z"}]
    end

    test "W2 a body without kind is a list and answers kind list", %{a: a} do
      {:ok, view} = create(a, valid_view())
      assert view.kind == "list" and view.group_by == [] and view.aggregates == []
    end

    test "W3 a pivot body with columns is unknown_key and stores nothing", %{a: a} do
      refused(a, pivot_view(%{"columns" => ["text"]}), "unknown_key")
    end

    test "W4 a pivot body with sort is unknown_key and stores nothing", %{a: a} do
      refused(a, pivot_view(%{"sort" => [%{"field" => "text", "dir" => "asc"}]}), "unknown_key")
    end

    test "W5 a list body with group_by is unknown_key and stores nothing", %{a: a} do
      refused(a, valid_view(%{"group_by" => [%{"field" => "text"}]}), "unknown_key")
      refused(a, valid_view(%{"kind" => "list", "group_by" => []}), "unknown_key")
    end

    test "W6 a list body with aggregates is unknown_key and stores nothing", %{a: a} do
      refused(a, valid_view(%{"aggregates" => [%{"fn" => "count"}]}), "unknown_key")
    end

    test "W7 an unknown kind is kind_invalid", %{a: a} do
      refused(a, valid_view(%{"kind" => "other"}), "kind_invalid")
      refused(a, valid_view(%{"kind" => nil}), "kind_invalid")
    end

    test "W8 update keeps the kind, replaces the clauses, refuses a kind change", %{a: a} do
      {:ok, view} = create(a, pivot_view())
      body = pivot_view(%{"group_by" => [], "aggregates" => [%{"fn" => "count"}]})
      kindless = Map.delete(body, "kind")

      assert {:ok, updated} = Views.update(a.schema_name, a.user_id, view.id, kindless)
      assert updated.kind == "pivot" and updated.group_by == []
      assert updated.aggregates == [%{"fn" => "count"}]

      assert {:error, {:unprocessable, "kind_immutable"}} =
               Views.update(a.schema_name, a.user_id, view.id, valid_view(%{"kind" => "list"}))

      {:ok, list} = create(a, valid_view())

      assert {:error, {:unprocessable, "kind_immutable"}} =
               Views.update(a.schema_name, a.user_id, list.id, pivot_view())

      assert {:ok, %{kind: "list"}} =
               Views.update(a.schema_name, a.user_id, list.id, valid_view())
    end

    test "W9 through the real router: create 201, PUT 200, bad body 422", %{a: a} do
      conn = request(:post, "/api/v1/entity-views", a, pivot_view())
      assert conn.status == 201, conn.resp_body
      view = body_of(conn)
      assert %{"kind" => "pivot", "columns" => [], "sort" => []} = view
      assert view["group_by"] == [%{"field" => "question_id"}]
      assert view["aggregates"] == [%{"fn" => "count"}, %{"fn" => "max", "field" => "text"}]

      put =
        request(:put, "/api/v1/entity-views/#{view["id"]}", a, pivot_view(%{"name" => "Renamed"}))

      assert put.status == 200 and body_of(put)["name"] == "Renamed"

      bad = request(:post, "/api/v1/entity-views", a, pivot_view(%{"columns" => ["text"]}))
      assert bad.status == 422
      assert body_of(bad)["error"]["code"] == "unknown_key" or bad.resp_body =~ "unknown_key"
    end
  end

  describe "criterion 2: validation" do
    @filter_cases [
      {"V1", "field_not_allowed", [%{"field" => "nope", "op" => "eq", "value" => "A"}]},
      {"V2", "unknown_operator", [%{"field" => "text", "op" => "like", "value" => "A"}]},
      {"V3", "value_arity_mismatch", [%{"field" => "text", "op" => "eq"}]},
      {"V4", "invalid_in_value", [%{"field" => "text", "op" => "in", "value" => "A"}]},
      {"V5", "invalid_decimal_value", [%{"field" => "score", "op" => "eq", "value" => "abc"}]},
      {"V6", "operator_not_valid_for_type",
       [%{"field" => "is_correct", "op" => "gt", "value" => true}]},
      {"V7", "filter_invalid", [42]}
    ]

    for {id, code, filter} <- @filter_cases do
      test "#{id} filter error #{code} equals the code a list view gets", %{a: a} do
        filter = unquote(Macro.escape(filter))
        code = unquote(code)
        refused(a, valid_view(%{"filter" => filter}), code)
        refused(a, pivot_view(%{"filter" => filter}), code)
      end
    end

    test "V8 a group_by field not on the type is field_not_allowed", %{a: a} do
      refused(a, pivot_view(%{"group_by" => [%{"field" => "nope"}]}), "field_not_allowed")
    end

    test "V9 an aggregate field not on the type is field_not_allowed", %{a: a} do
      body = pivot_view(%{"aggregates" => [%{"fn" => "max", "field" => "nope"}]})
      refused(a, body, "field_not_allowed")
    end

    test "V10 a join key is unknown_key", %{a: a} do
      join = [%{"entity_type" => "x", "on" => %{}}]
      refused(a, pivot_view(%{"join" => join}), "unknown_key")
      refused(a, pivot_view(%{"tenant_id" => Ecto.UUID.generate()}), "unknown_key")
    end

    test "V11 missing, empty, null, non-list and malformed aggregates are aggregates_invalid", %{
      a: a
    } do
      refused(a, Map.delete(pivot_view(), "aggregates"), "aggregates_invalid")

      for bad <- [[], nil, "count", %{"fn" => "count"}, [%{"field" => "text"}], [42]] do
        refused(a, pivot_view(%{"aggregates" => bad}), "aggregates_invalid")
      end

      refused(
        a,
        pivot_view(%{"aggregates" => [%{"fn" => "max", "field" => 5}]}),
        "aggregates_invalid"
      )
    end

    test "V12 an unknown fn is aggregates_invalid", %{a: a} do
      refused(a, pivot_view(%{"aggregates" => [%{"fn" => "median"}]}), "aggregates_invalid")
    end

    test "V13 fn and field arity and type are aggregates_invalid", %{a: a} do
      for bad <- [
            %{"fn" => "sum"},
            %{"fn" => "count", "field" => "text"},
            %{"fn" => "sum", "field" => "text"}
          ] do
        refused(a, pivot_view(%{"aggregates" => [bad]}), "aggregates_invalid")
      end
    end

    test "V15 a malformed group_by is group_by_invalid", %{a: a} do
      for bad <- [
            "is_correct",
            %{"field" => "text"},
            [%{"name" => "text"}],
            [%{"field" => 1}],
            [7]
          ] do
        refused(a, pivot_view(%{"group_by" => bad}), "group_by_invalid")
      end
    end

    test "V16 absent, null and empty group_by are accepted", %{a: a} do
      {:ok, one} = create(a, Map.delete(pivot_view(%{"name" => "one"}), "group_by"))
      {:ok, two} = create(a, pivot_view(%{"name" => "two", "group_by" => nil}))
      {:ok, three} = create(a, pivot_view(%{"name" => "three", "group_by" => []}))
      assert [one.group_by, two.group_by, three.group_by] == [[], [], []]
    end

    test "V17 a pivot with count, sum, min and max is accepted; null field means none", %{a: a} do
      aggregates = [
        %{"fn" => "count", "field" => nil},
        %{"fn" => "sum", "field" => "score"},
        %{"fn" => "min", "field" => "text"},
        %{"fn" => "max", "field" => "text", "extra" => 1}
      ]

      {:ok, view} = create(a, pivot_view(%{"aggregates" => aggregates}))

      assert view.aggregates == [
               %{"fn" => "count"},
               %{"fn" => "sum", "field" => "score"},
               %{"fn" => "min", "field" => "text"},
               %{"fn" => "max", "field" => "text"}
             ]
    end

    test "V18 the aggregate route accepts what the view accepts and refuses what it refuses", %{
      a: a
    } do
      cases = [
        {:ok, %{"group_by" => [%{"field" => "question_id"}]}},
        {:ok, %{"group_by" => nil}},
        {:ok, %{"aggregates" => [%{"fn" => "count", "field" => nil}]}},
        {:ok, %{"aggregates" => [%{"fn" => "min", "field" => "text"}]}},
        {"field_not_allowed", %{"group_by" => [%{"field" => "nope"}]}},
        {"field_not_allowed", %{"aggregates" => [%{"fn" => "max", "field" => "nope"}]}},
        {"aggregates_invalid", %{"aggregates" => []}},
        {"aggregates_invalid", %{"aggregates" => [%{"fn" => "median"}]}},
        {"aggregates_invalid", %{"aggregates" => [%{"fn" => "sum"}]}},
        {"aggregates_invalid", %{"aggregates" => [%{"fn" => "count", "field" => "text"}]}},
        {"aggregates_invalid", %{"aggregates" => [%{"fn" => "sum", "field" => "text"}]}},
        {"aggregates_invalid", %{"aggregates" => [%{"fn" => "max", "field" => 5}]}},
        {"group_by_invalid", %{"group_by" => [%{"field" => 1}]}}
      ]

      for {expected, overrides} <- cases do
        view = pivot_view(Map.put(overrides, "name", "parity #{System.unique_integer()}"))

        route_body =
          view
          |> Map.take(["entity_type", "group_by", "aggregates"])
          |> Map.put("filters", view["filter"])

        route = request(:post, @aggregate_path, a, route_body)

        case expected do
          :ok ->
            assert {:ok, _view} = create(a, view)
            assert route.status == 200, route.resp_body

          code ->
            assert {:error, {:unprocessable, ^code}} = create(a, view)
            assert route.status in [400, 422], route.resp_body
        end
      end
    end

    test "V19 an invalid update of a pivot stores nothing", %{a: a} do
      {:ok, view} = create(a, pivot_view())

      for {code, overrides} <- [
            {"field_not_allowed", %{"group_by" => [%{"field" => "nope"}]}},
            {"aggregates_invalid", %{"aggregates" => []}},
            {"group_by_invalid", %{"group_by" => "x"}},
            {"unknown_key", %{"columns" => ["text"]}},
            {"unknown_operator",
             %{"filter" => [%{"field" => "text", "op" => "like", "value" => 1}]}}
          ] do
        assert {:error, {:unprocessable, ^code}} =
                 Views.update(a.schema_name, a.user_id, view.id, pivot_view(overrides))
      end

      assert {:ok, same} = Views.get(a.schema_name, a.user_id, view.id)
      assert same == view
      assert audit_count(a, "entity_view.update") == 0
    end
  end
end
