defmodule Letflow.Routers.EntityViewsGraphTest do
  @moduledoc """
  REQ-613 part B / GH #3432: the saved graph kind behaves like a list view on the REQ-555 routes
  (`/api/v1/entity-views`): name uniqueness across kinds, visibility, permissions, replay equal to
  the hand-built aggregate request (without `chart_type`), uniform 404, cross-tenant (INV-10) and audit.

  Test ids follow the design: GU1-GU3 and GL1 (criterion 4), GP1/GP2 (5), GR1-GR3 (6), GN1 and
  GX1/GX2 (7), GA1-GA3 (8). A second-entity-type uniqueness case is dropped as in the pivot file:
  it needs a second active type fixture.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Letflow.EntityViewsSupport

  alias Letflow.Api.Authorization
  alias Letflow.Audit.Entry
  alias Letflow.Entities.Views

  @path "/api/v1/entity-views"
  @aggregate "/api/v1/entities/query/aggregate"
  @actions ["entity_view.create", "entity_view.update", "entity_view.delete"]

  setup do
    base = tenant!("graph-b-a")
    admin = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    worker = add_user!(base, ["TASK_WORKER"])
    {:ok, admin: admin, worker: worker}
  end

  defp create_graph!(ctx, overrides \\ %{}) do
    conn = request(:post, @path, ctx, graph_view(overrides))
    assert conn.status == 201, conn.resp_body
    body_of(conn)
  end

  defp audits(ctx), do: Enum.map(@actions, &audit_count(ctx, &1))

  defp audit_entry(ctx, action) do
    from(e in Entry, where: e.action == ^action) |> Repo.one!(prefix: ctx.schema_name)
  end

  # chart_type is a presentation hint and is not part of the aggregate request
  defp replay_body(view) do
    view
    |> Map.take(["entity_type", "group_by", "aggregates"])
    |> Map.put("filters", view["filter"])
  end

  defp view_row(ctx, id) do
    from(v in "entity_views",
      where: v.id == type(^id, :binary_id),
      select:
        map(v, [
          :id,
          :tenant_id,
          :entity_type,
          :name,
          :kind,
          :columns,
          :filter,
          :sort,
          :group_by,
          :aggregates,
          :chart_type,
          :created_by,
          :updated_by,
          :inserted_at,
          :updated_at
        ])
    )
    |> Repo.one!(prefix: ctx.schema_name)
  end

  describe "criterion 4: name unique per type across kinds; visibility" do
    test "GU1 a graph and a list view cannot share a name, in either order", %{admin: admin} do
      assert request(:post, @path, admin, valid_view(%{"name" => "Dup"})).status == 201
      before = view_count(admin)

      conn = request(:post, @path, admin, graph_view(%{"name" => "Dup"}))
      assert conn.status == 409
      assert view_count(admin) == before

      create_graph!(admin, %{"name" => "Dup2"})
      before = view_count(admin)
      conn = request(:post, @path, admin, valid_view(%{"name" => "Dup2"}))
      assert conn.status == 409
      assert view_count(admin) == before
    end

    test "GU2 a graph and a pivot view cannot share a name, in either order", %{admin: admin} do
      assert request(:post, @path, admin, pivot_view(%{"name" => "Dup"})).status == 201
      before = view_count(admin)

      conn = request(:post, @path, admin, graph_view(%{"name" => "Dup"}))
      assert conn.status == 409
      assert view_count(admin) == before

      create_graph!(admin, %{"name" => "Dup2"})
      before = view_count(admin)
      conn = request(:post, @path, admin, pivot_view(%{"name" => "Dup2"}))
      assert conn.status == 409
      assert view_count(admin) == before
    end

    test "GU3 renaming a graph onto a list view's name is a 409 and changes nothing", %{
      admin: admin
    } do
      assert request(:post, @path, admin, valid_view(%{"name" => "Taken"})).status == 201
      graph = create_graph!(admin)
      row_before = view_row(admin, graph["id"])

      conn = request(:put, "#{@path}/#{graph["id"]}", admin, graph_view(%{"name" => "Taken"}))
      assert conn.status == 409
      assert view_row(admin, graph["id"]) == row_before
    end

    test "GL1 a graph is listed to a reader of the type and not once the type is restricted", %{
      admin: admin,
      worker: worker
    } do
      graph = create_graph!(admin)

      assert [item] = request(:get, @path, worker) |> body_of() |> Map.fetch!("items")
      assert item["id"] == graph["id"]
      assert item["kind"] == "graph"
      assert item["group_by"] == graph["group_by"]
      assert item["aggregates"] == graph["aggregates"]
      assert item["chart_type"] == "bar"

      restrict_type!(admin, "answer_option")
      assert request(:get, @path, worker) |> body_of() |> Map.fetch!("items") == []
      assert request(:get, @path, admin) |> body_of() |> Map.fetch!("items") == []
    end
  end

  describe "criterion 5: permissions" do
    test "GP1 a reader reads; writes are the same 403 for a present or absent id", %{
      admin: admin,
      worker: worker
    } do
      graph = create_graph!(admin)
      row_before = view_row(admin, graph["id"])
      audits_before = audits(admin)
      absent = Ecto.UUID.generate()

      assert request(:get, "#{@path}/#{graph["id"]}", worker).status == 200
      assert request(:post, @path, worker, graph_view(%{"name" => "w"})).status == 403

      present_put = request(:put, "#{@path}/#{graph["id"]}", worker, graph_view())
      absent_put = request(:put, "#{@path}/#{absent}", worker, graph_view())
      assert present_put.status == 403
      assert norm(present_put) == norm(absent_put)

      present_del = request(:delete, "#{@path}/#{graph["id"]}", worker)
      absent_del = request(:delete, "#{@path}/#{absent}", worker)
      assert present_del.status == 403
      assert norm(present_del) == norm(absent_del)

      assert view_row(admin, graph["id"]) == row_before
      assert audits(admin) == audits_before
    end

    test "GP2 reads need EntitiesQuery and writes EntitiesViewsManage; no new atom" do
      assert Authorization.required_permission(:EntitiesQuery) == :EntitiesQuery
      assert Authorization.required_permission(:EntitiesViewsManage) == :EntitiesViewsManage

      routes =
        Letflow.Routers.EntityViews.__authz_routes__()
        |> Enum.map(fn {method, _path, key} -> {method, key} end)
        |> Enum.sort()

      assert routes ==
               Enum.sort([
                 {"GET", :EntitiesQuery},
                 {"GET", :EntitiesQuery},
                 {"POST", :EntitiesViewsManage},
                 {"PUT", :EntitiesViewsManage},
                 {"DELETE", :EntitiesViewsManage}
               ])
    end
  end

  describe "criterion 6: replay equals the hand-built request; no data in view routes" do
    test "GR1 stored group_by, aggregates and filter replay as the hand-built request", %{
      admin: admin
    } do
      stored = create_graph!(admin)

      hand_built = %{
        "entity_type" => "answer_option",
        "filters" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "group_by" => [%{"field" => "question_id"}],
        "aggregates" => [%{"fn" => "count"}]
      }

      replay = replay_body(stored)
      refute Map.has_key?(replay, "chart_type")

      by_hand = request(:post, @aggregate, admin, hand_built)
      replayed = request(:post, @aggregate, admin, replay)

      assert by_hand.status == 200, by_hand.resp_body
      assert stored["filter"] != []
      assert norm(replayed) == norm(by_hand)

      # the filter is not dropped: another filter gives another body
      other = %{hand_built | "filters" => [%{"field" => "text", "op" => "eq", "value" => "A"}]}
      assert norm(request(:post, @aggregate, admin, other)) != norm(replayed)
    end

    test "GR2 a caller without a grant on is_correct is refused alike for replay and by hand", %{
      admin: admin,
      worker: worker
    } do
      filter = [%{"field" => "is_correct", "op" => "eq", "value" => true}]
      stored = create_graph!(admin, %{"name" => "restricted filter", "filter" => filter})

      hand_built = Map.put(replay_body(stored), "filters", filter)

      replayed = request(:post, @aggregate, worker, replay_body(stored))
      by_hand = request(:post, @aggregate, worker, hand_built)

      assert by_hand.status == 403, by_hand.resp_body
      assert norm(replayed) == norm(by_hand)
    end

    test "GR3 no view route response carries aggregate or record data", %{admin: admin} do
      graph = create_graph!(admin)

      responses = [
        request(:get, @path, admin),
        request(:get, "#{@path}/#{graph["id"]}", admin),
        request(:put, "#{@path}/#{graph["id"]}", admin, graph_view()),
        request(:post, @path, admin, graph_view(%{"name" => "second"}))
      ]

      for conn <- responses do
        refute conn.resp_body =~ ~s("field_values")
        refute conn.resp_body =~ ~s("record_id")
        refute conn.resp_body =~ ~s("result")
        refute conn.resp_body =~ ~s("count":)
        refute conn.resp_body =~ ~s("groups")

        for text <- ["A", "B", "C"], do: refute(conn.resp_body =~ ~s("#{text}"))
      end

      assert Map.keys(graph) |> Enum.sort() ==
               ~w(aggregates chart_type columns created_by entity_type filter group_by id inserted_at kind name sort updated_at updated_by)

      assert graph["chart_type"] == "bar"
    end
  end

  describe "criterion 7: one 404, cross tenant (INV-5, INV-10)" do
    test "GN1 unreadable type, other tenant, absent and malformed id are the same 404", %{
      admin: admin
    } do
      graph = create_graph!(admin)
      b_admin = "graph-b-b" |> tenant!() |> add_user!(["TENANT_ADMIN"])
      restrict_type!(admin, "answer_option")
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, graph_view()}, {:delete, nil}] do
        gone = request(method, "#{@path}/#{absent}", admin, body)
        assert gone.status == 404

        for conn <- [
              request(method, "#{@path}/#{graph["id"]}", admin, body),
              request(method, "#{@path}/#{graph["id"]}", b_admin, body),
              request(method, "#{@path}/not-a-uuid", admin, body)
            ] do
          assert norm(conn) == norm(gone)
        end
      end

      assert view_count(admin) == 1
    end

    test "GX1 a graph only in tenant A is the absent-id 404 for tenant B's admin", %{admin: admin} do
      graph = create_graph!(admin)
      b_admin = "graph-b-b" |> tenant!() |> add_user!(["TENANT_ADMIN"])
      row_before = view_row(admin, graph["id"])
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, graph_view()}, {:delete, nil}] do
        foreign = request(method, "#{@path}/#{graph["id"]}", b_admin, body)
        missing = request(method, "#{@path}/#{absent}", b_admin, body)
        assert foreign.status == 404
        assert norm(foreign) == norm(missing)
      end

      assert view_row(admin, graph["id"]) == row_before
      assert request(:get, @path, b_admin) |> body_of() |> Map.fetch!("items") == []
      assert view_count(b_admin) == 0
    end

    test "GX2 a tenant identifier in a graph body is refused and nothing is stored", %{
      admin: admin
    } do
      conn = request(:post, @path, admin, graph_view(%{"tenant_id" => Ecto.UUID.generate()}))
      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "unknown_key"
      assert view_count(admin) == 0
    end
  end

  describe "criterion 8: audit in the same transaction" do
    test "GA1 create, update and delete each write one audit entry", %{admin: admin} do
      graph = create_graph!(admin)
      assert audits(admin) == [1, 0, 0]
      assert audit_entry(admin, "entity_view.create").after_state["kind"] == "graph"

      put = request(:put, "#{@path}/#{graph["id"]}", admin, graph_view(%{"name" => "Renamed"}))
      assert put.status == 200
      assert audits(admin) == [1, 1, 0]
      update = audit_entry(admin, "entity_view.update")
      assert update.before_state["name"] == graph["name"]
      assert update.after_state["name"] == "Renamed"

      assert request(:delete, "#{@path}/#{graph["id"]}", admin).status == 204
      assert audits(admin) == [1, 1, 1]
      delete = audit_entry(admin, "entity_view.delete")
      assert delete.before_state["kind"] == "graph"
      assert delete.after_state == nil
    end

    test "GA2 refusals write no audit entry", %{admin: admin, worker: worker} do
      graph = create_graph!(admin)
      before = audits(admin)
      absent = Ecto.UUID.generate()

      refusals = [
        {request(:post, @path, admin, graph_view(%{"aggregates" => []})), 422},
        {request(:post, @path, admin, graph_view()), 409},
        {request(:put, "#{@path}/#{absent}", admin, graph_view()), 404},
        {request(:delete, "#{@path}/#{absent}", admin), 404},
        {request(:put, "#{@path}/#{graph["id"]}", worker, graph_view()), 403},
        {request(:delete, "#{@path}/#{graph["id"]}", worker), 403}
      ]

      for {conn, status} <- refusals, do: assert(conn.status == status, conn.resp_body)

      restrict_type!(admin, "answer_option")
      assert request(:put, "#{@path}/#{graph["id"]}", admin, graph_view()).status == 404
      assert request(:delete, "#{@path}/#{graph["id"]}", admin).status == 404

      assert audits(admin) == before
      assert view_count(admin) == 1
    end

    test "GA3 an audit failure rolls the graph write back", %{admin: admin} do
      Repo.query!(
        ~s|ALTER TABLE "#{admin.schema_name}".audit_entries RENAME TO audit_entries_gone|
      )

      result =
        try do
          Views.create(admin.schema_name, admin.user_id, graph_view())
        rescue
          error -> {:raised, error}
        end

      refute match?({:ok, _}, result)
      assert view_count(admin) == 0
    end
  end
end
