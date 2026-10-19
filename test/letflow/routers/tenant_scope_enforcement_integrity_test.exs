defmodule Letflow.Routers.TenantScopeEnforcementIntegrityTest do
  @moduledoc """
  REQ-519 slice 2f-a (GH #2535), AC 9 last sentence (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.4 and 8.3; SEC
  code-gate merge condition "integrity body diff exact key sets", step-16 pr_body_items;
  spec `test/specs/REQ-519-2f-a.md`): the `on_gate` block of
  `GET /tenant/scope-enforcement/integrity`.

  The stage-1 keys (`bindings_without_row`, `items`, `orphan_group_rows`, `truncated`,
  `findings`) are pinned by `tenant_scope_enforcement_test.exs` (T-I1, where the clean-body
  assertion was edited on purpose to peel `on_gate` off). Here the NEW block:

    * the EXACT key sets of every level (top level gains only `on_gate`), so a field added to the
      body is a failing test;
    * counts, enums, dates and booleans only: no id, no name, no token data (INV-2);
    * `blocking` carries the stable gate codes in read order and agrees with the facts seeded;
      `information` carries the scoped-task-worker count that never blocks;
    * the two spellings: `findings` is the stage-1 informational list (OLD admin count),
      `on_gate.blocking` is what the `on` flip will check (explicit INTERACTIVE count, C-4);
    * it is a read: no audit entry;
    * a tenant that satisfies every fact reports `blocking: []`.

  Request shape as in `tenant_scope_enforcement_test.exs`: the router `call/2` with a hand
  assigned `auth_context` of a REAL tenant-wide TENANT_ADMIN user.

  `async: false`: committed writes, VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @router Letflow.Routers.TenantScopeEnforcement
  @trace "req519-2fa-router-trace-0001"

  setup do
    Fixture.unpin!()
    :ok
  end

  defp call(method, path, fx, user_id, roles, body) do
    method
    |> Fixture.router_conn(path, fx, roles, body)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: fx.tenant_id,
      roles: roles,
      credential: :oidc
    })
    |> assign(:trace_id, @trace)
    |> @router.call(@router.init([]))
  end

  defp integrity(fx), do: call(:get, "/integrity", fx, fx.admin.id, ["TENANT_ADMIN"], nil)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()

  defp sorted(list), do: Enum.sort(list)

  describe "the exact key sets of the on_gate block" do
    test "a clean tenant: every level is exactly the documented set, with the documented values" do
      fx = F.admin_tenant!("req519-ri1")
      conn = integrity(fx)

      assert conn.status == 200
      b = body(conn)

      assert sorted_keys(b) ==
               sorted(~w(bindings_without_row findings items on_gate orphan_group_rows truncated))

      gate = b["on_gate"]
      assert sorted_keys(gate) == sorted(~w(blocking counts evidence information))

      assert sorted_keys(gate["counts"]) ==
               sorted(~w(bindings_without_row explicit_tenant_wide_admins org_consistency
                         scoped_approvers tokens_exceeding_owner))

      assert gate["counts"] == %{
               "bindings_without_row" => 0,
               "org_consistency" => "ok",
               "tokens_exceeding_owner" => 0,
               "explicit_tenant_wide_admins" => 1,
               "scoped_approvers" => 0
             }

      assert gate["information"] == %{"scoped_task_workers_without_task_scope" => 0}

      ev = gate["evidence"]

      assert sorted_keys(ev) ==
               sorted(~w(criteria days_without_requests evidence_scope requests shadow_since
                         window_from window_to would_deny))

      assert sorted_keys(ev["criteria"]) ==
               sorted(~w(configuration duration every_day_has_requests no_blocking_would_deny
                         requests))

      assert sorted_keys(ev["would_deny"]) ==
               sorted(~w(grants_unavailable no_grant_rows not_tenant_wide out_of_scope
                         role_not_held unresolvable))

      assert ev["evidence_scope"] == "tenant_wide_and_admin_plane_routes_only"
      assert ev["shadow_since"] == nil
      assert ev["requests"] == 0
      assert ev["days_without_requests"] == 8

      assert ev["criteria"] == %{
               "duration" => false,
               "requests" => false,
               "every_day_has_requests" => false,
               "no_blocking_would_deny" => true,
               "configuration" => true
             }

      assert Enum.all?(ev["would_deny"], fn {_reason, count} -> count == 0 end)
      assert gate["blocking"] == ["shadow_evidence_insufficient"]

      to = Date.from_iso8601!(ev["window_to"])
      from = Date.from_iso8601!(ev["window_from"])
      assert Date.diff(to, from) == 7
    end

    test "a shadow tenant reports its start as an ISO-8601 instant" do
      fx = F.shadow_tenant!("req519-ri1b")

      ev = body(integrity(fx))["on_gate"]["evidence"]

      assert ev["shadow_since"] == DateTime.to_iso8601(fx.t0)
      assert ev["criteria"]["duration"] == false
    end
  end

  describe "no id, name or token data inside on_gate (INV-2)" do
    test "with every kind of fact seeded, the on_gate subtree holds no id" do
      fx = F.shadow_tenant!("req519-ri2")
      schema = fx.schema_name
      _approver = F.scoped_task_worker!(schema, true)
      g = RSG.fresh_group!(schema)
      _gap = RSG.raw_binding!(schema, "PROCESS_OPERATOR", :platform_role, g.id)
      lone = RSG.user!(schema)
      _token = F.raw_token!(schema, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)
      :ok = F.seed_orphan_node!(schema)

      b = body(integrity(fx))
      json = Jason.encode!(b["on_gate"])

      refute F.uuid_in?(json)
      refute json =~ fx.tenant_id
      refute json =~ schema
      refute json =~ "PROCESS_OPERATOR"
      refute json =~ "PROCESS_DESIGNER"
      refute json =~ "lf_tok_"

      # the stage-1 part of the body still lists the gap (unchanged behaviour)
      assert b["bindings_without_row"] == 1
    end
  end

  describe "blocking, information and counts follow the seeded facts" do
    test "every fact seeded: the stable codes in read order, the counts, the informational worker" do
      fx = F.shadow_tenant!("req519-ri3")
      schema = fx.schema_name
      _approver = F.scoped_task_worker!(schema, true)
      _worker = F.scoped_task_worker!(schema, false)
      g = RSG.fresh_group!(schema)
      _gap = RSG.raw_binding!(schema, "PROCESS_OPERATOR", :platform_role, g.id)
      lone = RSG.user!(schema)
      _token = F.raw_token!(schema, lone.id, ["PROCESS_DESIGNER"], fx.admin.id)
      :ok = F.seed_orphan_node!(schema)

      gate = body(integrity(fx))["on_gate"]

      assert gate["blocking"] == [
               "bindings_without_row",
               "org_inconsistent",
               "tokens_exceed_owner",
               "scoped_approvers_without_task_scope",
               "shadow_evidence_insufficient"
             ]

      assert gate["counts"] == %{
               "bindings_without_row" => 1,
               "org_consistency" => "inconsistent",
               "tokens_exceeding_owner" => 1,
               "explicit_tenant_wide_admins" => 1,
               "scoped_approvers" => 1
             }

      assert gate["information"] == %{"scoped_task_workers_without_task_scope" => 1}
    end

    test "a scoped task worker who is not an approver is information only: it is not in blocking" do
      fx = F.admin_tenant!("req519-ri3b")
      _worker = F.scoped_task_worker!(fx.schema_name, false)

      gate = body(integrity(fx))["on_gate"]

      refute "scoped_approvers_without_task_scope" in gate["blocking"]
      assert gate["information"] == %{"scoped_task_workers_without_task_scope" => 1}
      assert gate["counts"]["scoped_approvers"] == 0
    end
  end

  describe "the two spellings of zero_tenant_wide_admins on one endpoint" do
    test "findings (stage-1, OLD count) stays empty while on_gate.blocking (explicit interactive count) names it" do
      fx = F.admin_tenant!("req519-ri4")
      :ok = F.flag_service_principal!(fx.schema_name, fx.admin.id)

      b = body(integrity(fx))

      assert b["findings"] == []
      assert "zero_tenant_wide_admins" in b["on_gate"]["blocking"]
      assert b["on_gate"]["counts"]["explicit_tenant_wide_admins"] == 0
    end

    test "the explicit count follows membership, per tenant" do
      fx = F.admin_tenant!("req519-ri4b")
      other = F.admin_tenant!("req519-ri4c")

      # a second administrator makes the caller, then the first one leaves
      second = TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"])
      :ok = F.remove_memberships!(fx.schema_name, fx.admin.id)

      conn = call(:get, "/integrity", fx, second.id, ["TENANT_ADMIN"], nil)

      assert conn.status == 200
      assert body(conn)["findings"] == []
      assert body(conn)["on_gate"]["counts"]["explicit_tenant_wide_admins"] == 1
      refute "zero_tenant_wide_admins" in body(conn)["on_gate"]["blocking"]

      # the other tenant is untouched by all of this
      assert body(integrity(other))["on_gate"]["counts"]["explicit_tenant_wide_admins"] == 1
    end
  end

  describe "a read" do
    test "GET /integrity writes no audit entry, however often it is called" do
      fx = F.shadow_tenant!("req519-ri5")
      before = Repo.aggregate(Entry, :count, prefix: fx.schema_name)

      assert integrity(fx).status == 200
      assert integrity(fx).status == 200

      assert Repo.aggregate(Entry, :count, prefix: fx.schema_name) == before
    end
  end

  describe "a tenant that satisfies every fact" do
    test "reports blocking [] with every criterion true" do
      fx = F.admin_tenant!("req519-ri6")
      # a genuine-shaped shadow start eight days ago (raw: the wall clock is not stubbed here)
      eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * F.day_seconds(), :second)

      _ =
        F.raw_entry!(fx, %{
          action: "scope.enforcement_enabled",
          resource_type: "tenant",
          resource_id: fx.tenant_id,
          timestamp: eight_days_ago,
          after_state: %{"mode" => "shadow"}
        })

      gate = green_gate(fx, 3)

      assert gate["blocking"] == []
      assert Enum.all?(gate["evidence"]["criteria"], fn {_name, met?} -> met? end)
      assert gate["evidence"]["requests"] == 160
      assert gate["evidence"]["days_without_requests"] == 0
    end
  end

  # The request is evaluated against the REAL clock; if the UTC date changes between seeding
  # and the answer, the window moved and the seed is redone (bounded), so no run is flaky at
  # midnight.
  defp green_gate(fx, tries) do
    day = Date.utc_today()
    :ok = F.seed_requests!(fx, DateTime.utc_now(), 7, 20)
    gate = body(integrity(fx))["on_gate"]

    if Date.utc_today() == day or tries == 0 do
      gate
    else
      green_gate(fx, tries - 1)
    end
  end
end
