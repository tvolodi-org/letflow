Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ModuleStartRouteTest do
  @moduledoc """
  T-2444 (T-2443 review of T-2430), stock side: `POST /instances` refuses to start a definition whose
  nodes carry `module_writes`: only the module's own code starts it (`Engine.create/2` with
  `module_start: true`). The answer is the one for an unknown definition (404, INV-5) and nothing is
  started. Without it the issuer of a four-eyes opening B started `stock_receipt` with B's own
  variables as `initial_variables` and posted B alone.
  Tests: MS-S1 the exploit (a stock opening posted by its issuer alone through the start route),
  MS-S2 every stock write definition (receipt kinds, opening, reversal, count) by name and by id,
  MS-S3 a legitimate document issue, opening and reversal still start and post, MS-S4 tenant B's
  definition and tenant B's variables from tenant A's route.
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  @post_keys ~w(document_id document_type version_no org_unit_id mark posting)

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))
  end

  defp start_route(token, body) do
    Plug.Test.conn(:post, "/api/v1/instances", Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp complete_route(task, token, body) do
    Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  defp variables(ctx, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema).variables

  defp write_definitions do
    pack = File.read!("priv/modules/stock/pack.json") |> Jason.decode!()

    for d <- pack["definitions"],
        Enum.any?(d["graph"]["nodes"], &get_in(&1, ["attributes", "module_writes"])),
        do: d["process_key"]
  end

  defp assert_unknown(conn) do
    assert conn.status == 404, "#{conn.status} #{conn.resp_body}"
  end

  test "MS-S1 the issuer of opening B cannot post B alone through the start route", ctx do
    P.issue!(ctx)
    doc_b = O.issue!(ctx)
    approve_b = O.task(ctx, doc_b["id"], "approve", :pending)
    forged = Map.take(variables(ctx, approve_b), @post_keys)
    assert map_size(forged) == length(@post_keys)

    # X's own approve of B is refused by the four-eyes rule
    assert complete_route(approve_b, ctx.tok_a, %{}).status == 403

    before = instance_count(ctx.schema)

    for name <- ["stock_receipt", "stock_opening"] do
      body = %{"definition_name" => name, "initial_variables" => forged}
      assert_unknown(start_route(ctx.tok_a, body))
    end

    assert instance_count(ctx.schema) == before
    refute P.pending_task(ctx, doc_b["id"], "post")
    assert P.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
    assert O.task(ctx, doc_b["id"], "approve", :pending)

    # the honest path is unchanged: a second administrator approves, B posts once
    assert complete_route(approve_b, ctx.tok_u2, %{}).status == 200
    assert P.counts(ctx, doc_b["id"]).marks == 1
  end

  test "MS-S2 every stock write definition is refused by name and by id, nothing is started",
       ctx do
    names = write_definitions()
    assert length(names) >= 4

    # the definitions are made active the way the module does it on first use
    for name <- names, do: assert(Posting.ensure_active(ctx.schema, name, nil) == :ok)

    before = instance_count(ctx.schema)

    for name <- names do
      row =
        Repo.one!(from(d in ProcessDefinition, where: d.name == ^name and d.status == :active),
          prefix: ctx.schema
        )

      vars = %{"posting" => %{"lines" => []}, "document_id" => Ecto.UUID.generate()}

      by_name = %{"definition_name" => name, "initial_variables" => vars}
      assert_unknown(start_route(ctx.tok_a, by_name))

      by_id = %{"definition_id" => row.id, "initial_variables" => vars}
      assert_unknown(start_route(ctx.tok_a, by_id))

      # an empty body of variables is refused too: the whole definition is module-only
      assert_unknown(
        start_route(ctx.tok_a, %{"definition_name" => name, "initial_variables" => %{}})
      )
    end

    assert instance_count(ctx.schema) == before
  end

  test "MS-S3 a legitimate document issue, opening and reversal still start and post", ctx do
    doc = P.issue!(ctx)
    assert P.pending_task(ctx, doc["id"], "post")
    P.post_and_complete!(ctx, doc["id"])
    assert P.counts(ctx, doc["id"]).marks == 1

    opening = O.issue!(ctx)
    assert O.task(ctx, opening["id"], "approve", :pending)

    assert complete_route(O.task(ctx, opening["id"], "approve", :pending), ctx.tok_u2, %{}).status ==
             200

    assert P.counts(ctx, opening["id"]).marks == 1

    P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
    |> P.status!(200)

    assert P.pending_task(ctx, doc["id"], "reverse")
  end

  test "MS-S4 tenant B's variables and tenant B's definition from tenant A's route", ctx do
    P.issue!(ctx)
    doc_b = P.issue!(%{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb})
    task_b = P.pending_task(%{ctx | schema: ctx.b.schema_name}, doc_b["id"], "post")
    vars_b = variables(%{ctx | schema: ctx.b.schema_name}, task_b)
    before_a = instance_count(ctx.schema)
    before_b = instance_count(ctx.b.schema_name)

    body = %{"definition_name" => "stock_receipt", "initial_variables" => vars_b}
    assert_unknown(start_route(ctx.tok_a, body))

    assert instance_count(ctx.schema) == before_a
    assert instance_count(ctx.b.schema_name) == before_b
    assert P.counts(%{ctx | schema: ctx.b.schema_name}, doc_b["id"]) == %{entries: %{}, marks: 0}
  end

  test "MS-S5 the module start option is not read from the request body", ctx do
    P.issue!(ctx)
    before = instance_count(ctx.schema)

    body = %{
      "definition_name" => "stock_receipt",
      "initial_variables" => %{"module_start" => true},
      "module_start" => true
    }

    assert_unknown(start_route(ctx.tok_a, body))
    assert instance_count(ctx.schema) == before
  end
end
