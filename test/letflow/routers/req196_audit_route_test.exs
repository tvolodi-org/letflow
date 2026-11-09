defmodule Letflow.Routers.Req196AuditRouteTest do
  @moduledoc """
  Tests for REQ-196 (`lib/letflow/design/req196-audit-route.md`) -- repointing
  `GET /api/v1/audit` from `Letflow.EventStore.read_global/1` onto REQ-195's
  `audit_entries` store via the new `Letflow.Audit.list_entries/1`.

  Covers this requirement's 9 acceptance criteria (`docs/requirements.yaml`
  REQ-196):

    * AC1 -- real non-null `before_state`/`after_state` for a state-changing
      operation (the direct inverse of the always-null behaviour the old
      event-store-backed implementation had).
    * AC2 -- `resource_type` varies by resource kind, not the constant
      `"instance"`.
    * AC3 -- the `resource_type` filter actually discriminates.
    * AC4 -- the response envelope still matches `RawAuditPage`/`RawAuditEntry`
      field-for-field.
    * AC5 -- `:AuditRead` is still enforced, 403 without it.
    * AC6 -- cross-tenant isolation.
    * AC7 -- moduledoc content (checked directly against the shipped source).
    * AC8 -- no file under `web/` touched (checked via `git diff --stat` at the
      ELIXIR-DEV/TEST-RUNNER level, not asserted here).
    * AC9 -- `mix compile --warnings-as-errors`/`mix test` pass (execution
      gate, not a test case).

  Dispatches directly against `Letflow.Routers.Audit`'s own `Plug.Router`,
  exactly the convention `test/letflow/routers/req078_supporting_routes_test.exs`
  already establishes: `conn.assigns[:auth_context]` is set by hand, so nothing
  here depends on how that assign got populated.

  Uses `Letflow.DataCase` (real Postgres, per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1) and `Letflow.TenantFixture`
  for real provisioned tenant schemas. `async: false` -- tenant provisioning/
  migration replay needs `Sandbox.mode(Letflow.Repo, :auto)`, same reasoning as
  every other tenant-provisioning test file in this codebase. Self-contained:
  provisions its own tenants, does not share fixtures with any other test file
  (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.TenantFixture

  @audit_opts Letflow.Routers.Audit.init([])

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp build_conn(tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    query_string = Keyword.get(fields, :query_string, "")

    path = if query_string == "", do: "/", else: "/?" <> query_string

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_fixture.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req196-test-trace-id")
  end

  defp seed_audit_entry!(schema_name, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          actor_id: Ecto.UUID.generate(),
          action: "definition.create",
          resource_type: "definition",
          resource_id: Ecto.UUID.generate(),
          before_state: nil,
          after_state: %{"name" => "sample"},
          trace_id: nil
        },
        Map.new(overrides)
      )

    assert {:ok, entry} = Audit.insert_entry(Repo, attrs, schema_name)
    entry
  end

  defp get_audit(tenant, fields \\ []) do
    build_conn(tenant, fields)
    |> Letflow.Routers.Audit.call(@audit_opts)
  end

  # ---------------------------------------------------------------------------
  # AC1 -- real non-null before_state/after_state for a state-changing
  # operation. THE key test: this would have failed under the old
  # EventStore-backed implementation, which always emitted null for both.
  # ---------------------------------------------------------------------------

  describe "AC1 -- real before_state/after_state for a state-changing operation" do
    test "an activation-shaped audit entry (before + after) round-trips with real, non-null state" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac1")

      seed_audit_entry!(tenant.schema_name,
        action: "definition.activate",
        resource_type: "definition",
        before_state: %{"status" => "draft"},
        after_state: %{"status" => "active"}
      )

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [item] = body["items"]

      # The direct inverse of the old moduledoc's "before_state and after_state
      # are always null" -- both are real, non-null, and carry the actual
      # captured content, not a placeholder.
      assert item["before_state"] == %{"status" => "draft"}
      assert item["after_state"] == %{"status" => "active"}
      refute is_nil(item["before_state"])
      refute is_nil(item["after_state"])
    end

    test "an entry with no prior state (before_state nil) still returns real after_state" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac1-create")

      seed_audit_entry!(tenant.schema_name,
        action: "definition.create",
        before_state: nil,
        after_state: %{"name" => "brand-new"}
      )

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [item] = body["items"]
      assert item["before_state"] == nil
      assert item["after_state"] == %{"name" => "brand-new"}
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- resource_type varies by resource kind, not the constant "instance".
  # ---------------------------------------------------------------------------

  describe "AC2 -- resource_type varies by resource kind" do
    test "a single response contains at least two different resource_type values" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac2")

      seed_audit_entry!(tenant.schema_name,
        resource_type: "definition",
        action: "definition.create"
      )

      seed_audit_entry!(tenant.schema_name, resource_type: "instance", action: "instance.create")
      seed_audit_entry!(tenant.schema_name, resource_type: "task", action: "task.complete")

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      resource_types =
        body["items"] |> Enum.map(& &1["resource_type"]) |> Enum.uniq() |> Enum.sort()

      assert length(resource_types) >= 2
      assert resource_types == ["definition", "instance", "task"]
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- the resource_type query parameter actually filters.
  # ---------------------------------------------------------------------------

  describe "AC3 -- resource_type filter discriminates" do
    test "filtering to one resource kind returns only entries of that kind" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac3")

      seed_audit_entry!(tenant.schema_name,
        resource_type: "definition",
        action: "definition.create"
      )

      seed_audit_entry!(tenant.schema_name, resource_type: "task", action: "task.complete")
      seed_audit_entry!(tenant.schema_name, resource_type: "task", action: "task.assign")

      resp = get_audit(tenant, query_string: "resource_type=task")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 2
      assert Enum.all?(body["items"], &(&1["resource_type"] == "task"))
    end

    test "omitting resource_type returns all kinds" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac3-all")

      seed_audit_entry!(tenant.schema_name,
        resource_type: "definition",
        action: "definition.create"
      )

      seed_audit_entry!(tenant.schema_name, resource_type: "task", action: "task.complete")

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- response envelope matches RawAuditPage/RawAuditEntry field-for-field
  # (web/src/api/audit.ts).
  # ---------------------------------------------------------------------------

  describe "AC4 -- response shape matches web/src/api/audit.ts's RawAuditPage/RawAuditEntry" do
    test "page envelope has exactly items/next_cursor/count, item has exactly the 8 RawAuditEntry fields" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac4")

      entry =
        seed_audit_entry!(tenant.schema_name,
          resource_type: "definition",
          before_state: %{"v" => 1},
          after_state: %{"v" => 2}
        )

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      # RawAuditPage: items, next_cursor, count -- exactly these three keys.
      assert Map.keys(body) |> Enum.sort() == ["count", "items", "next_cursor"]
      assert is_integer(body["count"])
      assert [item] = body["items"]

      # RawAuditEntry (web/src/api/audit.ts:26-35): audit_id, actor_id, action,
      # resource_type, resource_id, timestamp, before_state, after_state --
      # exactly these 8 keys (+ actor_name, resource_name, T-1557), field by field. No `payload`, no
      # `pipeline_run_id`.
      assert Map.keys(item) |> Enum.sort() ==
               Enum.sort([
                 "audit_id",
                 "actor_name",
                 "resource_name",
                 "actor_id",
                 "action",
                 "resource_type",
                 "resource_id",
                 "timestamp",
                 "before_state",
                 "after_state"
               ])

      assert item["audit_id"] == entry.id
      assert item["actor_id"] == entry.actor_id
      assert item["action"] == entry.action
      assert item["resource_type"] == entry.resource_type
      assert item["resource_id"] == entry.resource_id
      assert item["timestamp"] == DateTime.to_iso8601(entry.timestamp)
      assert item["before_state"] == entry.before_state
      assert item["after_state"] == entry.after_state

      refute Map.has_key?(item, "payload")
      refute Map.has_key?(item, "pipeline_run_id")
    end

    test "a null actor_id passes through as JSON null, not omitted" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac4-nil-actor")
      seed_audit_entry!(tenant.schema_name, actor_id: nil)

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [item] = body["items"]
      assert Map.has_key?(item, "actor_id")
      assert item["actor_id"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC5 -- :AuditRead still enforced, 403 without it, no change to
  # lib/letflow/api/authorization.ex.
  # ---------------------------------------------------------------------------

  describe "AC5 -- :AuditRead permission still enforced" do
    test "TENANT_ADMIN (holds :AuditRead) gets 200" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac5-allow")
      seed_audit_entry!(tenant.schema_name)

      resp = get_audit(tenant, roles: ["TENANT_ADMIN"])

      assert resp.status == 200
    end

    test "TASK_WORKER (no :AuditRead) gets 403 and no entry data leaks" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac5-deny")
      entry = seed_audit_entry!(tenant.schema_name)

      resp = get_audit(tenant, roles: ["TASK_WORKER"])

      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 403
      refute Map.has_key?(body, "items")
      refute resp.resp_body =~ entry.resource_id
    end
  end

  # ---------------------------------------------------------------------------
  # AC6 -- cross-tenant isolation.
  # ---------------------------------------------------------------------------

  describe "AC6 -- a caller from one tenant does not receive another tenant's entries" do
    test "tenant A's response contains no tenant B audit_id/resource_id" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac6-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req196-ac6-b")

      entry_a = seed_audit_entry!(tenant_a.schema_name, resource_type: "definition")
      entry_b = seed_audit_entry!(tenant_b.schema_name, resource_type: "definition")

      resp = get_audit(tenant_a)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      audit_ids = Enum.map(body["items"], & &1["audit_id"])
      resource_ids = Enum.map(body["items"], & &1["resource_id"])

      assert entry_a.id in audit_ids
      refute entry_b.id in audit_ids
      refute entry_b.resource_id in resource_ids
    end
  end

  # ---------------------------------------------------------------------------
  # AC7 -- moduledoc no longer states before_state/after_state are always
  # null, or that resource_type is a constant; describes the new store.
  # ---------------------------------------------------------------------------

  describe "AC7 -- moduledoc content" do
    test "no stale always-null / constant-resource_type caveats remain" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _fn_docs} =
        Code.fetch_docs(Letflow.Routers.Audit)

      refute moduledoc =~ "before_state` and `after_state` are **always `null`**"
      refute moduledoc =~ "resource_type` is the constant string `\"instance\"`"
      refute moduledoc =~ "Letflow has no such table"
      refute moduledoc =~ "not supported — accepted, and honoured truthfully"
    end

    test "moduledoc positively describes the new audit_entries-backed source" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _fn_docs} =
        Code.fetch_docs(Letflow.Routers.Audit)

      assert moduledoc =~ "Letflow.Audit.list_entries/1"
      assert moduledoc =~ "audit_entries"
      assert moduledoc =~ "real, per-row resource kind"
    end
  end

  # ---------------------------------------------------------------------------
  # Router body no longer references Letflow.EventStore -- confirms the
  # repoint actually happened, not just the moduledoc's prose.
  # ---------------------------------------------------------------------------

  describe "router body is repointed off Letflow.EventStore" do
    test "no Repo./Ecto.Query call anywhere in lib/letflow/routers/audit.ex (INV-RT-1)" do
      source = File.read!("lib/letflow/routers/audit.ex")
      refute source =~ "Repo."
      refute source =~ "Ecto.Query"
    end

    test "the live handler calls Letflow.Audit.list_entries/1, not Letflow.EventStore.read_global/1" do
      source = File.read!("lib/letflow/routers/audit.ex")
      assert source =~ "Audit.list_entries("
      refute source =~ "EventStore.read_global("
    end
  end

  # ---------------------------------------------------------------------------
  # Pagination -- cursor round-trips over the new (timestamp, id) seek pair.
  # ---------------------------------------------------------------------------

  describe "pagination -- cursor round-trips over (timestamp, id)" do
    test "a page_size smaller than the row count returns has_more via a non-nil next_cursor, and the next page continues correctly" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-cursor")

      for n <- 1..3 do
        seed_audit_entry!(tenant.schema_name, resource_id: "res-#{n}")
      end

      resp1 = get_audit(tenant, query_string: "page_size=2")
      assert resp1.status == 200
      body1 = Jason.decode!(resp1.resp_body)
      assert body1["count"] == 2
      assert is_binary(body1["next_cursor"])

      resp2 =
        get_audit(tenant,
          query_string: "page_size=2&cursor=#{URI.encode_www_form(body1["next_cursor"])}"
        )

      assert resp2.status == 200
      body2 = Jason.decode!(resp2.resp_body)
      assert body2["count"] == 1
      assert body2["next_cursor"] == nil

      page1_ids = Enum.map(body1["items"], & &1["audit_id"])
      page2_ids = Enum.map(body2["items"], & &1["audit_id"])
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
    end

    test "an invalid cursor is rejected with 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-cursor-bad")

      resp = get_audit(tenant, query_string: "cursor=not-a-valid-cursor")

      assert resp.status == 400
    end
  end

  # ---------------------------------------------------------------------------
  # actor_id filter -- malformed UUID is a 422, not a crash.
  # ---------------------------------------------------------------------------

  describe "actor_id filter validation" do
    test "a malformed actor_id is rejected with 422, not a raised CastError" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-bad-actor")
      seed_audit_entry!(tenant.schema_name)

      resp = get_audit(tenant, query_string: "actor_id=not-a-uuid")

      assert resp.status == 422
    end

    test "a well-formed actor_id filters correctly" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-good-actor")
      actor_id = Ecto.UUID.generate()
      seed_audit_entry!(tenant.schema_name, actor_id: actor_id)
      seed_audit_entry!(tenant.schema_name, actor_id: Ecto.UUID.generate())

      resp = get_audit(tenant, query_string: "actor_id=#{actor_id}")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 1
      assert [item] = body["items"]
      assert item["actor_id"] == actor_id
    end
  end

  # ---------------------------------------------------------------------------
  # Gap-fill (TEST-DESIGNER, step-03b re-check): resource_id filter -- present
  # in design §1.3/§1.1 and implemented in `Letflow.Audit.list_entries/1`'s
  # `where_resource_id/2`, but had no dedicated test asserting it actually
  # discriminates. Mirrors the AC3 resource_type-filter test shape exactly.
  # ---------------------------------------------------------------------------

  describe "resource_id filter discriminates" do
    test "filtering to one resource_id returns only that entry" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-resid")

      seed_audit_entry!(tenant.schema_name, resource_id: "res-A", action: "definition.create")
      seed_audit_entry!(tenant.schema_name, resource_id: "res-B", action: "definition.create")
      seed_audit_entry!(tenant.schema_name, resource_id: "res-B", action: "definition.activate")

      resp = get_audit(tenant, query_string: "resource_id=res-A")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 1
      assert [item] = body["items"]
      assert item["resource_id"] == "res-A"
    end

    test "omitting resource_id returns entries for every resource_id" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-resid-all")

      seed_audit_entry!(tenant.schema_name, resource_id: "res-A")
      seed_audit_entry!(tenant.schema_name, resource_id: "res-B")

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Gap-fill: empty audit_entries table -- a freshly-provisioned tenant with no
  # rows must still return a well-shaped 200 page (items: [], count: 0,
  # next_cursor: nil), not an error and not a shape that only happens to work
  # when items is non-empty (list_entries/1's split_list_page/2 and
  # next_cursor/2 both have a `[]` clause that is otherwise never exercised by
  # any test in this file).
  # ---------------------------------------------------------------------------

  describe "empty audit_entries table" do
    test "a tenant with zero audit entries gets items: [], count: 0, next_cursor: nil, not an error" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-empty")

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["items"] == []
      assert body["count"] == 0
      assert body["next_cursor"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Gap-fill: page_size exact boundary. The existing pagination test only
  # covers page_size < row_count (has_more: true). The other side of
  # split_list_page/2's `length(rows) > page_size` branch -- exactly
  # page_size rows, no more -- must report has_more: false / next_cursor: nil,
  # not the has_more heuristic's documented false-positive shape.
  # ---------------------------------------------------------------------------

  describe "page_size exact boundary" do
    test "exactly page_size rows in the table yields has_more: false and a nil next_cursor" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-boundary")

      for n <- 1..2 do
        seed_audit_entry!(tenant.schema_name, resource_id: "boundary-#{n}")
      end

      resp = get_audit(tenant, query_string: "page_size=2")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 2
      assert body["next_cursor"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Gap-fill: from/to time-range filter -- declared supported in the router's
  # own "Filter disposition" table and implemented via `where_from/2`/
  # `where_to/2`, but had no test at all: neither the inclusive-bounds
  # filtering behavior, nor the `from > to` -> 422 `invalid_time_range` check
  # `handle_list/1`'s `check_time_range/2` performs before any query.
  #
  # `Entry.timestamp` is stamped internally by `insert_entry/3`
  # (`DateTime.utc_now()`, not attribute-overridable), so the only way to
  # assert `from`/`to` narrows the result set is to seed against real elapsed
  # time and read a cutoff back from the seeded rows themselves -- a short
  # `Process.sleep/1` between inserts (matching the established idiom at
  # `test/letflow/sandbox_pool_test.exs:149,186,729`) guarantees the two
  # entries land in different microseconds rather than asserting anything
  # about wall-clock time itself.
  # ---------------------------------------------------------------------------

  describe "from/to time-range filter" do
    test "from excludes entries stamped before it; to excludes entries stamped after it" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-timerange")

      early = seed_audit_entry!(tenant.schema_name, resource_id: "early")
      Process.sleep(5)
      cutoff = DateTime.utc_now()
      Process.sleep(5)
      late = seed_audit_entry!(tenant.schema_name, resource_id: "late")

      resp_from =
        get_audit(tenant,
          query_string: "from=#{URI.encode_www_form(DateTime.to_iso8601(cutoff))}"
        )

      assert resp_from.status == 200
      body_from = Jason.decode!(resp_from.resp_body)
      resource_ids_from = Enum.map(body_from["items"], & &1["resource_id"])
      assert late.resource_id in resource_ids_from
      refute early.resource_id in resource_ids_from

      resp_to =
        get_audit(tenant, query_string: "to=#{URI.encode_www_form(DateTime.to_iso8601(cutoff))}")

      assert resp_to.status == 200
      body_to = Jason.decode!(resp_to.resp_body)
      resource_ids_to = Enum.map(body_to["items"], & &1["resource_id"])
      assert early.resource_id in resource_ids_to
      refute late.resource_id in resource_ids_to
    end

    test "from > to is rejected with 422, before any query is issued" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-badrange")
      seed_audit_entry!(tenant.schema_name)

      later = DateTime.utc_now()
      earlier = DateTime.add(later, -60, :second)

      query =
        "from=#{URI.encode_www_form(DateTime.to_iso8601(later))}" <>
          "&to=#{URI.encode_www_form(DateTime.to_iso8601(earlier))}"

      resp = get_audit(tenant, query_string: query)

      assert resp.status == 422
    end
  end

  # ---------------------------------------------------------------------------
  # Gap-fill: malformed cursor variants beyond the one already-tested
  # base64-garbage case -- a cursor that decodes fine but was minted for a
  # DIFFERENT endpoint (`decode_cursor/4`'s `:wrong_endpoint` branch,
  # `check_prefix/2`), and a cursor with the correct "A:" prefix but a
  # malformed inner seek payload (`cursor_seek_from_cursor/1`'s own parse
  # failure, distinct from `Pagination.decode_cursor/4`'s failure).
  # ---------------------------------------------------------------------------

  describe "malformed cursor variants" do
    test "a cursor minted with a different endpoint's prefix is rejected with 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-wrongendpoint")
      seed_audit_entry!(tenant.schema_name)

      wrong_endpoint_cursor =
        Letflow.Api.Pagination.build_raw_cursor(
          "T:",
          System.system_time(:microsecond),
          "some-key"
        )
        |> Letflow.Api.Pagination.encode_cursor()

      resp =
        get_audit(tenant, query_string: "cursor=#{URI.encode_www_form(wrong_endpoint_cursor)}")

      assert resp.status == 400
    end

    test "a cursor with the right prefix but a malformed inner seek payload is rejected with 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req196-gap-badinner")
      seed_audit_entry!(tenant.schema_name)

      # "A:" prefix present (passes check_prefix/2), but the payload after it
      # has no parseable "<entry_ts_us>:<entry_id>" seek pair --
      # cursor_seek_from_cursor/1 must fail this, not raise.
      malformed_inner_cursor =
        Letflow.Api.Pagination.build_raw_cursor(
          "A:",
          System.system_time(:microsecond),
          "not-a-timestamp-colon-uuid"
        )
        |> Letflow.Api.Pagination.encode_cursor()

      resp =
        get_audit(tenant, query_string: "cursor=#{URI.encode_www_form(malformed_inner_cursor)}")

      assert resp.status == 400
    end
  end
end
