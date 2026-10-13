defmodule Letflow.Routers.PromotionsTest do
  @moduledoc """
  Tests for `Letflow.Routers.Promotions`'s R11 route, `GET /promotions/platform-events`
  (ISS-0733 GAP B, `lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
  §2). Brand-new code (did not exist pre-fix at all) -- per
  `docs/agents/workflows/WF-03_issue_resolving.md`'s "non-existence" section, a
  fail-first run against `main` would only prove `404`/route-not-found, which proves
  nothing about correctness, so coverage here is corroborated by mutation testing
  (see the WF-03 handoff's `result.summary` for the mutant runs/counts) rather than by
  a fail-then-pass proof against `main`.

  Dispatch strategy mirrors `req077_promotion_pipeline_test.exs` exactly: dispatches
  directly against `Letflow.Routers.Promotions.call/2` with `conn.assigns.auth_context`
  set by hand. `Letflow.Plugs.Authorize` is still a real, live plug in this router's
  pipeline (mounted by `use Letflow.Api.AuthorizedRouter`) and runs for every request --
  it resolves `conn.assigns.scoped_opts` from `conn.assigns.auth_context` itself, so no
  test below sets `scoped_opts` directly.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) and `Letflow.TenantFixture` for
  real provisioned tenant schemas. `async: false` -- tenant provisioning/migration
  replay needs `Sandbox.mode(Letflow.Repo, :auto)`, same reasoning as every other
  tenant-provisioning test file in this codebase. Self-contained: provisions its own
  tenants, does not share fixtures with any other test file (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Pagination
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.EventStore
  alias Letflow.EventStore.Registry
  alias Letflow.TenantFixture

  @promotions_opts Letflow.Routers.Promotions.init([])

  # ── Shared dispatch helpers (mirrors req077_promotion_pipeline_test.exs) ───────

  defp build_conn(tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    query_string = Keyword.get(fields, :query_string, "")

    path =
      if query_string == "", do: "/platform-events", else: "/platform-events?" <> query_string

    tenant_id = if tenant_fixture, do: tenant_fixture.tenant_id, else: Ecto.UUID.generate()

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Keyword.get(fields, :user_id, Ecto.UUID.generate()),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "iss0733-gapb-test-trace-id")
  end

  defp get_platform_events(tenant, fields \\ []) do
    build_conn(tenant, fields)
    |> Letflow.Routers.Promotions.call(@promotions_opts)
  end

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0733 GAP B #{slug_prefix} tenant"
    )
  end

  defp unique_type_name(prefix \\ "ISS0733_EVT") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp register_event_type!(tenant_id) do
    name = unique_type_name()

    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "ISS-0733 GAP B test fixture"
               },
               tenant_id
             )

    name
  end

  defp seed_platform_event!(schema_name, event_type, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          instance_id: EventStore.platform_instance_id(),
          event_type: event_type,
          payload: Jason.encode!(%{}),
          actor_id: Ecto.UUID.generate(),
          idempotency_key:
            "iss0733-gapb-" <> to_string(System.unique_integer([:positive, :monotonic]))
        },
        overrides
      )

    assert {:ok, %{event: event}} =
             EventStore.append_platform_event(attrs, prefix: schema_name)

    event
  end

  # ---------------------------------------------------------------------------
  # authz -- :Unknown gate (design §2.4, router moduledoc's own "The :Unknown
  # authorization decision"): historically PLATFORM_ADMIN only; now :PromotionsRead (tenant
  # scope, held by TENANT_ADMIN), Deny403 for everyone else, including a caller with no roles at
  # all and a PLATFORM_ADMIN of an ordinary tenant (REQ-447 PR 2: it holds nothing there).
  # ---------------------------------------------------------------------------

  describe "authz -- TENANT_ADMIN only (design §2.4)" do
    test "TENANT_ADMIN gets 200" do
      tenant = provisioned_tenant("req11-authz-allow")
      resp = get_platform_events(tenant, roles: ["TENANT_ADMIN"])
      assert resp.status == 200
    end

    test "a PLATFORM_ADMIN of an ordinary tenant gets 403 (legacy own-tenant power removed, REQ-447 PR 2)" do
      tenant = provisioned_tenant("req11-authz-legacy")
      type_name = register_event_type!(tenant.tenant_id)
      event = seed_platform_event!(tenant.schema_name, type_name)

      resp = get_platform_events(tenant, roles: ["PLATFORM_ADMIN"])

      assert resp.status == 403
      refute resp.resp_body =~ event.event_id
    end

    test "a non-TENANT_ADMIN role (e.g. TASK_WORKER) gets 403, no event data leaks" do
      tenant = provisioned_tenant("req11-authz-deny")
      type_name = register_event_type!(tenant.tenant_id)
      event = seed_platform_event!(tenant.schema_name, type_name)

      resp = get_platform_events(tenant, roles: ["TASK_WORKER"])

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 403
      refute Map.has_key?(body, "items")
      refute resp.resp_body =~ event.event_id
    end

    test "a caller with no roles at all gets 403" do
      tenant = provisioned_tenant("req11-authz-noroles")
      resp = get_platform_events(tenant, roles: [])
      assert resp.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # tenant scoping -- design §2.4: conn.assigns.scoped_opts's :prefix, derived
  # solely from the caller's own auth_context.tenant_id (mirrors GET /audit's
  # INV-1 boundary). A caller scoped to tenant A never sees tenant B's own
  # platform-sentinel event stream.
  # ---------------------------------------------------------------------------

  describe "tenant scoping (design §2.4)" do
    test "a caller scoped to tenant A does not see tenant B's platform events" do
      tenant_a = provisioned_tenant("req11-scope-a")
      tenant_b = provisioned_tenant("req11-scope-b")

      type_a = register_event_type!(tenant_a.tenant_id)
      type_b = register_event_type!(tenant_b.tenant_id)

      event_a = seed_platform_event!(tenant_a.schema_name, type_a)
      event_b = seed_platform_event!(tenant_b.schema_name, type_b)

      resp = get_platform_events(tenant_a)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      event_ids = Enum.map(body["items"], & &1["event_id"])

      assert event_a.event_id in event_ids
      refute event_b.event_id in event_ids
    end
  end

  # ---------------------------------------------------------------------------
  # response shape (design §2.6) -- hand-built allowlist, exactly the 6 item
  # keys and the 2 envelope keys named in the design.
  # ---------------------------------------------------------------------------

  describe "response shape (design §2.6)" do
    test "envelope has exactly items/next_cursor; a non-operator item has exactly the 5 named keys (no actor_id, ISS-0999)" do
      tenant = provisioned_tenant("req11-shape")
      type_name = register_event_type!(tenant.tenant_id)
      actor_id = Ecto.UUID.generate()
      event = seed_platform_event!(tenant.schema_name, type_name, %{actor_id: actor_id})

      resp = get_platform_events(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() == Enum.sort(["items", "next_cursor"])
      refute Map.has_key?(body, "count")
      assert [item] = body["items"]

      assert Map.keys(item) |> Enum.sort() ==
               Enum.sort([
                 "event_id",
                 "event_type",
                 "timestamp",
                 "sequence_num",
                 "payload"
               ])

      assert item["event_id"] == event.event_id
      assert item["event_type"] == type_name
      # ISS-0999: the promoting actor's id is never shown to a non-operator
      refute Map.has_key?(item, "actor_id")
      assert item["sequence_num"] == 1
      assert item["payload"] == %{}
      assert is_binary(item["timestamp"])
    end
  end

  # ---------------------------------------------------------------------------
  # event_type filter (design §2.5/§2.6) -- narrows only, never widens.
  # ---------------------------------------------------------------------------

  describe "event_type filter" do
    test "filtering to one event_type returns only that type's events" do
      tenant = provisioned_tenant("req11-eventtype")
      type_a = register_event_type!(tenant.tenant_id)
      type_b = register_event_type!(tenant.tenant_id)

      event_a = seed_platform_event!(tenant.schema_name, type_a)
      _event_b = seed_platform_event!(tenant.schema_name, type_b)

      resp = get_platform_events(tenant, query_string: "event_type=#{type_a}")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [item] = body["items"]
      assert item["event_id"] == event_a.event_id
    end

    test "omitting event_type returns events of every type" do
      tenant = provisioned_tenant("req11-eventtype-all")
      type_a = register_event_type!(tenant.tenant_id)
      type_b = register_event_type!(tenant.tenant_id)

      seed_platform_event!(tenant.schema_name, type_a)
      seed_platform_event!(tenant.schema_name, type_b)

      resp = get_platform_events(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert length(body["items"]) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # pagination -- cursor round-trip, exact boundary, invalid cursor 400.
  # ---------------------------------------------------------------------------

  describe "pagination" do
    test "a page_size smaller than the row count returns a non-nil next_cursor; the next page continues with no overlap" do
      tenant = provisioned_tenant("req11-page-cursor")
      type_name = register_event_type!(tenant.tenant_id)

      events = for _ <- 1..3, do: seed_platform_event!(tenant.schema_name, type_name)

      resp1 = get_platform_events(tenant, query_string: "page_size=2")
      assert resp1.status == 200
      body1 = Jason.decode!(resp1.resp_body)
      assert length(body1["items"]) == 2
      assert is_binary(body1["next_cursor"])

      resp2 =
        get_platform_events(tenant,
          query_string: "page_size=2&cursor=#{URI.encode_www_form(body1["next_cursor"])}"
        )

      assert resp2.status == 200
      body2 = Jason.decode!(resp2.resp_body)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      page1_ids = Enum.map(body1["items"], & &1["event_id"])
      page2_ids = Enum.map(body2["items"], & &1["event_id"])
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
      assert Enum.sort(page1_ids ++ page2_ids) == Enum.sort(Enum.map(events, & &1.event_id))
    end

    test "exactly page_size rows yields next_cursor: nil, not a false has_more" do
      tenant = provisioned_tenant("req11-page-boundary")
      type_name = register_event_type!(tenant.tenant_id)

      for _ <- 1..2, do: seed_platform_event!(tenant.schema_name, type_name)

      resp = get_platform_events(tenant, query_string: "page_size=2")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert length(body["items"]) == 2
      assert body["next_cursor"] == nil
    end

    test "an invalid (garbage) cursor is rejected with 400" do
      tenant = provisioned_tenant("req11-page-badcursor")
      resp = get_platform_events(tenant, query_string: "cursor=not-a-valid-cursor")
      assert resp.status == 400
    end

    test "a cursor minted with a different endpoint's prefix (e.g. audit's \"A:\") is rejected with 400" do
      tenant = provisioned_tenant("req11-page-wrongendpoint")

      wrong_endpoint_cursor =
        Pagination.build_raw_cursor("A:", System.system_time(:microsecond), "some-key")
        |> Pagination.encode_cursor()

      resp =
        get_platform_events(tenant,
          query_string: "cursor=#{URI.encode_www_form(wrong_endpoint_cursor)}"
        )

      assert resp.status == 400
    end

    test "an empty platform-events stream returns items: [], next_cursor: nil" do
      tenant = provisioned_tenant("req11-page-empty")
      resp = get_platform_events(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["items"] == []
      assert body["next_cursor"] == nil
    end
  end

  # ===========================================================================
  # GET /promotions -- R12 (REQ-397, design req397-promotion-review-list-route.md)
  # ===========================================================================

  defp build_list_conn(tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    query_string = Keyword.get(fields, :query_string, "")

    path = if query_string == "", do: "/", else: "/?" <> query_string

    tenant_id = if tenant_fixture, do: tenant_fixture.tenant_id, else: Ecto.UUID.generate()

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Keyword.get(fields, :user_id, Ecto.UUID.generate()),
      tenant_id: tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req397-list-test-trace-id")
  end

  defp list_reviews_http(tenant, fields \\ []) do
    build_list_conn(tenant, fields)
    |> Letflow.Routers.Promotions.call(@promotions_opts)
  end

  defp req397_process_key(prefix \\ "req397-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp req397_sample_plan(tenant_id, overrides) do
    %{
      source_tenant_id: Ecto.UUID.generate(),
      target_tenant_id: tenant_id,
      process_key: req397_process_key(),
      source_definition_id: Ecto.UUID.generate(),
      target_definition_id: nil,
      base_version: nil,
      entries: [
        %{
          type: :graph_node,
          id: "n1-#{System.unique_integer([:positive, :monotonic])}",
          change_kind: :added,
          after: %{"id" => "n1", "node_type" => "START"},
          before: nil
        }
      ]
    }
    |> Map.merge(overrides)
  end

  # Inserts one :pending_review row via the real insert_review/2 call (never a
  # direct Repo.insert! -- design §7's fixture-discipline rule).
  defp seed_review!(schema_name, tenant_id, overrides \\ %{}) do
    plan = req397_sample_plan(tenant_id, overrides)
    digest = PromotionDigest.compute_plan_digest(plan)

    assert {:ok, review} =
             PromotionReviewStore.insert_review(
               %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
               prefix: schema_name
             )

    %{review: review, plan: plan, digest: digest}
  end

  defp seed_approved_review!(schema_name, tenant_id, overrides \\ %{}) do
    %{review: review, digest: digest} = seed_review!(schema_name, tenant_id, overrides)

    assert {:ok, approved} =
             PromotionReviewStore.approve_review(review.id, Ecto.UUID.generate(), digest,
               prefix: schema_name
             )

    approved
  end

  defp seed_rejected_review!(schema_name, tenant_id, overrides \\ %{}) do
    %{review: review} = seed_review!(schema_name, tenant_id, overrides)

    assert {:ok, rejected} =
             PromotionReviewStore.reject_review(review.id, Ecto.UUID.generate(),
               prefix: schema_name
             )

    rejected
  end

  # ---------------------------------------------------------------------------
  # AC1 -- authenticated TENANT_ADMIN, paginated, most-recent-first.
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- AC1 (paginated, most-recent-first, real HTTP)" do
    test "returns the caller's own tenant's rows, most-recent first" do
      tenant = provisioned_tenant("req397-order")

      %{review: r1} = seed_review!(tenant.schema_name, tenant.tenant_id)
      Process.sleep(2)
      %{review: r2} = seed_review!(tenant.schema_name, tenant.tenant_id)
      Process.sleep(2)
      %{review: r3} = seed_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      ids = Enum.map(body["items"], & &1["id"])

      assert ids == [r3.id, r2.id, r1.id]
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- cross-tenant isolation.
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- AC2 (cross-tenant isolation)" do
    test "a caller from tenant A never sees tenant B's rows, and vice versa" do
      tenant_a = provisioned_tenant("req397-iso-a")
      tenant_b = provisioned_tenant("req397-iso-b")

      %{review: review_a} = seed_review!(tenant_a.schema_name, tenant_a.tenant_id)
      %{review: review_b} = seed_review!(tenant_b.schema_name, tenant_b.tenant_id)

      resp_a = list_reviews_http(tenant_a)
      resp_b = list_reviews_http(tenant_b)

      assert resp_a.status == 200
      assert resp_b.status == 200

      ids_a = Jason.decode!(resp_a.resp_body)["items"] |> Enum.map(& &1["id"])
      ids_b = Jason.decode!(resp_b.resp_body)["items"] |> Enum.map(& &1["id"])

      assert review_a.id in ids_a
      refute review_b.id in ids_a

      assert review_b.id in ids_b
      refute review_a.id in ids_b
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- status filter (single + multi-value union).
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- AC3 (status filter, single and multi-value)" do
    test "status=rejected returns only the rejected row(s)" do
      tenant = provisioned_tenant("req397-status-single")

      %{review: pending} = seed_review!(tenant.schema_name, tenant.tenant_id)
      approved = seed_approved_review!(tenant.schema_name, tenant.tenant_id)
      rejected = seed_rejected_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant, query_string: "status=rejected")

      assert resp.status == 200
      ids = Jason.decode!(resp.resp_body)["items"] |> Enum.map(& &1["id"])

      assert ids == [rejected.id]
      refute pending.id in ids
      refute approved.id in ids
    end

    test "status=approved,rejected returns the union of both statuses" do
      tenant = provisioned_tenant("req397-status-multi")

      %{review: pending} = seed_review!(tenant.schema_name, tenant.tenant_id)
      approved = seed_approved_review!(tenant.schema_name, tenant.tenant_id)
      rejected = seed_rejected_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant, query_string: "status=approved,rejected")

      assert resp.status == 200
      ids = Jason.decode!(resp.resp_body)["items"] |> Enum.map(& &1["id"])

      assert Enum.sort(ids) == Enum.sort([approved.id, rejected.id])
      refute pending.id in ids
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- unrecognised status value rejects the WHOLE filter with 400.
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- AC4 (invalid status filter -> 400, whole filter rejected)" do
    test "status=bogus_value -> 400 naming the allowed set" do
      tenant = provisioned_tenant("req397-status-bogus")

      resp = list_reviews_http(tenant, query_string: "status=bogus_value")

      assert resp.status == 400
      body = Jason.decode!(resp.resp_body)

      for allowed <- ~w(pending_review approved rejected applied failed superseded) do
        assert body["detail"] =~ allowed
      end
    end

    test "status=rejected,bogus_value -> 400, not silently reduced to the valid subset" do
      tenant = provisioned_tenant("req397-status-mixed")
      _rejected = seed_rejected_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant, query_string: "status=rejected,bogus_value")

      assert resp.status == 400
    end
  end

  # ---------------------------------------------------------------------------
  # AC5 -- def_id filter.
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- AC5 (def_id filter)" do
    test "def_id=<value> returns only that definition's own reviews" do
      tenant = provisioned_tenant("req397-defid")

      %{review: review_1, plan: plan_1} = seed_review!(tenant.schema_name, tenant.tenant_id)
      %{review: review_2} = seed_review!(tenant.schema_name, tenant.tenant_id)

      refute review_1.def_id == review_2.def_id

      resp = list_reviews_http(tenant, query_string: "def_id=#{plan_1.process_key}")

      assert resp.status == 200
      ids = Jason.decode!(resp.resp_body)["items"] |> Enum.map(& &1["id"])

      assert ids == [review_1.id]
    end
  end

  # ---------------------------------------------------------------------------
  # AC6 -- non-TENANT_ADMIN -> 403 (same Deny403 every other route returns).
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- AC6 (authz, non-TENANT_ADMIN -> 403)" do
    test "a non-TENANT_ADMIN role gets 403, no review data leaks" do
      tenant = provisioned_tenant("req397-authz-deny")
      %{review: review} = seed_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant, roles: ["TASK_WORKER"])

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 403
      refute Map.has_key?(body, "items")
      refute resp.resp_body =~ review.id
    end

    test "a PLATFORM_ADMIN of an ordinary tenant gets 403, no review data leaks (REQ-447 PR 2)" do
      tenant = provisioned_tenant("req397-authz-legacy")
      %{review: review} = seed_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant, roles: ["PLATFORM_ADMIN"])

      assert resp.status == 403
      refute resp.resp_body =~ review.id
    end

    test "a caller with no roles at all gets 403" do
      tenant = provisioned_tenant("req397-authz-noroles")
      resp = list_reviews_http(tenant, roles: [])
      assert resp.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # Response shape (AC5's description item 5) -- 7-key allowlist, exactly.
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- response shape (design §4.5)" do
    test "envelope has exactly items/next_cursor; item has exactly the 7 named keys" do
      tenant = provisioned_tenant("req397-shape")
      %{review: review} = seed_review!(tenant.schema_name, tenant.tenant_id)

      resp = list_reviews_http(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() == Enum.sort(["items", "next_cursor"])
      assert [item] = body["items"]

      assert Map.keys(item) |> Enum.sort() ==
               Enum.sort([
                 "id",
                 "status",
                 "def_type",
                 "def_id",
                 "requested_by",
                 "inserted_at",
                 "updated_at"
               ])

      assert item["id"] == review.id
      assert item["status"] == "pending_review"
      assert item["def_type"] == review.def_type
      assert item["def_id"] == review.def_id
      assert item["requested_by"] == review.requested_by
      assert is_binary(item["inserted_at"])
      assert is_binary(item["updated_at"])
    end
  end

  # ---------------------------------------------------------------------------
  # Pagination -- cursor round-trip + wrong-endpoint cursor rejection.
  # ---------------------------------------------------------------------------

  describe "GET /promotions -- pagination" do
    test "a page_size smaller than the row count returns a non-nil next_cursor; the next page continues with no overlap" do
      tenant = provisioned_tenant("req397-page-cursor")

      reviews =
        for _ <- 1..3 do
          %{review: review} = seed_review!(tenant.schema_name, tenant.tenant_id)
          Process.sleep(2)
          review
        end

      resp1 = list_reviews_http(tenant, query_string: "page_size=2")
      assert resp1.status == 200
      body1 = Jason.decode!(resp1.resp_body)
      assert length(body1["items"]) == 2
      assert is_binary(body1["next_cursor"])

      resp2 =
        list_reviews_http(tenant,
          query_string: "page_size=2&cursor=#{URI.encode_www_form(body1["next_cursor"])}"
        )

      assert resp2.status == 200
      body2 = Jason.decode!(resp2.resp_body)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      page1_ids = Enum.map(body1["items"], & &1["id"])
      page2_ids = Enum.map(body2["items"], & &1["id"])
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
      assert Enum.sort(page1_ids ++ page2_ids) == Enum.sort(Enum.map(reviews, & &1.id))
    end

    test "an invalid (garbage) cursor is rejected with 400" do
      tenant = provisioned_tenant("req397-page-badcursor")
      resp = list_reviews_http(tenant, query_string: "cursor=not-a-valid-cursor")
      assert resp.status == 400
    end

    test "a cursor minted with a different endpoint's prefix (\"PE:\", this same router's R11) is rejected with 400" do
      tenant = provisioned_tenant("req397-page-wrongendpoint")

      wrong_endpoint_cursor =
        Pagination.build_raw_cursor("PE:", System.system_time(:microsecond), "some-key")
        |> Pagination.encode_cursor()

      resp =
        list_reviews_http(tenant,
          query_string: "cursor=#{URI.encode_www_form(wrong_endpoint_cursor)}"
        )

      assert resp.status == 400
    end

    test "an empty promotion_reviews table returns items: [], next_cursor: nil" do
      tenant = provisioned_tenant("req397-page-empty")
      resp = list_reviews_http(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["items"] == []
      assert body["next_cursor"] == nil
    end
  end
end
