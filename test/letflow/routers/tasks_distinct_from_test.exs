defmodule Letflow.Routers.TasksDistinctFromTest do
  @moduledoc """
  REQ-463 -- the HTTP half of rule A (`distinct_from`): `POST /tasks/:id/complete` and
  `POST /tasks/:id/claim` refuse the user who most recently completed a named node of the same
  instance with ONE constant response, HTTP 403 `application/problem+json`, body exactly
  `{"detail":"separation of duties","status":403}` (design req459 section 4), for every cause
  and on both endpoints; the identity is the authenticated user, token or session alike; no role
  (TENANT_ADMIN included) is exempt; a replay of an accepted completion is today's 409.

  Real Postgres and a real engine instance per test (`Letflow.SodSupport`), two dispatch modes
  as in `tasks_required_outputs_test.exs`: `Letflow.Routers.Tasks.call/2` with a hand-assigned
  `auth_context`, and the FULL `Letflow.Router` pipeline with a real API token and the
  `x-tenant-slug` header. The engine-level cases (rows, audit, rework, parallel, claim clauses,
  query count) live in `test/letflow/engine_distinct_from_test.exs`.

  See `test/specs/REQ-463.md`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.Tasks.init([])
  @n1 S.n1()
  @n2 S.n2()
  @sod_body Letflow.Api.Response.separation_of_duties_body()

  # ── fixtures ────────────────────────────────────────────────────────────

  # U holds role-a and role-b, V holds role-b, W holds role-a only; X holds role-a/b/c (chain).
  defp case!(graph, schemas) do
    ctx = S.new_case!(graph, schemas, %{"seed" => "value"})
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    w = S.insert_user!(ctx.schema_name, "w")
    x = S.insert_user!(ctx.schema_name, "x")
    S.grant_role!(ctx.schema_name, "role-a", [u.id, w.id, x.id])
    S.grant_role!(ctx.schema_name, "role-b", [u.id, v.id, x.id])
    S.grant_role!(ctx.schema_name, "role-c", [x.id])
    Map.merge(ctx, %{u: u, v: v, w: w, x: x})
  end

  defp seq_case!, do: case!(S.seq_graph(%{"distinct_from" => [@n1]}), %{})

  defp post_direct(ctx, user, roles, task, action, body) do
    base = conn(:post, "/#{task.id}/#{action}")

    base =
      if body do
        base |> Map.put(:body_params, body) |> put_req_header("content-type", "application/json")
      else
        base
      end

    base
    |> assign(:auth_context, %{user_id: user.id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, "req463-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, @opts))
  end

  defp post_token(ctx, user, roles, task, action, body) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    conn(:post, "/api/v1/tasks/#{task.id}/#{action}", Jason.encode!(body || %{}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp complete(ctx, user, node_id),
    do: post_direct(ctx, user, ["TASK_WORKER"], S.pending_task!(ctx, node_id), "complete", %{})

  defp claim(ctx, user, node_id),
    do: post_direct(ctx, user, ["TASK_WORKER"], S.pending_task!(ctx, node_id), "claim", nil)

  # status 403, problem+json, the constant body byte for byte, and no identifier anywhere in
  # the body or in any response header.
  defp assert_separation!(conn, forbidden) do
    assert conn.status == 403
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/problem+json")
    assert conn.resp_body == @sod_body

    # the body carries no trace id at all (the full pipeline may add a generic trace HEADER, which
    # is not an identifier of a node, user, instance or tenant)
    refute conn.resp_body =~ "trace"
    headers = inspect(conn.resp_headers)

    for text <- forbidden do
      refute conn.resp_body =~ text, "the separation body leaked #{inspect(text)}"
      refute headers =~ text, "a separation response header leaked #{inspect(text)}"
    end

    conn
  end

  defp forbidden(ctx, user, task) do
    [
      ctx.instance_id,
      task.id,
      user.id,
      user.email,
      user.display_name,
      user.username,
      ctx.slug,
      ctx.tenant_id,
      @n1,
      @n2,
      "role-a",
      "role-b"
    ]
  end

  # ── A-1 / A-2 -- complete ───────────────────────────────────────────────

  describe "POST /tasks/:id/complete" do
    test "A-1: U completes N1 (200); U on N2 is 403 with the fixed body, nothing changed, one PII-free audit row; V completes N2 (200)" do
      ctx = seq_case!()
      assert complete(ctx, ctx.u, @n1).status == 200
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)

      conn =
        post_direct(ctx, ctx.u, ["TASK_WORKER"], n2_task, "complete", %{
          "note" => "SOD-ROUTER-NOTE"
        })

      assert_separation!(conn, forbidden(ctx, ctx.u, n2_task) ++ ["SOD-ROUTER-NOTE"])
      assert S.rows(ctx) == before
      assert S.reload_task!(ctx, n2_task).status == :pending

      assert [entry] = S.refusal_rows(ctx.schema_name)
      assert entry.actor_id == ctx.u.id
      assert entry.after_state["rule"] == "separation_of_duties"
      assert entry.after_state["blocking_node_ids"] == [@n1]
      dump = inspect(entry, limit: :infinity)

      for pii <- [
            ctx.u.email,
            ctx.u.display_name,
            ctx.u.username,
            "SOD-ROUTER-NOTE"
          ] do
        refute dump =~ pii
      end

      ok = complete(ctx, ctx.v, @n2)
      assert ok.status == 200
      assert S.reload_task!(ctx, n2_task).status == :completed
    end

    test "A-2: the body and headers are byte-identical from different triggers (node, user, instance, tenant, endpoint) and carry no identifier" do
      # trigger 1: seq definition, user U, node second-review, complete
      one = seq_case!()
      complete(one, one.u, @n1)
      task_one = S.pending_task!(one, @n2)
      conn_one = post_direct(one, one.u, ["TASK_WORKER"], task_one, "complete", %{})

      # trigger 2: chain definition in ANOTHER tenant, user X, node third-review (two blockers)
      two = case!(S.chain_graph([@n2, @n1]), %{})
      complete(two, two.x, @n1)
      complete(two, two.x, @n2)
      task_two = S.pending_task!(two, "third-review")
      conn_two = post_direct(two, two.x, ["TASK_WORKER"], task_two, "complete", %{})

      # trigger 3: the CLAIM endpoint of trigger 1's task
      conn_three = post_direct(one, one.u, ["TASK_WORKER"], task_one, "claim", nil)

      assert_separation!(conn_one, forbidden(one, one.u, task_one))
      assert_separation!(conn_two, forbidden(two, two.x, task_two) ++ ["third-review"])
      assert_separation!(conn_three, forbidden(one, one.u, task_one))

      assert conn_one.resp_body == conn_two.resp_body
      assert conn_two.resp_body == conn_three.resp_body
      assert conn_one.resp_headers == conn_two.resp_headers
      assert conn_two.resp_headers == conn_three.resp_headers
      assert byte_size(conn_one.resp_body) == byte_size(@sod_body)

      assert %{
               "detail" => "separation of duties",
               "status" => 403,
               "reason" => "separation_of_duties"
             } =
               Jason.decode!(conn_one.resp_body)
    end

    test "default-off: a definition without distinct_from lets U complete N1 and N2 (200 both)" do
      ctx = case!(S.seq_graph(%{}), %{})
      assert complete(ctx, ctx.u, @n1).status == 200
      assert complete(ctx, ctx.u, @n2).status == 200
      assert S.refusal_rows(ctx.schema_name) == []
    end

    test "step 4b precedes 4c: a request violating both separation and required_outputs is 403, not 422; the rule C 422 answers a non-blocked caller" do
      ctx =
        case!(
          S.seq_graph(%{"distinct_from" => [@n1], "required_outputs" => ["decision"]}),
          %{"decision" => %{"type" => "string"}}
        )

      complete(ctx, ctx.u, @n1)
      n2_task = S.pending_task!(ctx, @n2)

      sod = post_direct(ctx, ctx.u, ["TASK_WORKER"], n2_task, "complete", %{})
      assert_separation!(sod, forbidden(ctx, ctx.u, n2_task))

      other = post_direct(ctx, ctx.v, ["TASK_WORKER"], n2_task, "complete", %{})
      assert other.status == 422
      assert Jason.decode!(other.resp_body)["code"] == "output_refused"
    end

    test "A-13: re-POSTing an accepted completion is the existing 409 'task is not pending', not the separation body, and writes no refusal record" do
      ctx = seq_case!()
      n1_task = S.pending_task!(ctx, @n1)
      assert post_direct(ctx, ctx.u, ["TASK_WORKER"], n1_task, "complete", %{}).status == 200

      n2_task = S.pending_task!(ctx, @n2)
      assert post_direct(ctx, ctx.v, ["TASK_WORKER"], n2_task, "complete", %{}).status == 200

      for {user, task} <- [{ctx.u, n1_task}, {ctx.v, n2_task}] do
        replay = post_direct(ctx, user, ["TASK_WORKER"], task, "complete", %{})
        assert replay.status == 409
        assert replay.resp_body =~ "task is not pending"
        refute replay.resp_body == @sod_body
      end

      assert S.refusal_rows(ctx.schema_name) == []
    end

    test "A-15: with audit_entries unavailable the refusal is the same 403 body, does not raise, and logs ONE warning" do
      ctx = seq_case!()
      complete(ctx, ctx.u, @n1)
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)

      Repo.query!(~s(DROP TABLE "#{ctx.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{ctx.schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      {conn, log} =
        with_log([level: :warning], fn ->
          post_direct(ctx, ctx.u, ["TASK_WORKER"], n2_task, "complete", %{})
        end)

      assert_separation!(conn, forbidden(ctx, ctx.u, n2_task))
      assert S.rows(ctx) == before
      assert length(Regex.scan(~r/recording task\.completion_refused/, log)) == 1
    end
  end

  # ── A-3 -- claim ────────────────────────────────────────────────────────

  describe "POST /tasks/:id/claim" do
    test "U is refused with the same 403 body, nothing written and NO audit row; V (eligible) claims 200" do
      ctx = seq_case!()
      complete(ctx, ctx.u, @n1)
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)
      audit_before = S.audit_count(ctx.schema_name)

      conn = post_direct(ctx, ctx.u, ["TASK_WORKER"], n2_task, "claim", nil)

      assert_separation!(conn, forbidden(ctx, ctx.u, n2_task))
      assert S.rows(ctx) == before
      assert S.audit_count(ctx.schema_name) == audit_before
      assert S.refusal_rows(ctx.schema_name) == []

      ok = post_direct(ctx, ctx.v, ["TASK_WORKER"], n2_task, "claim", nil)
      assert ok.status == 200
      assert S.reload_task!(ctx, n2_task).assignee_ref == ctx.v.id
    end

    test "a caller who is not eligible gets the EXISTING claim refusal first, not the separation body (W completed N1 but does not hold role-b)" do
      ctx = seq_case!()
      complete(ctx, ctx.w, @n1)
      n2_task = S.pending_task!(ctx, @n2)

      conn = post_direct(ctx, ctx.w, ["TASK_WORKER"], n2_task, "claim", nil)

      assert conn.status == 409
      refute conn.resp_body == @sod_body
      refute conn.resp_body =~ "separation"
    end

    test "default-off: a definition without distinct_from gains no claim failure (U completed N1 and still claims N2: 200)" do
      ctx = case!(S.seq_graph(%{}), %{})
      complete(ctx, ctx.u, @n1)
      assert claim(ctx, ctx.u, @n2).status == 200
    end
  end

  # ── A-4 -- API token ────────────────────────────────────────────────────

  describe "A-4 -- API token through the full Letflow.Router pipeline" do
    test "U's token: complete N2 and claim N2 are 403 with the fixed body; another user's token completes N2 (200)" do
      ctx = seq_case!()
      n1_task = S.pending_task!(ctx, @n1)
      assert post_token(ctx, ctx.u, ["TASK_WORKER"], n1_task, "complete", %{}).status == 200
      n2_task = S.pending_task!(ctx, @n2)
      before = S.rows(ctx)

      refused = post_token(ctx, ctx.u, ["TASK_WORKER"], n2_task, "complete", %{})
      assert_separation!(refused, forbidden(ctx, ctx.u, n2_task))

      refused_claim = post_token(ctx, ctx.u, ["TASK_WORKER"], n2_task, "claim", nil)
      assert_separation!(refused_claim, forbidden(ctx, ctx.u, n2_task))

      # only the one audit row of the completion refusal; the claim wrote none
      assert [_one] = S.refusal_rows(ctx.schema_name)
      assert S.rows(ctx) == before

      ok = post_token(ctx, ctx.v, ["TASK_WORKER"], n2_task, "complete", %{})
      assert ok.status == 200
      assert S.reload_task!(ctx, n2_task).completed_by == ctx.v.id
    end
  end

  # ── A-5 -- TENANT_ADMIN is not exempt ───────────────────────────────────

  describe "A-5 -- TENANT_ADMIN is not exempt (REQ-447 PR2)" do
    test "a TENANT_ADMIN who completed N1 is refused on N2 (complete and claim); a different TENANT_ADMIN completes it" do
      ctx = seq_case!()
      admin = ["TENANT_ADMIN"]

      assert post_direct(ctx, ctx.u, admin, S.pending_task!(ctx, @n1), "complete", %{}).status ==
               200

      n2_task = S.pending_task!(ctx, @n2)

      assert_separation!(
        post_direct(ctx, ctx.u, admin, n2_task, "complete", %{}),
        forbidden(ctx, ctx.u, n2_task)
      )

      assert_separation!(
        post_direct(ctx, ctx.u, admin, n2_task, "claim", nil),
        forbidden(ctx, ctx.u, n2_task)
      )

      assert S.reload_task!(ctx, n2_task).status == :pending

      # control: the exemption is not inverted -- another TENANT_ADMIN is accepted
      assert post_direct(ctx, ctx.v, admin, n2_task, "complete", %{}).status == 200
    end

    test "the same through the full pipeline with a TENANT_ADMIN API token" do
      ctx = seq_case!()
      admin = ["TENANT_ADMIN"]

      assert post_token(ctx, ctx.u, admin, S.pending_task!(ctx, @n1), "complete", %{}).status ==
               200

      n2_task = S.pending_task!(ctx, @n2)

      assert_separation!(
        post_token(ctx, ctx.u, admin, n2_task, "complete", %{}),
        forbidden(ctx, ctx.u, n2_task)
      )

      assert post_token(ctx, ctx.v, admin, n2_task, "complete", %{}).status == 200
    end
  end

  test "the task row of a refused request is untouched in every router path (spot check on the EngineTask row)" do
    ctx = seq_case!()
    complete(ctx, ctx.u, @n1)
    n2_task = S.pending_task!(ctx, @n2)

    post_direct(ctx, ctx.u, ["TASK_WORKER"], n2_task, "complete", %{})
    post_direct(ctx, ctx.u, ["TASK_WORKER"], n2_task, "claim", nil)

    assert Repo.get!(EngineTask, n2_task.id, prefix: ctx.schema_name) == n2_task
  end
end
