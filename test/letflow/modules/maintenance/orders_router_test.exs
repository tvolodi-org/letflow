Code.require_file("../stock/stock_fixture.exs", __DIR__)
Code.require_file("../assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Maintenance.OrdersRouterTest do
  @moduledoc """
  REQ-896 / GH #4804 criteria 1 to 8 through the full `Letflow.Router` with real OIDC bearer tokens on
  committed tenants: O-01 from a request, O-02 direct and refusals, O-03 one transaction, O-04
  assignment and mail, O-05 the technician completes, O-06 close, O-07 reassign, cancel and filters,
  O-08 isolation and access. `async: false`, Sandbox `:auto`; the flag is on in `config/test.exs`
  and turned off only inside O-08.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: A
  alias Letflow.Documents.Document
  alias Letflow.Engine.Task
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Maintenance
  alias Letflow.Notifications.Delivery
  alias Letflow.StockFixture, as: S
  alias Letflow.UserNotifications.Notification

  @base "/api/v1/modules/maintenance"
  @modules ["org", "catalog_items", "locations", "codes", "stock", "assets", "maintenance"]

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = tenant!("mnt-oa", ctx.names.a)
    b = tenant!("mnt-ob", ctx.names.b)

    {1, _} =
      Repo.update_all(
        from(t in "tenants", where: t.id == type(^a.tenant_id, :binary_id)),
        set: [settings: %{"notifications.email_copy" => true}]
      )

    ctx =
      Map.merge(ctx, %{
        a: a,
        b: b,
        tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
        tok_b: S.token(ctx, :b, ["TENANT_ADMIN"]),
        w1: S.token(ctx, :a, ["TASK_WORKER"], sub: "mnt-w1"),
        w2: S.token(ctx, :a, ["TASK_WORKER"], sub: "mnt-w2")
      })

    ctx = Map.merge(ctx, %{unit_a: unit!(ctx.tok_a), unit_b: unit!(ctx.tok_b)})

    {:ok,
     Map.merge(ctx, %{u1: user_id!(ctx, ctx.w1, "mnt-w1"), u2: user_id!(ctx, ctx.w2, "mnt-w2")})}
  end

  defp tenant!(prefix, realm) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- @modules do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-896"
        )
    end

    t
  end

  defp req(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, path)
        body -> Plug.Test.conn(method, path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp key, do: Ecto.UUID.generate()
  defp mnt(tok, method, path, body \\ nil), do: req(method, @base <> path, tok, body)

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  # The first request of a token provisions its user; the user is found by the `sub` (username).
  defp user_id!(ctx, token, sub) do
    assert req(:get, "/api/v1/tasks/inbox", token).status == 200
    Repo.one!(from(u in User, where: u.username == ^sub, select: u.id), prefix: ctx.a.schema_name)
  end

  defp org!(tok, path, body) do
    ok!(
      req(:post, "/api/v1/modules/org" <> path, tok, Map.put(body, "idempotency_key", key())),
      201
    )
  end

  defp unit!(tok) do
    n = System.unique_integer([:positive])

    le =
      org!(tok, "/legal-entities", %{
        "code" => "L#{n}",
        "name" => "L#{n}",
        "bin" => String.pad_leading("#{n}", 12, "1")
      })["record_id"]

    site =
      org!(tok, "/sites", %{"code" => "S#{n}", "name" => "S#{n}", "legal_entity_id" => le})[
        "record_id"
      ]

    org!(tok, "/units", %{
      "code" => "U#{n}",
      "name" => "U#{n}",
      "legal_entity_id" => le,
      "site_id" => site
    })["record_id"]
  end

  defp card!(schema, unit, extra \\ %{}) do
    n = "M-#{System.unique_integer([:positive])}"

    A.card!(
      schema,
      n,
      Map.merge(
        %{
          "org_unit_id" => unit,
          "acquisition_cost" => "987654321.000000000",
          "name" => "Pump #{n}"
        },
        extra
      )
    ).record_id
  end

  defp request!(ctx, card) do
    ok!(
      mnt(ctx.tok_a, :post, "/requests", %{
        "asset_card_id" => card,
        "description" => "Leaking pump",
        "urgency" => "urgent",
        "idempotency_key" => key()
      }),
      201
    )
  end

  defp direct(card, extra \\ %{}) do
    Map.merge(
      %{
        "asset_card_id" => card,
        "description" => "Replace belt",
        "urgency" => "low",
        "idempotency_key" => key()
      },
      extra
    )
  end

  defp order!(ctx, body), do: ok!(mnt(ctx.tok_a, :post, "/orders", body), 201)

  defp get_order(ctx, id, tok \\ nil), do: mnt(tok || ctx.tok_a, :get, "/orders/#{id}")

  defp task!(ctx, order_id, node) do
    row =
      Repo.one!(from(l in Latest, where: l.record_id == ^order_id), prefix: ctx.a.schema_name)

    Repo.one!(
      from(t in Task,
        where: t.instance_id == ^row.field_values["instance_id"] and t.node_id == ^node,
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: ctx.a.schema_name
    )
  end

  defp complete(tok, task_id, body),
    do: req(:post, "/api/v1/tasks/#{task_id}/complete", tok, body)

  defp counts(schema) do
    {Repo.aggregate(from(l in Latest, where: l.entity_type == "maintenance_work_order"), :count,
       prefix: schema
     ), Repo.aggregate(Document, :count, prefix: schema),
     Repo.aggregate(InstanceProjection, :count, prefix: schema)}
  end

  defp await(fun) do
    Enum.reduce_while(1..100, nil, fn _i, _acc ->
      case fun.() do
        [_ | _] = found -> {:halt, found}
        _ -> Process.sleep(20) && {:cont, nil}
      end
    end)
  end

  defp deliveries(schema, user) do
    from(d in Delivery, where: d.recipient_user_id == ^user and d.template_key == "task_assigned")
    |> Repo.all(prefix: schema)
  end

  defp bells(schema, user) do
    from(n in Notification, where: n.user_id == ^user and n.kind == "task_assigned")
    |> Repo.all(prefix: schema)
  end

  test "O-01: an order from a new request: 201 open, WO number, request copied; request ordered",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    r = request!(ctx, card)

    o = order!(ctx, %{"request_id" => r["id"], "idempotency_key" => key()})
    assert o["status"] == "open" and o["assignee_user_id"] == nil
    assert o["number"] =~ ~r/\AWO-\d{4}-\d{6}\z/
    assert o["description"] == "Leaking pump" and o["urgency"] == "urgent"
    assert o["asset"]["id"] == card
    assert o["request"] == %{"id" => r["id"], "number" => r["number"]}
    refute inspect(o) =~ "987654321"

    after_req = ok!(mnt(ctx.tok_a, :get, "/requests/#{r["id"]}"), 200)
    assert after_req["status"] == "ordered"
    assert after_req["order"] == %{"id" => o["id"], "number" => o["number"]}

    again =
      ok!(
        mnt(ctx.tok_a, :post, "/orders", %{"request_id" => r["id"], "idempotency_key" => key()}),
        409
      )

    assert again["reason"] == "request_not_new"

    # the instance carries the six variables and no cost field
    stored =
      Repo.one!(from(l in Latest, where: l.record_id == ^o["id"]), prefix: ctx.a.schema_name)

    proj =
      Repo.get_by!(InstanceProjection, [instance_id: stored.field_values["instance_id"]],
        prefix: ctx.a.schema_name
      )

    assert proj.variables |> Map.keys() |> Enum.sort() ==
             ~w(asset_inventory_number asset_name description maintenance_order_id maintenance_order_number urgency)

    refute inspect(proj.variables) =~ "987654321"
  end

  test "O-02: direct order 201 with request null; refusals write nothing", ctx do
    schema = ctx.a.schema_name
    card = card!(schema, ctx.unit_a)
    retired = card!(schema, ctx.unit_a, %{"active" => false})
    foreign_user = user_of_b!(ctx)

    o = order!(ctx, direct(card))
    assert o["request"] == nil and o["status"] == "open"
    assert o["description"] == "Replace belt" and o["urgency"] == "low"

    r = request!(ctx, card)
    before = counts(schema)

    cases = [
      {direct(card, %{"request_id" => r["id"]}), "order_source_invalid"},
      {%{"description" => "x", "idempotency_key" => key()}, "order_source_invalid"},
      {%{"request_id" => r["id"], "description" => "x", "idempotency_key" => key()},
       "order_source_invalid"},
      {direct(retired), "asset_card_inactive"},
      {direct(card, %{"assignee_user_id" => Ecto.UUID.generate()}), "assignee_not_found"},
      {direct(card, %{"assignee_user_id" => foreign_user}), "assignee_not_found"},
      {direct(card, %{"assignee_user_id" => "nope"}), "assignee_not_found"}
    ]

    for {body, reason} <- cases do
      assert ok!(mnt(ctx.tok_a, :post, "/orders", body), 422)["reason"] == reason, reason
    end

    assert counts(schema) == before
    assert ok!(mnt(ctx.tok_a, :get, "/requests/#{r["id"]}"), 200)["status"] == "new"
  end

  defp user_of_b!(ctx) do
    tok = S.token(ctx, :b, ["TASK_WORKER"], sub: "mnt-bw")
    assert req(:get, "/api/v1/tasks/inbox", tok).status == 200

    Repo.one!(from(u in User, where: u.username == "mnt-bw", select: u.id),
      prefix: ctx.b.schema_name
    )
  end

  test "O-03: a failed instance start leaves no order, no WO document, the request still new",
       ctx do
    schema = ctx.a.schema_name
    card = card!(schema, ctx.unit_a)
    r = request!(ctx, card)
    before = counts(schema)

    Application.put_env(:letflow, :maintenance_order_start_fail?, true)
    on_exit(fn -> Application.delete_env(:letflow, :maintenance_order_start_fail?) end)

    conn =
      mnt(ctx.tok_a, :post, "/orders", %{"request_id" => r["id"], "idempotency_key" => key()})

    assert conn.status == 422

    assert counts(schema) == before
    assert ok!(mnt(ctx.tok_a, :get, "/requests/#{r["id"]}"), 200)["status"] == "new"
  end

  test "O-04: an assignee gives in_work, the inbox task, one mail row and one bell row", ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))
    assert o["status"] == "in_work" and o["assignee_user_id"] == ctx.u1

    task = task!(ctx, o["id"], "maintenance_work")
    inbox = req(:get, "/api/v1/tasks/inbox", ctx.w1)
    assert inbox.status == 200 and inbox.resp_body =~ task.id

    assert [_] = await(fn -> deliveries(ctx.a.schema_name, ctx.u1) end)
    assert [_] = bells(ctx.a.schema_name, ctx.u1)
    assert deliveries(ctx.a.schema_name, ctx.u2) == []
  end

  test "O-05: the technician completes with no maintenance permission; a colleague is refused",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))
    task = task!(ctx, o["id"], "maintenance_work")

    refused = complete(ctx.w2, task.id, %{"work_done" => "I did it"})
    assert refused.status in [403, 409]
    assert refused.resp_body =~ "assigned to a different user"
    assert ok!(get_order(ctx, o["id"]), 200)["status"] == "in_work"

    assert complete(ctx.w1, task.id, %{"work_done" => "Belt replaced"}).status == 200
    done = ok!(get_order(ctx, o["id"]), 200)
    assert done["status"] == "done" and done["assignee_user_id"] == ctx.u1

    assert ok!(get_order(ctx, o["id"], ctx.w1), 403)["title"] == "Forbidden"
  end

  test "O-06: a TENANT_ADMIN closes; assign on the closed order is 409", ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))
    work = task!(ctx, o["id"], "maintenance_work")
    assert complete(ctx.w1, work.id, %{"work_done" => "Done"}).status == 200

    # a work text outside the form (empty) never reaches done on another order
    close = task!(ctx, o["id"], "maintenance_close")
    assert complete(ctx.tok_a, close.id, %{}).status == 200
    assert ok!(get_order(ctx, o["id"]), 200)["status"] == "closed"

    refused = ok!(mnt(ctx.tok_a, :post, "/orders/#{o["id"]}/assign", %{"user_id" => ctx.u2}), 409)
    assert refused["reason"] == "order_not_assignable"
  end

  test "O-07: reassign, cancel and the status filter", ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    open = order!(ctx, direct(card))
    moving = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))
    cancelled = order!(ctx, direct(card))

    re = ok!(mnt(ctx.tok_a, :post, "/orders/#{moving["id"]}/assign", %{"user_id" => ctx.u2}), 200)
    assert re["status"] == "in_work" and re["assignee_user_id"] == ctx.u2
    assert [_] = await(fn -> deliveries(ctx.a.schema_name, ctx.u2) end)

    # open to in work through assign
    taken =
      ok!(mnt(ctx.tok_a, :post, "/orders/#{open["id"]}/assign", %{"user_id" => ctx.u1}), 200)

    assert taken["status"] == "in_work"

    assert ok!(
             mnt(ctx.tok_a, :post, "/orders/#{moving["id"]}/assign", %{
               "user_id" => Ecto.UUID.generate()
             }),
             422
           )["reason"] ==
             "assignee_not_found"

    row =
      Repo.one!(from(l in Latest, where: l.record_id == ^cancelled["id"]),
        prefix: ctx.a.schema_name
      )

    assert req(
             :post,
             "/api/v1/instances/#{row.field_values["instance_id"]}/cancel",
             ctx.tok_a,
             %{}
           ).status ==
             200

    assert ok!(get_order(ctx, cancelled["id"]), 200)["status"] == "cancelled"

    in_work = ok!(mnt(ctx.tok_a, :get, "/orders?status=in_work"), 200)
    ids = Enum.map(in_work["rows"], & &1["id"]) |> Enum.sort()
    assert ids == Enum.sort([moving["id"], open["id"]])
    assert Enum.all?(in_work["rows"], &(&1["status"] == "in_work"))

    assert ok!(mnt(ctx.tok_a, :get, "/orders?status=active"), 422)["reason"] == "invalid_filter"
    assert ok!(mnt(ctx.tok_a, :get, "/orders?status=cancelled"), 200)["rows"] |> length() == 1

    all = ok!(mnt(ctx.tok_a, :get, "/orders?limit=2"), 200)
    assert length(all["rows"]) == 2 and is_binary(all["next_cursor"])
    rest = ok!(mnt(ctx.tok_a, :get, "/orders?limit=2&cursor=#{all["next_cursor"]}"), 200)
    assert length(rest["rows"]) == 1 and rest["next_cursor"] == nil

    by_card = ok!(mnt(ctx.tok_a, :get, "/orders?asset_card_id=#{card}"), 200)
    assert length(by_card["rows"]) == 3

    assert ok!(mnt(ctx.tok_a, :get, "/orders?asset_card_id=bad"), 422)["reason"] ==
             "invalid_filter"
  end

  describe "O-08: isolation and access" do
    test "another tenant's order and an unknown id are one 404; roles; flag off", ctx do
      card = card!(ctx.a.schema_name, ctx.unit_a)
      o = order!(ctx, direct(card))

      other = strip(ok!(mnt(ctx.tok_b, :get, "/orders/#{o["id"]}"), 404))
      unknown = strip(ok!(mnt(ctx.tok_b, :get, "/orders/#{Ecto.UUID.generate()}"), 404))
      assert other == unknown

      assert strip(
               ok!(
                 mnt(ctx.tok_b, :post, "/orders/#{o["id"]}/assign", %{"user_id" => ctx.u1}),
                 404
               )
             ) ==
               other

      assert ok!(mnt(ctx.tok_b, :get, "/orders"), 200)["rows"] == []

      for role <- ["PROCESS_OPERATOR", "TENANT_AUDITOR"] do
        tok = S.token(ctx, :a, [role], sub: "mnt-o-#{role}")
        assert ok!(mnt(tok, :post, "/orders", direct(card)), 403)["title"] == "Forbidden"
        assert ok!(mnt(tok, :get, "/orders", nil), 403)["title"] == "Forbidden"
      end

      old = Application.get_env(:letflow, :maintenance_enabled)
      Application.put_env(:letflow, :maintenance_enabled, false)
      on_exit(fn -> Application.put_env(:letflow, :maintenance_enabled, old) end)
      before = counts(ctx.a.schema_name)

      bodies =
        for {m, p, b} <- [
              {:post, "/orders", direct(card)},
              {:get, "/orders", nil},
              {:get, "/orders/#{o["id"]}", nil},
              {:post, "/orders/#{o["id"]}/assign", %{"user_id" => ctx.u1}}
            ] do
          strip(ok!(mnt(ctx.tok_a, m, p, b), 404))
        end

      assert bodies |> Enum.uniq() |> length() == 1
      assert counts(ctx.a.schema_name) == before
      refute Maintenance.enabled?()
    end
  end

  defp strip(body), do: M.strip(body)
end
