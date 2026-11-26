Code.require_file("../stock/stock_fixture.exs", __DIR__)
Code.require_file("../assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.Maintenance.OrderLifeTest do
  @moduledoc """
  REQ-897 / GH #4803 criteria 1 to 5 (CMMS slice 1 part 5): the work order keeps what was done.

  Through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants: D-01 the done
  record, D-02 the close record, D-03 all or nothing when the handler refuses, D-04 a closed order
  is not changed (and the router has no route that changes one), D-05 the manifest, the pack and
  the permission matrix. `async: false`, Sandbox `:auto`; the flag is on in `config/test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.PermissionMatrix
  alias Letflow.AssetsFixture, as: A
  alias Letflow.Engine.Task
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.Identity.User
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Maintenance
  alias Letflow.StockFixture, as: S

  @base "/api/v1/modules/maintenance"
  @modules ["org", "catalog_items", "locations", "codes", "stock", "assets", "maintenance"]

  setup do
    ctx = S.setup_oidc!([:a])
    a = tenant!("mnt-life-a", ctx.names.a)

    ctx =
      Map.merge(ctx, %{
        a: a,
        tok_a: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "mnt-life-admin"),
        w1: S.token(ctx, :a, ["TASK_WORKER"], sub: "mnt-life-w1")
      })

    ctx = Map.merge(ctx, %{unit_a: unit!(ctx.tok_a)})

    {:ok,
     Map.merge(ctx, %{
       u1: user_id!(ctx, ctx.w1, "mnt-life-w1"),
       admin_id: user_id!(ctx, ctx.tok_a, "mnt-life-admin")
     })}
  end

  defp tenant!(prefix, realm) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- @modules do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-897"
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

  defp card!(schema, unit) do
    n = "M-#{System.unique_integer([:positive])}"

    A.card!(
      schema,
      n,
      %{
        "org_unit_id" => unit,
        "acquisition_cost" => "987654321.000000000",
        "name" => "Pump #{n}"
      }
    ).record_id
  end

  defp direct(card, extra) do
    Map.merge(
      %{
        "asset_card_id" => card,
        "description" => "Replace the seal",
        "urgency" => "normal",
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

  # The stored values of the order record, as the platform holds them.
  defp stored_values(schema, order_id) do
    Repo.one!(
      from(l in Latest, where: l.record_id == ^order_id, select: l.field_values),
      prefix: schema
    )
  end

  # The record events of the order (its creation and every later write of it).
  defp order_events(schema, order_id) do
    Repo.all(
      from(e in Event,
        where:
          e.event_type in ["ENTITY_RECORD_CREATED", "ENTITY_RECORD_UPDATED"] and
            fragment("?->>'entity_type' = ?", e.payload, "maintenance_work_order") and
            fragment("?->>'record_id' = ?", e.payload, ^order_id),
        order_by: [asc: e.global_seq]
      ),
      prefix: schema
    )
  end

  # The refusal the platform audited for one task (the handler's own refusal, named in the
  # entry's detail; the body of the answer carries no detail).
  defp refusals(schema, task_id) do
    Repo.all(
      from(a in Letflow.Audit.Entry,
        where: a.action == "entity_write.refused" and a.resource_id == ^task_id,
        select: a.after_state
      ),
      prefix: schema
    )
  end

  test "D-01: the technician's completion stores the work text, who and when", ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))

    before = ok!(get_order(ctx, o["id"]), 200)
    assert before["work_done"] == nil and before["done_by"] == nil
    assert before["done_at"] == nil and before["closed_by"] == nil
    assert before["closed_at"] == nil

    work = task!(ctx, o["id"], "maintenance_work")
    assert complete(ctx.w1, work.id, %{"work_done" => "Seal replaced"}).status == 200

    done = ok!(get_order(ctx, o["id"]), 200)
    assert done["work_done"] == "Seal replaced"
    assert done["done_by"] == ctx.u1
    assert is_binary(done["done_at"])
    assert {:ok, _, 0} = DateTime.from_iso8601(done["done_at"])
    assert done["closed_by"] == nil and done["closed_at"] == nil
    assert done["status"] == "done"
    assert done["number"] == before["number"]
  end

  test "D-02: the close task stores who closed the order and when; the rest is unchanged", ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))

    work = task!(ctx, o["id"], "maintenance_work")
    assert complete(ctx.w1, work.id, %{"work_done" => "Seal replaced"}).status == 200
    after_work = ok!(get_order(ctx, o["id"]), 200)

    close = task!(ctx, o["id"], "maintenance_close")
    assert complete(ctx.tok_a, close.id, %{}).status == 200

    closed = ok!(get_order(ctx, o["id"]), 200)
    assert closed["closed_by"] == ctx.admin_id
    assert is_binary(closed["closed_at"])
    assert {:ok, _, 0} = DateTime.from_iso8601(closed["closed_at"])
    assert closed["status"] == "closed"

    # the done record and the number are unchanged by the close
    assert closed["work_done"] == after_work["work_done"]
    assert closed["done_by"] == after_work["done_by"]
    assert closed["done_at"] == after_work["done_at"]
    assert closed["number"] == after_work["number"]
    assert closed["id"] == after_work["id"]
  end

  test "D-03: all or nothing: a refused handler leaves the task pending and the order clean",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))
    work = task!(ctx, o["id"], "maintenance_work")

    before_values = stored_values(ctx.a.schema_name, o["id"])
    before_events = order_events(ctx.a.schema_name, o["id"])

    # the handler refuses an empty work text: the completion answers an error, not a crash
    refused = complete(ctx.w1, work.id, %{"work_done" => ""})
    assert refused.status == 422, refused.resp_body
    assert Jason.decode!(refused.resp_body)["error"] == "validation_failed"

    # the refusal is the HANDLER's own, not the form's: the audit entry names it
    assert [%{"code" => "validation_failed", "detail" => "handler_invalid_arguments"}] =
             refusals(ctx.a.schema_name, work.id)

    # the task is still pending and nothing was written
    assert Repo.get(Task, work.id, prefix: ctx.a.schema_name).status == :pending
    assert stored_values(ctx.a.schema_name, o["id"]) == before_values
    assert order_events(ctx.a.schema_name, o["id"]) == before_events

    view = ok!(get_order(ctx, o["id"]), 200)
    assert view["work_done"] == nil and view["done_by"] == nil and view["done_at"] == nil
    assert view["status"] == "in_work"

    # the same task completes with a real text
    assert complete(ctx.w1, work.id, %{"work_done" => "Seal replaced"}).status == 200
    assert ok!(get_order(ctx, o["id"]), 200)["work_done"] == "Seal replaced"
  end

  test "D-04: a closed order is not changed: assign is 409, the values and the events stand",
       ctx do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))

    work = task!(ctx, o["id"], "maintenance_work")
    assert complete(ctx.w1, work.id, %{"work_done" => "Seal replaced"}).status == 200
    close = task!(ctx, o["id"], "maintenance_close")
    assert complete(ctx.tok_a, close.id, %{}).status == 200

    closed = ok!(get_order(ctx, o["id"]), 200)
    assert closed["status"] == "closed"
    values = stored_values(ctx.a.schema_name, o["id"])
    events = order_events(ctx.a.schema_name, o["id"])

    # the order was written four times: its creation, the update that names its document and
    # its instance, the done record and the close record
    assert length(events) == 4

    assert Enum.map(events, & &1.event_type) == [
             "ENTITY_RECORD_CREATED",
             "ENTITY_RECORD_UPDATED",
             "ENTITY_RECORD_UPDATED",
             "ENTITY_RECORD_UPDATED"
           ]

    # the last two writes are the module's own handlers
    assert Enum.map(Enum.slice(events, -2, 2), & &1.metadata["source.handler_name"]) == [
             "record_done",
             "record_closed"
           ]

    done_values =
      events |> Enum.slice(-2, 2) |> hd() |> Map.fetch!(:payload) |> Map.fetch!("field_values")

    closed_values =
      events |> Enum.slice(-1, 1) |> hd() |> Map.fetch!(:payload) |> Map.fetch!("field_values")

    assert done_values["work_done"] == "Seal replaced"
    assert done_values["done_by"] == ctx.u1
    assert done_values["closed_by"] == nil
    assert closed_values["closed_by"] == ctx.admin_id
    assert closed_values["work_done"] == "Seal replaced"

    refused = ok!(mnt(ctx.tok_a, :post, "/orders/#{o["id"]}/assign", %{"user_id" => ctx.u1}), 409)
    assert refused["reason"] == "order_not_assignable"

    assert stored_values(ctx.a.schema_name, o["id"]) == values
    assert order_events(ctx.a.schema_name, o["id"]) == events
    assert ok!(get_order(ctx, o["id"]), 200) == closed
  end

  # The completer's output variables are merged over the instance variables, so a forged
  # `maintenance_order_id` in the completion body must never redirect a handler write (T-2430: the
  # engine refuses that key with 422 output_refused).
  defp two_orders!(ctx) do
    card = card!(ctx.a.schema_name, ctx.unit_a)
    o1 = order!(ctx, direct(card, %{"assignee_user_id" => ctx.u1}))
    o2 = order!(ctx, direct(card, %{}))
    {o1, o2}
  end

  defp assert_refused_and_untouched(ctx, task, victim_id, body) do
    victim_values = stored_values(ctx.a.schema_name, victim_id)
    victim_events = order_events(ctx.a.schema_name, victim_id)

    answer = complete(body.tok, task.id, body.params)
    assert answer.status == 422, answer.resp_body

    # T-2430: the engine refuses the write target key before any handler runs (the handler
    # check `handler_invalid_arguments` stays as the second line, but is no longer reached)
    body = Jason.decode!(answer.resp_body)
    assert body["code"] == "output_refused"
    assert body["rejected_keys"] == ["maintenance_order_id"]
    assert refusals(ctx.a.schema_name, task.id) == []
    assert Repo.get(Task, task.id, prefix: ctx.a.schema_name).status == :pending
    assert stored_values(ctx.a.schema_name, victim_id) == victim_values
    assert order_events(ctx.a.schema_name, victim_id) == victim_events
  end

  test "D-06: a forged order id in the work completion cannot write another open order", ctx do
    {o1, o2} = two_orders!(ctx)
    work = task!(ctx, o1["id"], "maintenance_work")

    assert_refused_and_untouched(ctx, work, o2["id"], %{
      tok: ctx.w1,
      params: %{"work_done" => "HACK", "maintenance_order_id" => o2["id"]}
    })

    # nothing was written to the order of the task either, and the honest completion still works
    assert ok!(get_order(ctx, o1["id"]), 200)["work_done"] == nil
    assert complete(ctx.w1, work.id, %{"work_done" => "Seal replaced"}).status == 200
    assert ok!(get_order(ctx, o1["id"]), 200)["work_done"] == "Seal replaced"
    assert ok!(get_order(ctx, o2["id"]), 200)["work_done"] == nil
  end

  test "D-07: a forged order id in the close completion cannot write another order", ctx do
    {o1, o2} = two_orders!(ctx)
    work = task!(ctx, o1["id"], "maintenance_work")
    assert complete(ctx.w1, work.id, %{"work_done" => "Seal replaced"}).status == 200
    close = task!(ctx, o1["id"], "maintenance_close")

    assert_refused_and_untouched(ctx, close, o2["id"], %{
      tok: ctx.tok_a,
      params: %{"maintenance_order_id" => o2["id"]}
    })

    assert ok!(get_order(ctx, o1["id"]), 200)["closed_by"] == nil
    assert complete(ctx.tok_a, close.id, %{}).status == 200
    assert ok!(get_order(ctx, o1["id"]), 200)["closed_by"] == ctx.admin_id
    assert ok!(get_order(ctx, o2["id"]), 200)["closed_by"] == nil
  end

  test "D-08: a forged order id cannot reach a closed order or an unknown one", ctx do
    {o1, o2} = two_orders!(ctx)

    # o2 is taken through its whole life, so it is closed
    w2 = task!(ctx, o2["id"], "maintenance_work")
    assert complete(ctx.tok_a, w2.id, %{"work_done" => "Done by admin"}).status == 200
    c2 = task!(ctx, o2["id"], "maintenance_close")
    assert complete(ctx.tok_a, c2.id, %{}).status == 200
    assert ok!(get_order(ctx, o2["id"]), 200)["status"] == "closed"

    work = task!(ctx, o1["id"], "maintenance_work")

    assert_refused_and_untouched(ctx, work, o2["id"], %{
      tok: ctx.w1,
      params: %{"work_done" => "HACK", "maintenance_order_id" => o2["id"]}
    })

    # an id of no order, and an id that is no UUID: the same refusal, nothing written
    for forged <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert_refused_and_untouched(ctx, work, o1["id"], %{
        tok: ctx.w1,
        params: %{"work_done" => "HACK", "maintenance_order_id" => forged}
      })
    end
  end

  test "D-04: the router has no route that changes or deletes an order" do
    order_routes =
      for {method, path, _key} <- Maintenance.Router.__authz_routes__(),
          String.starts_with?(path, "/orders"),
          do: {method, path}

    assert Enum.sort(order_routes) == [
             {"GET", "/orders"},
             {"GET", "/orders/:id"},
             {"POST", "/orders"},
             {"POST", "/orders/:id/assign"}
           ]

    refute Enum.any?(order_routes, fn {method, _path} ->
             method in ["PATCH", "PUT", "DELETE"]
           end)
  end

  test "D-05: the manifest declares the two handlers and the pack calls them" do
    m = Maintenance.manifest()
    assert Catalog.validate(m) == :ok

    assert [done, closed] = m.write_handlers

    assert done.name == "record_done"
    assert done.function == {Letflow.Modules.Maintenance.Handlers, :record_done}
    assert done.targets == ["maintenance_work_order"]
    assert done.updates == %{"maintenance_work_order" => ["work_done", "done_by", "done_at"]}
    assert done.posts_ledger == nil

    assert done.args == %{
             "order_id" => %{required: true},
             "work_done" => %{required: true}
           }

    assert closed.name == "record_closed"
    assert closed.function == {Letflow.Modules.Maintenance.Handlers, :record_closed}
    assert closed.targets == ["maintenance_work_order"]
    assert closed.updates == %{"maintenance_work_order" => ["closed_by", "closed_at"]}
    assert closed.posts_ledger == nil

    pack = "priv/modules/maintenance/pack.json" |> File.read!() |> Jason.decode!()
    assert pack["version"] == Maintenance.manifest().version

    assert [%{"process_key" => "maintenance_work_order", "version" => "1.1.0", "graph" => graph}] =
             pack["definitions"]

    lines =
      for node <- graph["nodes"],
          node["node_type"] == "HUMAN_TASK",
          do: {node["id"], node["attributes"]["module_writes"]}

    assert [{"maintenance_work", work_writes}, {"maintenance_close", close_writes}] = lines

    assert [%{"module" => "maintenance", "handler" => "record_done", "args" => work_args}] =
             work_writes

    assert work_args == %{
             "order_id" => %{"var" => "maintenance_order_id"},
             "work_done" => %{"var" => "work_done"}
           }

    assert [%{"module" => "maintenance", "handler" => "record_closed", "args" => close_args}] =
             close_writes

    assert close_args == %{"order_id" => %{"var" => "maintenance_order_id"}}
  end

  test "D-05: the permission matrix gained no row: the three atoms, the two catch-alls only" do
    {:ok, golden} = PermissionMatrix.parse(File.read!("priv/permission_matrix/effective.golden"))

    assert golden.modules["maintenance"] == Maintenance.manifest().version

    atoms = Enum.map(Maintenance.manifest().permissions, &Atom.to_string/1)

    assert Enum.sort(atoms) == [
             "MaintenanceOrderManage",
             "MaintenanceRead",
             "MaintenanceRequestCreate"
           ]

    holders =
      for {{role, atom}, row} <- golden.rows,
          atom in atoms,
          row.allowed,
          do: {role, atom}

    assert Enum.sort(holders) == [
             {"PLATFORM_ADMIN", "MaintenanceOrderManage"},
             {"PLATFORM_ADMIN", "MaintenanceRead"},
             {"PLATFORM_ADMIN", "MaintenanceRequestCreate"},
             {"TENANT_ADMIN", "MaintenanceOrderManage"},
             {"TENANT_ADMIN", "MaintenanceRead"},
             {"TENANT_ADMIN", "MaintenanceRequestCreate"}
           ]
  end
end
