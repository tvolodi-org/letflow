defmodule Letflow.Routers.EntityViewsReportTest do
  @moduledoc """
  REQ-619 part B / GH #3453: the saved report kind behaves like the other kinds on the REQ-555
  routes (`/api/v1/entity-views`): permissions, replay equal to the hand-built aggregate and
  detail requests (INV-2), uniform 404 (INV-5), cross-tenant (INV-10) and audit.

  Test ids follow the design: RP1/RP2 (criterion 6), RR1-RR4 (7), RN1/RN2 (8), RX1/RX2 (9),
  RA1-RA3 (10). RA4 (no route added) is folded into RP2.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Letflow.EntityViewsSupport

  alias Letflow.Api.Authorization
  alias Letflow.Audit.Entry
  alias Letflow.Entities.Views

  @path "/api/v1/entity-views"
  @aggregate "/api/v1/entities/query/aggregate"
  @query "/api/v1/entities/query"
  @actions ["entity_view.create", "entity_view.update", "entity_view.delete"]

  setup do
    base = tenant!("report-b-a")
    admin = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    worker = add_user!(base, ["TASK_WORKER"])
    {:ok, admin: admin, worker: worker}
  end

  defp create_report!(ctx, overrides \\ %{}) do
    conn = request(:post, @path, ctx, report_view(overrides))
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

  defp detail_body(view) do
    view
    |> Map.take(["entity_type", "sort"])
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

  describe "criterion 6: permissions" do
    test "RP1 a reader reads; writes are the same 403 for a present or absent id", %{
      admin: admin,
      worker: worker
    } do
      report = create_report!(admin)
      row_before = view_row(admin, report["id"])
      audits_before = audits(admin)
      absent = Ecto.UUID.generate()

      one = request(:get, "#{@path}/#{report["id"]}", worker)
      assert one.status == 200
      assert body_of(one)["kind"] == "report"
      assert [item] = request(:get, @path, worker) |> body_of() |> Map.fetch!("items")
      assert item["id"] == report["id"]

      assert request(:post, @path, worker, report_view(%{"name" => "w"})).status == 403

      present_put = request(:put, "#{@path}/#{report["id"]}", worker, report_view())
      absent_put = request(:put, "#{@path}/#{absent}", worker, report_view())
      assert present_put.status == 403
      assert norm(present_put) == norm(absent_put)

      present_del = request(:delete, "#{@path}/#{report["id"]}", worker)
      absent_del = request(:delete, "#{@path}/#{absent}", worker)
      assert present_del.status == 403
      assert norm(present_del) == norm(absent_del)

      assert view_row(admin, report["id"]) == row_before
      assert audits(admin) == audits_before
      assert view_count(admin) == 1
    end

    test "RP2 reads need EntitiesQuery and writes EntitiesViewsManage; no new atom or route" do
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

  describe "criterion 7: replay equals the hand-built request (INV-2)" do
    test "RR1 stored filter, group_by and aggregates replay as the hand-built aggregate", %{
      admin: admin
    } do
      stored = create_report!(admin)

      hand_built = %{
        "entity_type" => "answer_option",
        "filters" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "group_by" => [%{"field" => "question_id"}],
        "aggregates" => [%{"fn" => "count"}]
      }

      by_hand = request(:post, @aggregate, admin, hand_built)
      replayed = request(:post, @aggregate, admin, replay_body(stored))

      assert by_hand.status == 200, by_hand.resp_body
      assert stored["filter"] != []
      assert norm(replayed) == norm(by_hand)

      other = %{hand_built | "filters" => [%{"field" => "text", "op" => "eq", "value" => "A"}]}
      assert norm(request(:post, @aggregate, admin, other)) != norm(replayed)
    end

    test "RR2 stored filter and sort replay as the hand-built detail query", %{admin: admin} do
      stored = create_report!(admin)

      hand_built = %{
        "entity_type" => "answer_option",
        "filters" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "sort" => [%{"field" => "text", "dir" => "asc"}]
      }

      by_hand = request(:post, @query, admin, hand_built)
      replayed = request(:post, @query, admin, detail_body(stored))

      assert by_hand.status == 200, by_hand.resp_body
      assert norm(replayed) == norm(by_hand)
    end

    test "RR3 a caller without a grant on is_correct gets the same answer by replay and by hand",
         %{admin: admin, worker: worker} do
      filter = [%{"field" => "is_correct", "op" => "eq", "value" => true}]
      stored = create_report!(admin, %{"name" => "restricted filter", "filter" => filter})

      for {path, body_fun} <- [{@aggregate, &replay_body/1}, {@query, &detail_body/1}] do
        replayed = request(:post, path, worker, body_fun.(stored))
        by_hand = request(:post, path, worker, Map.put(body_fun.(stored), "filters", filter))

        assert by_hand.status == 403, by_hand.resp_body
        assert norm(replayed) == norm(by_hand)
      end

      open = create_report!(admin, %{"name" => "open filter"})

      hand_built = %{
        "entity_type" => "answer_option",
        "filters" => open["filter"],
        "sort" => open["sort"]
      }

      replayed = request(:post, @query, worker, detail_body(open))
      by_hand = request(:post, @query, worker, hand_built)
      assert by_hand.status == 200, by_hand.resp_body
      assert norm(replayed) == norm(by_hand)
    end

    test "RR4 no view route response carries aggregate or record data", %{admin: admin} do
      report = create_report!(admin)

      responses = [
        request(:get, @path, admin),
        request(:get, "#{@path}/#{report["id"]}", admin),
        request(:put, "#{@path}/#{report["id"]}", admin, report_view()),
        request(:post, @path, admin, report_view(%{"name" => "second"}))
      ]

      for conn <- responses do
        refute conn.resp_body =~ ~s("field_values")
        refute conn.resp_body =~ ~s("record_id")
        refute conn.resp_body =~ ~s("result")
        refute conn.resp_body =~ ~s("count":)
        refute conn.resp_body =~ ~s("groups")

        for text <- ["A", "B", "C"], do: refute(conn.resp_body =~ ~s("#{text}"))
      end

      assert Map.keys(report) |> Enum.sort() ==
               ~w(aggregates chart_type columns created_by entity_type filter group_by id inserted_at kind name sort updated_at updated_by)
    end
  end

  describe "criterion 8 (INV-5): one 404" do
    test "RN1 unreadable type, other tenant, absent and malformed id are the same 404", %{
      admin: admin
    } do
      report = create_report!(admin)
      b_admin = "report-b-b" |> tenant!() |> add_user!(["TENANT_ADMIN"])
      restrict_type!(admin, "answer_option")
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, report_view()}, {:delete, nil}] do
        gone = request(method, "#{@path}/#{absent}", admin, body)
        assert gone.status == 404

        for conn <- [
              request(method, "#{@path}/#{report["id"]}", admin, body),
              request(method, "#{@path}/#{report["id"]}", b_admin, body),
              request(method, "#{@path}/not-a-uuid", admin, body)
            ] do
          assert norm(conn) == norm(gone)
        end
      end

      assert view_count(admin) == 1
    end

    test "RN2 creating a report for an unknown or a restricted type is the same 404", %{
      admin: admin
    } do
      unknown = request(:post, @path, admin, report_view(%{"entity_type" => "no_such_type"}))
      assert unknown.status == 404, unknown.resp_body

      restrict_type!(admin, "answer_option")
      restricted = request(:post, @path, admin, report_view())

      assert restricted.status == 404
      assert norm(restricted) == norm(unknown)
      assert view_count(admin) == 0
    end
  end

  describe "criterion 9 (INV-10): cross tenant" do
    test "RX1 a report only in tenant A is the absent-id 404 for tenant B's admin", %{
      admin: admin
    } do
      report = create_report!(admin)
      b_admin = "report-b-b" |> tenant!() |> add_user!(["TENANT_ADMIN"])
      row_before = view_row(admin, report["id"])
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, report_view()}, {:delete, nil}] do
        foreign = request(method, "#{@path}/#{report["id"]}", b_admin, body)
        missing = request(method, "#{@path}/#{absent}", b_admin, body)
        assert foreign.status == 404
        assert norm(foreign) == norm(missing)
      end

      assert view_row(admin, report["id"]) == row_before
      assert request(:get, @path, b_admin) |> body_of() |> Map.fetch!("items") == []
      assert view_count(b_admin) == 0
    end

    test "RX2 a tenant identifier in a report body is refused and nothing is stored", %{
      admin: admin
    } do
      conn = request(:post, @path, admin, report_view(%{"tenant_id" => Ecto.UUID.generate()}))
      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "unknown_key"
      assert view_count(admin) == 0
    end
  end

  describe "criterion 10: audit in the same transaction" do
    test "RA1 create, update and delete each write one audit entry", %{admin: admin} do
      report = create_report!(admin)
      assert audits(admin) == [1, 0, 0]
      assert audit_entry(admin, "entity_view.create").after_state["kind"] == "report"

      put = request(:put, "#{@path}/#{report["id"]}", admin, report_view(%{"name" => "Renamed"}))
      assert put.status == 200
      assert audits(admin) == [1, 1, 0]
      update = audit_entry(admin, "entity_view.update")
      assert update.before_state["name"] == report["name"]
      assert update.after_state["name"] == "Renamed"

      assert request(:delete, "#{@path}/#{report["id"]}", admin).status == 204
      assert audits(admin) == [1, 1, 1]
      delete = audit_entry(admin, "entity_view.delete")
      assert delete.before_state["kind"] == "report"
      assert delete.after_state == nil
    end

    test "RA2 refusals write no audit entry", %{admin: admin, worker: worker} do
      report = create_report!(admin)
      before = audits(admin)
      absent = Ecto.UUID.generate()

      refusals = [
        {request(:post, @path, admin, report_view(%{"aggregates" => []})), 422},
        {request(:post, @path, admin, report_view()), 409},
        {request(:put, "#{@path}/#{absent}", admin, report_view()), 404},
        {request(:delete, "#{@path}/#{absent}", admin), 404},
        {request(:put, "#{@path}/#{report["id"]}", worker, report_view()), 403},
        {request(:delete, "#{@path}/#{report["id"]}", worker), 403}
      ]

      for {conn, status} <- refusals, do: assert(conn.status == status, conn.resp_body)

      restrict_type!(admin, "answer_option")
      assert request(:put, "#{@path}/#{report["id"]}", admin, report_view()).status == 404
      assert request(:delete, "#{@path}/#{report["id"]}", admin).status == 404

      assert audits(admin) == before
      assert view_count(admin) == 1
    end

    test "RA3 an audit failure rolls the report write back", %{admin: admin} do
      Repo.query!(
        ~s|ALTER TABLE "#{admin.schema_name}".audit_entries RENAME TO audit_entries_gone|
      )

      result =
        try do
          Views.create(admin.schema_name, admin.user_id, report_view())
        rescue
          error -> {:raised, error}
        end

      refute match?({:ok, _}, result)
      assert view_count(admin) == 0
    end
  end
end
