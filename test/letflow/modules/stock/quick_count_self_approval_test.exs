Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.QuickCountSelfApprovalTest do
  @moduledoc """
  T-2410 (owner D-164, PM decision 2026-11-20): with the tenant's count rule `stock_quick_count` /
  `approve` OFF, the system completes the approve step of the counter's OWN quick count through
  `POST /quick-counts` (the same engine path as the old Qoimeks address, K6a). Committed tenants, real
  OIDC tokens, Sandbox `:auto`, `async: false`. Ids SA-1..SA-8.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  @moduletag timeout: 240_000

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))

    ctx =
      Map.merge(ctx, %{
        tok_adm: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-1"),
        tok_kb: S.token(ctx, :b, ["TENANT_ADMIN"], sub: "admin-b"),
        tok_sk: S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-1"),
        tok_sk2: S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-2")
      })

    # The first quick count of each tenant activates the module's process definition (rule ON: it waits).
    first_a = D.masters!(ctx.schema)

    assert D.request(
             :post,
             "/quick-counts",
             ctx.tok_a,
             qc_body(first_a, %{"counted_quantity" => "0"})
           ).status == 201

    first_b = D.masters!(ctx.b.schema_name)

    assert D.request(
             :post,
             "/quick-counts",
             ctx.tok_kb,
             qc_body(first_b, %{"counted_quantity" => "0"})
           ).status == 201

    ctx
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp api(method, path, token, body) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, "/api/v1" <> path)
        body -> Plug.Test.conn(method, "/api/v1" <> path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp qc_body(m, extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "responsible_id" => m.employee,
        "catalog_item_id" => m.item,
        "catalog_uom_id" => m.uom,
        "counted_quantity" => "7",
        "reason_code" => "recount"
      },
      extra
    )
  end

  defp count!(masters, token, extra \\ %{}),
    do: D.request(:post, "/quick-counts", token, qc_body(masters, extra)) |> P.status!(201)

  defp switch(token, four_eyes) do
    api(:put, "/approval-rules/stock_quick_count/approve", token, %{
      "four_eyes" => four_eyes,
      "reason" => "one-person company"
    })
    |> P.status!(200)
  end

  defp audit(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp balance(ctx, m) do
    path = "/balances?sku=#{m.item}&location=#{m.location}&org_unit=#{m.unit}"
    rows = S.get(path, ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp state(token, id),
    do: D.request(:get, "/documents/#{id}", token) |> P.status!(200) |> Map.fetch!("state")

  # -- criteria -----------------------------------------------------------------------------------

  test "SA-1 rule OFF: the storekeeper's count posts at once, one task.self_approved naming the system",
       ctx do
    switch(ctx.tok_a, false)
    m = D.masters!(ctx.schema)

    doc = count!(m, ctx.tok_sk)

    assert doc["state"] == "posted", "got #{inspect(doc["state"])}"
    assert Decimal.eq?(balance(ctx, m), 7)
    assert O.task(ctx, doc["id"], "submit", :completed)
    assert approve = O.task(ctx, doc["id"], "approve", :completed)
    assert P.counts(ctx, doc["id"]) == %{entries: %{"count_set" => 1}, marks: 1}

    # the audit: one self-approval, the human counter is the actor and the "same person" of the submit
    assert [self] = audit(ctx.schema, "task.self_approved")
    assert self.resource_id == approve.id
    assert self.actor_id == approve.completed_by
    assert self.actor_id == O.task(ctx, doc["id"], "submit", :completed).completed_by
    assert self.after_state["note"] == "self-approved, four-eyes off"
    assert self.after_state["definition_name"] == "stock_quick_count"
    assert self.after_state["node_id"] == "approve"
    assert self.after_state["same_person_as"] == ["submit"]
    assert self.after_state["approved_by"] == "system"
  end

  test "SA-2 rule ON (no row, then a stored true): the count waits for an administrator", ctx do
    m = D.masters!(ctx.schema)

    doc = count!(m, ctx.tok_sk)
    assert doc["state"] == "issued"
    assert O.task(ctx, doc["id"], "approve", :pending)
    assert audit(ctx.schema, "task.self_approved") == []

    switch(ctx.tok_a, false)
    switch(ctx.tok_a, true)
    doc2 = count!(D.masters!(ctx.schema), ctx.tok_sk)
    assert doc2["state"] == "issued"
    assert O.task(ctx, doc2["id"], "approve", :pending)
    assert audit(ctx.schema, "task.self_approved") == []
    assert Decimal.eq?(balance(ctx, m), 0)
  end

  test "SA-3 a count issued while ON stays pending after the switch goes OFF; another user's is never auto-approved",
       ctx do
    m = D.masters!(ctx.schema)
    older = count!(m, ctx.tok_sk)
    assert older["state"] == "issued"

    switch(ctx.tok_a, false)

    # a second storekeeper counts: only ITS document is approved by the system
    own = count!(D.masters!(ctx.schema), ctx.tok_sk2)
    assert own["state"] == "posted"

    assert state(ctx.tok_a, older["id"]) == "issued"
    assert O.task(ctx, older["id"], "approve", :pending)
    assert Decimal.eq?(balance(ctx, m), 0)
    assert [self] = audit(ctx.schema, "task.self_approved")
    assert self.resource_id == O.task(ctx, own["id"], "approve", :completed).id
  end

  test "SA-4 no privilege widening: the storekeeper still cannot approve, route or permission",
       ctx do
    switch(ctx.tok_a, false)
    m = D.masters!(ctx.schema)
    doc = count!(m, ctx.tok_sk)
    assert doc["state"] == "posted"

    assert api(:get, "/modules/stock/approval-access", ctx.tok_sk, nil).status == 403

    switch(ctx.tok_a, true)
    waiting = count!(D.masters!(ctx.schema), ctx.tok_sk)
    task = O.task(ctx, waiting["id"], "approve", :pending)
    assert api(:post, "/tasks/#{task.id}/complete", ctx.tok_sk, %{}).status == 404
    assert O.task(ctx, waiting["id"], "approve", :pending)
  end

  test "SA-5 cross-tenant (INV-1): a tenant with the rule OFF does not affect another tenant",
       ctx do
    switch(ctx.tok_kb, false)

    mb = D.masters!(ctx.b.schema_name)
    doc_b = count!(mb, ctx.tok_kb)
    assert doc_b["state"] == "posted"
    assert [_one] = audit(ctx.b.schema_name, "task.self_approved")

    # tenant A stays ON: its storekeeper's count waits and A's audit holds nothing
    doc_a = count!(D.masters!(ctx.schema), ctx.tok_sk)
    assert doc_a["state"] == "issued"
    assert O.task(ctx, doc_a["id"], "approve", :pending)
    assert audit(ctx.schema, "task.self_approved") == []

    # and the other way round: A OFF leaves the pending count of B (made while ON) untouched
    switch(ctx.tok_kb, true)
    pending_b = count!(D.masters!(ctx.b.schema_name), ctx.tok_kb)
    switch(ctx.tok_a, false)
    assert state(ctx.tok_kb, pending_b["id"]) == "issued"
  end

  test "SA-6 an API token (not an interactive sign-in) is never auto-approved", ctx do
    switch(ctx.tok_a, false)
    user = Letflow.Support.TokenMintFixture.role_holder!(ctx.schema, ["STOREKEEPER"])

    {:ok, %{plaintext: plaintext}} =
      Letflow.Identity.create_token(user.id, %{roles: ["STOREKEEPER"], expires_at: nil},
        prefix: ctx.schema
      )

    conn = D.request(:post, "/quick-counts", plaintext, qc_body(D.masters!(ctx.schema)))

    if conn.status == 201 do
      doc = S.json(conn)
      assert doc["state"] == "issued"
      assert O.task(ctx, doc["id"], "approve", :pending)
    end

    assert audit(ctx.schema, "task.self_approved") == []
  end

  test "SA-7 a count equal to the book is confirmed at once: no task, no self-approval", ctx do
    switch(ctx.tok_a, false)
    m = D.masters!(ctx.schema)

    doc = count!(m, ctx.tok_sk, %{"counted_quantity" => "0"})

    assert doc["state"] == "confirmed"
    assert audit(ctx.schema, "task.self_approved") == []
  end

  test "SA-8 a refusal of the approval cancels the issued count: nothing pending, nothing posted",
       ctx do
    # a user whose database roles do not allow the posting: the ledger authority refuses at the approval
    user = Letflow.Support.TokenMintFixture.role_holder!(ctx.schema, [])
    {:ok, tenant_id} = Letflow.TenantProvisioning.tenant_id_for_schema_name(ctx.schema)
    {:ok, authorized} = Letflow.Ledger.authorize_shared_access(ctx.schema, tenant_id, "stock")

    switch(ctx.tok_a, false)
    m = D.masters!(ctx.schema)
    {before_cancelled, before_issued} = {listed(ctx, "cancelled"), listed(ctx, "issued")}

    result =
      Letflow.Modules.Stock.Documents.quick_count(ctx.schema, qc_body(m), user.id,
        authorized: authorized,
        self_approve: :oidc
      )

    assert {:error, _reason} = result
    assert audit(ctx.schema, "task.self_approved") == []
    assert Decimal.eq?(balance(ctx, m), 0)

    # the count it made is cancelled, not left pending for an administrator
    assert listed(ctx, "cancelled") == before_cancelled + 1
    assert listed(ctx, "issued") == before_issued
  end

  defp listed(ctx, state) do
    D.request(:get, "/documents?kind=quick_count&state=#{state}&limit=100", ctx.tok_a)
    |> P.status!(200)
    |> Map.fetch!("rows")
    |> length()
  end
end
