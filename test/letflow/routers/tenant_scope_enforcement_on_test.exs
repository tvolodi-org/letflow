defmodule Letflow.Routers.TenantScopeEnforcementOnTest do
  @moduledoc """
  REQ-519 slice 2f-b (GH #2535), AC 8, AC 13, AC 14 (HTTP half), AC 18 (route half) at the HTTP
  layer: `PUT /tenant/scope-enforcement` with `on` settable (design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.2 and 8.4, tests T-H1..T-H10,
  T-X14; SEC step-21 merge conditions; spec `test/specs/REQ-519-2f-b.md`).

    * the PUT AUTHORITY MATRIX: an interactive (OIDC) tenant-wide `TENANT_ADMIN` is the only caller
      allowed, for EVERY transition (`off -> shadow`, `shadow -> on`, `on -> shadow`, `-> off`); an
      API token (also one holding `TENANT_ADMIN` whose owner is a tenant-wide admin, also through
      the full `Letflow.Router`), a platform-tenant `PLATFORM_ADMIN` without `TENANT_ADMIN`, a
      scoped-only admin, an OIDC admin whose group has zero rows, a flagged service principal and a
      non-admin all answer the SAME 403 body, change nothing and write no audit entry;
    * the live `shadow -> on` flip through the PUT with a satisfied gate (200, `enabled` entry) and
      the walk back (`on -> shadow` needs a reason and runs no gate, `-> off` needs a reason);
    * the 409 bodies: `shadow_required` (`current_mode` constant `off`) and
      `enforcement_precondition_failed` (`failed` codes, the six `report` counts, the `evidence`
      summary): exact key sets, values, no id; the refusal entry is written after the rollback;
    * a raise inside the gate is a detail-free 500 with exactly ONE `scope_enforcement_flip_failed`
      line and never a refusal entry; the body can never supply a clock;
    * `GET /integrity` on a raise: one constant `scope_enforcement_integrity_failed` line and a
      detail-free 500.

  Requests are dispatched straight into `Letflow.Routers.TenantScopeEnforcement.call/2` with a
  hand-assigned `auth_context` (the style of the router suite), plus one full-pipeline case.
  `async: false`: committed writes, committed DDL, VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.ShadowWindow
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.TokenMintFixture

  @router Letflow.Routers.TenantScopeEnforcement
  @trace "req519-2fb-route-trace-0001"
  @enabled "scope.enforcement_enabled"
  @disabled "scope.enforcement_disabled"
  @refused "scope.enforcement_refused"

  @report_keys [
    "bindings_without_row",
    "explicit_tenant_wide_admins",
    "org_consistency",
    "scoped_approvers",
    "scoped_task_workers_without_task_scope",
    "tokens_exceeding_owner"
  ]
  @evidence_keys [
    "criteria",
    "days_without_requests",
    "evidence_scope",
    "requests",
    "shadow_since",
    "window_from",
    "window_to",
    "would_deny"
  ]
  @criteria_keys [
    "configuration",
    "duration",
    "every_day_has_requests",
    "no_blocking_would_deny",
    "requests"
  ]
  @reasons ~w(role_not_held no_grant_rows not_tenant_wide out_of_scope unresolvable grants_unavailable)

  setup do
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp ctx(fx, user_id, roles, credential),
    do: %{user_id: user_id, tenant_id: fx.tenant_id, roles: roles, credential: credential}

  defp call(method, path, fx, auth_context, body) do
    method
    |> Fixture.router_conn(path, fx, auth_context.roles, body)
    |> assign(:auth_context, auth_context)
    |> assign(:trace_id, @trace)
    |> @router.call(@router.init([]))
  end

  defp admin_ctx(fx), do: ctx(fx, fx.admin.id, ["TENANT_ADMIN"], :oidc)
  defp put_as(fx, auth_context, body), do: call(:put, "/", fx, auth_context, body)
  defp put_admin(fx, body), do: put_as(fx, admin_ctx(fx), body)
  defp get_admin(fx, path), do: call(:get, path, fx, admin_ctx(fx), nil)
  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp store!(fx, mode), do: ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: [e.timestamp, e.id]),
      prefix: fx.schema_name
    )
  end

  defp flip_entries(fx), do: entries(fx, @enabled) ++ entries(fx, @disabled)

  defp all_audit_ids(fx), do: Repo.all(from(e in Entry, select: e.id), prefix: fx.schema_name)

  # a tenant that satisfies the gate at the injected clock `fx.now`, not at the real one
  defp injected_clock_green!(slug_prefix) do
    fx = F.shadow_tenant!(slug_prefix)
    :ok = F.satisfy!(fx, fx.now)
    fx
  end

  # the keys every problem body shares (derived, so the exact extension key sets can be pinned)
  defp base_problem_keys do
    fx = F.admin_tenant!("req519-h-base")
    conn = put_admin(fx, %{"mode" => "on"})
    assert conn.status == 409
    assert body(conn)["detail"] == "shadow_required"
    keys = body(conn) |> Map.keys() |> Enum.sort()
    assert "current_mode" in keys
    base = keys -- ["current_mode"]
    assert "detail" in base and "status" in base
    base
  end

  # --- T-H1: the permission scope ----------------------------------------------------------------

  describe "T-H1 the composed permission scope (design F8)" do
    test "ScopeEnforcementManage is a tenant-scope permission" do
      permission = Letflow.Api.Authorization.required_permission(:ScopeEnforcementManage)
      assert Letflow.Api.Authorization.permission_scope(permission) == :tenant
    end

    test "the PUT handler uses the shared interactive-admin helper and both routes share it" do
      router = File.read!("lib/letflow/routers/tenant_scope_enforcement.ex")
      identity = File.read!("lib/letflow/routers/identity.ex")

      assert router =~ "Scope.require_interactive_tenant_admin(conn)"
      assert identity =~ "Scope.require_interactive_tenant_admin(conn)"

      # the two private copies were deleted: the gates cannot diverge
      refute identity =~ "defp require_oidc"
      refute identity =~ "defp require_tenant_admin_tenant_wide"
    end
  end

  # --- T-H2: the authority matrix -----------------------------------------------------------------

  @transitions [
    {:off, "shadow"},
    {:shadow, "on"},
    {:on, "shadow"},
    {:shadow, "off"},
    {:on, "off"}
  ]

  # Every caller below is refused with the same bytes for every transition: a probe that tells
  # callers apart would leak who holds what.
  describe "T-H2 PUT authority: only an interactive tenant-wide TENANT_ADMIN" do
    test "every non-allowed caller gets the identical 403 for every transition; nothing changes" do
      fx = F.admin_tenant!("req519-h2")
      schema = fx.schema_name

      scoped_admin = On.scoped_holder!(fx, "TENANT_ADMIN")
      sp = TokenMintFixture.role_holder!(schema, ["TENANT_ADMIN"])
      :ok = F.flag_service_principal!(schema, sp.id)
      reader = RSG.user!(schema)

      callers = [
        # an API token holding TENANT_ADMIN whose owner IS a tenant-wide admin
        {:token_with_admin_owner, ctx(fx, fx.admin.id, ["TENANT_ADMIN"], :api_token)},
        {:token_without_credential_key,
         Map.delete(ctx(fx, fx.admin.id, ["TENANT_ADMIN"], :oidc), :credential)},
        {:scoped_only_admin, ctx(fx, scoped_admin.id, ["TENANT_ADMIN"], :oidc)},
        {:flagged_service_principal_token, ctx(fx, sp.id, ["TENANT_ADMIN"], :api_token)},
        {:non_admin, ctx(fx, reader.id, ["PROCESS_DESIGNER"], :oidc)},
        {:unknown_user, ctx(fx, Ecto.UUID.generate(), ["TENANT_ADMIN"], :oidc)}
      ]

      bodies =
        for {label, auth_context} <- callers, {from, to} <- @transitions do
          store!(fx, from)
          audit_before = all_audit_ids(fx)

          conn = put_as(fx, auth_context, %{"mode" => to, "reason" => "req519 matrix"})
          tag = "#{label} #{from} -> #{to}"

          assert conn.status == 403, tag
          assert body(conn)["detail"] == "insufficient permissions", tag
          assert mode!(fx) == from, tag
          assert all_audit_ids(fx) == audit_before, tag
          conn.resp_body
        end

      assert bodies |> Enum.uniq() |> length() == 1
    end

    test "an OIDC admin whose TENANT_ADMIN group has ZERO rows is refused the same way" do
      fx = F.admin_tenant!("req519-h2z")
      group_id = RSG.group_of!(fx.schema_name, "TENANT_ADMIN")
      assert RSG.raw_delete_rows!(fx.schema_name, group_id, "TENANT_ADMIN") == 1

      reference = refused_reference_body()

      for {from, to} <- @transitions do
        store!(fx, from)
        conn = put_admin(fx, %{"mode" => to, "reason" => "req519 zero rows"})

        assert conn.status == 403, "#{from} -> #{to}"
        assert conn.resp_body == reference
        assert mode!(fx) == from
      end
    end

    test "a platform-tenant PLATFORM_ADMIN WITHOUT TENANT_ADMIN is refused every transition" do
      p = F.admin_tenant!("req519-h2p")
      # the reference tenant is built BEFORE the pin: building a tenant through the fixture
      # clears the platform pin, which would make this caller an ordinary one
      reference = refused_reference_body()
      :ok = Fixture.pin!(p.tenant_id)
      assert Letflow.PlatformTenant.platform_tenant?(p.tenant_id)
      operator = RSG.user!(p.schema_name)
      operator_ctx = ctx(p, operator.id, ["PLATFORM_ADMIN"], :oidc)

      for {from, to} <- @transitions do
        store!(p, from)
        audit_before = all_audit_ids(p)

        conn = put_as(p, operator_ctx, %{"mode" => to, "reason" => "req519 platform"})

        assert conn.status == 403, "#{from} -> #{to}"
        assert conn.resp_body == reference
        assert mode!(p) == from
        assert all_audit_ids(p) == audit_before
      end
    end

    # TEST-DESIGN-VALIDATOR (2f-b): the helper has four overlapping checks. In an ORDINARY tenant a
    # caller that fails one is stopped by another. The PLATFORM tenant is the one place where the
    # tenant-wide permission check passes on the PLATFORM_ADMIN shortcut alone, so the
    # effective-scope check (4) can be isolated here (mutant "check 4 dropped" is killed only by
    # the next test). The credential check (1), the permission check (2) and the role check (3)
    # are each subsumed by (4) or (2): `effective_scope/2` is `:deny` for a token principal and for
    # a role not held, `principal_from_conn/1` fails for any other credential, and check (2) passes
    # for every caller that passes (3) and (4). Those single-check mutants are EQUIVALENT.
    test "platform tenant: PLATFORM_ADMIN with only a SCOPED TENANT_ADMIN row is refused every transition" do
      p = F.admin_tenant!("req519-h2ps")
      reference = refused_reference_body()
      :ok = Fixture.pin!(p.tenant_id)
      assert Letflow.PlatformTenant.platform_tenant?(p.tenant_id)
      scoped_admin = On.scoped_holder!(p, "TENANT_ADMIN")
      caller = ctx(p, scoped_admin.id, ["PLATFORM_ADMIN", "TENANT_ADMIN"], :oidc)

      for {from, to} <- @transitions do
        store!(p, from)
        audit_before = all_audit_ids(p)

        conn = put_as(p, caller, %{"mode" => to, "reason" => "req519 platform scoped admin"})

        assert conn.status == 403, "#{from} -> #{to}"
        assert conn.resp_body == reference
        assert mode!(p) == from
        assert all_audit_ids(p) == audit_before
      end
    end

    test "platform tenant: a context without the TENANT_ADMIN role is refused despite tenant-wide rows" do
      p = F.admin_tenant!("req519-h2pr")
      reference = refused_reference_body()
      :ok = Fixture.pin!(p.tenant_id)
      assert Letflow.PlatformTenant.platform_tenant?(p.tenant_id)
      # p.admin is a tenant-wide admin by its rows; the context claims PLATFORM_ADMIN only
      caller = ctx(p, p.admin.id, ["PLATFORM_ADMIN"], :oidc)

      # positive control: the SAME user and rows with the TENANT_ADMIN role in the context pass
      control = ctx(p, p.admin.id, ["PLATFORM_ADMIN", "TENANT_ADMIN"], :oidc)
      assert put_as(p, control, %{"mode" => "shadow"}).status == 200
      store!(p, :off)

      for {from, to} <- @transitions do
        store!(p, from)
        audit_before = all_audit_ids(p)

        conn = put_as(p, caller, %{"mode" => to, "reason" => "req519 platform role"})

        assert conn.status == 403, "#{from} -> #{to}"
        assert conn.resp_body == reference
        assert mode!(p) == from
        assert all_audit_ids(p) == audit_before
      end
    end

    test "through the FULL pipeline an API token (admin role, tenant-wide admin owner) is refused the PUT and still reads GET /" do
      fx = F.admin_tenant!("req519-h2f")

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(fx.admin.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: fx.schema_name
        )

      path = "/api/v1/tenant/scope-enforcement"

      put =
        Fixture.api_conn(:put, path, plaintext, fx.tenant.slug, %{"mode" => "shadow"})
        |> Fixture.dispatch_api()

      assert put.status == 403
      assert body(put)["detail"] == "insufficient permissions"
      assert mode!(fx) == :off

      get = Fixture.api_conn(:get, path, plaintext, fx.tenant.slug, nil) |> Fixture.dispatch_api()
      assert get.status == 200
      assert body(get)["mode"] == "off"
    end

    # T-H3 (the GET routes keep serving tokens, tenant-wide only)
    test "T-H3 the GET routes still serve an API token with a tenant-wide admin owner and refuse a scoped admin" do
      fx = F.admin_tenant!("req519-h3")
      scoped_admin = On.scoped_holder!(fx, "TENANT_ADMIN")
      token = ctx(fx, fx.admin.id, ["TENANT_ADMIN"], :api_token)

      for path <- ["/", "/integrity"] do
        assert call(:get, path, fx, token, nil).status == 200, path

        denied = call(:get, path, fx, ctx(fx, scoped_admin.id, ["TENANT_ADMIN"], :oidc), nil)
        assert denied.status == 403, path
      end
    end

    # the same allowed caller is accepted by the helper (the matrix has a positive control)
    test "the interactive tenant-wide TENANT_ADMIN is allowed: off -> shadow" do
      fx = F.admin_tenant!("req519-h2ok")

      conn = put_admin(fx, %{"mode" => "shadow"})

      assert conn.status == 200
      assert body(conn) == %{"mode" => "shadow", "previous" => "off", "changed" => true}
    end
  end

  # The one 403 body, taken from a plainly refused caller (a token) of a throwaway tenant.
  defp refused_reference_body do
    fx = F.admin_tenant!("req519-h-ref")
    conn = put_as(fx, ctx(fx, fx.admin.id, ["TENANT_ADMIN"], :api_token), %{"mode" => "shadow"})
    assert conn.status == 403
    conn.resp_body
  end

  # --- the live flip through the PUT ---------------------------------------------------------------

  describe "shadow -> on through the PUT with a satisfied gate" do
    test "200, mode on, one enabled entry with the six counts; then the walk back with reasons" do
      fx = F.backdated_shadow_tenant!("req519-h-live")

      conn = put_admin(fx, %{"mode" => "on", "reason" => "req519 pilot"})

      assert conn.status == 200, conn.resp_body
      assert body(conn) == %{"mode" => "on", "previous" => "shadow", "changed" => true}
      assert mode!(fx) == :on

      assert [_raw_t0, entry] = entries(fx, @enabled)
      assert entry.before_state == %{"mode" => "shadow"}
      assert entry.after_state["mode"] == "on"
      assert entry.after_state["reason"] == "req519 pilot"
      assert Enum.sort(Map.keys(entry.after_state["preconditions"])) == @report_keys
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == @trace
      assert entries(fx, @refused) == []

      # a same-mode PUT is a no-op
      conn = put_admin(fx, %{"mode" => "on"})
      assert conn.status == 200
      assert body(conn) == %{"mode" => "on", "previous" => "on", "changed" => false}

      # on -> shadow: a reason is mandatory (422) and nothing changes without one
      conn = put_admin(fx, %{"mode" => "shadow"})
      assert conn.status == 422
      assert body(conn)["detail"] == "reason_required"
      assert mode!(fx) == :on

      conn = put_admin(fx, %{"mode" => "shadow", "reason" => 5})
      assert conn.status == 422
      assert body(conn)["detail"] == "invalid_reason"
      assert mode!(fx) == :on

      conn = put_admin(fx, %{"mode" => "shadow", "reason" => "req519 pause"})
      assert conn.status == 200
      assert body(conn) == %{"mode" => "shadow", "previous" => "on", "changed" => true}

      assert [disabled] = entries(fx, @disabled)
      assert disabled.after_state == %{"mode" => "shadow", "reason" => "req519 pause"}
    end

    test "on -> shadow runs NO gate check: it succeeds with every fact failing; on -> off needs a reason" do
      fx = F.backdated_shadow_tenant!("req519-h-down")
      assert put_admin(fx, %{"mode" => "on"}).status == 200

      # a second admin stays the caller: breaking the facts removes the first admin's membership
      second = RSG.user!(fx.schema_name)
      _ = TokenMintFixture.grant_roles!(fx.schema_name, second.id, ["TENANT_ADMIN"])
      caller = ctx(fx, second.id, ["TENANT_ADMIN"], :oidc)
      F.break_all_facts!(fx)

      conn = put_as(fx, caller, %{"mode" => "shadow", "reason" => "req519 with failing facts"})
      assert conn.status == 200, conn.resp_body
      assert mode!(fx) == :shadow

      assert put_as(fx, caller, %{"mode" => "off"}).status == 422
      assert mode!(fx) == :shadow

      conn = put_as(fx, caller, %{"mode" => "off", "reason" => "req519 off"})
      assert conn.status == 200
      assert mode!(fx) == :off
      assert entries(fx, @refused) == []
    end

    test "same-mode rules: off -> off needs a reason (422), then is a no-op; shadow -> shadow needs none" do
      fx = F.admin_tenant!("req519-h-same")

      conn = put_admin(fx, %{"mode" => "off"})
      assert conn.status == 422
      assert body(conn)["detail"] == "reason_required"

      conn = put_admin(fx, %{"mode" => "off", "reason" => "req519 noop"})
      assert conn.status == 200
      assert body(conn) == %{"mode" => "off", "previous" => "off", "changed" => false}

      assert put_admin(fx, %{"mode" => "shadow"}).status == 200
      conn = put_admin(fx, %{"mode" => "shadow"})
      assert conn.status == 200
      assert body(conn) == %{"mode" => "shadow", "previous" => "shadow", "changed" => false}
      assert length(flip_entries(fx)) == 1
    end
  end

  # --- T-H5 / T-H6 / T-H7: the 409 bodies -----------------------------------------------------------

  describe "T-H6 409 shadow_required" do
    test "off -> on: exact body, current_mode is the constant off, one refusal entry written after the rollback" do
      base = base_problem_keys()
      fx = F.admin_tenant!("req519-h6")

      conn = put_admin(fx, %{"mode" => "on", "reason" => "req519 try"})

      assert conn.status == 409
      b = body(conn)
      assert Enum.sort(Map.keys(b)) == Enum.sort(base ++ ["current_mode"])
      assert b["detail"] == "shadow_required"
      assert b["current_mode"] == "off"
      refute F.uuid_in?(conn.resp_body)

      assert mode!(fx) == :off
      assert flip_entries(fx) == []
      assert [refusal] = entries(fx, @refused)
      assert refusal.before_state == %{"mode" => "off"}
      assert refusal.after_state["failed"] == ["shadow_required"]
      assert refusal.after_state["target"] == "on"
      assert refusal.actor_id == fx.admin.id
      assert refusal.trace_id == @trace
    end
  end

  describe "T-H5 / T-H7 409 enforcement_precondition_failed for on" do
    test "a fresh shadow tenant: exact key sets of body, report and evidence, values, no id" do
      base = base_problem_keys()
      fx = F.admin_tenant!("req519-h5")
      assert put_admin(fx, %{"mode" => "shadow"}).status == 200

      conn = put_admin(fx, %{"mode" => "on"})

      assert conn.status == 409
      b = body(conn)
      assert Enum.sort(Map.keys(b)) == Enum.sort(base ++ ["evidence", "failed", "report"])
      assert b["detail"] == "enforcement_precondition_failed"
      assert b["failed"] == ["shadow_evidence_insufficient"]

      assert Enum.sort(Map.keys(b["report"])) == @report_keys

      assert b["report"] == %{
               "bindings_without_row" => 0,
               "org_consistency" => "ok",
               "tokens_exceeding_owner" => 0,
               "explicit_tenant_wide_admins" => 1,
               "scoped_approvers" => 0,
               "scoped_task_workers_without_task_scope" => 0
             }

      evidence = b["evidence"]
      assert Enum.sort(Map.keys(evidence)) == @evidence_keys
      assert Enum.sort(Map.keys(evidence["criteria"])) == @criteria_keys
      assert Enum.sort(Map.keys(evidence["would_deny"])) == Enum.sort(@reasons)
      assert Enum.all?(Map.values(evidence["would_deny"]), &(&1 == 0))
      assert evidence["evidence_scope"] == ShadowWindow.evidence_scope()
      assert is_integer(evidence["requests"])
      assert is_integer(evidence["days_without_requests"])

      # the dates are ISO-8601 strings and the window spans min_days
      assert {:ok, _, 0} = DateTime.from_iso8601(evidence["shadow_since"])
      to = Date.from_iso8601!(evidence["window_to"])
      from = Date.from_iso8601!(evidence["window_from"])
      assert Date.diff(to, from) == ShadowWindow.thresholds().min_days

      assert evidence["criteria"]["duration"] == false
      assert evidence["criteria"]["requests"] == false

      # INV-2: no id of any kind in the refusal body
      refute F.uuid_in?(conn.resp_body)
      refute conn.resp_body =~ fx.schema_name

      # the refusal entry is committed after the rollback; the flag did not move
      assert mode!(fx) == :shadow
      assert [refusal] = entries(fx, @refused)
      assert refusal.after_state["failed"] == ["shadow_evidence_insufficient"]
      assert entries(fx, @enabled) |> length() == 1
    end

    test "each of facts 1 to 5 alone is named by its stable code, with the matching report count" do
      expected = [
        {:bindings_without_row, "bindings_without_row", 1},
        {:org_inconsistent, "org_consistency", "inconsistent"},
        {:tokens_exceed_owner, "tokens_exceeding_owner", 1},
        {:zero_tenant_wide_admins, "explicit_tenant_wide_admins", 0},
        {:scoped_approvers_without_task_scope, "scoped_approvers", 1}
      ]

      for {{code, count_key, value}, index} <- Enum.with_index(expected) do
        fx = F.backdated_shadow_tenant!("req519-h5-#{index}")
        # the admin must stay: the zero-admin case is the one that removes it, via break_fact!
        :ok = F.break_fact!(fx, code)

        # the interactive admin is gone in the zero-admin case, so use a second admin as the caller
        caller =
          if code == :zero_tenant_wide_admins do
            second = RSG.user!(fx.schema_name)
            _ = TokenMintFixture.grant_roles!(fx.schema_name, second.id, ["TENANT_ADMIN"])
            # a second admin would satisfy fact 4: remove it from the count again by flagging it
            :ok = F.flag_service_principal!(fx.schema_name, second.id)
            ctx(fx, second.id, ["TENANT_ADMIN"], :oidc)
          else
            admin_ctx(fx)
          end

        conn = put_as(fx, caller, %{"mode" => "on"})

        assert conn.status == 409, "#{code}: #{conn.resp_body}"
        assert body(conn)["failed"] == [Atom.to_string(code)], "#{code}"
        assert body(conn)["report"][count_key] == value, "#{code}"
        assert mode!(fx) == :shadow, "#{code}"
        assert [refusal] = entries(fx, @refused), "#{code}"
        assert refusal.after_state["failed"] == [Atom.to_string(code)]
        refute F.uuid_in?(conn.resp_body), "#{code}"
      end
    end

    test "several failing facts at once are all named, in read order" do
      fx = F.backdated_shadow_tenant!("req519-h5-all")
      second = RSG.user!(fx.schema_name)
      _ = TokenMintFixture.grant_roles!(fx.schema_name, second.id, ["TENANT_ADMIN"])
      F.break_all_facts!(fx)

      conn = put_as(fx, ctx(fx, second.id, ["TENANT_ADMIN"], :oidc), %{"mode" => "on"})

      assert conn.status == 409

      # the second admin keeps fact 4 satisfied; every other fact of 1..5 is broken
      assert body(conn)["failed"] == [
               "bindings_without_row",
               "org_inconsistent",
               "tokens_exceed_owner",
               "scoped_approvers_without_task_scope"
             ]
    end
  end

  # --- the body can never supply a clock ------------------------------------------------------------

  describe "attrs[:now] is not reachable from the router" do
    test "a body clock and thresholds do not turn an unsatisfied gate into a pass (the injected-clock tenant is refused)" do
      fx = injected_clock_green!("req519-h-now")

      body_with_clock = %{
        "mode" => "on",
        "now" => DateTime.to_iso8601(fx.now),
        "min_days" => 0,
        "min_requests" => 0,
        "attrs" => %{"now" => DateTime.to_iso8601(fx.now)}
      }

      conn = put_admin(fx, body_with_clock)

      # at the REAL clock this tenant has seconds of shadow; at fx.now it would pass
      assert conn.status == 409
      assert "shadow_evidence_insufficient" in body(conn)["failed"]
      assert mode!(fx) == :shadow
    end
  end

  # --- T-H9 / T-H10: a raise inside the gate ----------------------------------------------------------

  describe "T-H9 / T-H10 a raise inside the flip transaction" do
    test "is a detail-free 500, no flag change, NO refusal entry and exactly ONE constant log line" do
      fx = F.backdated_shadow_tenant!("req519-h9")

      {conn, log} =
        with_log(fn ->
          F.with_renamed_table!(fx, "api_tokens", fn ->
            send(self(), {:conn, put_admin(fx, %{"mode" => "on", "reason" => "req519 raise"})})
          end)

          receive do
            {:conn, conn} -> conn
          end
        end)

      assert conn.status == 500
      refute conn.resp_body =~ "api_tokens"
      refute conn.resp_body =~ "Postgrex"
      refute conn.resp_body =~ fx.schema_name
      refute F.uuid_in?(conn.resp_body)

      lines =
        log
        |> F.lines_with("scope_enforcement_flip_failed")
        |> Enum.map(fn line ->
          [constant] = Regex.run(~r/scope_enforcement_flip_failed.*$/, line)
          constant
        end)

      assert lines == [
               "scope_enforcement_flip_failed reason=transaction_failed exception=Postgrex.Error"
             ]

      assert mode!(fx) == :shadow
      assert entries(fx, @refused) == []
      assert length(entries(fx, @enabled)) == 1
    end

    test "a refusal (409) and a success (200) log no failure line" do
      fx = F.admin_tenant!("req519-h10")

      {conn, log} = with_log(fn -> put_admin(fx, %{"mode" => "on"}) end)
      assert conn.status == 409
      assert F.lines_with(log, "scope_enforcement_flip_failed") == []

      {conn, log} = with_log(fn -> put_admin(fx, %{"mode" => "shadow"}) end)
      assert conn.status == 200
      assert F.lines_with(log, "scope_enforcement_flip_failed") == []
    end
  end

  # --- GET /integrity on a raise -------------------------------------------------------------------------

  describe "GET /integrity on a raise (SEC 2f-a F-2)" do
    test "is a detail-free 500 with ONE constant scope_enforcement_integrity_failed line" do
      fx = F.admin_tenant!("req519-h-int")

      {conn, log} =
        with_log(fn ->
          F.with_renamed_table!(fx, "api_tokens", fn ->
            send(self(), {:conn, get_admin(fx, "/integrity")})
          end)

          receive do
            {:conn, conn} -> conn
          end
        end)

      assert conn.status == 500
      refute conn.resp_body =~ "api_tokens"
      refute conn.resp_body =~ "Postgrex"
      refute conn.resp_body =~ fx.schema_name
      refute conn.resp_body =~ "on_gate"
      refute F.uuid_in?(conn.resp_body)

      lines =
        log
        |> F.lines_with("scope_enforcement_integrity_failed")
        |> Enum.map(fn line ->
          [constant] = Regex.run(~r/scope_enforcement_integrity_failed.*$/, line)
          constant
        end)

      assert lines == ["scope_enforcement_integrity_failed exception=Postgrex.Error"]
    end

    test "the healthy body keeps its exact key sets and logs no failure line" do
      fx = F.admin_tenant!("req519-h-int2")

      {conn, log} = with_log(fn -> get_admin(fx, "/integrity") end)

      assert conn.status == 200
      assert F.lines_with(log, "scope_enforcement_integrity_failed") == []

      b = body(conn)

      assert Enum.sort(Map.keys(b)) ==
               [
                 "bindings_without_row",
                 "findings",
                 "items",
                 "on_gate",
                 "orphan_group_rows",
                 "truncated"
               ]

      assert Enum.sort(Map.keys(b["on_gate"])) == [
               "blocking",
               "counts",
               "evidence",
               "information"
             ]

      assert Enum.sort(Map.keys(b["on_gate"]["counts"])) ==
               Enum.reject(@report_keys, &(&1 == "scoped_task_workers_without_task_scope"))

      assert Enum.sort(Map.keys(b["on_gate"]["evidence"])) == @evidence_keys
    end
  end

  # --- T-H4: the generic APIs cannot set the column -------------------------------------------------

  describe "T-H4 the column is not settable through the generic tenant APIs (AC 8)" do
    test "PATCH /tenant/settings and PATCH /tenants/:slug with a scope_enforcement key leave the stored mode unchanged" do
      p = F.admin_tenant!("req519-h4")
      :ok = Fixture.pin!(p.tenant_id)

      for stored <- [:off, :shadow] do
        store!(p, stored)

        for value <- ["on", "shadow", "off"] do
          settings =
            Letflow.Routers.TenantSettings.call(
              Fixture.router_conn(
                :patch,
                "/",
                p,
                ["TENANT_ADMIN"],
                %{
                  "app_name" => "H4",
                  "scope_enforcement" => value,
                  "settings" => %{"scope_enforcement" => value}
                }
              ),
              Letflow.Routers.TenantSettings.init([])
            )

          assert settings.status in [200, 400, 422], "#{stored}/#{value}: #{settings.status}"
          assert mode!(p) == stored, "settings #{stored}/#{value}"

          tenants =
            Letflow.Routers.Tenants.call(
              Fixture.router_conn(
                :patch,
                "/#{p.tenant.slug}",
                p,
                ["PLATFORM_ADMIN"],
                %{"display_name" => "H4 tenant", "scope_enforcement" => value}
              ),
              Letflow.Routers.Tenants.init([])
            )

          assert tenants.status in [200, 400, 422], "#{stored}/#{value}: #{tenants.status}"
          assert mode!(p) == stored, "tenants #{stored}/#{value}"
        end
      end

      assert flip_entries(p) == []
    end
  end

  # --- T-X14: GET / -------------------------------------------------------------------------------------

  describe "T-X14 GET /" do
    test "lists the three settable modes for every stored mode" do
      fx = F.admin_tenant!("req519-x14")

      for mode <- [:off, :shadow, :on] do
        store!(fx, mode)

        assert body(get_admin(fx, "/")) ==
                 %{"mode" => Atom.to_string(mode), "available_modes" => ["off", "shadow", "on"]}
      end
    end
  end
end
