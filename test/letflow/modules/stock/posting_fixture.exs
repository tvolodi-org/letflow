Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.StockPostingFixture do
  @moduledoc """
  REQ-713 / GH #3748: setup and helpers of the posting tests. One committed tenant with the `stock`
  module installed and real masters, a bearer token of a TENANT_ADMIN, and a TENANT_ADMIN user
  row (`holder`) that completes tasks through `Letflow.Engine.complete_task/3` with `credential: :oidc`
  (the task completion path the ledger authority step checks). A `.exs` file loaded with
  `Code.require_file/2`; callers are `async: false` and run in Sandbox `:auto` mode.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @doc "The test context: tenant `a` (and `b` when asked), masters, tokens and a task completer."
  def setup!(names \\ [:a]) do
    ctx = S.setup_oidc!(names)
    a = S.tenant!("stk-pa", ctx.names.a)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:letflow, :stock_post_start_fail?) end)

    Map.merge(ctx, %{
      a: a,
      schema: a.schema_name,
      ma: D.masters!(a.schema_name),
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
      holder: TokenMintFixture.role_holder!(a.schema_name, ["TENANT_ADMIN"])
    })
  end

  @doc "A second tenant `b` with masters and a token, for the cross-tenant tests."
  def tenant_b!(ctx) do
    b = S.tenant!("stk-pb", ctx.names.b)
    %{b: b, mb: D.masters!(b.schema_name), tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])}
  end

  def status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    if conn.resp_body == "", do: nil, else: S.json(conn)
  end

  def save!(ctx, body \\ nil),
    do: D.request(:post, "/documents", ctx.tok_a, body || D.body(ctx.ma)) |> status!(201)

  @doc "Saves and issues a receipt through the routes; returns the issued document."
  def issue!(ctx, body \\ nil) do
    doc = save!(ctx, body)
    D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)
  end

  def get!(ctx, id), do: D.request(:get, "/documents/#{id}", ctx.tok_a) |> status!(200)

  def req(ctx, method, id, action, body \\ nil),
    do: D.request(method, "/documents/#{id}/#{action}", ctx.tok_a, body)

  @doc "The pending task of `node` (\"post\" / \"reverse\") of an active instance of document `id`."
  def pending_task(ctx, id, node) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: ctx.schema
    )
  end

  @doc "Completes `task` as `user` (default: the TENANT_ADMIN holder) with the OIDC credential."
  def complete(ctx, task, opts \\ []) do
    user = Keyword.get(opts, :user, ctx.holder)
    output = Keyword.get(opts, :output, %{})
    credential = Keyword.get(opts, :credential, :oidc)

    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: user.id, idempotency_key: Ecto.UUID.generate()},
      prefix: ctx.schema,
      credential: credential
    )
  end

  def post_and_complete!(ctx, id) do
    task = pending_task(ctx, id, "post") || flunk("no pending post task")
    assert {:ok, _} = complete(ctx, task)
    get!(ctx, id)
  end

  @doc "Rows of the ledger tables for document `id`: entry count by cause, and the mark count."
  def counts(ctx, id) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT cause, count(*) FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1 GROUP BY cause|,
        [id]
      )

    %{rows: [[marks]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{ctx.schema}".entity_record_latest WHERE entity_type = 'stock_posting_mark' AND NOT deleted AND field_values->>'document_id' = $1|,
        [id]
      )

    %{entries: Map.new(rows, fn [cause, n] -> {cause, n} end), marks: marks}
  end

  @doc "Movement rows of the document through the real read route."
  def movements(ctx, id) do
    S.get("/movements?document_id=#{id}", ctx.tok_a) |> status!(200) |> Map.fetch!("rows")
  end
end
