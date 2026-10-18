defmodule Letflow.Api.Scope.EnforceTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 19 and AC 20 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 4.3 and 4.5; spec
  `test/specs/REQ-517-2b.md`, T-G2..T-G6, T-I1, T-I2, T-C9 and the SEC advisory T-1):
  `Letflow.Api.Scope.Enforce.check/3`, called directly with a hand-built conn (`policy_key` and the
  optional `scope_class` in `conn.private`, the plug's `scoped_opts`, a real user in a dedicated
  provisioned tenant) so each branch of the decision is isolated from the router.

    * skipped keys keep their handling; `{:resolver, _}`, `:filter` and `:self_service` pass through;
    * `:admin_plane`, `:tenant_wide` and a default-sourced route are decided against
      `:tenant_wide`: a tenant-wide holder passes, a scoped-only holder and a holder with no row get
      the SAME uniform 403 bytes and one `[:letflow, :scope, :enforce, :denied]` event;
    * a token principal and a platform-tenant `PLATFORM_ADMIN` are tenant-wide (D1); a binding with
      zero rows and a failed grants load are denied;
    * any raise (a malformed `Grants` memo, a dropped `role_scope_grants` table) is a halted
      detail-free 500 with exactly one constant `scope_enforcement_failed` line, never the conn.

  `async: false`: committed writes, DDL (the dropped table), telemetry handlers and the VM-global
  platform pin.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.Scope.Enforce
  alias Letflow.Api.Scope.Grants
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @skipped_keys [:Unknown, :UnmatchedRoute, :UnmatchedPlatformPath, :MetricsRead]
  @admin "TENANT_ADMIN"

  # --- helpers ---------------------------------------------------------------------------------

  defp enforce_conn(fx, auth_context, private) do
    conn = conn(:get, "/x")

    conn =
      Enum.reduce(private, conn, fn {key, value}, acc -> put_private(acc, key, value) end)

    conn
    |> assign(:auth_context, auth_context)
    |> assign(:scoped_opts, prefix: fx.schema_name)
    |> assign(:trace_id, "enforce-test-trace")
  end

  defp access(auth_context) do
    %AccessContext{
      user_id: auth_context.user_id,
      roles: Enum.map(auth_context.roles, &String.to_existing_atom/1),
      platform_tenant?: false
    }
  end

  defp check(fx, auth_context, private, key) do
    conn = enforce_conn(fx, auth_context, private)
    {conn, Enforce.check(conn, access(auth_context), key)}
  end

  defp detail(conn), do: Jason.decode!(conn.resp_body)["detail"]

  defp tenant!(slug_prefix), do: S.tenant!(slug_prefix)

  # ===========================================================================================
  describe "T-G5 the skipped keys keep their handling" do
    test "each of :Unknown, :UnmatchedRoute, :UnmatchedPlatformPath, :MetricsRead returns the conn untouched, even for a scoped caller and a bare conn" do
      fx = tenant!("r517-enf-skip")
      scoped = On.scoped_holder!(fx, @admin)
      ref = On.attach_enforce_denied!()
      auth_context = On.ctx(fx, scoped.id, [@admin], :on)

      for key <- @skipped_keys do
        conn = enforce_conn(fx, auth_context, %{policy_key: key})
        assert Enforce.check(conn, access(auth_context), key) == conn, "#{key}"

        # a conn with no assigns at all is also returned as is (no principal is built)
        bare = conn(:get, "/x")
        assert Enforce.check(bare, access(auth_context), key) == bare, "#{key} (bare)"
      end

      assert On.drain(ref) == []
    end
  end

  # ===========================================================================================
  describe "T-G2 / T-G3 / T-C9 tenant-wide and default-sourced routes" do
    test "a tenant-wide holder passes on a declared :tenant_wide route, an admin-plane route and a default route" do
      fx = tenant!("r517-enf-allow")
      ref = On.attach_enforce_denied!()
      auth_context = On.ctx(fx, fx.admin.id, [@admin], :on)

      for {key, private} <- [
            {:InstancesRead, %{policy_key: :InstancesRead, scope_class: :tenant_wide}},
            {:GroupsManage, %{policy_key: :GroupsManage}},
            {:InstancesRead, %{policy_key: :InstancesRead}}
          ] do
        {_conn, result} = check(fx, auth_context, private, key)
        refute result.halted, inspect(private)
        assert result.status == nil
      end

      assert On.drain(ref) == []
    end

    test "a scoped-only holder is refused on all three shapes with the SAME 403 bytes and a :not_tenant_wide event (N2)" do
      fx = tenant!("r517-enf-scoped")
      scoped = On.scoped_holder!(fx, @admin)
      ref = On.attach_enforce_denied!()
      auth_context = On.ctx(fx, scoped.id, [@admin], :on)

      shapes = [
        {:InstancesRead, %{policy_key: :InstancesRead, scope_class: :tenant_wide}},
        {:GroupsManage, %{policy_key: :GroupsManage}},
        {:InstancesRead, %{policy_key: :InstancesRead}}
      ]

      conns =
        for {key, private} <- shapes do
          {_conn, result} = check(fx, auth_context, private, key)
          assert result.halted, inspect(private)
          assert result.status == 403
          assert detail(result) == "insufficient permissions"
          result
        end

      events = On.drain(ref)
      assert length(events) == 3

      assert Enum.all?(events, fn {m, meta} ->
               m == %{count: 1} and meta.reason == :not_tenant_wide
             end)

      assert Enum.map(events, fn {_m, meta} -> meta.policy end) == [
               :InstancesRead,
               :GroupsManage,
               :InstancesRead
             ]

      # the explicit :tenant_wide route and the default-sourced one answer identical bytes (T-C9)
      [declared, _admin, default] = conns
      assert declared.resp_body == default.resp_body
      assert get_resp_header(declared, "content-type") == get_resp_header(default, "content-type")
    end

    test "the deny is byte-identical to the coarse deny of Letflow.Plugs.Authorize (route-level, no existence oracle)" do
      fx = tenant!("r517-enf-bytes")
      scoped = On.scoped_holder!(fx, @admin)
      auth_context = On.ctx(fx, scoped.id, [@admin], :on)

      {_conn, enforce_deny} =
        check(fx, auth_context, %{policy_key: :InstancesRead}, :InstancesRead)

      # coarse deny: a caller with no role at all, same trace id
      coarse =
        conn(:get, "/x")
        |> assign(:auth_context, %{user_id: scoped.id, tenant_id: fx.tenant_id, roles: []})
        |> assign(:trace_id, "enforce-test-trace")
        |> then(&Letflow.Routers.Instances.call(&1, Letflow.Routers.Instances.init([])))

      assert coarse.status == 403
      assert enforce_deny.status == 403
      assert enforce_deny.resp_body == coarse.resp_body
    end

    test "a holder with no grant row is refused :no_grant_rows with the same bytes as a scoped holder" do
      fx = tenant!("r517-enf-norow")
      scoped = On.scoped_holder!(fx, @admin)
      rowless = On.rowless_holder!(fx)
      ref = On.attach_enforce_denied!()
      private = %{policy_key: :InstancesRead}

      {_c1, scoped_result} =
        check(fx, On.ctx(fx, scoped.id, [@admin], :on), private, :InstancesRead)

      {_c2, rowless_result} =
        check(fx, On.ctx(fx, rowless.id, [@admin], :on), private, :InstancesRead)

      assert rowless_result.halted and rowless_result.status == 403
      assert rowless_result.resp_body == scoped_result.resp_body

      reasons = ref |> On.drain() |> Enum.map(fn {_m, meta} -> meta.reason end)
      assert reasons == [:not_tenant_wide, :no_grant_rows]
    end

    test "a binding whose group row was removed (zero rows) denies its member (T-G6)" do
      fx = tenant!("r517-enf-zero")
      s = fx.schema_name
      holder = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])

      assert RSG.raw_delete_rows!(s, RSG.group_of!(s, "PROCESS_DESIGNER"), "PROCESS_DESIGNER") ==
               1

      ref = On.attach_enforce_denied!()

      {_conn, result} =
        check(
          fx,
          On.ctx(fx, holder.id, ["PROCESS_DESIGNER"], :on),
          %{policy_key: :DefinitionsRead},
          :DefinitionsRead
        )

      assert result.halted and result.status == 403
      assert [{_m, %{reason: :no_grant_rows, policy: :DefinitionsRead}}] = On.drain(ref)
    end

    test "a failed grants load (:not_loaded memo) denies :grants_unavailable, never allows (T-G6)" do
      fx = tenant!("r517-enf-unavail")
      ref = On.attach_enforce_denied!()

      auth_context =
        fx |> On.ctx(fx.admin.id, [@admin], :on) |> Map.put(:scope_grants, :not_loaded)

      {_conn, result} = check(fx, auth_context, %{policy_key: :InstancesRead}, :InstancesRead)

      assert result.halted and result.status == 403
      assert [{_m, %{reason: :grants_unavailable}}] = On.drain(ref)
    end

    test "a context that yields no principal (no credential) is a 403, never an allow" do
      fx = tenant!("r517-enf-nopr")
      ref = On.attach_enforce_denied!()
      auth_context = fx |> On.ctx(fx.admin.id, [@admin], :on) |> Map.delete(:credential)

      {_conn, result} = check(fx, auth_context, %{policy_key: :InstancesRead}, :InstancesRead)

      assert result.halted and result.status == 403
      assert detail(result) == "insufficient permissions"
      assert [{_m, %{reason: :no_principal}}] = On.drain(ref)
    end
  end

  # ===========================================================================================
  describe "T-G6 token principals and platform operators are tenant-wide (D1)" do
    test "an API-token principal holding the role passes with no grants read" do
      fx = tenant!("r517-enf-token")
      ref = On.attach_enforce_denied!()

      auth_context =
        fx |> S.ctx(fx.admin.id, [@admin], :api_token) |> Map.put(:scope_enforcement, :on)

      {{_conn, result}, queries} =
        Fixture.capture_repo_queries(fn ->
          check(fx, auth_context, %{policy_key: :GroupsManage}, :GroupsManage)
        end)

      refute result.halted
      assert Enum.map(queries, &Map.get(&1, :source)) == []
      assert On.drain(ref) == []
    end

    test "a token whose roles do not allow the permission is still refused (role_not_held)" do
      fx = tenant!("r517-enf-token-role")
      ref = On.attach_enforce_denied!()

      auth_context =
        fx
        |> S.ctx(fx.admin.id, ["TASK_WORKER"], :api_token)
        |> Map.put(:scope_enforcement, :on)

      {_conn, result} = check(fx, auth_context, %{policy_key: :GroupsManage}, :GroupsManage)

      assert result.halted and result.status == 403
      assert [{_m, %{reason: :role_not_held}}] = On.drain(ref)
    end

    test "a platform-tenant PLATFORM_ADMIN passes without any grant row" do
      fx = tenant!("r517-enf-platform")
      Fixture.pin!(fx.tenant_id)
      operator = RSG.user!(fx.schema_name)
      ref = On.attach_enforce_denied!()

      for key <- [:InstancesRead, :GroupsManage] do
        {_conn, result} =
          check(fx, On.ctx(fx, operator.id, ["PLATFORM_ADMIN"], :on), %{policy_key: key}, key)

        refute result.halted, "#{key}"
      end

      assert On.drain(ref) == []
    end

    test "the same PLATFORM_ADMIN claim outside the platform tenant holds nothing and is refused" do
      fx = tenant!("r517-enf-nonplat")
      operator = RSG.user!(fx.schema_name)

      {_conn, result} =
        check(
          fx,
          On.ctx(fx, operator.id, ["PLATFORM_ADMIN"], :on),
          %{policy_key: :InstancesRead},
          :InstancesRead
        )

      assert result.halted and result.status == 403
    end
  end

  # ===========================================================================================
  describe "T-G4 resolver, filter and self_service routes pass through" do
    test "a declared class other than tenant_wide returns the conn untouched for a scoped caller, with no principal read and no event" do
      fx = tenant!("r517-enf-pass")
      scoped = On.scoped_holder!(fx, @admin)
      ref = On.attach_enforce_denied!()
      auth_context = On.ctx(fx, scoped.id, [@admin], :on)

      for class <- [
            :filter,
            :self_service,
            {:resolver, {Letflow.Api.RouteScope, :class_of}}
          ] do
        conn = enforce_conn(fx, auth_context, %{policy_key: :InstancesRead, scope_class: class})

        {result, queries} =
          Fixture.capture_repo_queries(fn ->
            Enforce.check(conn, access(auth_context), :InstancesRead)
          end)

        # REQ-518 R-4: `:filter` and `{:resolver, _}` only gain the before-send backstop callback.
        if class == :self_service do
          assert result == conn, inspect(class)
        else
          refute result.halted, inspect(class)

          assert %{result | private: Map.delete(result.private, :before_send)} == conn,
                 inspect(class)

          assert length(result.private[:before_send]) == 1, inspect(class)
        end

        assert queries == [], inspect(class)
      end

      assert On.drain(ref) == []
    end

    test "an admin-plane key cannot be weakened by a declared :filter, :self_service or resolver (N12 at runtime)" do
      fx = tenant!("r517-enf-weaken")
      scoped = On.scoped_holder!(fx, @admin)
      auth_context = On.ctx(fx, scoped.id, [@admin], :on)

      for class <- [:filter, :self_service, {:resolver, {Letflow.Api.RouteScope, :class_of}}] do
        {_conn, result} =
          check(
            fx,
            auth_context,
            %{policy_key: :GroupsManage, scope_class: class},
            :GroupsManage
          )

        assert result.halted and result.status == 403, inspect(class)
      end
    end
  end

  # ===========================================================================================
  describe "T-I1 / T-I2 fail closed (AC 20)" do
    test "a malformed Grants memo is a halted detail-free 500 with exactly one constant line, never the conn" do
      fx = tenant!("r517-enf-raise")
      ref = On.attach_enforce_denied!()
      corrupted = %Grants{user_id: fx.admin.id, rows_by_role: :corrupted}

      auth_context =
        fx |> On.ctx(fx.admin.id, [@admin], :on) |> Map.put(:scope_grants, corrupted)

      conn = enforce_conn(fx, auth_context, %{policy_key: :InstancesRead})

      {result, log} =
        with_log(fn -> Enforce.check(conn, access(auth_context), :InstancesRead) end)

      assert result != conn
      assert result.halted
      assert result.status == 500
      assert detail(result) == "an unexpected error occurred"
      assert On.drain(ref) == []

      lines =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "scope_enforcement_failed"))

      assert [line] = lines
      assert line =~ "scope_enforcement_failed class=error exception=BadMapError"

      # T-I2: no id, slug, schema, role or value in the captured output
      for secret <- [
            fx.admin.id,
            fx.tenant_id,
            fx.schema_name,
            fx.tenant.slug,
            @admin,
            "InstancesRead"
          ] do
        refute String.contains?(log, secret), "the log leaks #{inspect(secret)}: #{log}"
      end
    end

    test "every request that raises answers 500, once per occurrence (no once-per-boot suppression)" do
      fx = tenant!("r517-enf-raise2")
      corrupted = %Grants{user_id: fx.admin.id, rows_by_role: :corrupted}

      auth_context =
        fx |> On.ctx(fx.admin.id, [@admin], :on) |> Map.put(:scope_grants, corrupted)

      conn = enforce_conn(fx, auth_context, %{policy_key: :GroupsManage})

      {results, log} =
        with_log(fn ->
          for _n <- 1..3, do: Enforce.check(conn, access(auth_context), :GroupsManage)
        end)

      assert Enum.all?(results, &(&1.halted and &1.status == 500))
      assert log |> String.split("scope_enforcement_failed class=error") |> length() == 4
    end

    test "end to end: a dropped role_scope_grants table makes the lazy grants load raise; the router answers a halted 500 and its handler never runs" do
      fx = tenant!("r517-enf-drop")
      ref = On.attach_enforce_denied!()
      Repo.query!(~s|DROP TABLE "#{fx.schema_name}".role_scope_grants CASCADE|)

      # a context that did not come from the pipeline: no scope_grants key, so the plug loads lazily
      auth_context = On.ctx(fx, fx.admin.id, [@admin], :on)

      {conn, log} =
        with_log(fn ->
          S.call(Letflow.Routers.Instances, :get, "/", fx, auth_context, nil)
        end)

      assert conn.halted
      assert conn.status == 500
      assert detail(conn) == "an unexpected error occurred"
      # the instance list handler would have answered 200 with an items page
      refute conn.resp_body =~ "items"
      assert On.drain(ref) == []

      assert [line] =
               log
               |> String.split("\n")
               |> Enum.filter(&String.contains?(&1, "scope_enforcement_failed"))

      assert line =~ "class=error exception=Postgrex.Error"
      # only the constant line is judged: the Ecto QUERY ERROR debug line in the same capture
      # legitimately names the schema
      refute String.contains?(line, fx.schema_name)
    end
  end
end
