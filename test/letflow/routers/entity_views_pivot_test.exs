defmodule Letflow.Routers.EntityViewsPivotTest do
  @moduledoc """
  REQ-598 part B / GH #3367: the saved pivot kind behaves like a list view on the REQ-555 routes
  (`/api/v1/entity-views`): name uniqueness across kinds, visibility, permissions, replay equal to
  the hand-built aggregate request, uniform 404, cross-tenant (INV-10) and audit.

  Test ids follow the design: U1/U2 and L1 (criterion 3), P1/P2 (4), R1-R3 (5), N1 (6), X1/X2 (7),
  A1-A3 (8). U3 (same name on a second entity type) is dropped: it needs a second active type
  fixture and U1/U2 already prove uniqueness is per type and across kinds.
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
    base = tenant!("pivot-b-a")
    admin = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    worker = add_user!(base, ["TASK_WORKER"])
    {:ok, admin: admin, worker: worker}
  end

  defp create_pivot!(ctx, overrides \\ %{}) do
    conn = request(:post, @path, ctx, pivot_view(overrides))
    assert conn.status == 201, conn.resp_body
    body_of(conn)
  end

  defp audits(ctx), do: Enum.map(@actions, &audit_count(ctx, &1))

  defp audit_entry(ctx, action) do
    from(e in Entry, where: e.action == ^action) |> Repo.one!(prefix: ctx.schema_name)
  end

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
          :created_by,
          :updated_by,
          :inserted_at,
          :updated_at
        ])
    )
    |> Repo.one!(prefix: ctx.schema_name)
  end

  describe "criterion 3: name unique per type across kinds; visibility" do
    test "U1 a pivot and a list view cannot share a name, in either order", %{admin: admin} do
      assert request(:post, @path, admin, valid_view(%{"name" => "Dup"})).status == 201
      before = view_count(admin)

      conn = request(:post, @path, admin, pivot_view(%{"name" => "Dup"}))
      assert conn.status == 409
      assert view_count(admin) == before

      create_pivot!(admin, %{"name" => "Dup2"})
      before = view_count(admin)
      conn = request(:post, @path, admin, valid_view(%{"name" => "Dup2"}))
      assert conn.status == 409
      assert view_count(admin) == before
    end

    test "U2 renaming a pivot onto a list view's name is a 409 and changes nothing", %{
      admin: admin
    } do
      assert request(:post, @path, admin, valid_view(%{"name" => "Taken"})).status == 201
      pivot = create_pivot!(admin)
      row_before = view_row(admin, pivot["id"])

      conn = request(:put, "#{@path}/#{pivot["id"]}", admin, pivot_view(%{"name" => "Taken"}))
      assert conn.status == 409
      assert view_row(admin, pivot["id"]) == row_before
    end

    test "L1 a pivot is listed to a reader of the type and not once the type is restricted", %{
      admin: admin,
      worker: worker
    } do
      pivot = create_pivot!(admin)

      assert [item] = request(:get, @path, worker) |> body_of() |> Map.fetch!("items")
      assert item["id"] == pivot["id"]
      assert item["kind"] == "pivot"
      assert item["group_by"] == pivot["group_by"]
      assert item["aggregates"] == pivot["aggregates"]

      restrict_type!(admin, "answer_option")
      assert request(:get, @path, worker) |> body_of() |> Map.fetch!("items") == []
      assert request(:get, @path, admin) |> body_of() |> Map.fetch!("items") == []
    end
  end

  describe "criterion 4: permissions" do
    test "P1 a reader reads; writes are the same 403 for a present or absent id", %{
      admin: admin,
      worker: worker
    } do
      pivot = create_pivot!(admin)
      row_before = view_row(admin, pivot["id"])
      audits_before = audits(admin)
      absent = Ecto.UUID.generate()

      assert request(:get, "#{@path}/#{pivot["id"]}", worker).status == 200
      assert request(:post, @path, worker, pivot_view(%{"name" => "w"})).status == 403

      present_put = request(:put, "#{@path}/#{pivot["id"]}", worker, pivot_view())
      absent_put = request(:put, "#{@path}/#{absent}", worker, pivot_view())
      assert present_put.status == 403
      assert norm(present_put) == norm(absent_put)

      present_del = request(:delete, "#{@path}/#{pivot["id"]}", worker)
      absent_del = request(:delete, "#{@path}/#{absent}", worker)
      assert present_del.status == 403
      assert norm(present_del) == norm(absent_del)

      assert view_row(admin, pivot["id"]) == row_before
      assert audits(admin) == audits_before
    end

    test "P2 reads need EntitiesQuery and writes EntitiesViewsManage; no new atom" do
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

  describe "criterion 5: replay equals the hand-built request; no data in view routes" do
    test "R1 stored group_by, aggregates and filter replay as the hand-built request", %{
      admin: admin
    } do
      stored = create_pivot!(admin)

      hand_built = %{
        "entity_type" => "answer_option",
        "filters" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "group_by" => [%{"field" => "question_id"}],
        "aggregates" => [%{"fn" => "count"}, %{"fn" => "max", "field" => "text"}]
      }

      by_hand = request(:post, @aggregate, admin, hand_built)
      replayed = request(:post, @aggregate, admin, replay_body(stored))

      assert by_hand.status == 200, by_hand.resp_body
      assert stored["filter"] != []
      assert norm(replayed) == norm(by_hand)

      # the filter is not dropped: another filter gives another body
      other = %{hand_built | "filters" => [%{"field" => "text", "op" => "eq", "value" => "A"}]}
      assert norm(request(:post, @aggregate, admin, other)) != norm(replayed)
    end

    test "R2 a caller without a grant on is_correct is refused alike for replay and by hand", %{
      admin: admin,
      worker: worker
    } do
      filter = [%{"field" => "is_correct", "op" => "eq", "value" => true}]
      stored = create_pivot!(admin, %{"name" => "restricted filter", "filter" => filter})

      hand_built = Map.put(replay_body(stored), "filters", filter)

      replayed = request(:post, @aggregate, worker, replay_body(stored))
      by_hand = request(:post, @aggregate, worker, hand_built)

      assert by_hand.status == 403, by_hand.resp_body
      assert norm(replayed) == norm(by_hand)
    end

    test "R3 no view route response carries aggregate or record data", %{admin: admin} do
      pivot = create_pivot!(admin)

      responses = [
        request(:get, @path, admin),
        request(:get, "#{@path}/#{pivot["id"]}", admin),
        request(:put, "#{@path}/#{pivot["id"]}", admin, pivot_view()),
        request(:post, @path, admin, pivot_view(%{"name" => "second"}))
      ]

      for conn <- responses do
        refute conn.resp_body =~ ~s("field_values")
        refute conn.resp_body =~ ~s("record_id")
        refute conn.resp_body =~ ~s("result")
        refute conn.resp_body =~ ~s("count":)
        refute conn.resp_body =~ ~s("groups")

        for text <- ["A", "B", "C"], do: refute(conn.resp_body =~ ~s("#{text}"))
      end

      assert Map.keys(pivot) |> Enum.sort() ==
               ~w(aggregates columns created_by entity_type filter group_by id inserted_at kind name sort updated_at updated_by)
    end
  end

  describe "criterion 6: one 404" do
    test "N1 unreadable type, other tenant, absent and malformed id are the same 404", %{
      admin: admin
    } do
      pivot = create_pivot!(admin)
      b_admin = "pivot-b-b" |> tenant!() |> add_user!(["TENANT_ADMIN"])
      restrict_type!(admin, "answer_option")
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, pivot_view()}, {:delete, nil}] do
        gone = request(method, "#{@path}/#{absent}", admin, body)
        assert gone.status == 404

        for conn <- [
              request(method, "#{@path}/#{pivot["id"]}", admin, body),
              request(method, "#{@path}/#{pivot["id"]}", b_admin, body),
              request(method, "#{@path}/not-a-uuid", admin, body)
            ] do
          assert norm(conn) == norm(gone)
        end
      end

      assert view_count(admin) == 1
    end
  end

  describe "criterion 7 (INV-10): cross tenant" do
    test "X1 a pivot only in tenant A is the absent-id 404 for tenant B's admin", %{admin: admin} do
      pivot = create_pivot!(admin)
      b_admin = "pivot-b-b" |> tenant!() |> add_user!(["TENANT_ADMIN"])
      row_before = view_row(admin, pivot["id"])
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, pivot_view()}, {:delete, nil}] do
        foreign = request(method, "#{@path}/#{pivot["id"]}", b_admin, body)
        missing = request(method, "#{@path}/#{absent}", b_admin, body)
        assert foreign.status == 404
        assert norm(foreign) == norm(missing)
      end

      assert view_row(admin, pivot["id"]) == row_before
      assert request(:get, @path, b_admin) |> body_of() |> Map.fetch!("items") == []
      assert view_count(b_admin) == 0
    end

    test "X2 a tenant identifier in a pivot body is refused and nothing is stored", %{
      admin: admin
    } do
      conn = request(:post, @path, admin, pivot_view(%{"tenant_id" => Ecto.UUID.generate()}))
      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "unknown_key"
      assert view_count(admin) == 0
    end
  end

  describe "criterion 8: audit in the same transaction" do
    test "A1 create, update and delete each write one audit entry", %{admin: admin} do
      pivot = create_pivot!(admin)
      assert audits(admin) == [1, 0, 0]
      assert audit_entry(admin, "entity_view.create").after_state["kind"] == "pivot"

      put = request(:put, "#{@path}/#{pivot["id"]}", admin, pivot_view(%{"name" => "Renamed"}))
      assert put.status == 200
      assert audits(admin) == [1, 1, 0]
      update = audit_entry(admin, "entity_view.update")
      assert update.before_state["name"] == pivot["name"]
      assert update.after_state["name"] == "Renamed"

      assert request(:delete, "#{@path}/#{pivot["id"]}", admin).status == 204
      assert audits(admin) == [1, 1, 1]
      delete = audit_entry(admin, "entity_view.delete")
      assert delete.before_state["kind"] == "pivot"
      assert delete.after_state == nil
    end

    test "A2 refusals write no audit entry", %{admin: admin, worker: worker} do
      pivot = create_pivot!(admin)
      before = audits(admin)
      absent = Ecto.UUID.generate()

      refusals = [
        {request(:post, @path, admin, pivot_view(%{"aggregates" => []})), 422},
        {request(:post, @path, admin, pivot_view()), 409},
        {request(:put, "#{@path}/#{absent}", admin, pivot_view()), 404},
        {request(:delete, "#{@path}/#{absent}", admin), 404},
        {request(:put, "#{@path}/#{pivot["id"]}", worker, pivot_view()), 403},
        {request(:delete, "#{@path}/#{pivot["id"]}", worker), 403}
      ]

      for {conn, status} <- refusals, do: assert(conn.status == status, conn.resp_body)

      restrict_type!(admin, "answer_option")
      assert request(:put, "#{@path}/#{pivot["id"]}", admin, pivot_view()).status == 404
      assert request(:delete, "#{@path}/#{pivot["id"]}", admin).status == 404

      assert audits(admin) == before
      assert view_count(admin) == 1
    end

    test "A3 an audit failure rolls the pivot write back", %{admin: admin} do
      Repo.query!(
        ~s|ALTER TABLE "#{admin.schema_name}".audit_entries RENAME TO audit_entries_gone|
      )

      result =
        try do
          Views.create(admin.schema_name, admin.user_id, pivot_view())
        rescue
          error -> {:raised, error}
        end

      refute match?({:ok, _}, result)
      assert view_count(admin) == 0
    end
  end
end
