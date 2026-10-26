defmodule Letflow.Modules.InstallsUninstallTest do
  @moduledoc """
  REQ-578 / GH #3267 (decision 0066 D2), slice 1 part 1, criteria 1-7 and 9: the
  `tenant_modules.status` column, the `Installs` read semantics for an uninstalled row, and
  `Installs.uninstall/3` / `reactivate/3` with exactly one audit entry each.

  `async: false`: tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.TenantConfigBundle
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @why "test: REQ-578 transition"

  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  defp install!(prefix, id) do
    {:ok, tm} = Installs.install(id, Ecto.UUID.generate(), prefix: prefix, rationale: @why)
    tm
  end

  defp opts(prefix), do: [prefix: prefix, rationale: @why]

  defp row!(prefix, id), do: Repo.get_by!(TenantModule, [module_id: id], prefix: prefix)

  defp audit_count(prefix), do: Repo.aggregate(Entry, :count, prefix: prefix)

  defp set_hash!(prefix, id, hash) do
    row!(prefix, id)
    |> Ecto.Changeset.change(%{manifest_hash: hash})
    |> Repo.update!(prefix: prefix)
  end

  # ── Real-router helpers (criteria 5 and 6): AuthPipeline -> Modules router / Me router ──

  defp http_ctx(slug_prefix) do
    t = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    ctx = %{schema_name: t.schema_name, slug: t.tenant.slug}

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req578-user-#{Ecto.UUID.generate()}",
        display_name: "REQ-578 test user",
        email: "req578-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TASK_WORKER"], expires_at: nil},
        prefix: ctx.schema_name
      )

    Map.put(ctx, :plaintext, plaintext)
  end

  defp http_get(path, ctx, trace_id \\ "req578-shared-trace-id") do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", trace_id)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  @module_path "/api/v1/modules/fixture/items/42"

  defp me_module_ids(ctx) do
    conn = http_get("/api/v1/me/modules", ctx)
    assert conn.status == 200
    for %{"module_id" => id} <- Jason.decode!(conn.resp_body)["installed_modules"], do: id
  end

  # The 404 a module id that was never installed gets: the byte-identity reference.
  defp never_installed_body(ctx),
    do: http_get("/api/v1/modules/does-not-exist/anything", ctx).resp_body

  @counted_tables ~w(tenant_modules entity_definitions process_definitions entity_record_latest events entity_field_restrictions)

  defp count_rows(prefix) do
    tenant_counts =
      Map.new(@counted_tables, fn t ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{prefix}\".#{t}")
        {t, n}
      end)

    # `secrets` is a shared table (rows carry tenant_id), so it is counted whole.
    %{rows: [[secrets]]} = Repo.query!("SELECT count(*) FROM secrets")
    Map.put(tenant_counts, "secrets", secrets)
  end

  describe "M: status column (criterion 1)" do
    test "M1: a row inserted with only the pre-existing columns reads :active" do
      %{schema_name: prefix} = tenant!("req578-m1")

      Repo.query!(
        "INSERT INTO \"#{prefix}\".tenant_modules (id, module_id, version, installed_at, settings) " <>
          "VALUES ($1, 'legacy', '0.0.1', now(), '{}')",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      assert %TenantModule{status: :active} = row!(prefix, "legacy")
    end

    test "M2: status_changeset accepts the two statuses only; insert_changeset does not cast it" do
      assert TenantModule.status_changeset(%TenantModule{}, :uninstalled).valid?
      assert TenantModule.status_changeset(%TenantModule{}, :active).valid?
      refute TenantModule.status_changeset(%TenantModule{}, :gone).valid?

      cs =
        TenantModule.insert_changeset(%TenantModule{}, %{
          module_id: "x",
          version: "1",
          installed_at: DateTime.utc_now(),
          status: :uninstalled
        })

      assert Ecto.Changeset.get_field(cs, :status) == :active
    end

    test "M3: a provisioned schema has status NOT NULL default 'active'; the migration is in the manifest" do
      %{schema_name: prefix} = tenant!("req578-m3")

      assert %{rows: [["NO", default]]} =
               Repo.query!(
                 "SELECT is_nullable, column_default FROM information_schema.columns " <>
                   "WHERE table_schema = $1 AND table_name = 'tenant_modules' AND column_name = 'status'",
                 [prefix]
               )

      assert default =~ "active"

      assert 20_261_027_100_001 in Enum.map(
               Letflow.TenantProvisioning.tenant_scoped_migrations(),
               &elem(&1, 0)
             )
    end
  end

  describe "I: Installs on an uninstalled row (criteria 2, 3)" do
    test "I1: list_installed, installed?, hash and put_settings treat it as not installed" do
      %{schema_name: prefix} = tenant!("req578-i1")
      install!(prefix, "fixture")

      assert [_] = Installs.list_installed(prefix: prefix)
      assert Installs.installed?("fixture", prefix: prefix)
      assert {:ok, _} = Installs.installed_manifest_hash("fixture", prefix: prefix)

      assert {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      assert Installs.list_installed(prefix: prefix) == []
      assert [%TenantModule{status: :uninstalled}] = Installs.list_all(prefix: prefix)
      refute Installs.installed?("fixture", prefix: prefix)

      assert {:error, :not_installed} =
               Installs.installed_manifest_hash("fixture", prefix: prefix)

      before_settings = row!(prefix, "fixture").settings

      assert {:error, {:module_not_installed, "fixture"}} =
               Installs.put_settings("fixture", %{"greeting" => "hi"}, prefix: prefix)

      assert row!(prefix, "fixture").settings == before_settings
    end

    test "I2: a dependent cannot install over an uninstalled dependency; reinstall is :already_installed" do
      %{schema_name: prefix} = tenant!("req578-i2")
      install!(prefix, "fixture")
      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      assert {:error, {:dependency_not_installed, "fixture"}} =
               Installs.install("fixture_dependent", Ecto.UUID.generate(), opts(prefix))

      assert Repo.all(from(m in TenantModule, where: m.module_id == "fixture_dependent"),
               prefix: prefix
             ) == []

      assert {:error, :already_installed} =
               Installs.install("fixture", Ecto.UUID.generate(), opts(prefix))
    end
  end

  describe "U: uninstall/3 (criterion 5, 7)" do
    test "U1: only the status changes; the other columns and tenant B stay" do
      %{schema_name: prefix} = tenant!("req578-u1")
      %{schema_name: other} = tenant!("req578-u1b")
      before_row = install!(prefix, "fixture")
      install!(other, "fixture")

      assert {:ok, %TenantModule{status: :uninstalled}} =
               Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      after_row = row!(prefix, "fixture")

      assert Map.take(after_row, [:id, :version, :manifest_hash, :settings, :installed_at]) ==
               Map.take(before_row, [:id, :version, :manifest_hash, :settings, :installed_at])

      assert Repo.aggregate(TenantModule, :count, prefix: prefix) == 1
      assert %TenantModule{status: :active} = row!(other, "fixture")
    end

    test "U2: missing or already uninstalled row is :not_installed" do
      %{schema_name: prefix} = tenant!("req578-u2")

      assert {:error, :not_installed} =
               Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      install!(prefix, "fixture")
      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      assert {:error, :not_installed} =
               Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))
    end

    test "D1: refused while an active module depends on it (criterion 7)" do
      %{schema_name: prefix} = tenant!("req578-d1")
      install!(prefix, "fixture")
      install!(prefix, "fixture_dependent")

      assert {:error, {:dependents_installed, ["fixture_dependent"]}} =
               Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      assert %TenantModule{status: :active} = row!(prefix, "fixture")

      assert {:ok, _} =
               Installs.uninstall("fixture_dependent", Ecto.UUID.generate(), opts(prefix))

      assert {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))
    end

    test "N1: a missing, non-string or blank rationale is refused, status unchanged" do
      %{schema_name: prefix} = tenant!("req578-n1")
      install!(prefix, "fixture")
      actor = Ecto.UUID.generate()

      for bad <- [[], [rationale: 5], [rationale: "  "]] do
        o = [prefix: prefix] ++ bad
        assert {:error, :rationale_required} = Installs.uninstall("fixture", actor, o)
        assert {:error, :rationale_required} = Installs.reactivate("fixture", actor, o)
      end

      assert %TenantModule{status: :active} = row!(prefix, "fixture")
    end
  end

  describe "R: reactivate/3 (criterion 6)" do
    test "R1: matching hash reactivates" do
      %{schema_name: prefix} = tenant!("req578-r1")
      install!(prefix, "fixture")
      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      assert {:ok, %TenantModule{status: :active}} =
               Installs.reactivate("fixture", Ecto.UUID.generate(), opts(prefix))

      assert Installs.installed?("fixture", prefix: prefix)
      assert [_] = Installs.list_installed(prefix: prefix)
    end

    test "R2: differing or nil hash is :upgrade_required and the row stays uninstalled" do
      %{schema_name: prefix} = tenant!("req578-r2")
      install!(prefix, "fixture")
      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      for hash <- [String.duplicate("0", 64), nil] do
        set_hash!(prefix, "fixture", hash)

        assert {:error, :upgrade_required} =
                 Installs.reactivate("fixture", Ecto.UUID.generate(), opts(prefix))

        assert %TenantModule{status: :uninstalled} = row!(prefix, "fixture")
        refute Installs.installed?("fixture", prefix: prefix)
      end
    end

    test "R3: an inactive dependency is :dependency_not_installed" do
      %{schema_name: prefix} = tenant!("req578-r3")
      install!(prefix, "fixture")
      install!(prefix, "fixture_dependent")
      actor = Ecto.UUID.generate()
      {:ok, _} = Installs.uninstall("fixture_dependent", actor, opts(prefix))
      {:ok, _} = Installs.uninstall("fixture", actor, opts(prefix))

      assert {:error, {:dependency_not_installed, "fixture"}} =
               Installs.reactivate("fixture_dependent", actor, opts(prefix))

      assert %TenantModule{status: :uninstalled} = row!(prefix, "fixture_dependent")
    end

    test "R4: an active or missing row is :not_installed" do
      %{schema_name: prefix} = tenant!("req578-r4")
      actor = Ecto.UUID.generate()
      assert {:error, :not_installed} = Installs.reactivate("fixture", actor, opts(prefix))
      install!(prefix, "fixture")
      assert {:error, :not_installed} = Installs.reactivate("fixture", actor, opts(prefix))
    end
  end

  describe "A: audit (criterion 9)" do
    test "A1: one entry per success, none per refusal, carrying the facts and no settings" do
      %{schema_name: prefix} = tenant!("req578-a1")
      install!(prefix, "fixture")
      actor = Ecto.UUID.generate()
      base = audit_count(prefix)

      {:ok, tm} = Installs.uninstall("fixture", actor, opts(prefix))
      assert audit_count(prefix) == base + 1

      entry = Repo.one!(from(e in Entry, where: e.action == "module.uninstall"), prefix: prefix)
      assert entry.actor_id == actor
      assert entry.resource_type == "tenant_module"
      assert entry.resource_id == tm.id
      assert entry.before_state == %{"module_id" => "fixture", "status" => "active"}

      assert entry.after_state ==
               %{"module_id" => "fixture", "status" => "uninstalled", "rationale" => @why}

      {:ok, _} = Installs.reactivate("fixture", actor, opts(prefix))
      assert audit_count(prefix) == base + 2

      assert [_] =
               Repo.all(from(e in Entry, where: e.action == "module.reactivate"), prefix: prefix)

      assert {:error, :not_installed} = Installs.reactivate("fixture", actor, opts(prefix))
      assert audit_count(prefix) == base + 2
    end

    test "A2: a failing audit write raises and rolls the status change back" do
      %{schema_name: prefix} = tenant!("req578-a2")
      install!(prefix, "fixture")
      Repo.query!(~s(DROP TABLE "#{prefix}".audit_entries))

      error =
        assert_raise Postgrex.Error, fn ->
          Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))
        end

      assert error.postgres.code == :undefined_table
      assert error.postgres.message =~ "audit_entries"
      assert %TenantModule{status: :active} = row!(prefix, "fixture")
    end
  end

  describe "X: other readers" do
    test "X2: scope declarations keep resolving after uninstall (decision 0066 D3)" do
      fx = F.provision!("req578-x2")
      prefix = fx.schema_name
      actor = Ecto.UUID.generate()
      declared = ScopeDeclaration.for_type("scoped_managed_item", prefix)
      assert declared == {:column, "scope_node"}

      {:ok, _} = Installs.uninstall("fixture_scoped", actor, opts(prefix))
      assert ScopeDeclaration.for_type("scoped_managed_item", prefix) == declared

      {:ok, _} = Installs.reactivate("fixture_scoped", actor, opts(prefix))
      assert ScopeDeclaration.for_type("scoped_managed_item", prefix) == declared
    end

    test "X3: the config bundle export omits an uninstalled module" do
      %{schema_name: prefix, tenant_id: tenant_id} = tenant!("req578-x3")
      install!(prefix, "fixture")

      ids = fn ->
        {:ok, bundle} = TenantConfigBundle.export(tenant_id, prefix)
        Enum.map(bundle["module_settings"], & &1["module_id"])
      end

      assert ids.() == ["fixture"]
      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))
      assert ids.() == []
    end
  end

  describe "H: HTTP reachability through the real router (criteria 5, 6)" do
    test "U1h: after uninstall the module router answers the byte-identical 404, /me/modules drops it" do
      ctx = http_ctx("req578-h1")
      install!(ctx.schema_name, "fixture")

      assert http_get(@module_path, ctx).status == 200
      assert me_module_ids(ctx) == ["fixture"]

      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(ctx.schema_name))

      conn = http_get(@module_path, ctx)
      assert conn.status == 404
      assert conn.resp_body == never_installed_body(ctx)
      assert me_module_ids(ctx) == []
    end

    test "U1c: uninstall deletes or changes no definition, record, restriction or secret row" do
      %{schema_name: prefix, tenant_id: tenant_id} = tenant!("req578-h2")

      # Global tables with an FK to tenants that the fixture teardown does not know (same
      # arrangement as test/letflow/modules/install_activation_test.exs).
      on_exit(fn ->
        Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
      end)

      install!(prefix, "fixture_fk_pack")
      before_counts = count_rows(prefix)
      assert before_counts["entity_definitions"] >= 2

      {:ok, _} = Installs.uninstall("fixture_fk_pack", Ecto.UUID.generate(), opts(prefix))

      # events/audit are append-only; the transition adds no event row of its own
      assert count_rows(prefix) == before_counts
    end

    test "R1h: after reactivate the router and /me/modules work again as before" do
      ctx = http_ctx("req578-h3")
      install!(ctx.schema_name, "fixture")
      before_conn = http_get(@module_path, ctx)
      actor = Ecto.UUID.generate()
      {:ok, _} = Installs.uninstall("fixture", actor, opts(ctx.schema_name))
      {:ok, _} = Installs.reactivate("fixture", actor, opts(ctx.schema_name))

      after_conn = http_get(@module_path, ctx)

      assert {after_conn.status, after_conn.resp_body} ==
               {before_conn.status, before_conn.resp_body}

      assert after_conn.status == 200
      assert me_module_ids(ctx) == ["fixture"]
    end

    test "R2h: after upgrade_required the router still answers the byte-identical 404" do
      ctx = http_ctx("req578-h4")
      prefix = ctx.schema_name
      install!(prefix, "fixture")
      {:ok, _} = Installs.uninstall("fixture", Ecto.UUID.generate(), opts(prefix))

      for hash <- [String.duplicate("0", 64), nil] do
        set_hash!(prefix, "fixture", hash)

        assert {:error, :upgrade_required} =
                 Installs.reactivate("fixture", Ecto.UUID.generate(), opts(prefix))

        conn = http_get(@module_path, ctx)
        assert conn.status == 404
        assert conn.resp_body == never_installed_body(ctx)
        assert me_module_ids(ctx) == []
      end
    end
  end
end
