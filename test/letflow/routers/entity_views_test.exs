defmodule Letflow.Routers.EntityViewsTest do
  @moduledoc """
  REQ-555 / GH #3157 (decision 0066): the saved-view routes at `/api/v1/entity-views`.

  Test ids follow the design: V422a-f (criterion 2), P1 (3), F1/F2 (4), N1-N3 (5), X1/X2 (6).
  """

  use Letflow.DataCase, async: false

  import Letflow.EntityViewsSupport

  @path "/api/v1/entity-views"

  setup do
    base = tenant!("views-a")
    admin = base |> add_user!(["TENANT_ADMIN"]) |> answer_option!()
    worker = add_user!(base, ["TASK_WORKER"])
    {:ok, admin: admin, worker: worker}
  end

  defp create!(ctx, overrides \\ %{}) do
    conn = request(:post, @path, ctx, valid_view(overrides))
    assert conn.status == 201, conn.resp_body
    body_of(conn)
  end

  describe "create, read, update, delete" do
    test "round trip returns the allowlisted shape and no tenant id", %{admin: admin} do
      view = create!(admin)

      assert Map.keys(view) |> Enum.sort() ==
               ~w(aggregates chart_type columns created_by entity_type filter group_by id inserted_at kind name sort updated_at updated_by)

      assert view["created_by"] == admin.user_id

      assert request(:get, "#{@path}/#{view["id"]}", admin) |> body_of() == view
      assert [%{"id" => id}] = request(:get, @path, admin) |> body_of() |> Map.fetch!("items")
      assert id == view["id"]

      put = request(:put, "#{@path}/#{view["id"]}", admin, valid_view(%{"name" => "Renamed"}))
      assert put.status == 200
      assert body_of(put)["name"] == "Renamed"

      assert request(:delete, "#{@path}/#{view["id"]}", admin).status == 204
      assert request(:get, "#{@path}/#{view["id"]}", admin).status == 404
    end

    test "a duplicate name on the same type is a 409 and stores nothing", %{admin: admin} do
      create!(admin)
      before = view_count(admin)
      conn = request(:post, @path, admin, valid_view())
      assert conn.status == 409
      assert view_count(admin) == before
    end

    test "update cannot change the entity type", %{admin: admin} do
      view = create!(admin)

      conn =
        request(:put, "#{@path}/#{view["id"]}", admin, valid_view(%{"entity_type" => "other"}))

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "entity_type_immutable"
    end

    test "a non-object body is a 400", %{admin: admin} do
      conn =
        Plug.Test.conn(:post, @path, "[1]")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> admin.plaintext)
        |> Plug.Conn.put_req_header("x-tenant-slug", admin.slug)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert conn.status == 400
    end
  end

  describe "criterion 2: validation on write, one test per case" do
    defp refused(admin, overrides, detail) do
      before = view_count(admin)
      conn = request(:post, @path, admin, valid_view(overrides))
      assert conn.status == 422, conn.resp_body
      assert body_of(conn)["detail"] =~ detail
      assert view_count(admin) == before
    end

    test "V422a a filter field not on the type", %{admin: admin} do
      refused(
        admin,
        %{"filter" => [%{"field" => "nope", "op" => "eq", "value" => "x"}]},
        "field_not_allowed"
      )
    end

    test "V422b an unknown operator", %{admin: admin} do
      refused(
        admin,
        %{"filter" => [%{"field" => "text", "op" => "like", "value" => "x"}]},
        "unknown_operator"
      )
    end

    test "V422c an unknown sort direction", %{admin: admin} do
      refused(admin, %{"sort" => [%{"field" => "text", "dir" => "sideways"}]}, "unknown_sort_dir")
    end

    test "V422d a sort field not on the type", %{admin: admin} do
      refused(
        admin,
        %{"sort" => [%{"field" => "nope", "dir" => "asc"}]},
        "field_not_allowed"
      )
    end

    test "V422e a column not on the type", %{admin: admin} do
      refused(admin, %{"columns" => ["text", "nope"]}, "column_not_on_type")
    end

    test "V422f a tenant_id body key is refused and stores nothing", %{admin: admin} do
      refused(admin, %{"tenant_id" => Ecto.UUID.generate()}, "unknown_key")
    end

    test "malformed clauses are 422, not a crash", %{admin: admin} do
      refused(admin, %{"filter" => ["not a map"]}, "filter_invalid")
      refused(admin, %{"filter" => [%{"field" => 1, "op" => 2}]}, "filter_invalid")
      refused(admin, %{"sort" => [42]}, "sort_invalid")
      refused(admin, %{"columns" => []}, "columns_invalid")
      refused(admin, %{"name" => ""}, "name_invalid")
    end

    test "an update that fails validation changes nothing", %{admin: admin} do
      view = create!(admin)

      conn =
        request(
          :put,
          "#{@path}/#{view["id"]}",
          admin,
          valid_view(%{"sort" => [%{"field" => "text", "dir" => "up"}]})
        )

      assert conn.status == 422
      assert request(:get, "#{@path}/#{view["id"]}", admin) |> body_of() == view
    end
  end

  describe "P1 permissions" do
    test "a reader lists and reads; the three writes are the same 403 for a present or absent id",
         %{admin: admin, worker: worker} do
      view = create!(admin)

      assert request(:get, @path, worker).status == 200
      assert request(:get, "#{@path}/#{view["id"]}", worker).status == 200

      absent = Ecto.UUID.generate()

      present_put = request(:put, "#{@path}/#{view["id"]}", worker, valid_view())
      absent_put = request(:put, "#{@path}/#{absent}", worker, valid_view())
      assert present_put.status == 403
      assert norm(present_put) == norm(absent_put)

      present_del = request(:delete, "#{@path}/#{view["id"]}", worker)
      absent_del = request(:delete, "#{@path}/#{absent}", worker)
      assert present_del.status == 403
      assert norm(present_del) == norm(absent_del)

      assert request(:post, @path, worker, valid_view(%{"name" => "w"})).status == 403
      assert request(:get, "#{@path}/#{view["id"]}", admin) |> body_of() == view
    end
  end

  describe "criterion 4 (INV-2): a view never reads or widens record access" do
    test "F1 replaying a stored view redacts exactly as a hand-built query", %{
      admin: admin,
      worker: worker
    } do
      stored =
        create!(admin, %{
          "name" => "with restricted column",
          "columns" => ["text", "is_correct"],
          "filter" => [%{"field" => "text", "op" => "neq", "value" => "Z"}]
        })

      hand_built = %{
        "entity_type" => "answer_option",
        "filters" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "sort" => [%{"field" => "text", "dir" => "asc"}]
      }

      replay = %{
        "entity_type" => stored["entity_type"],
        "filters" => stored["filter"],
        "sort" => stored["sort"]
      }

      by_hand = request(:post, "/api/v1/entities/query", worker, hand_built)
      replayed = request(:post, "/api/v1/entities/query", worker, replay)

      assert by_hand.status == 200
      assert norm(replayed) == norm(by_hand)

      assert body_of(replayed)["items"] != []

      for item <- body_of(replayed)["items"] do
        assert item["field_values"]["is_correct"] == "__field_redacted__"
      end
    end

    test "F2 no view route response contains a record value", %{admin: admin} do
      view = create!(admin)

      responses = [
        request(:get, @path, admin),
        request(:get, "#{@path}/#{view["id"]}", admin),
        request(:put, "#{@path}/#{view["id"]}", admin, valid_view()),
        request(:post, @path, admin, valid_view(%{"name" => "second"}))
      ]

      for conn <- responses, text <- ["A", "B", "C"] do
        refute conn.resp_body =~ ~s("field_values")
        refute conn.resp_body =~ ~s("record_id")
        refute conn.resp_body =~ ~s("#{text}"), "record value #{text} leaked"
      end
    end
  end

  describe "criterion 5 (INV-5): one 404 for absent, malformed and type-denied ids" do
    test "N1 a view of a type the caller may not read answers like an absent id", %{admin: admin} do
      view = create!(admin)
      restrict_type!(admin, "answer_option")
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, valid_view()}, {:delete, nil}] do
        denied = request(method, "#{@path}/#{view["id"]}", admin, body)
        gone = request(method, "#{@path}/#{absent}", admin, body)

        assert denied.status == 404
        assert norm(denied) == norm(gone)
      end

      assert view_count(admin) == 1
    end

    test "N2 a non-UUID id is the same 404", %{admin: admin} do
      absent = request(:get, "#{@path}/#{Ecto.UUID.generate()}", admin)
      bad = request(:get, "#{@path}/not-a-uuid", admin)
      assert bad.status == 404
      assert norm(bad) == norm(absent)
    end

    test "N3 the list omits views of a restricted type; create of that type is a 404", %{
      admin: admin,
      worker: worker
    } do
      create!(admin)
      restrict_type!(admin, "answer_option")

      assert request(:get, @path, worker) |> body_of() |> Map.fetch!("items") == []
      assert request(:get, @path, admin) |> body_of() |> Map.fetch!("items") == []

      before = view_count(admin)
      conn = request(:post, @path, admin, valid_view(%{"name" => "again"}))
      assert conn.status == 404
      assert view_count(admin) == before
    end
  end

  describe "criterion 6 (INV-10): cross tenant" do
    test "X1 a view that exists only in tenant A is the absent-id 404 for tenant B's admin", %{
      admin: admin
    } do
      view = create!(admin)
      b_admin = tenant!("views-b") |> add_user!(["TENANT_ADMIN"])

      row_before = row(admin, view["id"])
      absent = Ecto.UUID.generate()

      for {method, body} <- [{:get, nil}, {:put, valid_view()}, {:delete, nil}] do
        foreign = request(method, "#{@path}/#{view["id"]}", b_admin, body)
        missing = request(method, "#{@path}/#{absent}", b_admin, body)

        assert foreign.status == 404
        assert norm(foreign) == norm(missing)
      end

      assert row(admin, view["id"]) == row_before
      assert request(:get, @path, b_admin) |> body_of() |> Map.fetch!("items") == []
    end

    test "X2 a tenant identifier in the body is refused; the view lands in the caller's tenant",
         %{admin: admin} do
      conn = request(:post, @path, admin, valid_view(%{"tenant_id" => Ecto.UUID.generate()}))
      assert conn.status == 422

      view = create!(admin)
      assert row(admin, view["id"]).tenant_id |> Ecto.UUID.cast!() == admin.tenant_id
    end
  end

  defp row(ctx, id) do
    import Ecto.Query, only: [from: 2]

    from(v in "entity_views",
      where: v.id == type(^id, :binary_id),
      select:
        map(v, [
          :id,
          :tenant_id,
          :entity_type,
          :name,
          :columns,
          :filter,
          :sort,
          :created_by,
          :updated_by,
          :inserted_at,
          :updated_at
        ])
    )
    |> Repo.one!(prefix: ctx.schema_name)
  end
end
