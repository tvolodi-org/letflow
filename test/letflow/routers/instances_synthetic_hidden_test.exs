defmodule Letflow.Routers.InstancesSyntheticHiddenTest do
  @moduledoc """
  GH #2702 (PR-0b): every Instances route that takes an instance id answers a SYNTHETIC
  entity-type instance (and the platform sentinel id) exactly like a nonexistent id, never
  mutates it, and leaves real workflow instances untouched.

  Design: `lib/letflow/design/gh2702-hide-synthetic-instances.md` section 6 (T2, T2b, T3,
  T4, T5, T6, T8). The reconstruct guard was narrowed after review: it refuses ONLY
  synthetic ids and the platform sentinel id (INV-RC-2 stays: an absent id or a real
  instance whose projection row was deleted still reconstructs / answers from the log).

  Real HTTP through `Letflow.Router` (bearer token + `x-tenant-slug`), so authorization,
  parsing and rendering are all exercised. Comparisons are on status, body and the FULL
  response headers; only the request id and `date` headers are masked, the trace id is
  pinned by sending a fixed `x-trace-id`, and the instance id itself is masked where a
  success body echoes it. Failure messages never print a response body.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @fixed_trace "00000000-0000-4000-8000-0000000000aa"
  @attachment_id "7f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b"
  @masked_headers ["x-request-id", "date"]

  # {method, route template (as declared in the router), roles that probe it, expectation}
  # expectation :not_found -> the nonexistent-id answer is a 404 and so must the synthetic one be;
  # :same -> only equality with the nonexistent-id answer is asserted (attachment routes, F4).
  @walk [
    {"GET", "/:id", [:worker, :auditor], :not_found},
    {"GET", "/:id/history", [:worker, :auditor], :not_found},
    {"GET", "/:id/timeline", [:worker, :auditor], :not_found},
    {"GET", "/:id/pins", [:worker, :auditor], :not_found},
    {"GET", "/:id/attachments", [:admin], :same},
    {"GET", "/:id/attachments/:attachment_id", [:admin], :same},
    {"GET", "/:id/attachments/:attachment_id/link-content", [:admin], :same},
    {"POST", "/:id/attachments", [:admin], :upload},
    {"POST", "/:id/attachments/:attachment_id/link", [:admin], :same},
    {"DELETE", "/:id/attachments/:attachment_id", [:admin], :same},
    {"POST", "/:id/rebind-pins", [:admin], :not_found},
    {"POST", "/:id/cancel", [:admin], :not_found},
    {"POST", "/:id/reconstruct", [:admin], :not_found},
    {"POST", "/:id/advance-timer", [:admin], :not_found}
  ]

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "synthetic-hidden-#{Ecto.UUID.generate()}",
      display_name: "Synthetic Hidden Test User",
      email: "synthetic-hidden-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp token!(user, tenant, role) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [role], expires_at: nil},
        prefix: tenant.schema_name
      )

    plaintext
  end

  defp create_active_entity!(ctx_like, name) do
    {:ok, entity_definition} =
      EntityDefinitions.create_definition(
        %{
          definition: %{
            name: name,
            display_name: String.capitalize(name),
            fields: [%{name: "label", type: :string, queried: true}]
          },
          created_by: ctx_like.user_id
        },
        ctx_like.schema_name
      )

    {:ok, _} =
      EntityDefinitions.activate_definition(
        entity_definition.name,
        ctx_like.user_id,
        "gh2702 go-live",
        ctx_like.schema_name
      )

    :ok
  end

  defp write_record!(ctx, entity_type, label) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: %{"label" => label},
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  # One tenant, three bearer tokens, two entity types with one record each (=> two synthetic
  # instances), nothing else.
  defp ctx! do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2702-hidden",
        display_name: "GH2702 Synthetic Hidden Test Tenant"
      )

    {:ok, _} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    ctx = %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      user_id: user.id,
      tokens: %{
        admin: token!(user, tenant, "TENANT_ADMIN"),
        worker: token!(user, tenant, "TASK_WORKER"),
        auditor: token!(user, tenant, "TENANT_AUDITOR")
      }
    }

    create_active_entity!(ctx, "widget")
    create_active_entity!(ctx, "gadget")
    write_record!(ctx, "widget", "w1")
    write_record!(ctx, "gadget", "g1")

    {:ok, widget_id} = EntityTypeInstance.fetch_instance_id("widget", ctx.schema_name)
    {:ok, gadget_id} = EntityTypeInstance.fetch_instance_id("gadget", ctx.schema_name)

    Map.merge(ctx, %{widget_id: widget_id, gadget_id: gadget_id})
  end

  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp real_definition!(ctx) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: "gh2702-def-" <> to_string(System.unique_integer([:positive])),
          version: "1.0.0",
          graph: graph_human_task_end(),
          created_by: Ecto.UUID.generate()
        },
        prefix: ctx.schema_name
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: ctx.schema_name)
    activated
  end

  defp start_real_instance!(ctx, definition) do
    {:ok, result} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "start-" <> to_string(System.unique_integer([:positive]))
        },
        prefix: ctx.schema_name
      )

    result.instance_id
  end

  # ── HTTP helpers ────────────────────────────────────────────────────────────

  defp request(ctx, role, method, path, opts \\ []) do
    body = Keyword.get(opts, :body)
    content_type = Keyword.get(opts, :content_type, "application/json")

    payload =
      case body do
        nil -> nil
        %{} = map -> Jason.encode!(map)
        raw when is_binary(raw) -> raw
      end

    base = if payload, do: conn(method, path, payload), else: conn(method, path)

    base
    |> then(fn c -> if payload, do: put_req_header(c, "content-type", content_type), else: c end)
    |> put_req_header("authorization", "Bearer " <> Map.fetch!(ctx.tokens, role))
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", @fixed_trace)
    |> then(fn c ->
      Enum.reduce(Keyword.get(opts, :headers, []), c, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)
    end)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp api(template, id) do
    "/api/v1/instances" <>
      (template |> String.replace(":attachment_id", @attachment_id) |> String.replace(":id", id))
  end

  defp multipart_body do
    "--gh2702b\r\n" <>
      "Content-Disposition: form-data; name=\"file\"; filename=\"doc.txt\"\r\n" <>
      "Content-Type: text/plain\r\n\r\nhello\r\n--gh2702b--\r\n"
  end

  defp row_opts("POST", "/:id/rebind-pins", _expect), do: [body: rebind_body()]
  defp row_opts("POST", "/:id/advance-timer", _expect), do: [body: %{}]
  defp row_opts("POST", "/:id/attachments/:attachment_id/link", _expect), do: [body: %{}]

  defp row_opts("POST", "/:id/attachments", :upload),
    do: [body: multipart_body(), content_type: "multipart/form-data; boundary=gh2702b"]

  defp row_opts(_method, _template, _expect), do: []

  defp rebind_body do
    %{
      "reason" => "gh2702 probe",
      "entries" => [%{"kind" => "catalog_entry", "ref" => "x", "version" => "1.0.0"}]
    }
  end

  @uuid_re ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
  @ts_re ~r/\d{4}-\d{2}-\d{2}T[\d:.]+Z?/

  # status + body + FULL headers; only request id / date masked, the instance id masked in the body.
  defp normalised(conn, id, mask_all_ids? \\ false) do
    body = String.replace(conn.resp_body, id, "<ID>")

    body =
      if mask_all_ids? do
        body
        |> then(&Regex.replace(@uuid_re, &1, "<UUID>"))
        |> then(&Regex.replace(@ts_re, &1, "<TS>"))
      else
        body
      end

    headers =
      conn.resp_headers
      |> Enum.reject(fn {k, _} -> k in @masked_headers end)
      |> Enum.sort()

    {conn.status, body, headers}
  end

  defp walk_one(ctx, {method, template, roles, expect}, id) do
    for role <- roles do
      conn = request(ctx, role, method, api(template, id), row_opts(method, template, expect))
      {role, normalised(conn, id, expect == :upload)}
    end
  end

  defp assert_row_hidden!(ctx, {method, template, _roles, expect} = row, hidden_id) do
    random_id = Ecto.UUID.generate()
    hidden = walk_one(ctx, row, hidden_id)
    random = walk_one(ctx, row, random_id)

    # Boolean probes: a mismatch names the row and never prints a body.
    assert {method, template, hidden == random} == {method, template, true}

    if expect == :not_found do
      assert {method, template, Enum.map(hidden, fn {_role, {status, _, _}} -> status end)} ==
               {method, template, List.duplicate(404, length(hidden))}
    end
  end

  defp count_queries(fun) do
    counter = :counters.new(1, [])
    handler = "gh2702-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == test_pid, do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  # Measures a hidden/random request pair. `Identity.touch_last_used_and_verify/2`
  # truncates to the second and Ecto only issues `UPDATE api_tokens SET last_used_at`
  # when the value changed, so whichever request first runs in a new wall-clock second
  # pays one extra query (GH #2729). Pinning is racy (the second can roll after the
  # pin), so instead: warm up both routes inside the attempt, record the second before
  # and after the measured pair, and if it was crossed retry the whole pair (max 5).
  # An attempt that stayed inside one second is returned as-is and must satisfy the
  # caller's unchanged assertion; a crossed final attempt is returned too (and fails
  # honestly rather than being masked).
  defp measure_pair(warmup, hidden_fun, random_fun, attempts \\ 5) do
    # The boundary check must cover the warm-up too: its last request touches last_used_at
    # partway through, so a roll between that touch and a later clock read would charge the
    # first measured request the extra UPDATE without being detected.
    second_before = System.os_time(:second)
    warmup.()
    {hidden, hidden_queries} = count_queries(hidden_fun)
    {random, random_queries} = count_queries(random_fun)
    crossed? = System.os_time(:second) != second_before

    if crossed? and hidden_queries != random_queries and attempts > 1 do
      measure_pair(warmup, hidden_fun, random_fun, attempts - 1)
    else
      {{hidden, hidden_queries}, {random, random_queries}}
    end
  end

  defp idempotency_count(ctx),
    do: Repo.aggregate(IdempotencyRecord, :count, prefix: ctx.schema_name)

  defp event_summary(ctx, instance_id) do
    rows =
      from(e in Event,
        where: e.instance_id == ^instance_id,
        order_by: e.sequence_number,
        select: {e.sequence_number, e.event_type}
      )
      |> Repo.all(prefix: ctx.schema_name)

    {length(rows), rows}
  end

  defp projection(ctx, id), do: Repo.get!(InstanceProjection, id, prefix: ctx.schema_name)

  # ── route inventory ────────────────────────────────────────────────────────

  describe "route inventory" do
    test "every router route that takes an instance id has a decision in the walk" do
      actual =
        Letflow.Routers.Instances.__authz_routes__()
        |> Enum.filter(fn {_method, path, _key} -> String.contains?(path, ":id") end)
        |> Enum.map(fn {method, path, _key} -> {method, path} end)
        |> Enum.sort()

      walked = @walk |> Enum.map(fn {m, t, _r, _e} -> {m, t} end) |> Enum.sort()

      assert actual == walked
    end
  end

  # ── T1 / T2 / T4 / T8: hidden everywhere ───────────────────────────────────

  describe "T2 route walk: synthetic id vs random UUID" do
    test "each id route answers the synthetic widget and gadget instances like a nonexistent id" do
      ctx = ctx!()

      for row <- @walk, hidden_id <- [ctx.widget_id, ctx.gadget_id] do
        assert_row_hidden!(ctx, row, hidden_id)
      end
    end

    test "GET /instances omits both synthetic instances" do
      ctx = ctx!()

      for role <- [:worker, :auditor, :admin] do
        conn = request(ctx, role, "GET", "/api/v1/instances?page_size=100")
        assert conn.status == 200

        ids =
          conn.resp_body
          |> Jason.decode!()
          |> Map.fetch!("items")
          |> Enum.map(& &1["instance_id"])

        assert {ctx.widget_id in ids, ctx.gadget_id in ids} == {false, false}
      end
    end
  end

  describe "T4 platform sentinel" do
    test "after a real platform event exists every id route still answers like a nonexistent id" do
      ctx = ctx!()

      type_name = "GH2702_PLATFORM_" <> to_string(System.unique_integer([:positive]))

      {:ok, _} =
        Registry.register_type(
          %{
            "name" => type_name,
            "schema_version" => 1,
            "json_schema" => %{"type" => "object"},
            "description" => "GH2702 platform sentinel probe"
          },
          ctx.tenant_id
        )

      assert {:ok, %{is_duplicate: false}} =
               EventStore.append_platform_event(
                 %{
                   instance_id: EventStore.platform_instance_id(),
                   event_type: type_name,
                   payload: Jason.encode!(%{}),
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: "gh2702-platform-" <> Ecto.UUID.generate()
                 },
                 prefix: ctx.schema_name
               )

      # the sentinel now owns a non-empty event log (reconstruct used to answer 500 here)
      assert {_count, [_ | _]} = event_summary(ctx, EventStore.platform_instance_id())

      for row <- @walk do
        assert_row_hidden!(ctx, row, EventStore.platform_instance_id())
      end
    end
  end

  # ── T2b: wider INV-5 ───────────────────────────────────────────────────────

  describe "T2b INV-5 comparisons" do
    test "(i) a replayed Idempotency-Key on cancel and rebind-pins: replay equals first call, equals the nonexistent id's, stores nothing" do
      ctx = ctx!()
      key = [{"idempotency-key", "gh2702-replay-key"}]

      for {template, opts} <- [
            {"/:id/cancel", [headers: key]},
            {"/:id/rebind-pins", [headers: key, body: rebind_body()]}
          ] do
        before_count = idempotency_count(ctx)

        for hidden_id <- [ctx.widget_id] do
          random_id = Ecto.UUID.generate()

          first_h = request(ctx, :admin, "POST", api(template, hidden_id), opts)
          replay_h = request(ctx, :admin, "POST", api(template, hidden_id), opts)
          first_r = request(ctx, :admin, "POST", api(template, random_id), opts)
          replay_r = request(ctx, :admin, "POST", api(template, random_id), opts)

          assert {template, normalised(first_h, hidden_id) == normalised(replay_h, hidden_id),
                  normalised(replay_h, hidden_id) == normalised(replay_r, random_id),
                  normalised(first_r, random_id) == normalised(replay_r, random_id)} ==
                   {template, true, true, true}

          assert replay_h.status == 404
        end

        assert {template, idempotency_count(ctx)} == {template, before_count}
      end
    end

    test "(ii) the 403 case (TASK_WORKER lacks the mutation permissions) is identical for synthetic and nonexistent ids" do
      ctx = ctx!()

      for {template, opts} <- [
            {"/:id/cancel", []},
            {"/:id/rebind-pins", [body: rebind_body()]},
            {"/:id/reconstruct", []},
            {"/:id/advance-timer", [body: %{}]}
          ] do
        random_id = Ecto.UUID.generate()
        hidden = request(ctx, :worker, "POST", api(template, ctx.widget_id), opts)
        random = request(ctx, :worker, "POST", api(template, random_id), opts)

        assert {template, hidden.status,
                normalised(hidden, ctx.widget_id) == normalised(random, random_id)} ==
                 {template, 403, true}
      end
    end

    test "(iii) 422 cases (over-long Idempotency-Key, bad entries) are identical for synthetic and nonexistent ids" do
      ctx = ctx!()
      too_long = [{"idempotency-key", String.duplicate("k", 400)}]

      for {template, opts} <- [
            {"/:id/cancel", [headers: too_long]},
            {"/:id/rebind-pins", [headers: too_long, body: rebind_body()]},
            {"/:id/rebind-pins", [body: %{"reason" => "x", "entries" => "not-a-list"}]},
            {"/:id/rebind-pins", [body: %{"entries" => []}]}
          ] do
        random_id = Ecto.UUID.generate()
        hidden = request(ctx, :admin, "POST", api(template, ctx.widget_id), opts)
        random = request(ctx, :admin, "POST", api(template, random_id), opts)

        assert {template, hidden.status,
                normalised(hidden, ctx.widget_id) == normalised(random, random_id)} ==
                 {template, 422, true}
      end
    end

    test "(iv) a non-object JSON body with a synthetic id equals the same body with a nonexistent id" do
      ctx = ctx!()

      for template <- ["/:id/rebind-pins", "/:id/advance-timer"] do
        # valid JSON that is not an object: Plug.Parsers raises on invalid JSON before any route code
        opts = [body: "[1, 2]", content_type: "application/json"]
        random_id = Ecto.UUID.generate()
        hidden = request(ctx, :admin, "POST", api(template, ctx.widget_id), opts)
        random = request(ctx, :admin, "POST", api(template, random_id), opts)

        assert {template, hidden.status in 400..499,
                normalised(hidden, ctx.widget_id) == normalised(random, random_id)} ==
                 {template, true, true}
      end
    end

    test "(v) equal DB query count for synthetic vs nonexistent ids on get, history, timeline, cancel and rebind-pins" do
      ctx = ctx!()

      probes = [
        {:worker, "GET", "/:id", []},
        {:worker, "GET", "/:id/history", []},
        {:worker, "GET", "/:id/timeline", []},
        {:admin, "POST", "/:id/cancel", []},
        {:admin, "POST", "/:id/rebind-pins", [body: rebind_body()]}
      ]

      for {role, method, template, opts} <- probes do
        random_id = Ecto.UUID.generate()

        hidden_fun = fn -> request(ctx, role, method, api(template, ctx.widget_id), opts) end
        random_fun = fn -> request(ctx, role, method, api(template, random_id), opts) end

        # warm-up (inside measure_pair): first request of a route may populate caches
        {{hidden, hidden_queries}, {random, random_queries}} =
          measure_pair(
            fn ->
              hidden_fun.()
              random_fun.()
            end,
            hidden_fun,
            random_fun
          )

        assert {template, hidden.status, hidden_queries > 0} == {template, 404, true}
        assert {template, hidden_queries} == {template, random_queries}
        assert random.status == 404
      end
    end

    test "(v) reconstruct of a synthetic id performs no replay reads: never more queries than a nonexistent id" do
      ctx = ctx!()
      random_id = Ecto.UUID.generate()
      path = fn id -> api("/:id/reconstruct", id) end

      hidden_fun = fn -> request(ctx, :admin, "POST", path.(ctx.widget_id)) end
      random_fun = fn -> request(ctx, :admin, "POST", path.(random_id)) end

      {{_, hidden_queries}, {_, random_queries}} =
        measure_pair(
          fn ->
            hidden_fun.()
            random_fun.()
          end,
          hidden_fun,
          random_fun
        )

      assert hidden_queries <= random_queries
    end
  end

  # ── T3: mutating routes leave the synthetic instance untouched ─────────────

  describe "T3 mutating routes do not touch a synthetic instance" do
    test "cancel, rebind-pins, reconstruct and advance-timer change nothing; record writes still work" do
      ctx = ctx!()
      before_projection = projection(ctx, ctx.widget_id)
      before_events = event_summary(ctx, ctx.widget_id)
      before_idempotency = idempotency_count(ctx)

      for {template, opts} <- [
            {"/:id/cancel", []},
            {"/:id/rebind-pins", [body: rebind_body()]},
            {"/:id/reconstruct", []},
            {"/:id/advance-timer", [body: %{}]}
          ] do
        conn = request(ctx, :admin, "POST", api(template, ctx.widget_id), opts)
        assert {template, conn.status} == {template, 404}
      end

      after_projection = projection(ctx, ctx.widget_id)

      assert {after_projection.status, after_projection.cancelled_at} == {:active, nil}
      assert after_projection == before_projection
      assert event_summary(ctx, ctx.widget_id) == before_events
      assert idempotency_count(ctx) == before_idempotency

      {_count, events} = event_summary(ctx, ctx.widget_id)
      types = Enum.map(events, fn {_seq, type} -> type end)
      assert {"INSTANCE_CANCELLED" in types, "INSTANCE_PINS_REBOUND" in types} == {false, false}

      # the DoS this closes: a cancelled synthetic instance refuses every later record write
      assert %{record_id: _} = write_record!(ctx, "widget", "w2")
    end
  end

  # ── T5 / T8: real workflow instances are unchanged ─────────────────────────

  describe "T5 control: a real workflow instance behaves as before" do
    test "list, get, history, timeline, pins and cancel work and are listed beside hidden synthetic ones" do
      ctx = ctx!()
      id = start_real_instance!(ctx, real_definition!(ctx))

      list = request(ctx, :worker, "GET", "/api/v1/instances?page_size=100")

      ids =
        list.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["instance_id"])

      assert {id in ids, ctx.widget_id in ids, ctx.gadget_id in ids} == {true, false, false}

      get = request(ctx, :worker, "GET", api("/:id", id))
      assert get.status == 200
      assert Jason.decode!(get.resp_body)["instance_id"] == id

      history = request(ctx, :worker, "GET", api("/:id/history", id))
      assert history.status == 200

      event_types =
        history.resp_body
        |> Jason.decode!()
        |> Map.fetch!("items")
        |> Enum.map(& &1["event_type"])

      assert "INSTANCE_STARTED" in event_types

      for template <- ["/:id/timeline", "/:id/pins"] do
        conn = request(ctx, :worker, "GET", api(template, id))
        assert {template, conn.status} == {template, 200}
      end

      cancel = request(ctx, :admin, "POST", api("/:id/cancel", id))
      assert cancel.status == 200
      assert Jason.decode!(cancel.resp_body)["status"] == "CANCELLED"
      assert projection(ctx, id).status == :cancelled
    end

    test "T8 pagination stays exact: 3 real + 4 synthetic (2 newer than the real ones) instances, page_size=2" do
      ctx = ctx!()
      definition = real_definition!(ctx)
      real_ids = for _ <- 1..3, do: start_real_instance!(ctx, definition)

      # Two MORE synthetic instances created AFTER the real ones: the list orders by
      # started_at desc, so these sort FIRST and a post-limit filter would return a short
      # (or empty) first page. The ctx's own widget/gadget are older and sort last.
      for name <- ["latea", "lateb"] do
        create_active_entity!(ctx, name)
        write_record!(ctx, name, name)
      end

      page = fn cursor ->
        suffix = if cursor, do: "&cursor=" <> URI.encode_www_form(cursor), else: ""
        conn = request(ctx, :admin, "GET", "/api/v1/instances?page_size=2" <> suffix)
        assert conn.status == 200
        Jason.decode!(conn.resp_body)
      end

      first = page.(nil)
      assert length(first["items"]) == 2
      assert is_binary(first["next_cursor"])

      second = page.(first["next_cursor"])
      assert length(second["items"]) == 1

      all_ids = Enum.map(first["items"] ++ second["items"], & &1["instance_id"])
      assert Enum.sort(all_ids) == Enum.sort(real_ids)
    end

    test "a real instance whose projection row was deleted still reconstructs (INV-RC-2 is intact)" do
      ctx = ctx!()
      id = start_real_instance!(ctx, real_definition!(ctx))

      Repo.delete_all(from(t in EngineTask, where: t.instance_id == ^id), prefix: ctx.schema_name)

      Repo.delete_all(from(t in TokenRecord, where: t.instance_id == ^id),
        prefix: ctx.schema_name
      )

      Repo.delete_all(from(p in InstanceProjection, where: p.instance_id == ^id),
        prefix: ctx.schema_name
      )

      assert {:ok, _result} = Reconstruction.reconstruct_instance(id, prefix: ctx.schema_name)

      conn = request(ctx, :admin, "POST", api("/:id/reconstruct", id))
      assert conn.status == 200
    end

    test "reconstruct of an absent id is still :instance_not_found; of a synthetic or sentinel id too" do
      ctx = ctx!()

      for id <- [Ecto.UUID.generate(), ctx.widget_id, EventStore.platform_instance_id()] do
        assert {:error, :instance_not_found} =
                 Reconstruction.reconstruct_instance(id, prefix: ctx.schema_name)
      end
    end
  end

  # ── T6: internal callers unaffected ────────────────────────────────────────

  describe "T6 internal callers are unaffected" do
    test "record writes, the projector and get_or_create keep working for a synthetic instance" do
      ctx = ctx!()

      assert {:ok, same_id} = EntityTypeInstance.get_or_create("widget", ctx.schema_name)
      assert same_id == ctx.widget_id

      record = write_record!(ctx, "widget", "w-internal")

      conn =
        request(ctx, :admin, "POST", "/api/v1/entities/query", body: %{"entity_type" => "widget"})

      assert conn.status == 200
      items = conn.resp_body |> Jason.decode!() |> Map.fetch!("items")
      assert record.record_id != nil

      assert Enum.any?(items, fn item ->
               (item["field_values"] || %{})["label"] == "w-internal"
             end)

      # the synthetic instance keeps accumulating events and stays hidden from the client routes
      {count, _} = event_summary(ctx, ctx.widget_id)
      assert count >= 2
      assert request(ctx, :worker, "GET", api("/:id/history", ctx.widget_id)).status == 404
    end
  end
end
