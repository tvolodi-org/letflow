Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.StockOpeningFixture do
  @moduledoc """
  REQ-725 / REQ-726: bodies and helpers of the opening balance tests. Built on `Letflow.StockPostingFixture`
  (committed tenant, OIDC token, a TENANT_ADMIN holder) and `Letflow.StockDocsFixture` (masters, requests).
  A `.exs` file loaded with `Code.require_file/2`; callers are `async: false`, Sandbox `:auto`.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.TokenMintFixture

  @doc "A date `days` back from today (ISO text); the real receipt date of a line."
  def back(days), do: Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

  @doc "One valid opening line for masters `m` (the plain item), `extra` overrides keys."
  def line(m, extra \\ %{}) do
    Map.merge(
      %{
        "location_id" => m.location,
        "responsible_id" => m.employee,
        "catalog_item_id" => m.item,
        "catalog_uom_id" => m.uom,
        "quantity" => "10.5",
        "received_on" => back(400)
      },
      extra
    )
  end

  @doc "A valid opening body: one plain line and one lot-tracked line with its lot."
  def body(m, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "opening",
        "org_unit_id" => m.unit,
        "note" => "migration stock",
        "lines" => [
          line(m),
          line(m, %{
            "catalog_item_id" => m.lot_item,
            "catalog_lot_id" => m.lot,
            "quantity" => "2",
            "received_on" => back(30),
            "unit_price" => "3.5",
            "line_value" => "7"
          })
        ]
      },
      extra
    )
  end

  def save!(ctx, body \\ nil),
    do: D.request(:post, "/documents", ctx.tok_a, body || body(ctx.ma)) |> P.status!(201)

  @doc "Saves and issues an opening through the routes (the issuing user submits); the issued document."
  def issue!(ctx, body \\ nil) do
    doc = save!(ctx, body)
    D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
  end

  @doc "Header records, line records and documents of `schema` (for 'nothing written' counts)."
  def counts(schema) do
    alias Letflow.Entities.Record.Latest

    records =
      Repo.aggregate(
        from(r in Latest, where: r.entity_type in ["stock_opening", "stock_opening_line"]),
        :count,
        prefix: schema
      )

    {records, Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: schema)}
  end

  @doc "The pending or completed task of `node` of the instances of document `id` (latest first)."
  def task(ctx, id, node, status) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == ^status and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: ctx.schema
    )
  end

  @doc "A second TENANT_ADMIN user row (not the issuer): the approver U2."
  def second_admin!(ctx), do: TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

  @doc "Completes the pending `approve` task of document `id` as `user` (an id holder), OIDC credential."
  def approve(ctx, id, user, opts \\ []) do
    task = task(ctx, id, "approve", :pending) || flunk("no pending approve task")
    P.complete(ctx, task, Keyword.put(opts, :user, user))
  end

  @doc "The issuing user's id: the one that completed `submit`."
  def issuer_id(ctx, id) do
    (task(ctx, id, "submit", :completed) || flunk("submit not completed")).completed_by
  end
end
