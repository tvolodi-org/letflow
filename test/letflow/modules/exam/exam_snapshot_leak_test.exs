defmodule Letflow.Modules.Exam.ExamSnapshotLeakTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` sections
  8.4, 12.4 (T-30) and 18.2 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`): after a full candidate
  flow (start, state, autosave, anti-cheat signal, submit, certificate, download, public
  projection), no route a tenant caller can read returns the session's `exam_snapshot`, its nonce,
  its digest, the `correct_option_ids` key, or an answer-key flag.

  Probes use a TASK_WORKER, a TENANT_AUDITOR and a TENANT_ADMIN token of the same tenant (PR-0 #2697
  and PR-0b #2702 are merged):

    1. the Instances GET routes that take an id, for the session's synthetic entity-type instance
       AND for an `answer_option` one: byte-identical to a random uuid's answer, and a 404 where
       the route is not an attachment route (the PR-0b rule); the list omits both;
    2. `POST /entities/query` (plain), `/aggregate` and `/records/session/export` (default mode);
       the join variant is T-27 in `snapshot_restrictions_test.exs`;
    3. `GET /audit`, `GET /promotions/platform-events`, a process script's read through the entity
       port (`ScriptReads`);
    4. the `PUT /entities/records/session/:id` response and its error bodies never echo the PRIOR
       snapshot (done last: a full-replacement write drops the field);
    5. the public certificate projection.

  The route list is closed by an inventory assertion on `Letflow.Routers.Instances`: a new GET
  route that takes an instance id fails the test until it is probed here.

  Comparisons are on status, body and headers (the request id and `date` are masked, the trace id
  is pinned); a failure message never prints a body.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.EntityPortImpl
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.ScriptPolicyFixture, as: SP

  @base "/api/v1/modules/exam/exam-sessions"
  @fixed_trace "00000000-0000-4000-8000-0000000000cc"
  @attachment_id "7f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b"
  @masked_headers ["x-request-id", "date"]

  # {route template as declared in Letflow.Routers.Instances, roles that probe it, expectation}
  @instance_get_walk [
    {"/:id", [:worker, :auditor], :not_found},
    {"/:id/history", [:worker, :auditor], :not_found},
    {"/:id/timeline", [:worker, :auditor], :not_found},
    {"/:id/pins", [:worker, :auditor], :not_found},
    {"/:id/attachments", [:admin], :same},
    {"/:id/attachments/:attachment_id", [:admin], :same},
    {"/:id/attachments/:attachment_id/link-content", [:admin], :same}
  ]

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(token, slug, method, path, body \\ nil) do
    base =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    base
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", slug)
    |> put_req_header("x-trace-id", @fixed_trace)
    |> dispatch()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp mint_token!(schema, roles), do: schema |> mint_token_and_user!(roles) |> elem(0)

  defp mint_token_and_user!(schema, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2682-leak-#{Ecto.UUID.generate()}",
        display_name: "GH2682 Leak Test User",
        email: "gh2682-leak-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    {plaintext, user.id}
  end

  defp normalised(conn, id) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {key, _} -> key in @masked_headers end)
      |> Enum.sort()

    {conn.status, String.replace(conn.resp_body, id, "<ID>"), headers}
  end

  # One flow, run once for the whole file's scenarios would hide a failure in setup; a setup per
  # test is slower but each test then stands on its own.
  defp flow! do
    %{tenant_id: tenant_id, schema_name: schema} =
      Fx.provisioned_tenant_with_exam_definitions(
        "gh2682-t30-#{System.unique_integer([:positive])}"
      )

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)

    {admin_token, admin_id} = mint_token_and_user!(schema, ["TENANT_ADMIN"])

    tokens = %{
      candidate: mint_token!(schema, ["CANDIDATE"]),
      worker: mint_token!(schema, ["TASK_WORKER"]),
      auditor: mint_token!(schema, ["TENANT_AUDITOR"]),
      admin: admin_token
    }

    category_id = Ecto.UUID.generate()

    exam =
      Fx.create_record!(schema, "exam", %{
        "title" => %{"en" => "Leak Exam"},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 5,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => true
      })

    question =
      Fx.create_record!(schema, "question", %{
        "category_id" => category_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"},
        "explanation" => %{"en" => "EXPLANATION-MARKER-2682"}
      })

    [correct_id, _wrong_id] =
      for {sort_order, correct?} <- [{0, true}, {1, false}] do
        Fx.create_record!(schema, "answer_option", %{
          "question_id" => question.record_id,
          "sort_order" => sort_order,
          "is_correct" => correct?,
          "text" => %{"en" => "Option #{sort_order}"}
        }).record_id
      end

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    candidate = fn method, path, body -> request(tokens.candidate, slug, method, path, body) end

    started = candidate.("POST", @base, %{"exam_id" => exam.record_id})
    assert started.status == 201
    session_id = json(started)["session"]["id"]

    state = candidate.("GET", "#{@base}/#{session_id}", nil)

    saved =
      candidate.("PUT", "#{@base}/#{session_id}/answers/#{question.record_id}", %{
        "selected_option_ids" => [correct_id],
        "time_spent_seconds" => 0
      })

    signal = candidate.("POST", "#{@base}/#{session_id}/events", %{"type" => "tab_switch"})
    submitted = candidate.("POST", "#{@base}/#{session_id}/submit", nil)
    certificate = candidate.("POST", "#{@base}/#{session_id}/certificate", nil)
    download = candidate.("GET", "#{@base}/#{session_id}/certificate/download", nil)

    for conn <- [state, saved, signal, submitted, certificate, download] do
      assert conn.status == 200
    end

    public_handle = json(certificate)["public_handle"]

    public =
      conn(:get, "/api/public/certificate/#{public_handle}")
      |> dispatch()

    assert public.status == 200

    snapshot = Fx.session_snapshot(schema, session_id)

    %{
      schema: schema,
      slug: slug,
      tokens: tokens,
      admin_id: admin_id,
      session_id: session_id,
      question_id: question.record_id,
      candidate_conns: [started, state, saved, signal, submitted, certificate, download, public],
      snapshot: snapshot,
      secrets: [snapshot["nonce"], snapshot["digest"]]
    }
  end

  # The strings that must never appear in a tenant-readable body.
  defp assert_no_snapshot_content!(label, %Plug.Conn{resp_body: body}, secrets) do
    leaked =
      Enum.filter(secrets ++ ["correct_option_ids"], &String.contains?(body, &1))

    assert {label, leaked} == {label, []}
  end

  # ── the candidate's own responses ──────────────────────────────────────────────────────────

  describe "T-30: the candidate-facing flow" do
    test "no response of the full flow carries the snapshot, its nonce or digest, or the correct_option_ids key" do
      flow = flow!()

      for {conn, index} <- Enum.with_index(flow.candidate_conns) do
        assert_no_snapshot_content!({:candidate_response, index}, conn, flow.secrets)
      end
    end
  end

  # ── (1) Instances routes ───────────────────────────────────────────────────────────────────

  describe "T-30 (1): the Instances GET routes" do
    test "inventory: every GET route that takes an instance id is probed here" do
      actual =
        Letflow.Routers.Instances.__authz_routes__()
        |> Enum.filter(fn {method, path, _key} ->
          method == "GET" and String.contains?(path, ":id")
        end)
        |> Enum.map(fn {_method, path, _key} -> path end)
        |> Enum.sort()

      assert actual == @instance_get_walk |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "the session's and an answer_option's synthetic instance answer exactly like a random uuid, as 404 on the content routes" do
      flow = flow!()
      {:ok, session_instance} = EntityTypeInstance.fetch_instance_id("session", flow.schema)
      {:ok, option_instance} = EntityTypeInstance.fetch_instance_id("answer_option", flow.schema)

      for {template, roles, expect} <- @instance_get_walk,
          hidden_id <- [session_instance, option_instance],
          role <- roles do
        path = fn id ->
          "/api/v1/instances" <>
            (template
             |> String.replace(":attachment_id", @attachment_id)
             |> String.replace(":id", id))
        end

        hidden = request(flow.tokens[role], flow.slug, "GET", path.(hidden_id))
        random_id = Ecto.UUID.generate()
        random = request(flow.tokens[role], flow.slug, "GET", path.(random_id))

        assert {template, role, normalised(hidden, hidden_id)} ==
                 {template, role, normalised(random, random_id)}

        if expect == :not_found,
          do: assert({template, role, hidden.status} == {template, role, 404})

        assert_no_snapshot_content!({template, role}, hidden, flow.secrets)
      end
    end

    test "GET /instances lists neither synthetic instance and carries no snapshot content" do
      flow = flow!()
      {:ok, session_instance} = EntityTypeInstance.fetch_instance_id("session", flow.schema)
      {:ok, option_instance} = EntityTypeInstance.fetch_instance_id("answer_option", flow.schema)

      for role <- [:worker, :auditor, :admin] do
        conn = request(flow.tokens[role], flow.slug, "GET", "/api/v1/instances?page_size=100")
        assert conn.status == 200

        ids = conn |> json() |> Map.fetch!("items") |> Enum.map(& &1["instance_id"])
        assert {role, session_instance in ids, option_instance in ids} == {role, false, false}
        assert_no_snapshot_content!({:instances_list, role}, conn, flow.secrets)
      end
    end
  end

  # ── (2) entities routes ────────────────────────────────────────────────────────────────────

  describe "T-30 (2): query, aggregate and export" do
    test "plain query: session.exam_snapshot is the sentinel and the answer-key flags are redacted, for all three callers" do
      flow = flow!()
      sentinel = Atom.to_string(FieldGrants.redacted_sentinel())

      for role <- [:worker, :auditor, :admin] do
        sessions =
          request(flow.tokens[role], flow.slug, "POST", "/api/v1/entities/query", %{
            "entity_type" => "session"
          })

        assert {role, sessions.status} == {role, 200}
        assert [item] = json(sessions)["items"]
        assert item["field_values"]["exam_snapshot"] == sentinel
        assert_no_snapshot_content!({:query_session, role}, sessions, flow.secrets)

        options =
          request(flow.tokens[role], flow.slug, "POST", "/api/v1/entities/query", %{
            "entity_type" => "answer_option"
          })

        assert {role, options.status} == {role, 200}

        for option <- json(options)["items"] do
          assert option["field_values"]["is_correct"] == sentinel
        end

        questions =
          request(flow.tokens[role], flow.slug, "POST", "/api/v1/entities/query", %{
            "entity_type" => "question"
          })

        refute questions.resp_body =~ "EXPLANATION-MARKER-2682"
      end
    end

    test "aggregate: a count over sessions carries no snapshot content, and a request naming the field is refused" do
      flow = flow!()

      for role <- [:worker, :auditor, :admin] do
        counted =
          request(flow.tokens[role], flow.slug, "POST", "/api/v1/entities/query/aggregate", %{
            "entity_type" => "session",
            "aggregates" => [%{"fn" => "count"}]
          })

        assert {role, counted.status} == {role, 200}
        assert_no_snapshot_content!({:aggregate, role}, counted, flow.secrets)

        named =
          request(flow.tokens[role], flow.slug, "POST", "/api/v1/entities/query/aggregate", %{
            "entity_type" => "session",
            "aggregates" => [%{"fn" => "count"}],
            "filters" => [%{"field" => "exam_snapshot", "op" => "eq", "value" => "x"}]
          })

        assert {role, named.status in [403, 422]} == {role, true}
        assert_no_snapshot_content!({:aggregate_named, role}, named, flow.secrets)
      end
    end

    test "default-mode export (TENANT_ADMIN, the only core role holding it) redacts exam_snapshot; the others are refused" do
      flow = flow!()
      sentinel = Atom.to_string(FieldGrants.redacted_sentinel())

      export =
        request(
          flow.tokens.admin,
          flow.slug,
          "POST",
          "/api/v1/entities/records/session/export",
          %{}
        )

      assert export.status == 200
      assert [record] = json(export)["records"]
      assert record["field_values"]["exam_snapshot"] == sentinel
      assert_no_snapshot_content!(:export_admin, export, flow.secrets)

      for role <- [:worker, :auditor] do
        refused =
          request(
            flow.tokens[role],
            flow.slug,
            "POST",
            "/api/v1/entities/records/session/export",
            %{}
          )

        assert {role, refused.status} == {role, 403}
        assert_no_snapshot_content!({:export_refused, role}, refused, flow.secrets)
      end
    end
  end

  # ── (3) audit, platform events, script reads ──────────────────────────────────────────────

  describe "T-30 (3): audit entries, platform events and a process script's read" do
    test "GET /audit and GET /promotions/platform-events carry no snapshot content for any of the three callers" do
      flow = flow!()

      for role <- [:worker, :auditor, :admin],
          path <- ["/api/v1/audit?page_size=200", "/api/v1/promotions/platform-events"] do
        conn = request(flow.tokens[role], flow.slug, "GET", path)
        assert_no_snapshot_content!({path, role}, conn, flow.secrets)
      end
    end

    test "a script's read through the entity port omits exam_snapshot for the finished session" do
      flow = flow!()
      :ok = SP.flag_raw!(flow.schema, "session")

      read = SP.id_read("s", "session", ["status", "exam_snapshot", "score_pct"])

      assert {:ok, %{"s" => [row]}} =
               EntityPortImpl.prefetch(flow.schema, [read], %{"cid" => flow.session_id})

      assert row["status"] == "submitted"
      refute Map.has_key?(row, "exam_snapshot")
      refute inspect(row) =~ List.first(flow.secrets)
    end
  end

  # ── (4) the write routes never echo a PRIOR snapshot ───────────────────────────────────────

  describe "T-30 (4): PUT /entities/records/session/:id" do
    test "the response and the error bodies return what the caller sent, never the prior exam_snapshot" do
      flow = flow!()
      path = "/api/v1/entities/records/session/#{flow.session_id}"
      stored = flow.schema |> session_values(flow.session_id) |> Map.delete("exam_snapshot")

      # GH #2784: an actor holding no grant for the restricted `exam_snapshot` is refused every PUT
      # of a `session` outright (PUT replaces `field_values` wholesale): one constant 403, so no
      # response of any shape can carry the prior snapshot.
      refused =
        request(flow.tokens.admin, flow.slug, "PUT", path, %{
          "field_values" => stored,
          "expected_last_event_global_seq" => 0
        })

      assert refused.status == 403
      assert_no_snapshot_content!(:put_ungranted, refused, flow.secrets)

      # the rest of the scenario runs as an admin holding the grant
      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(flow.admin_id),
            entity_type: "session",
            field_name: "exam_snapshot",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: flow.schema
      )

      # a stale version guard: the 409 body is constant
      conflict =
        request(flow.tokens.admin, flow.slug, "PUT", path, %{
          "field_values" => stored,
          "expected_last_event_global_seq" => 0
        })

      assert conflict.status == 409
      assert_no_snapshot_content!(:put_conflict, conflict, flow.secrets)

      # a validation error: the body lists field errors only
      invalid =
        request(flow.tokens.admin, flow.slug, "PUT", path, %{"field_values" => %{"status" => 12}})

      assert invalid.status in [400, 422]
      assert_no_snapshot_content!(:put_invalid, invalid, flow.secrets)

      # a success that omits the snapshot: the response is what was sent
      updated = request(flow.tokens.admin, flow.slug, "PUT", path, %{"field_values" => stored})
      assert updated.status == 200
      assert_no_snapshot_content!(:put_ok, updated, flow.secrets)

      # a hostile caller trying to read it back through the same response: it sends a different
      # snapshot, and gets THAT back, not the stored one
      forged = %{"v" => 1, "origin" => "start", "nonce" => "forged-nonce"}

      echoed =
        request(flow.tokens.admin, flow.slug, "PUT", path, %{
          "field_values" => Map.put(stored, "exam_snapshot", forged)
        })

      assert echoed.status == 200
      assert_no_snapshot_content!(:put_forged, echoed, flow.secrets)
    end
  end

  describe "T-30 (4b): DELETE /entities/records/session/:id" do
    test "an ungranted admin's delete response (and a repeat) never carries the snapshot" do
      flow = flow!()
      path = "/api/v1/entities/records/session/#{flow.session_id}"

      for _attempt <- 1..2 do
        deleted = request(flow.tokens.admin, flow.slug, "DELETE", path)
        assert deleted.status == 200
        assert_no_snapshot_content!(:delete_ungranted, deleted, flow.secrets)

        assert Jason.decode!(deleted.resp_body)["field_values"]["exam_snapshot"] ==
                 "__field_redacted__"
      end
    end
  end

  defp session_values(schema, session_id) do
    assert {:ok, row} = Letflow.Entities.Record.Latest.get(session_id, "session", schema)
    row.field_values
  end
end
