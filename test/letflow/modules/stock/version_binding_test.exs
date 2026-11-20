Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.VersionBindingTest do
  @moduledoc """
  REQ-903 / GH #4819 (ledger slice L7 part 2c, decision 0073 D6): `post_document` refuses with 409
  `record_version_conflict` a posting that is not the issued current version of its document or whose
  content differs. Criteria 1..8 of the requirement (9 is the documentation, `runbook_test.exs`).
  Committed tenants, Sandbox `:auto`, `async: false`; completions through the real route or `Engine`.
  Tests: VB-REG-1, VB-OK-1, VB-CHG-1..7, VB-WO-1, VB-VER-1..3, VB-ORD-1, VB-SCAN-1, VB-AUTH-1, VB-ISO-1.
  Invariants exercised: INV-1 (VB-ISO-1: another tenant's ids reveal nothing), INV-6 (the version is read
  only through the declared facade `HandlerWrites.read_document_version/3`, VB-SCAN-1), INV-10 (authority is
  checked before release: VB-AUTH-1, a completer without the stock permission answers the same as before).
  """

  use Letflow.DataCase, async: false

  @moduletag timeout: 300_000

  import Ecto.Query, only: [from: 2]

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Documents
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Stock
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp one_line_body(ctx, kind \\ "receipt", extra \\ %{}) do
    body =
      D.body(ctx.ma, nil, %{
        "kind" => kind,
        "lines" => [
          %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "2"}
        ]
      })

    body |> Map.merge(extra)
  end

  defp instance(ctx, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)

  defp posting(ctx, task), do: instance(ctx, task).variables["posting"]

  defp with_line(posting, fun),
    do: Map.put(posting, "lines", List.update_at(posting["lines"], 0, fun))

  defp assert_conflict(ctx, id, task, output) do
    assert {:error, {:entity_write_refused, 0, :record_version_conflict}} =
             P.complete(ctx, task, output: output)

    assert_untouched(ctx, id, task)
  end

  defp assert_untouched(ctx, id, task) do
    assert P.counts(ctx, id) == %{entries: %{}, marks: 0}
    assert Repo.get!(Letflow.Engine.Task, task.id, prefix: ctx.schema).status == :pending
  end

  defp complete_route(ctx, task, token, body) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    _ = ctx
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp strip_trace(body) do
    body |> Jason.decode!() |> Map.drop(["trace_id"]) |> Jason.encode!()
  end

  # -- criterion 1 --------------------------------------------------------------------------------

  test "VB-REG-1 post_document declares reads_documents; the other handlers do not; version raised" do
    m = Stock.manifest()
    assert Letflow.Modules.Catalog.validate(m) == :ok
    handler = fn name -> Enum.find(m.write_handlers, &(&1.name == name)) end

    assert handler.("post_document").reads_documents == true

    for name <- ~w(post_count post_kind_change_out reverse_document) do
      refute Map.get(handler.(name), :reads_documents, false), "#{name} must not read documents"
    end

    [major, minor, patch] = m.version |> String.split(".") |> Enum.map(&String.to_integer/1)
    assert {major, minor, patch} > {0, 22, 0}
  end

  # -- criterion 2 --------------------------------------------------------------------------------

  test "VB-OK-1 an issued receipt posted with unchanged variables: one entry, one mark", ctx do
    doc = P.issue!(ctx, one_line_body(ctx))
    posted = P.post_and_complete!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
  end

  # -- criterion 3 --------------------------------------------------------------------------------

  describe "changed content is refused (criterion 3)" do
    setup ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      task = P.pending_task(ctx, doc["id"], "post")
      Map.merge(ctx, %{id: doc["id"], task: task, posting: posting(ctx, task)})
    end

    test "VB-CHG-1 (a) one line's quantity differs", ctx do
      out = %{"posting" => with_line(ctx.posting, &Map.put(&1, "quantity", "3"))}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-2 (b) one line's sku is another live active item", ctx do
      other = Cat.item!(ctx.schema, "VB-I-#{System.unique_integer([:positive])}", ctx.ma.uom)
      out = %{"posting" => with_line(ctx.posting, &Map.put(&1, "sku", other.record_id))}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-3 (c) the to location is another live active location", ctx do
      other = D.masters!(ctx.schema)

      out = %{
        "posting" =>
          with_line(ctx.posting, fn l ->
            Map.put(l, "to", Map.put(l["to"], "location", other.location))
          end)
      }

      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-4 (d) a line is added", ctx do
      [first | _] = ctx.posting["lines"]
      extra = Map.put(first, "line_id", Ecto.UUID.generate())
      out = %{"posting" => Map.put(ctx.posting, "lines", ctx.posting["lines"] ++ [extra])}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-5 (e) client_event_time differs", ctx do
      out = %{"posting" => Map.put(ctx.posting, "client_event_time", "2001-01-01T00:00:00Z")}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-6 (f) client_op_id is another uuid", ctx do
      out = %{"posting" => Map.put(ctx.posting, "client_op_id", Ecto.UUID.generate())}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-7 an org_unit_id argument of another live active org unit", ctx do
      other = D.masters!(ctx.schema)
      vars = instance(ctx, ctx.task).variables
      assert vars["org_unit_id"] == ctx.ma.unit
      assert other.unit != ctx.ma.unit
      assert_conflict(ctx, ctx.id, ctx.task, %{"org_unit_id" => other.unit})
    end

    test "VB-CHG-8 the document_type argument and the posting document_id are bound too", ctx do
      assert_conflict(ctx, ctx.id, ctx.task, %{"document_type" => "stock_issue"})
      other = P.save!(ctx)

      out = %{"posting" => Map.put(ctx.posting, "document_id", other["id"])}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-9 a cause of another kind is refused", ctx do
      out = %{"posting" => Map.put(ctx.posting, "cause", "issue")}
      assert_conflict(ctx, ctx.id, ctx.task, out)
    end

    test "VB-CHG-10 over the route: 409 record_version_conflict, nothing written", ctx do
      out = %{"posting" => with_line(ctx.posting, &Map.put(&1, "quantity", "3"))}
      conn = complete_route(ctx, ctx.task, ctx.tok_a, out)
      assert conn.status == 409
      assert conn.resp_body =~ "record_version_conflict"
      assert_untouched(ctx, ctx.id, ctx.task)
    end
  end

  # -- criterion 4 --------------------------------------------------------------------------------

  test "VB-WO-1 a write-off whose reason_code differs from the header's is refused", ctx do
    doc = P.issue!(ctx, one_line_body(ctx))
    P.post_and_complete!(ctx, doc["id"])

    wo =
      one_line_body(ctx, "write_off", %{"reason_code" => "damaged"})
      |> Map.delete("counterparty_id")
      |> Map.put("lines", [
        %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"}
      ])

    wo_doc = P.issue!(ctx, wo)
    task = P.pending_task(ctx, wo_doc["id"], "post")
    p = posting(ctx, task)
    assert p["reason_code"] == "damaged"

    assert_conflict(ctx, wo_doc["id"], task, %{"posting" => Map.put(p, "reason_code", "lost")})
  end

  # -- criterion 5 --------------------------------------------------------------------------------

  describe "version state (criterion 5)" do
    test "VB-VER-1 a version cancelled directly: its post task is refused with 409", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")

      assert {:ok, _} =
               Documents.cancel(
                 ctx.schema,
                 %{document_id: id, version_no: 1, reason: "r"},
                 ctx.holder.id
               )

      conn = complete_route(ctx, task, ctx.tok_a, %{})
      assert conn.status == 409 and conn.resp_body =~ "record_version_conflict"
      assert_untouched(ctx, id, task)
    end

    test "VB-VER-2 a generic start with a draft's id and version_no 1 is refused with 409", ctx do
      issued = P.issue!(ctx, one_line_body(ctx))
      task = P.pending_task(ctx, issued["id"], "post")
      draft = P.save!(ctx)

      vars =
        Map.merge(instance(ctx, task).variables, %{
          "document_id" => draft["id"],
          "version_no" => 1,
          "posting" => Map.put(posting(ctx, task), "document_id", draft["id"])
        })

      {:ok, _} =
        Letflow.Engine.create(
          %{
            definition_name: "stock_receipt",
            initial_variables: vars,
            actor_id: ctx.holder.id,
            idempotency_key: "vb-#{Ecto.UUID.generate()}"
          },
          prefix: ctx.schema
        )

      generic =
        Repo.one!(
          from(t in Letflow.Engine.Task,
            join: p in InstanceProjection,
            on: p.instance_id == t.instance_id,
            where:
              t.status == :pending and
                fragment("?->>'document_id' = ?", p.variables, ^draft["id"])
          ),
          prefix: ctx.schema
        )

      conn = complete_route(ctx, generic, ctx.tok_a, %{})
      assert conn.status == 409 and conn.resp_body =~ "record_version_conflict"
      assert P.counts(ctx, draft["id"]) == %{entries: %{}, marks: 0}
    end

    test "VB-VER-3 an unknown document uuid is 422 validation_failed, detail handler_invalid_arguments",
         ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      task = P.pending_task(ctx, doc["id"], "post")
      unknown = Ecto.UUID.generate()
      p = Map.put(posting(ctx, task), "document_id", unknown)

      conn =
        complete_route(ctx, task, ctx.tok_a, %{"document_id" => unknown, "posting" => p})

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "validation_failed"

      entry =
        Repo.one(
          from(a in Letflow.Audit.Entry,
            where: fragment("?->>'detail' = 'handler_invalid_arguments'", a.after_state),
            order_by: [desc: a.inserted_at],
            limit: 1
          ),
          prefix: ctx.schema
        )

      assert entry != nil
      assert_untouched(ctx, doc["id"], task)
    end
  end

  # -- criterion 6 --------------------------------------------------------------------------------

  test "VB-ORD-1 a cancelled version whose item is then retired: version check runs first", ctx do
    doc = P.issue!(ctx, one_line_body(ctx))
    id = doc["id"]
    task = P.pending_task(ctx, id, "post")

    {:ok, _} =
      Documents.cancel(ctx.schema, %{document_id: id, version_no: 1, reason: "r"}, ctx.holder.id)

    r =
      Repo.get_by!(Latest, [record_id: ctx.ma.item, entity_type: "catalog_item"],
        prefix: ctx.schema
      )

    Cat.update!(ctx.schema, r, Map.put(r.field_values, "active", false))

    assert {:error, {:entity_write_refused, 0, :record_version_conflict}} =
             P.complete(ctx, task)

    _ = CatalogItems
    assert_untouched(ctx, id, task)
  end

  # -- criterion 7 --------------------------------------------------------------------------------

  test "VB-SCAN-1 one pure legs module; posting and handlers call it; no other comparison" do
    root = Path.expand("../../../../lib/letflow/modules/stock", __DIR__)
    legs = File.read!(Path.join(root, "documents/legs.ex"))

    for banned <- ["Repo", "Ecto.Query", "Letflow.Documents"] do
      refute legs =~ banned, "legs.ex must not reference #{banned}"
    end

    assert File.read!(Path.join(root, "documents/posting.ex")) =~ "Legs."
    handlers = File.read!(Path.join(root, "handlers.ex"))
    assert handlers =~ "Legs."
    assert handlers =~ "HandlerWrites.read_document_version("

    others =
      Path.join(root, "**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "legs.ex"))
      |> Enum.filter(fn f ->
        src = File.read!(f)
        src =~ ~r/def\s+legs_match\?|defp?\s+leg_key\(|defp?\s+expected_from\(/
      end)

    assert others == [], "legs comparison defined outside legs.ex: #{inspect(others)}"
  end

  # -- criterion 8 --------------------------------------------------------------------------------

  test "VB-AUTH-1 a TASK_WORKER completer: refused, body identical to the unchanged posting's",
       ctx do
    doc = P.issue!(ctx, one_line_body(ctx))
    id = doc["id"]
    task = P.pending_task(ctx, id, "post")
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "vb-worker")

    unchanged = complete_route(ctx, task, worker, %{})
    changed_out = %{"posting" => with_line(posting(ctx, task), &Map.put(&1, "quantity", "3"))}
    changed = complete_route(ctx, task, worker, changed_out)

    # Authority before release: a completer without the post authority is refused (403, or the
    # uniform 404 of the StockApprove guard of the post node, INV-5) BEFORE the binding check runs,
    # so a changed posting answers exactly as the unchanged one and leaks no 409.
    assert unchanged.status == changed.status and unchanged.status in [403, 404],
           inspect({unchanged.status, changed.status})

    assert strip_trace(changed.resp_body) == strip_trace(unchanged.resp_body)
    _ = TokenMintFixture
    assert_untouched(ctx, id, task)
  end

  # -- cross-tenant (INV-1) -----------------------------------------------------------------------

  test "VB-ISO-1 another tenant's document id gives the closed 422, not a conflict or a read",
       ctx do
    doc_b = D.request(:post, "/documents", ctx.tok_b, D.body(ctx.mb)) |> P.status!(201)
    issued_b = D.request(:post, "/documents/#{doc_b["id"]}/issue", ctx.tok_b) |> P.status!(200)

    doc = P.issue!(ctx, one_line_body(ctx))
    task = P.pending_task(ctx, doc["id"], "post")
    p = Map.put(posting(ctx, task), "document_id", issued_b["id"])

    conn =
      complete_route(ctx, task, ctx.tok_a, %{"document_id" => issued_b["id"], "posting" => p})

    assert conn.status == 422
    refute conn.resp_body =~ "record_version_conflict"
    refute conn.resp_body =~ issued_b["id"]
    assert_untouched(ctx, doc["id"], task)
    assert P.counts(%{schema: ctx.b.schema_name}, issued_b["id"]).entries == %{}
  end
end
