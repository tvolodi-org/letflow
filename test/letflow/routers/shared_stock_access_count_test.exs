Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Routers.SharedStockAccessCountTest do
  @moduledoc """
  REQ-912 / GH #4908 (K6a of docs/status/qoimeks-old-client-compat.md section 5.3; decision 0091): the
  count of the old Qoimeks app (`POST /qoimeks/:slug/api/movements`, kind `adjustment`) with the
  tenant's four-eyes switch for counts OFF, through the full `Letflow.Router` over a committed tenant
  with real ledger postings. IDs follow the acceptance criteria: K6a-1 posts at once, K6a-2 zero and
  negative, K6a-3 the audit, K6a-5 the switch ON keeps `invalid kind`, K6a-6 a count equal to the
  book, K6a-7 a negative book, K6a-8 the refusal texts, K6a-9 the client id, K6a-10 the history rows.
  Criterion 4 (the narrow widening) is in `test/letflow/engine/separation_of_duties_test.exs`.
  `async: false`: committed tenants, VM-global config.
  """

  # impl_order: REQ-912
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Plugs.AuthAttemptLimit
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.Repo
  alias Letflow.SharedStockAccess
  alias Letflow.SharedStockAccess.IntIds
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @stale "Остаток изменился, пока подсчёт ждал подтверждения. Посчитайте ещё раз"
  @frozen "Место заморожено пересчётом. Подсчёт не принят"
  @in_progress "На этом месте идёт пересчёт по приказу. Подсчёт не принят"
  @other_rows "Этот товар на этом месте числится за другим ответственным или в другой партии. " <>
                "Попросите администратора провести пересчёт по ведомости"

  setup do
    ctx = P.setup!([:a])
    a = ctx.a

    originals = %{
      tenants: Application.fetch_env(:letflow, :shared_stock_access_tenants),
      limits: Application.fetch_env(:letflow, AuthAttemptLimit)
    }

    on_exit(fn ->
      restore(:shared_stock_access_tenants, originals.tenants)
      restore(AuthAttemptLimit, originals.limits)
      Application.delete_env(:letflow, :old_app_count_between)
      Bucket.reset()
    end)

    Application.put_env(:letflow, :shared_stock_access_tenants, [a.tenant.slug])

    Application.put_env(:letflow, AuthAttemptLimit,
      failure_capacity: 1000,
      request_capacity: 1000
    )

    Bucket.reset()

    m = ctx.ma
    [sku] = Map.values(IntIds.assign(ctx.schema, :sku, [m.item]))
    [loc] = Map.values(IntIds.assign(ctx.schema, :location, [m.location]))

    {:ok, ctx: ctx, a: a, m: m, sku: sku, loc: loc, value: access!(a)}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:letflow, key, value)
  defp restore(key, :error), do: Application.delete_env(:letflow, key)

  defp access!(fx) do
    {:ok, _kind, value} =
      SharedStockAccess.put(fx.schema_name, fx.tenant.slug, %{}, %{
        user_id: Ecto.UUID.generate(),
        trace_id: nil
      })

    value
  end

  defp call(method, slug, path, value, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, "/qoimeks/#{slug}#{path}")
        body -> Plug.Test.conn(method, "/qoimeks/#{slug}#{path}", Jason.encode!(body))
      end

    conn = if value, do: put_req_header(conn, "authorization", "Bearer " <> value), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp post_movement(t, body), do: call(:post, t.a.tenant.slug, "/api/movements", t.value, body)
  defp history(t), do: call(:get, t.a.tenant.slug, "/api/movements", t.value) |> status!(200)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp movement(t, kind, qty, extra \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "kind" => kind,
        "sku_id" => t.sku,
        "location_id" => t.loc,
        "qty" => qty,
        "operator" => "Айгуль"
      },
      extra
    )
  end

  defp receive!(t, qty), do: post_movement(t, movement(t, "receipt", qty)) |> status!(201)

  defp balance(t) do
    rows = call(:get, t.a.tenant.slug, "/api/balances", t.value) |> status!(200)

    case Enum.filter(rows, &(&1["location_id"] == t.loc and &1["sku_id"] == t.sku)) do
      [row] -> row["qty"]
      [] -> 0
    end
  end

  defp switch!(t, four_eyes) do
    Repo.insert!(
      %ApprovalRuleSetting{
        definition_name: "stock_quick_count",
        node_id: "approve",
        four_eyes: four_eyes,
        changed_by: Ecto.UUID.generate(),
        changed_at: DateTime.utc_now(),
        reason: "REQ-912 fixture"
      },
      prefix: t.ctx.schema
    )
  end

  defp written(schema) do
    %{rows: [[entries]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".ledger_entry|)
    {entries, D.counts(schema), pending_tasks(schema)}
  end

  defp pending_tasks(schema),
    do: Repo.aggregate(from(k in EngineTask, where: k.status == :pending), :count, prefix: schema)

  defp audit(schema, action),
    do: Entry |> Ecto.Query.where([a], a.action == ^action) |> Repo.all(prefix: schema)

  defp count_documents(schema) do
    Repo.all(
      from(d in Letflow.Documents.Document,
        where: d.type_key == "stock_quick_count",
        order_by: [asc: d.inserted_at],
        select: d.id
      ),
      prefix: schema
    )
  end

  # -- K6a-1 ----------------------------------------------------------------------------------------

  describe "switch OFF: the count posts at once" do
    test "K6a-1 and K6a-3 a count of 7 against a book of 5: 201, balance 7, one count document, audit",
         t do
      switch!(t, false)
      receive!(t, 5)
      before = written(t.ctx.schema)
      id = Ecto.UUID.generate()

      row = post_movement(t, movement(t, "adjustment", 7, %{"id" => id})) |> status!(201)

      assert %{"kind" => "adjustment", "qty" => 7, "operator" => "Айгуль"} = row
      assert row["sku_id"] == t.sku and row["location_id"] == t.loc
      assert [%{"qty" => 7, "sku_id" => sku, "location_id" => loc}] = row["balances"]
      assert {sku, loc} == {t.sku, t.loc}
      assert balance(t) == 7

      assert [doc_id] = count_documents(t.ctx.schema)
      assert P.get!(t.ctx, doc_id)["state"] == "posted"
      {entries, {_records, documents}, pending} = written(t.ctx.schema)
      {before_entries, {_r, before_documents}, before_pending} = before
      assert {entries, documents, pending} == {before_entries + 1, before_documents + 1, 0}
      assert before_pending == 0

      # K6a-3 the audit: one self-approval of the count's approve task by the shared access actor
      actor =
        Repo.one!(from(c in SharedStockAccess.Credential, select: c.actor_id),
          prefix: t.ctx.schema
        )

      assert [entry] = audit(t.ctx.schema, "task.self_approved")
      assert entry.actor_id == actor

      assert %{
               "note" => "self-approved, four-eyes off",
               "definition_name" => "stock_quick_count",
               "node_id" => "approve"
             } = entry.after_state

      submit =
        Repo.one!(
          from(k in EngineTask, where: k.node_id == "submit" and k.status == :completed),
          prefix: t.ctx.schema
        )

      assert submit.output_variables == %{"operator" => "Айгуль"}
      assert submit.completed_by == actor
      assert entry.resource_id != submit.id
    end

    test "K6a-2 a count of 0 posts and zeroes the book; negative is 400; a receipt of 0 stays 400",
         t do
      switch!(t, false)
      receive!(t, 4)

      row = post_movement(t, movement(t, "adjustment", 0)) |> status!(201)
      assert %{"kind" => "adjustment", "qty" => 0, "balances" => [%{"qty" => 0}]} = row
      assert balance(t) == 0

      before = written(t.ctx.schema)

      assert %{"error" => "quantity must be positive"} ==
               post_movement(t, movement(t, "adjustment", -1)) |> status!(400)

      assert %{"error" => "quantity must be positive"} ==
               post_movement(t, movement(t, "receipt", 0)) |> status!(400)

      assert written(t.ctx.schema) == before
    end

    test "K6a-2b a zero count with no balance row is a stored movement and can be reversed", t do
      switch!(t, false)

      body = movement(t, "adjustment", 0)
      row = post_movement(t, body) |> status!(201)

      assert %{"kind" => "adjustment", "qty" => 0, "operator" => "Айгуль"} = row
      assert [%{"qty" => 0, "sku_id" => sku, "location_id" => loc}] = row["balances"]
      assert {sku, loc} == {t.sku, t.loc}
      assert Enum.any?(history(t), &(&1["id"] == row["id"]))
      assert post_movement(t, body) |> status!(200) == row

      assert [doc_id] = count_documents(t.ctx.schema)
      assert %{"state" => "posted", "posting_check" => "ok"} = P.get!(t.ctx, doc_id)

      reversal =
        call(:post, t.a.tenant.slug, "/api/movements/#{row["id"]}/reverse", t.value, %{
          "id" => Ecto.UUID.generate(),
          "operator" => "Ерлан"
        })
        |> status!(201)

      assert %{"kind" => "adjustment", "qty" => 0, "reverses" => reverses} = reversal
      assert reverses == row["id"]
      assert [%{"qty" => 0}] = reversal["balances"]
      assert balance(t) == 0
      assert %{"state" => "reversed", "posting_check" => "ok"} = P.get!(t.ctx, doc_id)
    end

    test "K6a-2c a zero count with stock is a stored movement and reversing restores the stock",
         t do
      switch!(t, false)
      receive!(t, 4)

      row = post_movement(t, movement(t, "adjustment", 0)) |> status!(201)
      assert Enum.any?(history(t), &(&1["id"] == row["id"]))
      assert balance(t) == 0

      reversal =
        call(:post, t.a.tenant.slug, "/api/movements/#{row["id"]}/reverse", t.value, %{
          "id" => Ecto.UUID.generate(),
          "operator" => "Ерлан"
        })
        |> status!(201)

      assert %{"kind" => "adjustment", "qty" => 4, "reverses" => reverses} = reversal
      assert reverses == row["id"]
      assert [%{"qty" => 4}] = reversal["balances"]
      assert balance(t) == 4
    end

    test "K6a-6 a count equal to the book answers at once and writes no entry, audit or history row",
         t do
      switch!(t, false)
      receive!(t, 5)
      before = written(t.ctx.schema)
      id = Ecto.UUID.generate()

      row = post_movement(t, movement(t, "adjustment", 5, %{"id" => id})) |> status!(201)

      # no process starts for it, so the typed name is stored nowhere: "" in the answer and its replay
      assert %{"kind" => "adjustment", "qty" => 5, "operator" => ""} = row
      assert row["id"] =~ ~r/\A[0-9]+\z/
      assert [%{"qty" => 5, "location_id" => loc}] = row["balances"]
      assert loc == t.loc
      assert balance(t) == 5

      {entries, _documents, pending} = written(t.ctx.schema)
      {before_entries, _before_documents, _before_pending} = before
      assert entries == before_entries and pending == 0
      assert audit(t.ctx.schema, "task.self_approved") == []
      refute Enum.any?(history(t), &(&1["id"] == row["id"]))

      assert post_movement(t, movement(t, "adjustment", 5, %{"id" => id})) |> status!(200) == row
    end

    test "K6a-7 a negative book of -2 counted 3 posts +5 and the key reads 3", t do
      switch!(t, false)
      Letflow.LedgerFixture.set_negative_balance!(t.ctx.schema, "stock", true)
      post_movement(t, movement(t, "issue", 2)) |> status!(201)
      assert balance(t) == -2

      row = post_movement(t, movement(t, "adjustment", 3)) |> status!(201)
      assert [%{"qty" => 3}] = row["balances"]
      assert row["qty"] == 3
      assert balance(t) == 3

      %{rows: [[quantity]]} =
        Repo.query!(
          ~s|SELECT l.quantity FROM "#{t.ctx.schema}".ledger_leg l JOIN "#{t.ctx.schema}".ledger_entry e ON e.id = l.entry_id WHERE e.cause = 'count_set'|
        )

      assert Decimal.eq?(quantity, 5)
    end
  end

  # -- K6a-5 ----------------------------------------------------------------------------------------

  describe "switch ON" do
    test "K6a-5 no row: a count is still 400 invalid kind and writes nothing", t do
      receive!(t, 5)
      before = written(t.ctx.schema)

      assert %{"error" => "invalid kind"} ==
               post_movement(t, movement(t, "adjustment", 7)) |> status!(400)

      assert written(t.ctx.schema) == before
      assert balance(t) == 5
    end

    test "K6a-5b a row four_eyes true is ON too", t do
      switch!(t, true)
      receive!(t, 5)
      before = written(t.ctx.schema)

      assert %{"error" => "invalid kind"} ==
               post_movement(t, movement(t, "adjustment", 7)) |> status!(400)

      assert written(t.ctx.schema) == before
    end
  end

  # -- K6a-8 ----------------------------------------------------------------------------------------

  describe "refusal texts (400, never 409 or 422)" do
    defp count_order!(ctx, m, status) do
      owner = ManagedTypes.owner_for!(Letflow.Modules.Stock)

      base = %{
        "org_unit_id" => m.unit,
        "status" => status,
        "kind" => "full",
        "planned_start" => DateTime.to_iso8601(DateTime.utc_now()),
        "planned_end" => DateTime.to_iso8601(DateTime.utc_now()),
        "chair_employee_id" => m.employee,
        "number" => "CO-T-#{System.unique_integer([:positive])}"
      }

      # scope-all: test fixture writing a count order header directly (own tenant schema)
      {:ok, %{record: order}} =
        Records.create_record(
          %{
            entity_type: "count_order",
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate(),
            field_values: base
          },
          ctx.schema,
          owner
        )

      # scope-all: test fixture
      {:ok, _} =
        Records.create_record(
          %{
            entity_type: "count_order_scope",
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate(),
            field_values: %{
              "count_order_id" => order.record_id,
              "location_id" => m.location,
              "org_unit_id" => m.unit
            }
          },
          ctx.schema,
          owner
        )

      :ok
    end

    test "K6a-8a a count inside an opened count order is refused at the call", t do
      switch!(t, false)
      receive!(t, 5)
      count_order!(t.ctx, t.m, "counting")
      before = written(t.ctx.schema)

      assert %{"error" => @in_progress} ==
               post_movement(t, movement(t, "adjustment", 7)) |> status!(400)

      assert written(t.ctx.schema) == before
      assert balance(t) == 5
    end

    test "K6a-8b stock under another responsible is refused balance_in_other_rows", t do
      switch!(t, false)
      # a second employee posts a receipt of the same item at the same place
      other =
        Letflow.OrgFixture.create!(
          t.ctx.schema,
          "org_employee",
          Letflow.OrgFixture.values("org_employee", "E2-#{System.unique_integer([:positive])}", %{
            "org_unit_id" => t.m.unit
          })
        )

      # the stock is held by the one of the two employees the old address does NOT pick
      first = Letflow.Modules.Org.first_active_employee_id(t.ctx.schema)
      holder = Enum.find([t.m.employee, other.record_id], &(&1 != first))

      S.post!(t.ctx.schema, "receipt", %{
        lines: [
          S.line(
            t.m.item,
            "3",
            %{to: S.side(t.m.unit, t.m.location, %{responsible: holder})},
            %{unit: t.m.uom}
          )
        ]
      })

      before = written(t.ctx.schema)

      assert %{"error" => @other_rows} ==
               post_movement(t, movement(t, "adjustment", 7)) |> status!(400)

      assert written(t.ctx.schema) == before
    end

    test "K6a-8c a count order that opens between the issue and the approval: location_frozen",
         t do
      switch!(t, false)
      receive!(t, 5)

      Application.put_env(:letflow, :old_app_count_between, fn _prefix ->
        count_order!(t.ctx, t.m, "counting")
      end)

      assert %{"error" => @frozen} ==
               post_movement(t, movement(t, "adjustment", 7)) |> status!(400)

      assert balance(t) == 5
      assert [doc_id] = count_documents(t.ctx.schema)
      assert P.get!(t.ctx, doc_id)["state"] == "cancelled"
      assert pending_tasks(t.ctx.schema) == 0
      assert audit(t.ctx.schema, "task.self_approved") == []
    end

    test "K6a-8d a key that moves between the issue and the approval: quick_count_stale", t do
      switch!(t, false)
      receive!(t, 5)

      Application.put_env(:letflow, :old_app_count_between, fn _prefix ->
        Application.delete_env(:letflow, :old_app_count_between)
        receive!(t, 1)
      end)

      id = Ecto.UUID.generate()

      assert %{"error" => @stale} ==
               post_movement(t, movement(t, "adjustment", 7, %{"id" => id})) |> status!(400)

      assert balance(t) == 6
      assert [doc_id] = count_documents(t.ctx.schema)
      assert P.get!(t.ctx, doc_id)["state"] == "cancelled"
      assert pending_tasks(t.ctx.schema) == 0

      # a refusal binds no client id: the same id counts again and posts
      row = post_movement(t, movement(t, "adjustment", 7, %{"id" => id})) |> status!(201)
      assert [%{"qty" => 7}] = row["balances"]
      assert balance(t) == 7
    end

    test "K6a-8e any other refusal of the approval is the cancel text, 400", t do
      switch!(t, false)
      receive!(t, 5)

      # the switch turned ON between the issue and the approval: the approval is refused
      Application.put_env(:letflow, :old_app_count_between, fn prefix ->
        Repo.update_all(ApprovalRuleSetting, [set: [four_eyes: true]], prefix: prefix)
      end)

      assert %{"error" => "Подсчёт отменён. Посчитайте ещё раз"} ==
               post_movement(t, movement(t, "adjustment", 7)) |> status!(400)

      assert balance(t) == 5
      assert pending_tasks(t.ctx.schema) == 0
      assert audit(t.ctx.schema, "task.self_approved") == []
    end
  end

  # -- K6a-9 ----------------------------------------------------------------------------------------

  describe "the client id" do
    test "K6a-9 a repeat answers 200 with the first body; other data is 409; no id is 400", t do
      switch!(t, false)
      receive!(t, 5)
      id = Ecto.UUID.generate()
      body = movement(t, "adjustment", 7, %{"id" => id})
      first = post_movement(t, body) |> status!(201)

      # a receipt of 1 in between does not change the stored answer
      receive!(t, 1)
      assert balance(t) == 8
      assert post_movement(t, body) |> status!(200) == first
      assert hd(first["balances"])["qty"] == 7

      before = written(t.ctx.schema)

      assert %{"error" => "this operation was already posted with different data"} ==
               post_movement(t, Map.put(body, "qty", 8)) |> status!(409)

      assert written(t.ctx.schema) == before

      assert %{"error" => "id is required"} ==
               post_movement(t, Map.delete(body, "id")) |> status!(400)
    end
  end

  # -- K6a-10 ---------------------------------------------------------------------------------------

  describe "history rows of counts" do
    test "K6a-10a the old-address count shows qty = the counted quantity and the typed operator",
         t do
      switch!(t, false)
      receive!(t, 5)
      post_movement(t, movement(t, "adjustment", 7)) |> status!(201)

      assert [adj, %{"kind" => "receipt"}] = history(t)
      assert %{"kind" => "adjustment", "qty" => 7, "operator" => "Айгуль"} = adj
    end

    test "K6a-10b a count of a personal account shows qty = counted and an empty operator", t do
      m = t.m

      doc =
        P.issue!(
          t.ctx,
          D.body(m, nil, %{
            "lines" => [
              %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "7"}
            ]
          })
        )

      P.post_and_complete!(t.ctx, doc["id"])

      body = %{
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "responsible_id" => m.employee,
        "catalog_item_id" => m.item,
        "catalog_uom_id" => m.uom,
        "counted_quantity" => "2",
        "reason_code" => "recount"
      }

      count = D.request(:post, "/quick-counts", t.ctx.tok_a, body) |> P.status!(201)
      approver = S.token(t.ctx, :a, ["TENANT_ADMIN"], sub: "second-admin")
      task = P.pending_task(t.ctx, count["id"], "approve") || flunk("no pending approve")

      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(%{}))
      |> put_req_header("authorization", "Bearer " <> approver)
      |> put_req_header("content-type", "application/json")
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
      |> P.status!(200)

      assert [adj, _receipt] = history(t)
      assert %{"kind" => "adjustment", "qty" => 2, "operator" => ""} = adj
    end

    test "K6a-10c reversing the count takes back the difference: qty 2, balance 5", t do
      switch!(t, false)
      receive!(t, 5)
      count = post_movement(t, movement(t, "adjustment", 7)) |> status!(201)

      rev =
        call(:post, t.a.tenant.slug, "/api/movements/#{count["id"]}/reverse", t.value, %{
          "id" => Ecto.UUID.generate(),
          "operator" => "Ерлан"
        })
        |> status!(201)

      assert %{"kind" => "adjustment", "reverses" => reverses, "qty" => 2} = rev
      assert reverses == count["id"]
      assert [%{"qty" => 5}] = rev["balances"]
      assert balance(t) == 5
    end
  end
end
