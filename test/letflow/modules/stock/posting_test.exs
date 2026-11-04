Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.PostingTest do
  @moduledoc """
  REQ-713 / GH #3748 criteria 2, 3, 4, 5 and 6: lazy activation, the posting of an issued receipt
  from its human task, the read states, the retry route, the idempotency rule and the binding check.
  Committed tenant, Sandbox `:auto`, `async: false`; requests through the full `Letflow.Router`.
  Tests: B-ACT-1..3, B-POST-1..5, B-ST-1, B-RT-1..5, B-ID-1..4, B-CHK-1..3.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.TokenMintFixture

  setup do
    P.setup!()
  end

  defp instances(ctx, id) do
    Repo.aggregate(
      from(p in Letflow.EventStore.InstanceProjection,
        where: fragment("?->>'document_id' = ?", p.variables, ^id)
      ),
      :count,
      prefix: ctx.schema
    )
  end

  defp definition(ctx, name) do
    Repo.one!(from(d in ProcessDefinition, where: d.name == ^name), prefix: ctx.schema)
  end

  defp reason(conn, status), do: conn |> P.status!(status) |> Map.fetch!("reason")

  describe "lazy activation" do
    test "B-ACT-1 the first issue activates stock_receipt and starts one instance", ctx do
      assert definition(ctx, "stock_receipt").status == :draft
      doc = P.issue!(ctx)

      row = definition(ctx, "stock_receipt")
      assert row.status == :active
      assert row.owner_module == "stock"
      assert row.activated_by["user_id"] == Repo.one!(user_id_query(), prefix: ctx.schema)
      assert instances(ctx, doc["id"]) == 1
      assert %{node_id: "post"} = P.pending_task(ctx, doc["id"], "post")
      # the reversal definition is activated by the reverse route only
      assert definition(ctx, "stock_reversal").status == :draft
    end

    test "B-ACT-2 B-ACT-3 an activator that cannot activate: 409 before a number is taken", ctx do
      doc = P.save!(ctx)
      prefix = ctx.schema
      actor = Ecto.UUID.generate()

      no_perm = %{permissions: [], entities_records_write?: true, user_id: actor, roles: []}
      no_write = %{permissions: ["DefinitionsActivate"], entities_records_write?: false}

      for activator <- [nil, no_perm, no_write] do
        assert {:error, :definition_not_active} =
                 Documents.issue(prefix, doc["id"], actor, activator: activator)
      end

      assert P.get!(ctx, doc["id"])["state"] == "draft"
      assert definition(ctx, "stock_receipt").status == :draft
      # no number was taken: the next successful issue is number 1 of the year
      issued = P.issue!(ctx, D.body(ctx.ma))
      assert issued["number"] =~ "-000001"
      assert issued["id"] != doc["id"]
    end
  end

  defp user_id_query do
    from(u in Letflow.Identity.User,
      where: like(u.username, "mock-subject%"),
      limit: 1,
      select: u.id
    )
  end

  describe "posting" do
    test "B-POST-1 B-POST-2 completion posts one entry, one mark; balances show it", ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      assert P.counts(ctx, id) == %{entries: %{}, marks: 0}

      posted = P.post_and_complete!(ctx, id)
      assert posted["state"] == "posted"
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
      assert posted["posting_check"] == "ok"
      assert posted["posted_by"] == ctx.holder.id
      assert is_binary(posted["posted_at"]) and is_binary(posted["entry_id"])

      [entry] = P.movements(ctx, id)
      assert entry["cause"] == "receipt"
      assert entry["document_type"] == "stock_receipt"
      assert entry["document_id"] == id
      assert entry["entry_id"] == posted["entry_id"]
      # the entry event time is the header's, not the posting time (offline triple)
      {:ok, event, _} = DateTime.from_iso8601(entry["event_time"])
      {:ok, header, _} = DateTime.from_iso8601(doc["event_time"])
      assert abs(DateTime.diff(event, header, :second)) <= 1

      m = ctx.ma
      [l1, l2] = Enum.sort_by(entry["legs"], & &1["leg_no"])

      assert %{
               "sku" => sku,
               "location" => loc,
               "org_unit" => unit,
               "responsible" => resp,
               "lot" => lot,
               "unit_ref" => uom
             } = l1

      assert {sku, loc, unit, resp, lot, uom} ==
               {m.item, m.location, m.unit, m.employee, m.lot, m.uom}

      assert Decimal.equal?(Decimal.new(l1["quantity"]), Decimal.new("10.5"))
      assert l2["lot"] == nil and Decimal.equal?(Decimal.new(l2["quantity"]), 2)
      line_ids = doc["lines"] |> Enum.sort_by(& &1["line_no"]) |> Enum.map(& &1["line_id"])
      assert Enum.map([l1, l2], & &1["document_line_id"]) == line_ids

      # the idempotency key of the ledger is the issued version id
      version = Documents.Posting.issued(ctx.schema, id)

      %{rows: [[op_id]]} =
        Repo.query!(
          ~s|SELECT client_op_id FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1|,
          [id]
        )

      assert op_id == version.version_id

      [mark] = marks(ctx, id)
      assert mark["mark"] == "posted" and mark["org_unit_id"] == m.unit
      assert mark["version_no"] == version.version_no and mark["document_type"] == "stock_receipt"

      balances = S.get("/balances?sku=#{m.item}", ctx.tok_a) |> P.status!(200)

      total =
        balances["rows"] |> Enum.map(&Decimal.new(&1["quantity"])) |> Enum.reduce(&Decimal.add/2)

      assert Decimal.equal?(total, Decimal.new("12.5"))
    end

    test "B-POST-3 a completion the ledger refuses writes nothing and the task stays pending",
         ctx do
      old = DateTime.utc_now() |> DateTime.add(-97 * 3600, :second) |> DateTime.to_iso8601()
      # the issue-time window (96 h) cannot be bypassed by the routes: a 97 h time is refused at
      # issue, so the posting is started through the generic start route with a 97 h client time.
      doc = P.issue!(ctx)
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

      posting = Map.put(instance.variables["posting"], "client_event_time", old)
      vars = %{instance.variables | "posting" => posting}
      {:ok, _} = start_generic(ctx, vars, "late")
      late = pending_for_instance(ctx, id, exclude: task.id)

      assert {:error, _} = P.complete(ctx, late)
      assert P.counts(ctx, id) == %{entries: %{}, marks: 0}
      assert Repo.get!(Letflow.Engine.Task, late.id, prefix: ctx.schema).status == :pending
    end

    test "B-POST-4 a TASK_WORKER and an API-token completion are refused; nothing is written",
         ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      worker = TokenMintFixture.role_holder!(ctx.schema, ["TASK_WORKER"])

      assert {:error, _} = P.complete(ctx, task, user: worker)
      assert {:error, _} = P.complete(ctx, task, credential: :api_token)
      assert P.counts(ctx, id) == %{entries: %{}, marks: 0}
      assert Repo.get!(Letflow.Engine.Task, task.id, prefix: ctx.schema).status == :pending
    end

    test "B-POST-5 a 100-line receipt posts (200 legs would be the cap, 100 lines are 100 legs)",
         ctx do
      line = %{
        "catalog_item_id" => ctx.ma.item,
        "catalog_uom_id" => ctx.ma.uom,
        "quantity" => "1"
      }

      doc = P.issue!(ctx, D.body(ctx.ma, nil, %{"lines" => List.duplicate(line, 100)}))
      posted = P.post_and_complete!(ctx, doc["id"])
      assert posted["state"] == "posted" and posted["posting_check"] == "ok"
      [entry] = P.movements(ctx, doc["id"])
      assert length(entry["legs"]) == 100
    end
  end

  defp marks(ctx, id) do
    Repo.all(
      from(r in Letflow.Entities.Record.Latest,
        where:
          r.entity_type == "stock_posting_mark" and not r.deleted and
            fragment("?->>'document_id' = ?", r.field_values, ^id),
        select: r.field_values
      ),
      prefix: ctx.schema
    )
  end

  defp start_generic(ctx, vars, tag) do
    Letflow.Engine.create(
      %{
        definition_name: "stock_receipt",
        initial_variables: vars,
        actor_id: ctx.holder.id,
        idempotency_key: "generic-#{tag}-#{Ecto.UUID.generate()}"
      },
      prefix: ctx.schema
    )
  end

  defp pending_for_instance(ctx, id, exclude: exclude_id) do
    Repo.one!(
      from(t in Letflow.Engine.Task,
        join: p in Letflow.EventStore.InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.id != ^exclude_id and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        limit: 1
      ),
      prefix: ctx.schema
    )
  end

  describe "states and the retry route" do
    test "B-ST-1 B-RT-2..5 the state follows the marks; the retry route refuses", ctx do
      draft = P.save!(ctx)
      assert draft["state"] == "draft"
      assert reason(P.req(ctx, :post, draft["id"], "post"), 409) == "document_not_issued"

      doc = P.issue!(ctx)
      id = doc["id"]
      assert doc["state"] == "issued" and doc["posted_at"] == nil and doc["posting_check"] == nil
      assert reason(P.req(ctx, :post, id, "post"), 409) == "posting_pending"
      assert filtered(ctx, "issued") == [id]
      assert filtered(ctx, "posted") == []

      P.post_and_complete!(ctx, id)
      assert reason(P.req(ctx, :post, id, "post"), 409) == "document_posted"
      assert filtered(ctx, "posted") == [id]
      assert filtered(ctx, "issued") == []
      [row] = (D.request(:get, "/documents?state=posted", ctx.tok_a) |> P.status!(200))["rows"]
      assert row["state"] == "posted"
      assert filtered(ctx, "draft") == [draft["id"]]
    end

    test "B-RT-1 B-RT-5 a forced start failure leaves the document issued; the retry posts once",
         ctx do
      Application.put_env(:letflow, :stock_post_start_fail?, true)
      doc = P.issue!(ctx)
      id = doc["id"]
      Application.delete_env(:letflow, :stock_post_start_fail?)

      assert doc["state"] == "issued" and doc["number"] =~ "-000001"
      assert instances(ctx, id) == 0
      assert P.pending_task(ctx, id, "post") == nil

      retried = P.req(ctx, :post, id, "post") |> P.status!(200)
      assert retried["state"] == "issued"
      assert instances(ctx, id) == 1

      assert P.post_and_complete!(ctx, id)["state"] == "posted"
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "B-RT-4 a cancelled document is not posted again", ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      cancel_instance!(ctx, P.pending_task(ctx, id, "post"))

      cancelled = P.req(ctx, :post, id, "cancel", %{"reason" => "wrong"}) |> P.status!(200)
      assert cancelled["state"] == "cancelled"
      assert reason(P.req(ctx, :post, id, "post"), 409) == "document_cancelled"
      assert instances(ctx, id) == 1
    end

    test "B-RT-6 a cancelled posting instance can be restarted (attempt number, no correlation key)",
         ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      cancel_instance!(ctx, P.pending_task(ctx, id, "post"))
      assert P.pending_task(ctx, id, "post") == nil

      P.req(ctx, :post, id, "post") |> P.status!(200)
      assert instances(ctx, id) == 2
      assert P.post_and_complete!(ctx, id)["state"] == "posted"
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    end
  end

  defp cancel_instance!(ctx, task) do
    assert {:ok, _} =
             Letflow.Engine.cancel_instance(
               task.instance_id,
               %{actor_id: ctx.holder.id, idempotency_key: Ecto.UUID.generate()},
               prefix: ctx.schema
             )
  end

  defp filtered(ctx, state) do
    (D.request(:get, "/documents?state=#{state}", ctx.tok_a) |> P.status!(200))["rows"]
    |> Enum.map(& &1["id"])
  end

  describe "idempotency (criterion 5)" do
    # Criterion 5 wording deviation (design F2): a second completion is REFUSED by the unique mark
    # rule instead of returning the ledger's duplicate result; entry and mark counts stay 1.
    test "B-ID-1 a second instance with the same variables is refused; one entry, one mark",
         ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      first = P.pending_task(ctx, id, "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, first.instance_id, prefix: ctx.schema)

      assert {:ok, _} = P.complete(ctx, first)

      {:ok, _} = start_generic(ctx, instance.variables, "dup")
      second = P.pending_task(ctx, id, "post")
      assert second.id != first.id

      assert {:error, refusal} = P.complete(ctx, second)
      # the unique mark rule: the mark step (line 0) fails validation; typed, not an exception
      assert refusal == {:entity_write_refused, 0, :validation_failed}
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
      assert Repo.get!(Letflow.Engine.Task, second.id, prefix: ctx.schema).status == :pending

      # the same through the real completion route: a typed 4xx, never a 500
      conn = complete_route(ctx, second)

      # pinned: the completion route answers 422 validation_failed for the mark step, never a 500 (INV-8)
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body) == %{"error" => "validation_failed", "line_index" => 0}
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "B-ID-2 a changed quantity under the same client_op_id is refused; nothing is written",
         ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      first = P.pending_task(ctx, id, "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, first.instance_id, prefix: ctx.schema)

      assert {:ok, _} = P.complete(ctx, first)

      lines = instance.variables["posting"]["lines"]
      changed = List.update_at(lines, 0, &Map.put(&1, "quantity", "99"))
      posting = Map.put(instance.variables["posting"], "lines", changed)
      {:ok, _} = start_generic(ctx, %{instance.variables | "posting" => posting}, "chg")

      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "B-ID-3 a different completer is refused too; the read shows posting_check ok", ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      first = P.pending_task(ctx, id, "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, first.instance_id, prefix: ctx.schema)

      assert {:ok, _} = P.complete(ctx, first)

      other_admin = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])
      {:ok, _} = start_generic(ctx, instance.variables, "other")
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"), user: other_admin)
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
      assert P.get!(ctx, id)["posting_check"] == "ok"
    end

    test "B-ID-4 the unique rule is on the type: one posted and one reversed mark per document",
         ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      P.post_and_complete!(ctx, id)

      definition =
        Repo.one!(
          from(d in Letflow.Entities.EntityDefinition, where: d.name == "stock_posting_mark"),
          prefix: ctx.schema
        )

      assert Enum.any?(definition.definition_json["constraints"] || [], fn c ->
               c["name"] == "uq_stock_posting_mark_doc_mark" and c["type"] == "unique" and
                 c["fields"] == ["document_id", "mark"]
             end)

      owner = Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Stock)

      values = fn mark ->
        %{
          "document_id" => id,
          "document_type" => "stock_receipt",
          "version_no" => 1,
          "mark" => mark,
          "org_unit_id" => ctx.ma.unit
        }
      end

      create = fn mark ->
        # scope-all: SEC-518-R1 (test: the type's own unique rule, own-record system path)
        Letflow.Entities.Records.create_record(
          %{
            entity_type: "stock_posting_mark",
            field_values: values.(mark),
            actor_id: ctx.holder.id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema,
          owner
        )
      end

      assert {:error, _} = create.("posted")
      assert {:ok, _} = create.("reversed")
      assert {:error, _} = create.("reversed")
    end
  end

  defp complete_route(ctx, task) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", "{}")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.tok_a)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  describe "binding check on read (criterion 6)" do
    test "B-CHK-1 output variables that change a quantity give posted + mismatch, no detail",
         ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

      lines =
        List.update_at(instance.variables["posting"]["lines"], 0, &Map.put(&1, "quantity", "3"))

      output = %{"posting" => Map.put(instance.variables["posting"], "lines", lines)}

      assert {:ok, _} = P.complete(ctx, task, output: output)
      read = P.get!(ctx, id)
      assert read["state"] == "posted" and read["posting_check"] == "mismatch"
      refute inspect(read) =~ "mismatch_detail"
    end

    test "B-CHK-2 a posting started for a draft's document id shows mismatch on the draft", ctx do
      issued = P.issue!(ctx)
      task = P.pending_task(ctx, issued["id"], "post")

      instance =
        Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

      draft = P.save!(ctx)

      posting =
        Map.merge(instance.variables["posting"], %{
          "document_id" => draft["id"],
          "client_op_id" => Ecto.UUID.generate()
        })

      vars = Map.merge(instance.variables, %{"document_id" => draft["id"], "posting" => posting})
      {:ok, _} = start_generic(ctx, vars, "draft")
      assert {:ok, _} = P.complete(ctx, pending_for_instance(ctx, draft["id"], exclude: task.id))

      read = P.get!(ctx, draft["id"])
      assert read["state"] == "draft" and read["posting_check"] == "mismatch"
    end

    test "B-CHK-3 the document read carries exactly the documented keys", ctx do
      doc = P.issue!(ctx)
      posted = P.post_and_complete!(ctx, doc["id"])

      assert posted |> Map.keys() |> Enum.sort() ==
               ~w(counterparty_id entry_id event_time header_id id issued_at kind lines location_id note number org_unit_id posted_at posted_by posting_check responsible_id reversed_at reversed_by state)

      assert posted["posting_check"] in ["ok", "mismatch", nil]
    end
  end
end
