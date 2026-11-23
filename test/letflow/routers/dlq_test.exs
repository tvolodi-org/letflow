defmodule Letflow.Routers.DlqTest do
  @moduledoc """
  Tests for `Letflow.Routers.Dlq` (REQ-178) -- the route/controller layer
  atop REQ-176's `Letflow.Dlq` context module. See `test/specs/REQ-178.md`
  for the full acceptance-criterion -> test-case mapping and rationale.
  Design authority: `lib/letflow/design/req178-dlq-routes.md`.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1, matching
  `test/letflow/routers/tasks_test.exs`'s own established idiom for this
  class of router test: direct `Letflow.Routers.Dlq.call/2` dispatch,
  `conn.assigns[:auth_context]` set directly (bypassing `AuthPipeline`),
  `Letflow.TenantFixture.provisioned_tenant!/1` for real tenant schemas, and
  the same cross-tenant-identical-404 idiom. `async: false` for the same
  reason every other tenant-fixture-using test file in this codebase sets
  it (real schema creation/teardown against one shared Postgres instance).

  This file does not modify, and does not duplicate the coverage of,
  `test/letflow/dlq_test.exs` (REQ-176) -- that file exercises
  `Letflow.Dlq` directly with no HTTP layer; this file exercises only the
  new router/response-shaping code added by REQ-178.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Dlq
  alias Letflow.Instances.StepRetry
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Dlq.init([])

  # ── Shared test dispatch helper (matches tasks_test.exs's build_conn/4 shape) ──

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Dlq.call(conn, @opts)

  # ── Fixture helpers (matches test/letflow/dlq_test.exs's own precedent) ──

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-178 DLQ Router Test Tenant"
    )
  end

  defp enqueue!(tenant, attrs \\ %{}) do
    base = %{entry_type: "event"}
    {:ok, entry} = Dlq.enqueue(Map.merge(base, attrs), prefix: tenant.schema_name)
    entry
  end

  # No public function of `Letflow.Dlq` ever transitions an entry to
  # `:resolved`, and `discard/2` is the only public way to reach
  # `:discarded` -- for AC4's already-terminal fixtures this force-writes
  # `:resolved` directly, matching `test/letflow/dlq_test.exs`'s own
  # `force_status!/3` precedent for a state no public API produces.
  defp force_status!(tenant, entry, status) do
    entry
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!(prefix: tenant.schema_name)
  end

  @dlq_entry_keys [
                    "id",
                    "entry_type",
                    "instance_id",
                    "reference_id",
                    "reason",
                    "full_reason",
                    "error_detail",
                    "error_chain",
                    "source_payload",
                    "context_json",
                    "retry_history",
                    "retry_count",
                    "retry_limit",
                    "next_retry_at",
                    "status",
                    "created_at",
                    "first_failed_at",
                    "last_failed_at"
                  ]
                  |> Enum.sort()

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- GET /dlq list shape: {items, next_cursor}, DlqEntry field allowlist
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: GET /dlq returns {items, next_cursor} with DlqEntry-shaped items" do
    test "top-level body has exactly items/next_cursor, and each item's keys match web/src/types/api.ts's DlqEntry" do
      tenant = provisioned_tenant("req178-shape")
      entry = enqueue!(tenant, %{entry_type: "event", reason: "boom"})

      conn = build_conn(:get, "/", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.keys(body) |> Enum.sort() == ["items", "next_cursor"]
      assert [item] = body["items"]

      assert Map.keys(item) |> Enum.sort() == @dlq_entry_keys

      # AC1's own named minimum field set, verified against real values.
      assert item["id"] == entry.id
      assert item["entry_type"] == "event"
      assert item["instance_id"] == nil
      assert item["reason"] == "boom"
      assert item["full_reason"] == nil
      assert item["retry_count"] == 0
      assert item["status"] == "pending"
      assert is_binary(item["created_at"])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- each list filter independently narrows the result set
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: GET /dlq filters" do
    test "status narrows the result set" do
      tenant = provisioned_tenant("req178-f-status")
      pending = enqueue!(tenant)
      retrying_source = enqueue!(tenant)
      {:ok, retrying} = Dlq.retry(retrying_source.id, prefix: tenant.schema_name)

      conn =
        build_conn(:get, "/?status=pending", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      body = Jason.decode!(conn.resp_body)
      ids = Enum.map(body["items"], & &1["id"])

      assert ids == [pending.id]
      refute retrying.id in ids
    end

    test "source_type narrows the result set (renamed to entry_type at the Letflow.Dlq boundary)" do
      tenant = provisioned_tenant("req178-f-type")
      event_entry = enqueue!(tenant, %{entry_type: "event"})
      _timer_entry = enqueue!(tenant, %{entry_type: "timer"})

      conn =
        build_conn(:get, "/?source_type=event", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["id"]) == [event_entry.id]
    end

    test "search narrows the result set" do
      tenant = provisioned_tenant("req178-f-search")
      matching = enqueue!(tenant, %{reason: "distinctive-needle-reason"})
      _other = enqueue!(tenant, %{reason: "unrelated"})

      conn =
        build_conn(:get, "/?search=distinctive-needle", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["id"]) == [matching.id]
    end

    test "instance_id narrows the result set" do
      tenant = provisioned_tenant("req178-f-instance")
      instance_id = Ecto.UUID.generate()
      matching = enqueue!(tenant, %{instance_id: instance_id})
      _other = enqueue!(tenant, %{instance_id: Ecto.UUID.generate()})

      conn =
        build_conn(:get, "/?instance_id=#{instance_id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["id"]) == [matching.id]
    end

    test "page_size narrows the result set (and cursor advances to a distinct next page)" do
      tenant = provisioned_tenant("req178-f-page")
      entries = for _ <- 1..3, do: enqueue!(tenant)
      all_ids = MapSet.new(entries, & &1.id)

      conn1 =
        build_conn(:get, "/?page_size=1", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      body1 = Jason.decode!(conn1.resp_body)
      assert length(body1["items"]) == 1
      refute is_nil(body1["next_cursor"])

      cursor = URI.encode_www_form(body1["next_cursor"])

      conn2 =
        build_conn(:get, "/?page_size=1&cursor=#{cursor}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      body2 = Jason.decode!(conn2.resp_body)
      assert length(body2["items"]) == 1

      seen_ids = Enum.map(body1["items"] ++ body2["items"], & &1["id"])
      assert length(seen_ids) == length(Enum.uniq(seen_ids))
      assert MapSet.subset?(MapSet.new(seen_ids), all_ids)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- retry/discard require DlqOperate: 403 without it, 404-never-403
  # cross-tenant
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: retry/discard require DlqOperate" do
    test "POST /dlq/:id/retry -> 403 for a caller with no role holding DlqOperate" do
      tenant = provisioned_tenant("req178-403-retry")
      entry = enqueue!(tenant)

      conn =
        build_conn(:post, "/#{entry.id}/retry", tenant, roles: ["TASK_WORKER"]) |> dispatch()

      assert conn.status == 403

      # No state change on 403.
      reloaded = Repo.get!(Letflow.Dlq.Entry, entry.id, prefix: tenant.schema_name)
      assert reloaded.status == :pending
    end

    test "POST /dlq/:id/discard -> 403 for a caller with no role holding DlqOperate" do
      tenant = provisioned_tenant("req178-403-discard")
      entry = enqueue!(tenant)

      conn =
        build_conn(:post, "/#{entry.id}/discard", tenant, roles: ["TASK_WORKER"]) |> dispatch()

      assert conn.status == 403

      reloaded = Repo.get!(Letflow.Dlq.Entry, entry.id, prefix: tenant.schema_name)
      assert reloaded.status == :pending
    end

    test "a real id belonging to a different tenant returns 404, never 403, for both retry and discard" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req178-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req178-cross-b")

      tenant_b_entry = enqueue!(tenant_b)

      retry_conn =
        build_conn(:post, "/#{tenant_b_entry.id}/retry", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      discard_conn =
        build_conn(:post, "/#{tenant_b_entry.id}/discard", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert retry_conn.status == 404
      assert discard_conn.status == 404

      # Cross-tenant-404 identical to a genuinely-absent id (INV-5).
      never_existed_conn =
        build_conn(:post, "/#{Ecto.UUID.generate()}/retry", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert never_existed_conn.status == 404
      assert never_existed_conn.resp_body == retry_conn.resp_body

      # The other tenant's row is untouched.
      reloaded = Repo.get!(Letflow.Dlq.Entry, tenant_b_entry.id, prefix: tenant_b.schema_name)
      assert reloaded.status == :pending
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 -- retry/discard: 404 for nonexistent, 409 (not 500) for terminal
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: retry/discard against a nonexistent id" do
    test "POST /dlq/:id/retry -> 404 for a genuinely nonexistent id" do
      tenant = provisioned_tenant("req178-404-retry")

      conn =
        build_conn(:post, "/#{Ecto.UUID.generate()}/retry", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 404
    end

    test "POST /dlq/:id/discard -> 404 for a genuinely nonexistent id" do
      tenant = provisioned_tenant("req178-404-discard")

      conn =
        build_conn(:post, "/#{Ecto.UUID.generate()}/discard", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 404
    end
  end

  describe "AC4: retry/discard against an already-terminal entry" do
    test "POST /dlq/:id/retry -> 409, not 500, against an already-resolved entry, and leaves it unchanged" do
      tenant = provisioned_tenant("req178-409-retry")
      entry = enqueue!(tenant)
      resolved = force_status!(tenant, entry, :resolved)

      conn =
        build_conn(:post, "/#{entry.id}/retry", tenant, roles: ["TENANT_ADMIN"]) |> dispatch()

      assert conn.status == 409

      reloaded = Repo.get!(Letflow.Dlq.Entry, entry.id, prefix: tenant.schema_name)
      assert reloaded.status == :resolved
      assert reloaded.retry_count == resolved.retry_count
    end

    test "POST /dlq/:id/discard -> 409, not 500, against an already-discarded entry, and leaves it unchanged" do
      tenant = provisioned_tenant("req178-409-discard")
      entry = enqueue!(tenant)
      {:ok, discarded} = Dlq.discard(entry.id, prefix: tenant.schema_name)

      conn =
        build_conn(:post, "/#{entry.id}/discard", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 409

      reloaded = Repo.get!(Letflow.Dlq.Entry, entry.id, prefix: tenant.schema_name)
      assert reloaded.status == :discarded
      assert reloaded.retry_count == discarded.retry_count
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 -- GET /dlq is tenant-scoped
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: GET /dlq is tenant-scoped" do
    test "an entry enqueued under tenant A never appears in tenant B's list" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req178-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req178-iso-b")

      entry_a = enqueue!(tenant_a)

      conn_a = build_conn(:get, "/", tenant_a, roles: ["TENANT_ADMIN"]) |> dispatch()
      conn_b = build_conn(:get, "/", tenant_b, roles: ["TENANT_ADMIN"]) |> dispatch()

      body_a = Jason.decode!(conn_a.resp_body)
      body_b = Jason.decode!(conn_b.resp_body)

      assert Enum.map(body_a["items"], & &1["id"]) == [entry_a.id]
      assert body_b["items"] == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC (moduledoc) -- R-Co dlq.zig non-inspection is documented, not assumed
  # ══════════════════════════════════════════════════════════════════════

  describe "moduledoc states R-Co's dlq.zig was not inspected and names the real binding contract" do
    test "moduledoc mentions dlq.zig, 'not inspected', and the web/ contract files" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _} =
        Code.fetch_docs(Letflow.Routers.Dlq)

      assert moduledoc =~ "dlq.zig"
      assert moduledoc =~ "not inspected"
      assert moduledoc =~ "web/src/api/dlq.ts"
      assert moduledoc =~ "web/src/types/api.ts"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # The retry of a STEP failure (pilot gap G7): a platform act, so the
  # platform admin only. The route's own `:DlqOperate` permission is wider
  # (a `:PROCESS_OPERATOR` holds it), so the step entries carry an extra
  # check.
  # ══════════════════════════════════════════════════════════════════════

  describe "the retry of a step failure is a platform act" do
    test "a caller who is not the platform admin is refused with 403" do
      tenant = provisioned_tenant("req178-step-403")
      PlatformFx.pin!(tenant.tenant_id)

      entry =
        enqueue!(tenant, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: Ecto.UUID.generate(),
          reference_id: "call"
        })

      conn =
        build_conn(:post, "/#{entry.id}/retry", tenant, roles: ["PROCESS_OPERATOR"])
        |> dispatch()

      assert conn.status == 403

      # No state change on 403.
      reloaded = Repo.get!(Letflow.Dlq.Entry, entry.id, prefix: tenant.schema_name)
      assert reloaded.status == :pending
    end

    test "a caller in another tenant is refused with 403 for a step entry" do
      tenant = provisioned_tenant("req178-step-other-tenant")
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req178-step-other")

      entry =
        enqueue!(tenant, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: Ecto.UUID.generate(),
          reference_id: "call"
        })

      # The platform tenant is pinned to `tenant`, so a caller of `other` is
      # not in the platform scope even with the platform role.
      conn =
        build_conn(:post, "/#{entry.id}/retry", other, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 403
    end

    test "the platform admin may retry a step entry" do
      tenant = provisioned_tenant("req178-step-admin")
      PlatformFx.pin!(tenant.tenant_id)

      entry =
        enqueue!(tenant, %{
          entry_type: StepRetry.platform_step_entry_type(),
          instance_id: Ecto.UUID.generate(),
          reference_id: "call"
        })

      conn =
        build_conn(:post, "/#{entry.id}/retry", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "retrying"
    end
  end
end
