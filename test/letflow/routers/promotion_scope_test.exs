defmodule Letflow.Routers.PromotionScopeTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 items 7 and 8, A2 ENFORCING (spec
  `test/specs/ISS-0993-A2.md`): the twelve routes that used to be declared without a policy key
  (rows 23-34 of design 7.2) carry explicit TENANT-scope keys, and every tenant id a request (or a
  stored review) names must be the caller's own, unless the caller is the platform operator
  (`Letflow.Api.TenantTarget`, `Letflow.Definitions.PromotionAccess`).

  Item 7:

    * every one of the twelve routes: a `TENANT_ADMIN` of an ordinary tenant (and with the pin
      unset) and the platform tenant's own `PLATFORM_ADMIN` reach the handler (not 403); every
      other role gets 403, including (REQ-447 PR 2, legacy removed) a `PLATFORM_ADMIN` of an
      ordinary tenant or with the pin unset, which holds nothing;
    * `POST /promotions` and `/plan` naming a foreign source and/or target (another EXISTING tenant)
      answer the byte-identical 404 of a nonexistent tenant (full body and headers, request-id
      excluded), issue no query against the foreign tenant and write no review;
    * a STORED review naming a foreign source or target (written while the caller was the
      operator) cannot be applied or have its assertions re-run by an ordinary tenant admin: the
      same 404 bytes as a nonexistent review, and no row is written in any schema;
    * the platform operator can plan, submit, approve, apply and promote across tenants;
    * `default_permission_checker` is gone from `lib/` (source scan).

  Item 8 (`GET /promotions/platform-events`): events seeded in another tenant's schema are never
  returned to the caller; the caller sees only its own sentinel events (own-schema read).

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin and query
  telemetry).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionReview
  alias Letflow.EventStore
  alias Letflow.EventStore.Registry
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @unused_uuid "00000000-0000-4000-8000-000000000002"

  # {router, method, concrete local path, body, policy key}   (rows 23-34)
  @rows [
    {Letflow.Routers.Promotions, :post, "/", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/plan", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :get, "/platform-events", nil, :PromotionsRead},
    {Letflow.Routers.Promotions, :get, "/" <> @unused_uuid, nil, :PromotionsRead},
    {Letflow.Routers.Promotions, :get, "/" <> @unused_uuid <> "/context", nil, :PromotionsRead},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/approve", %{},
     :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/reject", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/apply", %{}, :PromotionsManage},
    {Letflow.Routers.Promotions, :post, "/" <> @unused_uuid <> "/run-assertions", %{},
     :PromotionsManage},
    {Letflow.Routers.Promotions, :get, "/", nil, :PromotionsRead},
    {Letflow.Routers.Definitions, :post, "/no-such-process/rollback", %{}, :DefinitionsRollback},
    {Letflow.Routers.Tenants, :post, "/{SOURCE}/promote/no-such-process", nil, :PromotionsManage}
  ]

  defp dispatch(router, conn), do: router.call(conn, router.init([]))

  # `{SOURCE}` is replaced by an existing, provisioned tenant id.
  defp request({router, method, path, body, _key}, fixture, roles, source_id) do
    path = String.replace(path, "{SOURCE}", source_id)
    dispatch(router, Fixture.router_conn(method, path, fixture, roles, body))
  end

  defp promotions(method, path, fixture, roles, body) do
    dispatch(
      Letflow.Routers.Promotions,
      Fixture.router_conn(method, path, fixture, roles, body)
    )
  end

  defp promote(source_id, process_key, fixture, roles) do
    dispatch(
      Letflow.Routers.Tenants,
      Fixture.router_conn(:post, "/#{source_id}/promote/#{process_key}", fixture, roles, nil)
    )
  end

  defp plan_body(source, target, process_key, base_version \\ "1.0.0") do
    %{
      "source_tenant_id" => source,
      "target_tenant_id" => target,
      "process_key" => process_key,
      "base_version" => base_version
    }
  end

  # The bytes a caller can observe: status, body and every header but the request id.
  defp observable(resp) do
    {resp.status, resp.resp_body,
     Enum.reject(resp.resp_headers, &(elem(&1, 0) == "x-request-id"))}
  end

  defp insert_active_definition!(fixture, name, version \\ "1.0.0") do
    definition =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: name,
        version: version,
        graph: %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{"id" => "end", "node_type" => "END"}
          ],
          # the edge id carries the version, so two tenants' definitions of one key differ
          "edges" => [%{"id" => "e-" <> version, "source" => "start", "target" => "end"}]
        },
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{fixture.schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(definition.id)]
             )

    definition
  end

  defp unique_key,
    do: "iss0993-scope-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # Every row of every schema this file can write: definitions, reviews, assertion runs.
  defp snapshot(fixtures) do
    for fixture <- fixtures, into: %{} do
      definitions =
        ProcessDefinition
        |> Repo.all(prefix: fixture.schema_name)
        |> Enum.map(&{&1.id, &1.name, &1.version, &1.status})
        |> Enum.sort()

      reviews =
        PromotionReview
        |> Repo.all(prefix: fixture.schema_name)
        |> Enum.map(&{&1.id, &1.status})
        |> Enum.sort()

      runs = Repo.aggregate(PromotionAssertionRun, :count, :id, prefix: fixture.schema_name)

      {fixture.tenant_id, {definitions, reviews, runs}}
    end
  end

  defp touching(queries, fixture), do: Enum.filter(queries, &Fixture.touches_tenant?(&1, fixture))

  # --- ISS-1042 pooled tenant (design iss1042-pooled-tenant-fixture.md 6.2 adopter audit) ---------
  # Spawned/un-awaited processes (item 1): none -- no Task, spawn, start_supervised or GenServer
  #   in this module or in PlatformTenantFixture (capture_repo_queries/1 only attaches a
  #   telemetry handler for the duration of its fun and detaches it).
  # lib/ fire-and-forget workers (item 2): none reachable -- only Letflow.Routers.Promotions,
  #   Definitions and Tenants (promote) and the Definitions/EventStore contexts are called.
  # In-memory tenant-keyed state (item 3): no ETS / Admission / rate-limit bucket touched (no
  #   api_conn, no bearer token); no capture_log / deny-log assertion; the platform pin is
  #   Application env restored by the fixture's per-test on_exit.
  setup_all context do
    Letflow.TenantFixture.start_pool!(context,
      slots: [[slug_prefix: "scope-a"], [slug_prefix: "scope-b"], [slug_prefix: "scope-p"]]
    )
  end

  # MUST stay the module's first setup (before anything that provisions a tenant).
  setup context do
    Letflow.TenantFixture.attach_pool!(context)
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "item 7: rows 23-34" do
    test "there are twelve rows and each declares its expected key" do
      assert length(@rows) == 12

      for {router, method, _path, _body, key} <- @rows do
        verb = method |> Atom.to_string() |> String.upcase()
        keys = for {^verb, _pattern, k} <- router.__authz_routes__(), do: k
        assert key in keys, "#{inspect(router)} #{verb} declares none of #{inspect(key)}"
      end
    end

    test "a TENANT_ADMIN (ordinary tenant, pin unset) and the platform tenant's PLATFORM_ADMIN reach the handler",
         ctx do
      for {label, fixture, roles, pin?} <- [
            {"ordinary tenant TENANT_ADMIN", ctx.a, ["TENANT_ADMIN"], true},
            {"platform tenant PLATFORM_ADMIN", ctx.p, ["PLATFORM_ADMIN"], true},
            {"pin unset TENANT_ADMIN", ctx.p, ["TENANT_ADMIN"], false}
          ],
          row <- @rows do
        if pin?, do: Fixture.pin!(ctx.p.tenant_id), else: Fixture.unpin!()

        resp = request(row, fixture, roles, ctx.b.tenant_id)

        refute resp.status == 403, "#{label}: #{elem(row, 1)} #{elem(row, 2)}"
      end
    end

    test "REQ-447 PR 2: a PLATFORM_ADMIN of an ordinary tenant, or with the pin unset, is denied 403 on every row",
         ctx do
      for {label, fixture, pin?} <- [
            {"ordinary tenant", ctx.a, true},
            {"pin unset", ctx.p, false}
          ],
          row <- @rows do
        if pin?, do: Fixture.pin!(ctx.p.tenant_id), else: Fixture.unpin!()

        resp = request(row, fixture, ["PLATFORM_ADMIN"], ctx.b.tenant_id)

        assert resp.status == 403, "#{label}: #{elem(row, 1)} #{elem(row, 2)}"
      end
    end

    test "every other role is denied 403 on every row", ctx do
      for row <- @rows,
          roles <- [
            ["PROCESS_DESIGNER"],
            ["PROCESS_OPERATOR"],
            ["TASK_WORKER"],
            # REQ-446 AC3: the two roles the original grid omitted
            ["CANDIDATE"],
            ["AGENT_RUNNER"],
            []
          ],
          fixture <- [ctx.a, ctx.p] do
        resp = request(row, fixture, roles, ctx.b.tenant_id)
        assert resp.status == 403, "#{inspect(roles)} #{elem(row, 1)} #{elem(row, 2)}"
      end
    end
  end

  describe "item 7: foreign source and target ids on plan and submit" do
    test "naming another existing tenant is the byte-identical 404 of a nonexistent tenant",
         ctx do
      key = unique_key()

      for path <- ["/plan", "/"] do
        responses =
          for {label, source, target} <- [
                {"foreign source", ctx.b.tenant_id, ctx.a.tenant_id},
                {"foreign target", ctx.a.tenant_id, ctx.b.tenant_id},
                {"both foreign", ctx.b.tenant_id, ctx.p.tenant_id},
                {"nonexistent source", Ecto.UUID.generate(), ctx.a.tenant_id},
                {"nonexistent target", ctx.a.tenant_id, Ecto.UUID.generate()}
              ] do
            {label,
             promotions(
               :post,
               path,
               ctx.a,
               ["TENANT_ADMIN"],
               plan_body(source, target, key)
             )}
          end

        for {label, resp} <- responses do
          assert resp.status == 404, "#{path} #{label}: #{resp.status}"
        end

        observed = responses |> Enum.map(fn {_l, r} -> observable(r) end) |> Enum.uniq()
        assert length(observed) == 1, "#{path}: observable responses differ"

        {_status, body, _headers} = hd(observed)
        refute body =~ ctx.b.tenant_id
        refute body =~ ctx.b.tenant.slug
      end
    end

    test "the denied request never queries the foreign tenant and writes no review", ctx do
      key = unique_key()
      insert_active_definition!(ctx.b, key)
      before = snapshot([ctx.a, ctx.b, ctx.p])

      for path <- ["/plan", "/"], target <- [ctx.a.tenant_id, ctx.b.tenant_id] do
        {resp, queries} =
          Fixture.capture_repo_queries(fn ->
            promotions(
              :post,
              path,
              ctx.a,
              ["TENANT_ADMIN"],
              plan_body(ctx.b.tenant_id, target, key)
            )
          end)

        assert resp.status == 404
        assert touching(queries, ctx.b) == [], "#{path}: queried B"
      end

      assert snapshot([ctx.a, ctx.b, ctx.p]) == before
    end

    test "the caller's own tenant on both sides is not refused by the scope rule", ctx do
      key = unique_key()
      insert_active_definition!(ctx.a, key)

      resp =
        promotions(
          :post,
          "/plan",
          ctx.a,
          ["TENANT_ADMIN"],
          plan_body(ctx.a.tenant_id, ctx.a.tenant_id, key)
        )

      refute resp.status in [403, 404], "own-tenant plan answered #{resp.status}"
    end

    test "the promote route with another existing tenant as source is 404 before any source read",
         ctx do
      key = unique_key()
      insert_active_definition!(ctx.b, key)
      before = snapshot([ctx.a, ctx.b, ctx.p])

      {foreign, foreign_queries} =
        Fixture.capture_repo_queries(fn ->
          promote(ctx.b.tenant_id, key, ctx.a, ["TENANT_ADMIN"])
        end)

      {nonexistent, nonexistent_queries} =
        Fixture.capture_repo_queries(fn ->
          promote(Ecto.UUID.generate(), key, ctx.a, ["TENANT_ADMIN"])
        end)

      assert foreign.status == 404
      assert Jason.decode!(foreign.resp_body)["title"] == "Not Found"
      assert observable(foreign) == observable(nonexistent)

      # the telemetry capture sees the operator's request read B (control), and never the denial's
      assert touching(foreign_queries, ctx.b) == []
      assert touching(nonexistent_queries, ctx.b) == []
      assert length(foreign_queries) == length(nonexistent_queries)
      assert snapshot([ctx.a, ctx.b, ctx.p]) == before

      {operator, operator_queries} =
        Fixture.capture_repo_queries(fn ->
          promote(ctx.b.tenant_id, key, ctx.p, ["PLATFORM_ADMIN"])
        end)

      assert operator.status == 201
      assert touching(operator_queries, ctx.b) != []
    end
  end

  describe "item 7: stored foreign ids on apply and run-assertions (R7/R8)" do
    # A review row that names a foreign tenant on one side, stored in A's schema. Such a row can
    # only be written by the operator (or by a pre-fix build): submit it with the pin on A, then
    # return the pin to P so A's TENANT_ADMIN is an ordinary tenant admin again (the stored review is
    # written as A's PLATFORM_ADMIN while A is the pinned platform tenant).
    defp store_review_in_a!(ctx, source, target, key, base_version \\ "1.0.0") do
      Fixture.pin!(ctx.a.tenant_id)

      resp =
        promotions(
          :post,
          "/",
          ctx.a,
          ["PLATFORM_ADMIN"],
          plan_body(source.tenant_id, target.tenant_id, key, base_version)
        )

      assert resp.status == 201, "operator submit answered #{resp.status}: #{resp.resp_body}"
      Fixture.pin!(ctx.p.tenant_id)

      body = Jason.decode!(resp.resp_body)
      {body["review_id"], body["plan_digest"]}
    end

    defp artifact do
      row =
        Jason.encode!(%{
          "id" => Ecto.UUID.generate(),
          "tenant_id" => Ecto.UUID.generate(),
          "name" => "iss0993-fixture",
          "version" => "1.0.0",
          "status" => "draft",
          "graph" => %{"nodes" => [], "edges" => []},
          "created_by" => Ecto.UUID.generate(),
          "created_at" => "2026-01-01T00:00:00.000000",
          "updated_at" => "2026-01-01T00:00:00.000000"
        })

      %{
        "id" => "iss0993-artifact",
        "assertions" => [%{"id" => "a1", "payload" => Jason.encode!(%{"result" => "expected"})}],
        "fixtures" => [%{"table_name" => "process_definitions", "row_json" => row}],
        "rng_seed" => 1_700_000_000 * 4_294_967_296 + 424_242,
        "non_deterministic_fields" => [],
        "candidate_definitions" => []
      }
    end

    defp apply_review(ctx, review_id, digest, roles \\ ["TENANT_ADMIN"]) do
      promotions(:post, "/#{review_id}/apply", ctx.a, roles, %{
        "plan_digest" => digest
      })
    end

    defp run_assertions(ctx, review_id, digest) do
      promotions(:post, "/#{review_id}/run-assertions", ctx.a, ["TENANT_ADMIN"], %{
        "plan_digest" => digest,
        "artifact" => artifact()
      })
    end

    test "a stored foreign SOURCE or TARGET makes apply and run-assertions the nonexistent-review 404",
         ctx do
      key = unique_key()
      # different versions, so no plan is empty ("identical after canonicalisation")
      insert_active_definition!(ctx.a, key, "1.0.0")
      insert_active_definition!(ctx.b, key, "2.0.0")

      # {label, source, target, the target's active version (the plan's base_version)}
      for {label, source, target, base_version} <- [
            {"foreign source", ctx.b, ctx.a, "1.0.0"},
            {"foreign target", ctx.a, ctx.b, "2.0.0"},
            {"both foreign", ctx.b, ctx.p, "1.0.0"}
          ] do
        {review_id, digest} = store_review_in_a!(ctx, source, target, key, base_version)
        before = snapshot([ctx.a, ctx.b, ctx.p])

        for {action, fun} <- [
              {"apply", &apply_review/3},
              {"run-assertions", &run_assertions/3}
            ] do
          {resp, queries} = Fixture.capture_repo_queries(fn -> fun.(ctx, review_id, digest) end)

          reference = fun.(ctx, Ecto.UUID.generate(), digest)

          assert resp.status == 404, "#{label} #{action}: #{resp.status} #{resp.resp_body}"
          assert observable(resp) == observable(reference), "#{label} #{action}"
          assert touching(queries, ctx.b) == [], "#{label} #{action}: queried B"
        end

        assert snapshot([ctx.a, ctx.b, ctx.p]) == before, "#{label}: a row was written"
      end
    end

    test "control: the same stored review is not refused by the scope rule for the operator",
         ctx do
      key = unique_key()
      insert_active_definition!(ctx.b, key, "2.0.0")

      {review_id, digest} = store_review_in_a!(ctx, ctx.b, ctx.a, key)

      # an ordinary tenant admin: refused
      assert apply_review(ctx, review_id, digest).status == 404

      # the operator reaches the domain logic (the review exists but is not approved: a domain
      # answer, not the zero-detail authorization 404)
      Fixture.pin!(ctx.a.tenant_id)
      refute apply_review(ctx, review_id, digest, ["PLATFORM_ADMIN"]).status == 404
    end
  end

  describe "item 7: the platform operator works across tenants" do
    test "plan, submit, approve, apply and promote with ids that are not the operator's own",
         ctx do
      key = unique_key()
      insert_active_definition!(ctx.b, key, "2.0.0")
      operator = ctx.p

      plan =
        promotions(
          :post,
          "/plan",
          operator,
          ["PLATFORM_ADMIN"],
          plan_body(ctx.b.tenant_id, ctx.a.tenant_id, key)
        )

      assert plan.status == 200

      submit =
        promotions(
          :post,
          "/",
          operator,
          ["PLATFORM_ADMIN"],
          plan_body(ctx.b.tenant_id, ctx.a.tenant_id, key)
        )

      assert submit.status == 201
      %{"review_id" => review_id, "plan_digest" => digest} = Jason.decode!(submit.resp_body)

      # approve (Fixture.router_conn gives every request a fresh user id, so the approver is not
      # the requester)
      approve =
        promotions(:post, "/#{review_id}/approve", operator, ["PLATFORM_ADMIN"], %{
          "plan_digest" => digest
        })

      assert approve.status == 200

      Repo.insert!(
        %PromotionAssertionRun{
          review_id: review_id,
          idempotency_key: "iss0993-fixture-#{System.unique_integer([:positive, :monotonic])}",
          plan_digest: digest,
          status: :passed,
          assertions_total: 1,
          assertions_passed: 1,
          assertions_failed: 0,
          completed_at: DateTime.utc_now()
        },
        prefix: ctx.p.schema_name
      )

      # apply writes into A, a tenant that is neither the operator's nor the caller's
      applied =
        promotions(:post, "/#{review_id}/apply", operator, ["PLATFORM_ADMIN"], %{
          "plan_digest" => digest
        })

      assert applied.status == 200
      assert Jason.decode!(applied.resp_body)["status"] == "applied"

      assert Repo.get_by!(ProcessDefinition, [name: key, status: :active],
               prefix: ctx.a.schema_name
             ).version == "2.0.0"

      # promote: source B into the operator's own tenant
      promote_key = unique_key()
      insert_active_definition!(ctx.b, promote_key)

      assert promote(ctx.b.tenant_id, promote_key, operator, ["PLATFORM_ADMIN"]).status == 201

      assert Repo.get_by!(ProcessDefinition, [name: promote_key, status: :active],
               prefix: ctx.p.schema_name
             )
    end

    test "with no platform tenant configured the same cross-tenant plan is refused 404", ctx do
      key = unique_key()
      insert_active_definition!(ctx.b, key)
      Fixture.unpin!()

      resp =
        promotions(
          :post,
          "/plan",
          ctx.p,
          ["TENANT_ADMIN"],
          plan_body(ctx.b.tenant_id, ctx.a.tenant_id, key)
        )

      assert resp.status == 404

      # REQ-447 PR 2: with no pin there is no platform tenant, so a PLATFORM_ADMIN holds nothing.
      legacy =
        promotions(
          :post,
          "/plan",
          ctx.p,
          ["PLATFORM_ADMIN"],
          plan_body(ctx.b.tenant_id, ctx.a.tenant_id, key)
        )

      assert legacy.status == 403
    end
  end

  describe "item 7: default_permission_checker is gone from lib/" do
    test "no file under lib/ (design documents excluded) mentions default_permission_checker" do
      files =
        Enum.reject(Path.wildcard("lib/**/*.ex"), &String.contains?(&1, "lib/letflow/design/"))

      # the scan is not vacuous: it covers the file the function used to live in
      assert "lib/letflow/definitions/promotion_plan.ex" in files

      offenders = for file <- files, File.read!(file) =~ "default_permission_checker", do: file

      assert offenders == []
    end

    test "PromotionPlan no longer exports default_permission_checker" do
      Code.ensure_loaded!(Letflow.Definitions.PromotionPlan)

      refute function_exported?(Letflow.Definitions.PromotionPlan, :default_permission_checker, 2)
    end
  end

  describe "item 8: GET /promotions/platform-events" do
    defp register_event_type!(tenant_id) do
      name = "ISS0993_EVT_" <> to_string(System.unique_integer([:positive, :monotonic]))

      assert {:ok, _} =
               Registry.register_type(
                 %{
                   "name" => name,
                   "schema_version" => 1,
                   "json_schema" => %{"type" => "object"},
                   "description" => "platform scope test fixture"
                 },
                 tenant_id
               )

      name
    end

    defp seed_platform_event!(fixture) do
      attrs = %{
        instance_id: EventStore.platform_instance_id(),
        event_type: register_event_type!(fixture.tenant_id),
        payload: Jason.encode!(%{}),
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "iss0993-" <> to_string(System.unique_integer([:positive, :monotonic]))
      }

      assert {:ok, %{event: event}} =
               EventStore.append_platform_event(attrs, prefix: fixture.schema_name)

      event
    end

    defp event_ids(fixture, roles) do
      resp =
        dispatch(
          Letflow.Routers.Promotions,
          Fixture.router_conn(:get, "/platform-events", fixture, roles, nil)
        )

      assert resp.status == 200
      Jason.decode!(resp.resp_body)["items"] |> Enum.map(& &1["event_id"])
    end

    test "events seeded in another tenant's schema are never returned; the caller sees its own",
         ctx do
      event_a = seed_platform_event!(ctx.a)
      event_b = seed_platform_event!(ctx.b)

      ids_a = event_ids(ctx.a, ["TENANT_ADMIN"])
      assert event_a.event_id in ids_a
      refute event_b.event_id in ids_a

      ids_b = event_ids(ctx.b, ["TENANT_ADMIN"])
      assert event_b.event_id in ids_b
      refute event_a.event_id in ids_b
    end

    test "the platform tenant's PLATFORM_ADMIN reads only the platform tenant's own schema",
         ctx do
      event_p = seed_platform_event!(ctx.p)
      event_a = seed_platform_event!(ctx.a)

      ids = event_ids(ctx.p, ["PLATFORM_ADMIN"])
      assert event_p.event_id in ids
      refute event_a.event_id in ids
    end

    test "a role without the read permission gets 403 and no event data", ctx do
      event_a = seed_platform_event!(ctx.a)

      resp =
        dispatch(
          Letflow.Routers.Promotions,
          Fixture.router_conn(:get, "/platform-events", ctx.a, ["TASK_WORKER"], nil)
        )

      assert resp.status == 403
      refute resp.resp_body =~ event_a.event_id
    end
  end
end
