Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.ModuleStartRouteTest do
  @moduledoc """
  T-2444 (T-2443 review of T-2430), assets side: `POST /instances` refuses to start an assets
  definition (commission, opening, reversal, ...): 404 as for an unknown definition, nothing started,
  nothing posted. The assets handlers read nothing and trust their arguments, so a start with chosen
  variables would post any lines or reverse any entry.
  Tests: MS-A1 the exploit (the issuer of opening B starts a definition with B's variables), MS-A2 every
  active assets write definition by name and by id with forged `posting` and `reverses_entry_id`,
  MS-A3 the legitimate document flow (commission, opening, reversal) still starts and posts,
  MS-A4 tenant B's variables from tenant A's route. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  @post_keys ~w(document_id document_type version_no org_unit_id mark posting)

  setup do
    ctx = D.setup!([:a, :b])
    ctx = Map.merge(ctx, D.tenant_b!(ctx))
    {:ok, Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))}
  end

  defp start_route(token, body) do
    Plug.Test.conn(:post, "/api/v1/instances", Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  defp variables(ctx, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema).variables

  # an issued opening (needs lines) saved by the first admin and issued by it, as WT-A3 does
  defp issued_opening!(ctx) do
    body = D.opening_body(ctx.ma, %{"lines" => [D.opening_line(ctx.ma, ctx.ma.low)]})
    doc = D.save!(ctx, body)
    D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(200)
  end

  defp assets_write_rows(ctx) do
    Repo.all(
      from(d in ProcessDefinition,
        where: d.owner_module == "assets" and d.status == :active
      ),
      prefix: ctx.schema
    )
    |> Enum.filter(fn d ->
      Enum.any?(d.graph["nodes"], &get_in(&1, ["attributes", "module_writes"]))
    end)
  end

  test "MS-A1 the issuer of opening B cannot post B alone by starting another definition", ctx do
    doc_b = issued_opening!(ctx)
    approve_b = D.pending_task(ctx, doc_b["id"], "approve")
    forged = Map.take(variables(ctx, approve_b), @post_keys)
    assert map_size(forged) == length(@post_keys)
    assert D.task_route(approve_b, ctx.tok_a, "complete", "{}").status == 403

    # an active write definition to aim at: a posted commission activates the commission one
    D.run_task!(ctx, D.issue!(ctx)["id"])
    before = instance_count(ctx.schema)

    for row <- assets_write_rows(ctx) do
      body = %{"definition_name" => row.name, "initial_variables" => forged}
      assert start_route(ctx.tok_a, body).status == 404, row.name
    end

    assert instance_count(ctx.schema) == before
    assert D.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
    refute D.pending_task(ctx, doc_b["id"], "post")
    assert D.pending_task(ctx, doc_b["id"], "approve")
  end

  test "MS-A2 every active assets write definition is refused by name and by id", ctx do
    doc = D.issue!(ctx)
    D.run_task!(ctx, doc["id"])

    D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
      "reason_code" => "wrong_document"
    })
    |> D.status!(200)

    issued_opening!(ctx)
    rows = assets_write_rows(ctx)
    names = Enum.map(rows, & &1.name)
    assert length(rows) >= 3, inspect(names)
    before = instance_count(ctx.schema)

    forged = %{
      "posting" => %{"lines" => [], "reverses_entry_id" => Ecto.UUID.generate()},
      "document_id" => Ecto.UUID.generate(),
      "reason_code" => "other"
    }

    for row <- rows do
      by_name = %{"definition_name" => row.name, "initial_variables" => forged}
      assert start_route(ctx.tok_a, by_name).status == 404, row.name
      by_id = %{"definition_id" => row.id, "initial_variables" => forged}
      assert start_route(ctx.tok_a, by_id).status == 404, row.name
      empty = %{"definition_name" => row.name, "initial_variables" => %{}}
      assert start_route(ctx.tok_a, empty).status == 404, row.name
    end

    assert instance_count(ctx.schema) == before
  end

  test "MS-A3 the legitimate flow still starts and posts: commission, opening, reversal", ctx do
    doc = D.issue!(ctx)
    D.run_task!(ctx, doc["id"])
    assert D.counts(ctx, doc["id"]) == %{entries: %{"commission" => 1}, marks: 1}

    D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
      "reason_code" => "wrong_document"
    })
    |> D.status!(200)

    assert D.pending_task(ctx, doc["id"], "reverse")

    opening = issued_opening!(ctx)
    approve = D.pending_task(ctx, opening["id"], "approve")
    assert D.task_route(approve, ctx.tok_u2, "complete", "{}").status == 200
    assert D.counts(ctx, opening["id"]).marks == 1
  end

  test "MS-A4 tenant B's variables from tenant A's route start nothing in either tenant", ctx do
    D.run_task!(ctx, D.issue!(ctx)["id"])
    ctx_b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    doc_b = D.issue!(ctx_b)
    task_b = D.pending_task(ctx_b, doc_b["id"], "post")
    vars_b = variables(ctx_b, task_b)
    before_a = instance_count(ctx.schema)
    before_b = instance_count(ctx_b.schema)

    [row | _] = assets_write_rows(ctx)
    body = %{"definition_name" => row.name, "initial_variables" => Map.take(vars_b, @post_keys)}
    assert start_route(ctx.tok_a, body).status == 404

    assert instance_count(ctx.schema) == before_a
    assert instance_count(ctx_b.schema) == before_b
    assert D.counts(ctx_b, doc_b["id"]) == %{entries: %{}, marks: 0}
  end
end
