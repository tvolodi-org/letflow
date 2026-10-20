defmodule Letflow.Routers.Req442TenantsModeTest do
  @moduledoc """
  REQ-442 AC2 (write authorisation, audit, null reset, failure modes) and the
  platform-admin half of AC3 (the seven-key tenant shape on every route that uses
  `tenant_map/1`). See `test/specs/REQ-442.md` for the criterion -> test map.

  Dispatch is direct `Letflow.Routers.Tenants.call/2` with `conn.assigns.auth_context`
  set by hand, exactly as `test/letflow/routers/tenants_test.exs` does, so the
  router's own real `Authorize` plug and `:TenantsManage` gate run for real.

  `async: false`: `TenantFixture.provisioned_tenant!/1` needs `Sandbox.mode(:auto)`.
  Every tenant is unique per test (`slug_prefix` + unique slug), no wall clock.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # The platform tenant is provisioned BEFORE any test body inserts a row: provisioning flips the
  # sandbox to :auto, which would hide a row the test had already inserted (ISS-1032).
  setup do
    platform_fixture()
    :ok
  end

  @opts Letflow.Routers.Tenants.init([])
  @audit_opts Letflow.Routers.Audit.init([])
  @modes ["uniform_plus_email", "redirect_single"]
  @seven_keys Enum.sort([
                "id",
                "slug",
                "display_name",
                "status",
                "login_disclosure_mode",
                "inserted_at",
                "updated_at"
              ])

  defp build_conn(method, path, roles, body, user_id) do
    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(
      :auth_context,
      PlatformTenantFixture.operator_auth_context(user_id, platform_fixture().tenant_id, roles)
    )
    |> assign(:trace_id, "req442-trace-id")
  end

  # ISS-1032 / GH 2351: a mode change also writes a PLATFORM-chain entry, so the operator's tenant is a
  # real, provisioned platform tenant (pinned by operator_auth_context/3), created in setup.
  defp platform_fixture do
    case Process.get(:req442_platform_fixture) do
      nil ->
        fixture = TenantFixture.provisioned_tenant!(slug_prefix: "req442-platform")
        Process.put(:req442_platform_fixture, fixture)
        fixture

      fixture ->
        fixture
    end
  end

  defp platform_entries(tenant_id) do
    Repo.all(
      from(e in Entry,
        where:
          e.resource_id == ^tenant_id and e.action == "platform.tenant_platform_setting.updated"
      ),
      prefix: platform_fixture().schema_name
    )
  end

  defp dispatch(conn), do: Letflow.Routers.Tenants.call(conn, @opts)

  defp admin_patch(slug, body, user_id) do
    build_conn(:patch, "/#{slug}", ["PLATFORM_ADMIN"], body, user_id) |> dispatch()
  end

  defp set_mode!(tenant_id, mode) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id),
        set: [login_disclosure_mode: mode]
      )

    :ok
  end

  defp stored_mode(tenant_id), do: Repo.get!(Tenant, tenant_id).login_disclosure_mode

  defp mode_audit_entries(schema_name, tenant_id) do
    Repo.all(
      from(e in Entry,
        where:
          e.resource_type == "tenant" and e.resource_id == ^tenant_id and
            e.action == "tenant.platform_setting.updated"
      ),
      prefix: schema_name
    )
  end

  defp all_audit_count(schema_name), do: Repo.aggregate(Entry, :count, prefix: schema_name)

  defp get_audit(tenant_id, roles) do
    conn(:get, "/")
    |> assign(:auth_context, %{user_id: Ecto.UUID.generate(), tenant_id: tenant_id, roles: roles})
    |> assign(:trace_id, "req442-audit-trace-id")
    |> Letflow.Routers.Audit.call(@audit_opts)
  end

  # ── PLATFORM_ADMIN happy paths ──────────────────────────────────────────

  describe "AC2: PLATFORM_ADMIN sets the mode through PATCH /tenants/:slug" do
    for mode <- @modes do
      test "#{mode}: 200, stored, echoed in the platform-admin response, and exactly one value-free audit row in the target tenant's chain" do
        mode = unquote(mode)
        t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-set")
        actor = Ecto.UUID.generate()

        resp = admin_patch(t.tenant.slug, %{"login_disclosure_mode" => mode}, actor)

        assert resp.status == 200
        body = Jason.decode!(resp.resp_body)
        assert body["login_disclosure_mode"] == mode
        assert Map.keys(body) |> Enum.sort() == @seven_keys
        assert stored_mode(t.tenant_id) == mode

        # ISS-1032: the TENANT chain entry has a NIL actor and a constant actor class; the operator's
        # id is in the PLATFORM chain only.
        assert [entry] = mode_audit_entries(t.schema_name, t.tenant_id)
        assert entry.actor_id == nil
        assert entry.resource_type == "tenant"
        assert entry.resource_id == t.tenant_id
        assert entry.trace_id == nil
        assert entry.before_state == nil
        assert entry.after_state == %{"changed" => true, "actor_class" => "platform_operator"}
        refute inspect(Map.from_struct(entry)) =~ actor

        assert [platform_entry] = platform_entries(t.tenant_id)
        assert platform_entry.actor_id == actor
        assert platform_entry.resource_type == "tenant"
        assert platform_entry.resource_id == t.tenant_id
        assert platform_entry.trace_id == "req442-trace-id"
        assert platform_entry.before_state == nil
        assert platform_entry.after_state == %{"tenant_id" => t.tenant_id, "changed" => true}

        # value-free (INV-2): neither the mode value nor the attribute name is in either entry
        for e <- [entry, platform_entry] do
          dumped = inspect(Map.from_struct(e))
          refute dumped =~ "uniform_plus_email"
          refute dumped =~ "redirect_single"
          refute dumped =~ "login_disclosure_mode"
        end

        # nothing else was audited in the tenant chain
        assert all_audit_count(t.schema_name) == 1
      end
    end

    test "changing from one mode to the other writes a second audit row; re-sending the SAME value writes none" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-flip")
      actor = Ecto.UUID.generate()

      assert admin_patch(t.tenant.slug, %{"login_disclosure_mode" => "uniform_plus_email"}, actor).status ==
               200

      assert admin_patch(t.tenant.slug, %{"login_disclosure_mode" => "uniform_plus_email"}, actor).status ==
               200

      assert length(mode_audit_entries(t.schema_name, t.tenant_id)) == 1

      assert admin_patch(t.tenant.slug, %{"login_disclosure_mode" => "redirect_single"}, actor).status ==
               200

      assert length(mode_audit_entries(t.schema_name, t.tenant_id)) == 2
      assert stored_mode(t.tenant_id) == "redirect_single"
    end

    test "an explicit JSON null through HTTP resets the value to NULL (deployment fallback), audited as a change" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-null")
      set_mode!(t.tenant_id, "uniform_plus_email")

      resp = admin_patch(t.tenant.slug, %{"login_disclosure_mode" => nil}, Ecto.UUID.generate())

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert Map.has_key?(body, "login_disclosure_mode")
      assert body["login_disclosure_mode"] == nil
      assert stored_mode(t.tenant_id) == nil
      assert length(mode_audit_entries(t.schema_name, t.tenant_id)) == 1
    end

    test "null on an already-NULL tenant is a no-op: 200, no audit row" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-null-noop")

      resp = admin_patch(t.tenant.slug, %{"login_disclosure_mode" => nil}, Ecto.UUID.generate())

      assert resp.status == 200
      assert stored_mode(t.tenant_id) == nil
      assert all_audit_count(t.schema_name) == 0
    end

    test "an absent key leaves the mode alone, and a display_name-only patch writes no audit row (status quo)" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-absent")
      set_mode!(t.tenant_id, "uniform_plus_email")

      resp = admin_patch(t.tenant.slug, %{"display_name" => "Renamed 442"}, Ecto.UUID.generate())

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["display_name"] == "Renamed 442"
      assert body["login_disclosure_mode"] == "uniform_plus_email"
      assert stored_mode(t.tenant_id) == "uniform_plus_email"
      assert all_audit_count(t.schema_name) == 0
    end

    test "display_name and mode together: both applied, one audit row" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-both")

      resp =
        admin_patch(
          t.tenant.slug,
          %{"display_name" => "Both 442", "login_disclosure_mode" => "redirect_single"},
          Ecto.UUID.generate()
        )

      assert resp.status == 200
      reloaded = Repo.get!(Tenant, t.tenant_id)

      assert {reloaded.display_name, reloaded.login_disclosure_mode} ==
               {"Both 442", "redirect_single"}

      assert length(mode_audit_entries(t.schema_name, t.tenant_id)) == 1
    end

    test "an invalid mode ('picker_unauth', wrong case, empty string, a number) is 422, row unchanged, nothing audited" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-invalid")
      set_mode!(t.tenant_id, "redirect_single")

      for bad <- [
            "picker_unauth",
            "Redirect_Single",
            "",
            "uniform",
            7,
            true,
            ["uniform_plus_email"]
          ] do
        resp = admin_patch(t.tenant.slug, %{"login_disclosure_mode" => bad}, Ecto.UUID.generate())
        assert resp.status == 422, "expected 422 for #{inspect(bad)}, got #{resp.status}"
        assert stored_mode(t.tenant_id) == "redirect_single"
      end

      assert all_audit_count(t.schema_name) == 0
    end

    test "an unknown extra key is still silently dropped (status cannot be written via this path)" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-extra")

      resp =
        admin_patch(
          t.tenant.slug,
          %{
            "login_disclosure_mode" => "redirect_single",
            "status" => "inactive",
            "idp_realm_id" => "x"
          },
          Ecto.UUID.generate()
        )

      assert resp.status == 200
      reloaded = Repo.get!(Tenant, t.tenant_id)
      assert reloaded.status == :active
      assert reloaded.idp_realm_id == t.tenant.idp_realm_id
    end
  end

  # ── Authorization matrix ────────────────────────────────────────────────

  describe "AC2: authorization matrix -- only PLATFORM_ADMIN may write the mode" do
    test "TENANT_ADMIN (not a platform role), every ordinary role and no role at all get the existing 403, row unchanged, nothing audited" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-authz")
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req442-authz-other")
      set_mode!(t.tenant_id, "uniform_plus_email")
      before = Repo.get!(Tenant, t.tenant_id)

      role_sets =
        [["TENANT_ADMIN"], [], ["tenant-admin"]] ++
          for role <- Letflow.Api.Authorization.roles(), role != :PLATFORM_ADMIN do
            [Atom.to_string(role)]
          end

      for roles <- role_sets, target <- [t, other] do
        resp =
          build_conn(
            :patch,
            "/#{target.tenant.slug}",
            roles,
            %{"login_disclosure_mode" => "redirect_single"},
            Ecto.UUID.generate()
          )
          |> dispatch()

        assert resp.status == 403, "roles #{inspect(roles)} got #{resp.status}"

        assert Jason.decode!(resp.resp_body) == %{
                 "type" => "https://bpm.example.com/problems/forbidden",
                 "title" => "Forbidden",
                 "status" => 403,
                 "detail" => "insufficient permissions",
                 "trace_id" => "req442-trace-id"
               }
      end

      assert Repo.get!(Tenant, t.tenant_id) == before
      assert stored_mode(other.tenant_id) == nil
      assert all_audit_count(t.schema_name) == 0
      assert all_audit_count(other.schema_name) == 0
    end

    test "a non-platform caller also cannot READ the mode through GET /tenants/:slug or the list" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-authz-read")
      set_mode!(t.tenant_id, "uniform_plus_email")

      for path <- ["/#{t.tenant.slug}", "/?search=#{t.tenant.slug}"] do
        resp =
          build_conn(:get, path, ["PROCESS_OPERATOR"], nil, Ecto.UUID.generate()) |> dispatch()

        assert resp.status == 403
        refute resp.resp_body =~ "login_disclosure_mode"
        refute resp.resp_body =~ "uniform_plus_email"
      end
    end

    test "the tenant-settings route (a tenant admin's own write path) never persists login_disclosure_mode, top level or wrapped" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-settings")

      for body <- [
            %{"login_disclosure_mode" => "uniform_plus_email"},
            %{"settings" => %{"login_disclosure_mode" => "uniform_plus_email"}},
            %{"app_name" => "Kept 442", "login_disclosure_mode" => "redirect_single"}
          ] do
        resp =
          conn(:patch, "/")
          |> Map.put(:body_params, body)
          |> put_req_header("content-type", "application/json")
          |> assign(:auth_context, %{
            user_id: Ecto.UUID.generate(),
            tenant_id: t.tenant_id,
            roles: ["TENANT_ADMIN"]
          })
          |> assign(:trace_id, "req442-settings-trace")
          |> Letflow.Routers.TenantSettings.call(Letflow.Routers.TenantSettings.init([]))

        # the closed vocabulary drops the key (existing contract: 200 with the recognised part)
        assert resp.status == 200
        refute resp.resp_body =~ "login_disclosure_mode"
        refute resp.resp_body =~ "uniform_plus_email"
        refute resp.resp_body =~ "redirect_single"

        reloaded = Repo.get!(Tenant, t.tenant_id)
        assert reloaded.login_disclosure_mode == nil
        refute inspect(reloaded.settings) =~ "login_disclosure_mode"
      end
    end

    test "the closed settings vocabulary rejects the key at the context level too (Identity.update_tenant_settings/2)" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-vocab")

      result =
        Identity.update_tenant_settings(t.tenant.slug, %{
          "settings" => %{"login_disclosure_mode" => "uniform_plus_email"}
        })

      case result do
        {:error, %Ecto.Changeset{}} -> :ok
        {:ok, updated} -> refute inspect(updated.settings) =~ "login_disclosure_mode"
      end

      assert stored_mode(t.tenant_id) == nil
      refute inspect(Repo.get!(Tenant, t.tenant_id).settings) =~ "login_disclosure_mode"
    end
  end

  # ── Failure modes (fail closed) ─────────────────────────────────────────

  describe "AC2: a mode change that cannot be audited fails closed" do
    test "nil actor on a mode change: 500 internal-error envelope, row unchanged, nothing audited" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-nilactor")

      resp = admin_patch(t.tenant.slug, %{"login_disclosure_mode" => "uniform_plus_email"}, nil)

      assert resp.status == 500
      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 500
      assert body["title"] == "Internal Server Error"
      assert body["type"] =~ "internal-error"
      refute resp.resp_body =~ "uniform_plus_email"
      assert stored_mode(t.tenant_id) == nil
      assert all_audit_count(t.schema_name) == 0
    end

    test "nil actor on a display_name-only patch is fine (no audit needed)" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-nilactor-name")

      resp = admin_patch(t.tenant.slug, %{"display_name" => "Name Only"}, nil)

      assert resp.status == 200
      assert Repo.get!(Tenant, t.tenant_id).display_name == "Name Only"
    end

    test "a tenant row with no schema registration (unprovisioned): 500 envelope, no raise, row unchanged" do
      tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{
            slug: Letflow.TenantSlugFixture.unique_slug("req442-unprov"),
            display_name: "Unprovisioned"
          },
          :disabled
        )
        |> Repo.insert!()

      assert Repo.get_by(TenantProvisioning.Registration, tenant_id: tenant.id) == nil

      resp =
        admin_patch(
          tenant.slug,
          %{"login_disclosure_mode" => "uniform_plus_email"},
          Ecto.UUID.generate()
        )

      assert resp.status == 500
      body = Jason.decode!(resp.resp_body)
      assert body["title"] == "Internal Server Error"
      assert body["type"] =~ "internal-error"
      # fixed body: no slug, tenant id, mode or exception text (INV-4)
      refute resp.resp_body =~ tenant.slug
      refute resp.resp_body =~ tenant.id
      refute resp.resp_body =~ "uniform_plus_email"
      assert stored_mode(tenant.id) == nil
    end

    test "an unprovisioned tenant can still have its display_name patched (the audit pre-check applies to mode changes only)" do
      tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{
            slug: Letflow.TenantSlugFixture.unique_slug("req442-unprov-name"),
            display_name: "Unprovisioned B"
          },
          :disabled
        )
        |> Repo.insert!()

      resp = admin_patch(tenant.slug, %{"display_name" => "Still Works"}, Ecto.UUID.generate())
      assert resp.status == 200
    end

    test "a genuine audit-insert failure (audit_entries dropped) rolls the mode update back: 500 envelope, row unchanged, fixed log line" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-auditfail")
      set_mode!(t.tenant_id, "redirect_single")

      Repo.query!(~s(DROP TABLE "#{t.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE IF NOT EXISTS "#{t.schema_name}".audit_entries (
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

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          resp =
            admin_patch(
              t.tenant.slug,
              %{"login_disclosure_mode" => "uniform_plus_email"},
              Ecto.UUID.generate()
            )

          assert resp.status == 500
          body = Jason.decode!(resp.resp_body)
          assert body["type"] =~ "internal-error"
          refute resp.resp_body =~ "audit_entries"
          refute resp.resp_body =~ "Postgrex"
          refute resp.resp_body =~ "uniform_plus_email"
        end)

      assert log =~ "tenant platform-setting patch failed (tenant_id=#{t.tenant_id})"
      # the update rolled back with the failed audit step
      assert stored_mode(t.tenant_id) == "redirect_single"
    end

    # GH #2483. A pool checkout exit is not an exception, so `rescue` alone let it escape the router
    # as a crash. An exit cannot be injected from a telemetry handler (telemetry detaches a handler
    # that exits), so the handler instead points the calling process at a dynamic repo whose pool
    # pid is dead: the next checkout is a GenServer call on it, which exits with :noproc. The
    # handler fires after the registration lookup, so the exit hits the audit transaction.
    test "a pool checkout exit on a mode change fails closed: 500 envelope, exit tag logged only, nothing written" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-exit")
      set_mode!(t.tenant_id, "redirect_single")

      dead_pool = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pool)
      assert_receive {:DOWN, ^ref, :process, ^dead_pool, _}

      stand_in = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(stand_in, :kill) end)

      broken_meta = %{Ecto.Repo.Registry.lookup(Letflow.Repo) | pid: dead_pool}
      :ok = Ecto.Repo.Registry.associate(stand_in, nil, broken_meta)

      registration_source = TenantProvisioning.Registration.__schema__(:source)
      handler_id = {__MODULE__, :checkout_exit, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # Runs in the calling process.
          if metadata[:source] == registration_source do
            :telemetry.detach(handler_id)
            Letflow.Repo.put_dynamic_repo(stand_in)
            send(test_pid, :checkout_exit_armed)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          try do
            resp =
              admin_patch(
                t.tenant.slug,
                %{"login_disclosure_mode" => "uniform_plus_email"},
                Ecto.UUID.generate()
              )

            assert resp.status == 500
            body = Jason.decode!(resp.resp_body)
            assert body["title"] == "Internal Server Error"
            assert body["type"] =~ "internal-error"
            refute resp.resp_body =~ "uniform_plus_email"
            refute resp.resp_body =~ "noproc"
          after
            Letflow.Repo.put_dynamic_repo(Letflow.Repo)
          end
        end)

      assert_received :checkout_exit_armed

      assert log =~
               "tenant platform-setting patch failed (tenant_id=#{t.tenant_id}, exit=:noproc)"

      refute log =~ "Letflow.Repo"
      refute log =~ "DBConnection"

      # nothing partial: the mode and both audit chains agree
      assert stored_mode(t.tenant_id) == "redirect_single"
      assert mode_audit_entries(t.schema_name, t.tenant_id) == []
      assert platform_entries(t.tenant_id) == []
    end

    test "Identity.patch_tenant/3 is the only arity (no unaudited patch_tenant/2 bypass remains)" do
      assert function_exported?(Identity, :patch_tenant, 3)
      refute function_exported?(Identity, :patch_tenant, 2)
    end

    test "Identity.patch_tenant/3 contract: not found, invalid changeset, and :audit_failed tags" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-ctx")

      assert Identity.patch_tenant("no-such-slug-442-#{Ecto.UUID.generate()}", %{}, []) ==
               {:error, :not_found}

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Identity.patch_tenant(t.tenant.slug, %{login_disclosure_mode: "picker_unauth"},
                 actor_id: Ecto.UUID.generate()
               )

      assert Identity.patch_tenant(t.tenant.slug, %{login_disclosure_mode: "redirect_single"}, []) ==
               {:error, :audit_failed}

      assert Identity.patch_tenant(t.tenant.slug, %{login_disclosure_mode: "redirect_single"},
               actor_id: 12_345
             ) == {:error, :audit_failed}

      # a binary actor but no verified platform prefix: nothing is written (ISS-1032)
      assert Identity.patch_tenant(t.tenant.slug, %{login_disclosure_mode: "redirect_single"},
               actor_id: Ecto.UUID.generate()
             ) == {:error, :audit_failed}

      assert stored_mode(t.tenant_id) == nil
      assert all_audit_count(t.schema_name) == 0
    end

    test "a failed PLATFORM-chain write rolls back the tenant update and the tenant-chain entry (ISS-1032)" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-platfail")
      platform = platform_fixture()
      set_mode!(t.tenant_id, "redirect_single")

      Repo.query!(~s(DROP TABLE "#{platform.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE IF NOT EXISTS "#{platform.schema_name}".audit_entries (
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

      ExUnit.CaptureLog.capture_log(fn ->
        resp =
          admin_patch(
            t.tenant.slug,
            %{"login_disclosure_mode" => "uniform_plus_email"},
            Ecto.UUID.generate()
          )

        assert resp.status == 500
      end)

      assert stored_mode(t.tenant_id) == "redirect_single"
      assert mode_audit_entries(t.schema_name, t.tenant_id) == []
      assert all_audit_count(t.schema_name) == 0
    end
  end

  # ── Tenant-admin-readable audit ─────────────────────────────────────────

  describe "AC3: the audit entry is readable by a tenant admin and carries no mode" do
    test "GET /audit shows the neutral action and a byte-level search finds neither the value nor the attribute name" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-auditread")

      operator = Ecto.UUID.generate()

      assert admin_patch(
               t.tenant.slug,
               %{"login_disclosure_mode" => "uniform_plus_email"},
               operator
             ).status ==
               200

      for roles <- [["TENANT_ADMIN"], ["PROCESS_OPERATOR"]] do
        resp = get_audit(t.tenant_id, roles)
        assert resp.status == 200
        assert resp.resp_body =~ "tenant.platform_setting.updated"
        # ISS-1032: the tenant's own administrators cannot learn which operator acted
        refute resp.resp_body =~ operator
        refute resp.resp_body =~ "platform.tenant_platform_setting.updated"
        refute resp.resp_body =~ "uniform_plus_email"
        refute resp.resp_body =~ "redirect_single"
        refute resp.resp_body =~ "login_disclosure_mode"
      end
    end
  end

  # ── Seven-key shape on every tenant_map/1 route ─────────────────────────

  describe "AC3 (platform-admin half): the tenant shape has exactly seven keys on every route" do
    test "get, list, patch, deactivate and reactivate carry the key (value or null) alongside the six existing keys" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-shape")
      set_mode!(t.tenant_id, "uniform_plus_email")
      slug = t.tenant.slug
      actor = Ecto.UUID.generate()

      get = build_conn(:get, "/#{slug}", ["PLATFORM_ADMIN"], nil, actor) |> dispatch()
      assert get.status == 200
      assert Map.keys(Jason.decode!(get.resp_body)) |> Enum.sort() == @seven_keys
      assert Jason.decode!(get.resp_body)["login_disclosure_mode"] == "uniform_plus_email"

      list = build_conn(:get, "/?search=#{slug}", ["PLATFORM_ADMIN"], nil, actor) |> dispatch()
      assert list.status == 200
      item = Enum.find(Jason.decode!(list.resp_body)["items"], &(&1["slug"] == slug))
      assert Map.keys(item) |> Enum.sort() == @seven_keys
      assert item["login_disclosure_mode"] == "uniform_plus_email"

      patch = admin_patch(slug, %{"display_name" => "Shape 442"}, actor)
      assert patch.status == 200
      assert Map.keys(Jason.decode!(patch.resp_body)) |> Enum.sort() == @seven_keys

      deactivate =
        build_conn(:post, "/#{slug}/deactivate", ["PLATFORM_ADMIN"], nil, actor) |> dispatch()

      assert deactivate.status == 200
      assert Map.keys(Jason.decode!(deactivate.resp_body)) |> Enum.sort() == @seven_keys
      assert Jason.decode!(deactivate.resp_body)["login_disclosure_mode"] == "uniform_plus_email"

      reactivate =
        build_conn(:post, "/#{slug}/reactivate", ["PLATFORM_ADMIN"], nil, actor) |> dispatch()

      assert reactivate.status == 200
      assert Map.keys(Jason.decode!(reactivate.resp_body)) |> Enum.sort() == @seven_keys
    end

    test "an unset tenant renders the key as JSON null (present, not omitted) on get" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-shape-null")

      get =
        build_conn(:get, "/#{t.tenant.slug}", ["PLATFORM_ADMIN"], nil, Ecto.UUID.generate())
        |> dispatch()

      body = Jason.decode!(get.resp_body)
      assert Map.has_key?(body, "login_disclosure_mode")
      assert body["login_disclosure_mode"] == nil
      assert get.resp_body =~ ~s("login_disclosure_mode":null)
    end

    test "POST /tenants returns seven keys with a null mode, and a login_disclosure_mode in the create body is ignored (not cast on create)" do
      SandboxAutoMode.provision!(Letflow.Repo, fn ->
        slug = "req442-create-#{Ecto.UUID.generate()}"

        resp =
          build_conn(
            :post,
            "/",
            ["PLATFORM_ADMIN"],
            %{
              "slug" => slug,
              "display_name" => "Create 442",
              "login_disclosure_mode" => "uniform_plus_email"
            },
            Ecto.UUID.generate()
          )
          |> dispatch()

        assert resp.status == 201
        body = Jason.decode!(resp.resp_body)
        tenant_id = body["id"]

        on_exit(fn ->
          SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

          case TenantProvisioning.schema_name_for_tenant(tenant_id) do
            {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
            {:error, :invalid_tenant_id} -> :ok
          end

          Repo.delete_all(
            from(r in TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
          )

          Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
        end)

        assert Map.keys(body) |> Enum.sort() == @seven_keys
        assert body["login_disclosure_mode"] == nil
        assert Repo.get!(Tenant, tenant_id).login_disclosure_mode == nil
      end)
    end
  end
end
