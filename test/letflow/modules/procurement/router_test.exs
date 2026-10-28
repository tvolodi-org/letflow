Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.RouterTest do
  @moduledoc """
  GH #3162 / REQ-544 part 2, criterion 10 (authorization and tenancy) and the HTTP half of 5, 7 and 9
  (spec: state/tasks/T-0746/design.md, tests A1..A5, P2, C2 router case): `Letflow.Modules.Procurement.Router`
  through the full pipeline (`Letflow.Router`) with real tokens.

  Write, Read and Decide are held by the same two roles (TENANT_ADMIN, PLATFORM_ADMIN) because the
  manifest has no `role_grants`: the requester/approver split beyond the permission gate rests on
  the self-decision check (A2).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Modules.Procurement.Decision
  alias Letflow.Modules.Procurement.PurchaseRequests
  alias Letflow.Modules.Procurement.Router
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo

  @base "/api/v1/modules/procurement/purchase-requests"

  setup do
    a = Fixture.tenant!("gh3162ra")
    b = Fixture.tenant!("gh3162rb")
    admin = Fixture.user!(a, ["TENANT_ADMIN"])
    approver = Fixture.user!(a, ["TENANT_ADMIN"])
    worker = Fixture.user!(a, ["TASK_WORKER"])
    request = Fixture.issued!(a, admin.user_id)
    %{a: a, b: b, admin: admin, approver: approver, worker: worker, request: request}
  end

  defp call(method, path, user, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> put_req_header("x-trace-id", "t-3162")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp decision_body(request, overrides \\ %{}) do
    Map.merge(
      %{
        "version_no" => request.version_no,
        "content_hash" => request.hash,
        "decision" => "approve",
        "idempotency_key" => "k-" <> Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp rows(ctx), do: Repo.aggregate(Decision, :count, prefix: ctx.schema)

  test "create, read, submit and revise over HTTP", ctx do
    conn = call(:post, @base, ctx.admin, Fixture.params(ctx.a))
    assert conn.status == 201
    %{"document_id" => id, "version_no" => 1, "status" => "draft"} = json(conn)

    conn =
      call(:post, "#{@base}/#{id}/submit", ctx.admin, %{
        "version_no" => 1,
        "idempotency_key" => "s-1"
      })

    assert conn.status == 200
    assert %{"state" => "submitted", "replayed" => false, "content_hash" => hash} = json(conn)

    conn =
      call(:post, "#{@base}/#{id}/submit", ctx.admin, %{
        "version_no" => 1,
        "idempotency_key" => "s-1"
      })

    assert conn.status == 200
    assert %{"replayed" => true, "content_hash" => ^hash} = json(conn)

    conn = call(:get, "#{@base}/#{id}", ctx.admin)
    assert conn.status == 200
    assert %{"state" => "submitted", "content_hash" => ^hash} = json(conn)

    conn =
      call(
        :post,
        "#{@base}/#{id}/revise",
        ctx.admin,
        Fixture.params(ctx.a, %{"justification" => "More"})
      )

    assert conn.status == 200
    assert %{"version_no" => 2} = json(conn)
  end

  test "A1: a role without the Decide atom gets 403 and a non-requester admin gets 201", ctx do
    golden = File.read!("priv/permission_matrix/effective.golden")

    for role <- ~w(TASK_WORKER PROCESS_OPERATOR) do
      assert golden =~ ~r/^#{role} ProcurementRequestDecide false module:procurement /m
    end

    path = "#{@base}/#{ctx.request.id}/decisions"
    assert call(:post, path, ctx.worker, decision_body(ctx.request)).status == 403
    assert rows(ctx.a) == 0

    conn =
      call(:post, path, ctx.approver, decision_body(ctx.request, %{"idempotency_key" => "a1"}))

    assert conn.status == 201
    assert %{"decision" => "approve", "replayed" => false} = json(conn)

    conn =
      call(:post, path, ctx.approver, decision_body(ctx.request, %{"idempotency_key" => "a1"}))

    assert conn.status == 200
    assert %{"replayed" => true} = json(conn)
    assert rows(ctx.a) == 1
  end

  # The role denial is the Authorize plug's own 403 (it only logs); the scope-enforcement event
  # fires for tenants with scope enforcement on and is not what this path emits. Module code never
  # runs, so no procurement refusal count and no audit row either.
  test "C2: the router's no-permission 403 writes no audit row and no decision", ctx do
    id = "gh3162-denied-" <> Ecto.UUID.generate()
    test = self()

    :telemetry.attach(
      id,
      [:letflow, :procurement, :refused],
      fn _event, _measurements, _metadata, _config -> send(test, :refused) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    audits = Repo.aggregate(Letflow.Audit.Entry, :count, prefix: ctx.a.schema)

    path = "#{@base}/#{ctx.request.id}/decisions"
    assert call(:post, path, ctx.worker, decision_body(ctx.request)).status == 403
    refute_received :refused
    assert Repo.aggregate(Letflow.Audit.Entry, :count, prefix: ctx.a.schema) == audits
    assert rows(ctx.a) == 0
  end

  test "A2: a requester cannot decide their own request", ctx do
    path = "#{@base}/#{ctx.request.id}/decisions"
    conn = call(:post, path, ctx.admin, decision_body(ctx.request))
    assert conn.status == 403
    assert %{"reason" => "self_decision"} = json(conn)
    assert rows(ctx.a) == 0

    assert call(:post, path, ctx.approver, decision_body(ctx.request)).status == 201
  end

  test "A3: a requester cannot submit or revise someone else's request", ctx do
    {:ok, %{document_id: id}} =
      PurchaseRequests.create(ctx.a.schema, ctx.approver.user_id, Fixture.params(ctx.a))

    absent = Ecto.UUID.generate()
    submit = %{"version_no" => 1, "idempotency_key" => "s-3"}

    foreign = call(:post, "#{@base}/#{id}/submit", ctx.admin, submit)
    missing = call(:post, "#{@base}/#{absent}/submit", ctx.admin, submit)
    assert foreign.status == 404
    assert foreign.resp_body == missing.resp_body

    foreign = call(:post, "#{@base}/#{id}/revise", ctx.admin, Fixture.params(ctx.a))
    missing = call(:post, "#{@base}/#{absent}/revise", ctx.admin, Fixture.params(ctx.a))
    assert foreign.status == 404
    assert foreign.resp_body == missing.resp_body
  end

  test "A4: absent, malformed and other-tenant ids give identical 404 bodies", ctx do
    other = Fixture.user!(ctx.b, ["TENANT_ADMIN"])
    theirs = Fixture.issued!(ctx.b, other.user_id)
    body = decision_body(ctx.request)

    for {method, suffix, payload} <- [{:get, "", nil}, {:post, "/decisions", body}] do
      bodies =
        for id <- [Ecto.UUID.generate(), "not-a-uuid", theirs.id] do
          conn = call(method, "#{@base}/#{id}#{suffix}", ctx.approver, payload)
          assert conn.status == 404
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
    end

    # a non-requester without Decide cannot read it either: same 404
    worker_read = call(:get, "#{@base}/#{ctx.request.id}", ctx.worker)
    assert worker_read.status == 403
  end

  test "A5: tenant B cannot read or decide tenant A's request by id", ctx do
    outsider = Fixture.user!(ctx.b, ["TENANT_ADMIN"])
    path = "#{@base}/#{ctx.request.id}"

    assert call(:get, path, outsider).status == 404
    assert call(:post, path <> "/decisions", outsider, decision_body(ctx.request)).status == 404
    assert rows(ctx.a) == 0
    assert rows(ctx.b) == 0

    # no route takes a tenant identifier
    for {_method, route, _key} <- Router.__authz_routes__() do
      refute route =~ ~r/tenant|slug/i, route
    end

    # body fields that name a performer or a tenant are ignored
    forged =
      decision_body(ctx.request, %{
        "performer" => ctx.admin.user_id,
        "tenant_id" => ctx.b.tenant_id
      })

    conn = call(:post, path <> "/decisions", ctx.approver, forged)
    assert conn.status == 201
    assert json(conn)["performer"] == ctx.approver.user_id
  end

  test "the decision refusal bodies carry a code and no hash", ctx do
    path = "#{@base}/#{ctx.request.id}/decisions"

    conn = call(:post, path, ctx.approver, decision_body(ctx.request, %{"version_no" => 9}))
    assert conn.status == 422
    assert %{"reason" => "binding_refused"} = json(conn)
    refute conn.resp_body =~ ctx.request.hash

    conn = call(:post, path, ctx.approver, decision_body(ctx.request, %{"decision" => "maybe"}))
    assert conn.status == 422
    assert %{"reason" => "validation"} = json(conn)

    conn =
      call(:post, path, ctx.approver, decision_body(ctx.request, %{"idempotency_key" => "z"}))

    assert conn.status == 201

    conn =
      call(
        :post,
        path,
        ctx.approver,
        decision_body(ctx.request, %{"idempotency_key" => "z", "decision" => "reject"})
      )

    assert conn.status == 409
    assert %{"reason" => "idempotency_key_reused"} = json(conn)
  end

  test "P2: the five routes are declared with their permissions", _ctx do
    routes = Router.__authz_routes__() |> Enum.map(fn {m, p, k} -> {m, p, k} end) |> Enum.sort()

    assert routes == [
             {"GET", "/purchase-requests/:id", :ProcurementRequestRead},
             {"POST", "/purchase-requests", :ProcurementRequestWrite},
             {"POST", "/purchase-requests/:id/decisions", :ProcurementRequestDecide},
             {"POST", "/purchase-requests/:id/revise", :ProcurementRequestWrite},
             {"POST", "/purchase-requests/:id/submit", :ProcurementRequestWrite}
           ]
  end
end
