defmodule Letflow.TenantPurgeTest do
  @moduledoc """
  REQ-580 / GH #3292: `Letflow.TenantPurge` and the platform route `POST /tenants/:slug/purge`, against
  real Postgres and real tenant schemas. Test IDs: E (eligibility), R (what is removed), K (what is
  kept), F (failure), I (idempotence), S (settings), X (no cross-tenant deletion), P (platform route),
  RA (reactivation), O (order).

  `async: false`: provisioning flips the sandbox to `:auto`, and the platform-tenant pin and the
  retention setting are VM-global. The race between two purges (C1) cannot be forced here: the
  sandbox serialises on one connection and makes the advisory lock reentrant.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantPurge

  @day 86_400

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "req580-plat")
    Fixture.pin!(platform.tenant_id)
    previous = Application.get_env(:letflow, Letflow.TenantProvisioner)
    Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 30)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, Letflow.TenantProvisioner, previous),
        else: Application.delete_env(:letflow, Letflow.TenantProvisioner)
    end)

    %{platform: platform}
  end

  # --- helpers ---------------------------------------------------------------

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days * @day, :second)

  # A deactivated, provisioned demo tenant whose deletion was requested `requested` days ago, with a
  # login-directory row and a membership row.
  defp victim!(opts \\ []) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "req580-v")
    id = fixture.tenant_id
    Repo.update_all(from(t in Tenant, where: t.id == ^id), set: [status: :inactive])

    Repo.insert!(%Lifecycle{
      tenant_id: id,
      lifecycle: Keyword.get(opts, :lifecycle, "suspended"),
      tier: Keyword.get(opts, :tier, "demo"),
      language: "en",
      expires_at: Keyword.get(opts, :expires_at),
      deletion_requested_at: Keyword.get(opts, :requested, ago(31))
    })

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      {:ok, bin} = Ecto.UUID.dump(id)
      Repo.query!("DELETE FROM tenant_memberships WHERE tenant_id = $1", [bin])
      Repo.query!("DELETE FROM tenant_login_directory WHERE tenant_id = $1", [bin])
      Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
    end)

    seed_global_rows!(id)
    fixture
  end

  defp seed_global_rows!(id) do
    {:ok, bin} = Ecto.UUID.dump(id)
    key = :crypto.strong_rand_bytes(32)

    Repo.query!(
      "INSERT INTO tenant_login_directory (email_key, tenant_id, key_id, inserted_at) VALUES ($1, $2, 'k1', now())",
      [key, bin]
    )

    Repo.query!(
      "INSERT INTO tenant_memberships (id, subject_key, tenant_id, display_label, inserted_at, updated_at) VALUES ($1, $2, $3, 'Jane Doe', now(), now())",
      [Ecto.UUID.bingenerate(), "subject-#{id}", bin]
    )
  end

  defp global_counts(id) do
    {:ok, bin} = Ecto.UUID.dump(id)

    for {table, column} <- TenantPurge.removed_tables(), into: %{} do
      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} = $1", [bin])

      {table, n}
    end
  end

  defp schema_exists?(schema) do
    Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [schema]).rows !=
      []
  end

  defp lifecycle!(id), do: Repo.get!(Lifecycle, id)

  defp entries(ctx, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: ctx.platform.schema_name)

  # --- E: eligibility ---------------------------------------------------------

  describe "E eligibility" do
    test "E1 an active tenant is not eligible and nothing changes" do
      v = victim!()
      Repo.update_all(from(t in Tenant, where: t.id == ^v.tenant_id), set: [status: :active])
      before = global_counts(v.tenant_id)
      assert {:error, :not_eligible} = TenantPurge.purge(v.tenant_id, :provisioner)
      assert schema_exists?(v.schema_name)
      assert global_counts(v.tenant_id) == before
      assert lifecycle!(v.tenant_id).purged_at == nil
    end

    test "E2 a lifecycle of active, or a deleted-less no-reference row, is not eligible" do
      a = victim!(lifecycle: "active")
      b = victim!(requested: nil)
      assert {:error, :not_eligible} = TenantPurge.purge(a.tenant_id, :provisioner)
      assert {:error, :not_eligible} = TenantPurge.purge(b.tenant_id, :provisioner)
      assert schema_exists?(a.schema_name) and schema_exists?(b.schema_name)
    end

    test "E4 the boundary second purges, the second before does not" do
      requested = DateTime.utc_now()
      v = victim!(requested: requested)
      boundary = DateTime.add(requested, 30 * @day, :second)

      assert {:error, :not_eligible} =
               TenantPurge.purge(v.tenant_id, :provisioner,
                 now: DateTime.add(boundary, -1, :second)
               )

      assert schema_exists?(v.schema_name)
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner, now: boundary)
      refute schema_exists?(v.schema_name)
    end

    test "E5 production is never purged, by tenant_type or by tier" do
      a = victim!(tier: "production")
      b = victim!()

      Repo.update_all(from(t in Tenant, where: t.id == ^b.tenant_id),
        set: [tenant_type: "production"]
      )

      assert {:error, :not_eligible} = TenantPurge.purge(a.tenant_id, :provisioner)
      assert {:error, :not_eligible} = TenantPurge.purge(b.tenant_id, :provisioner)
      assert schema_exists?(a.schema_name) and schema_exists?(b.schema_name)
    end

    test "E6/E7 no lifecycle row, unknown id, non-uuid and the platform tenant are one :not_found",
         ctx do
      bare = TenantFixture.provisioned_tenant!(slug_prefix: "req580-bare")
      Repo.update_all(from(t in Tenant, where: t.id == ^bare.tenant_id), set: [status: :inactive])
      pid = ctx.platform.tenant_id

      Repo.insert!(%Lifecycle{
        tenant_id: pid,
        lifecycle: "suspended",
        tier: "demo",
        language: "en",
        deletion_requested_at: ago(90)
      })

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
        Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^pid))
      end)

      for id <- [bare.tenant_id, Ecto.UUID.generate(), "nope", pid, nil] do
        assert {:error, :not_found} = TenantPurge.purge(id, :provisioner)
      end

      assert schema_exists?(bare.schema_name) and schema_exists?(ctx.platform.schema_name)
    end

    test "E3 an expired tenant counts its retention from expires_at" do
      v = victim!(lifecycle: "expired", expires_at: ago(10), requested: ago(90))
      assert {:error, :not_eligible} = TenantPurge.purge(v.tenant_id, :provisioner)

      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^v.tenant_id),
        set: [expires_at: ago(31)]
      )

      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)
    end
  end

  # --- R / K: removed and kept ------------------------------------------------

  describe "R/K purge" do
    test "R1/R2/R4/K1/K2/K3 removes data, keeps the marker rows, writes one audit entry", ctx do
      v = victim!()
      id = v.tenant_id
      slug = v.tenant.slug
      realm_before = Repo.get!(Tenant, id).idp_realm_id
      assert %{"tenant_memberships" => 1, "tenant_login_directory" => 1} = global_counts(id)
      assert schema_exists?(v.schema_name)

      assert {:ok, :purged} =
               TenantPurge.purge(id, :platform_admin, actor_id: Ecto.UUID.generate())

      refute schema_exists?(v.schema_name)
      assert Enum.all?(global_counts(id), fn {_table, n} -> n == 0 end)

      tenant = Repo.get!(Tenant, id)
      assert %{id: ^id, slug: ^slug, status: :inactive, display_name: "purged"} = tenant
      assert tenant.idp_realm_id == realm_before
      assert %Lifecycle{lifecycle: "deleted", purged_at: %DateTime{}} = lifecycle!(id)

      assert [entry] =
               Enum.filter(entries(ctx, "platform.tenant.purged"), &(&1.resource_id == id))

      assert Enum.sort(Map.keys(entry.after_state)) == [
               "purged_at",
               "tables_dropped",
               "tenant_id",
               "trigger"
             ]

      assert entry.after_state["trigger"] == "platform_admin"
      refute inspect(entry) =~ "Jane Doe"
    end

    test "R6 every public table with a tenant column is removed or on the kept list" do
      kept = ~w(tenant_lifecycles onboarding_registry event_history_retirement_outcomes)
      removed = Enum.map(TenantPurge.removed_tables(), &elem(&1, 0))

      %{rows: rows} =
        Repo.query!(
          "SELECT DISTINCT table_name FROM information_schema.columns WHERE table_schema = 'public' AND column_name IN ('tenant_id', 'owner_tenant_id')"
        )

      unclassified = Enum.map(rows, &hd/1) -- (removed ++ kept)
      assert unclassified == []
    end

    test "K4 no kept table carries a personal-data column" do
      %{rows: rows} =
        Repo.query!(
          "SELECT table_name FROM information_schema.columns WHERE table_schema = 'public' AND column_name IN ('email', 'display_label', 'subject_key') AND table_name IN ('tenant_lifecycles', 'onboarding_registry', 'event_history_retirement_outcomes')"
        )

      assert rows == []
    end
  end

  # --- F / I / S / X / O --------------------------------------------------------

  describe "F failure" do
    test "F1 a failing audit insert rolls the whole purge back", ctx do
      v = victim!()
      id = v.tenant_id
      table = ~s("#{ctx.platform.schema_name}".audit_entries)
      Repo.query!("ALTER TABLE #{table} RENAME TO audit_entries_gone")

      try do
        assert {:error, :purge_failed} = TenantPurge.purge(id, :provisioner)
      after
        Repo.query!(
          ~s(ALTER TABLE "#{ctx.platform.schema_name}".audit_entries_gone RENAME TO audit_entries)
        )
      end

      assert schema_exists?(v.schema_name)
      assert %{"tenant_memberships" => 1} = global_counts(id)
      assert %Lifecycle{lifecycle: "suspended", purged_at: nil} = lifecycle!(id)
      assert {:ok, :purged} = TenantPurge.purge(id, :provisioner)
    end
  end

  describe "I idempotence" do
    test "I1 a second purge answers :already_purged and writes nothing", ctx do
      v = victim!()
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)
      purged = lifecycle!(v.tenant_id)
      assert {:ok, :already_purged} = TenantPurge.purge(v.tenant_id, :sweep)
      assert lifecycle!(v.tenant_id) == purged

      assert [_one] =
               Enum.filter(
                 entries(ctx, "platform.tenant.purged"),
                 &(&1.resource_id == v.tenant_id)
               )
    end
  end

  describe "S settings" do
    test "S1 retention_days is a setting: 0 purges at once, 365 does not; parser default and range" do
      v = victim!(requested: ago(1))
      Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 365)
      assert {:error, :not_eligible} = TenantPurge.purge(v.tenant_id, :provisioner)
      Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 0)
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)

      assert {:ok, %{provisioner: []}} = Config.parse(%{}, :test)

      assert {:ok, %{provisioner: [retention_days: 7]}} =
               Config.parse(%{"LETFLOW_PROVISIONER_RETENTION_DAYS" => "7"}, :test)

      assert {:ok, %{provisioner: [retention_days: 0]}} =
               Config.parse(%{"LETFLOW_PROVISIONER_RETENTION_DAYS" => "0"}, :test)

      for bad <- ["abc", "-1", "3651"] do
        assert {:error, "LETFLOW_PROVISIONER_RETENTION_DAYS"} =
                 Config.parse(%{"LETFLOW_PROVISIONER_RETENTION_DAYS" => bad}, :test)
      end

      Application.delete_env(:letflow, Letflow.TenantProvisioner)
      assert Config.retention_days() == 30
    end
  end

  describe "X no cross-tenant deletion" do
    test "X1 purging A leaves B's schema, rows and lifecycle unchanged" do
      a = victim!()
      b = victim!()

      b_before =
        {global_counts(b.tenant_id), lifecycle!(b.tenant_id), Repo.get!(Tenant, b.tenant_id)}

      assert {:ok, :purged} = TenantPurge.purge(a.tenant_id, :provisioner)

      assert schema_exists?(b.schema_name)

      assert b_before ==
               {global_counts(b.tenant_id), lifecycle!(b.tenant_id),
                Repo.get!(Tenant, b.tenant_id)}
    end

    test "X2 DROP SCHEMA exists in exactly one file of lib/" do
      hits =
        for path <- Path.wildcard("lib/**/*.ex"),
            File.read!(path) =~ ~r/DROP SCHEMA/i,
            do: path

      # sandbox_pool.ex drops its own pool schemas (not a tenant schema); no other file may.
      assert hits -- ["lib/letflow/sandbox_pool.ex"] == ["lib/letflow/tenant_purge.ex"]

      for path <- Path.wildcard("lib/**/*.ex") do
        refute File.read!(path) =~ ~r/delete_all\(\s*(from\([a-z]+ in )?Lifecycle/, path
      end
    end
  end

  describe "O order and reactivation" do
    test "O1 a purged tenant cannot be reactivated and stays inactive" do
      v = victim!()
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)
      assert {:error, :tenant_purged} = Identity.reactivate_tenant(v.tenant.slug)
      assert Repo.get!(Tenant, v.tenant_id).status == :inactive
    end
  end

  # --- P: platform route -------------------------------------------------------

  describe "P platform route" do
    @opts Letflow.Routers.Tenants.init([])

    defp post_purge(slug, roles, tenant_id) do
      conn(:post, "/#{slug}/purge")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: roles
      })
      |> assign(:trace_id, "fixed-test-trace-id")
      |> Letflow.Routers.Tenants.call(@opts)
    end

    test "P1 PLATFORM_ADMIN of the platform tenant purges; a repeat answers the same", ctx do
      v = victim!()
      conn = post_purge(v.tenant.slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"tenant_id" => _, "status" => "deleted", "purged_at" => at} = body
      assert is_binary(at)

      assert post_purge(v.tenant.slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id).resp_body ==
               conn.resp_body

      refute schema_exists?(v.schema_name)
    end

    test "P2 inside retention is 409 and nothing is purged", ctx do
      v = victim!(requested: ago(1))
      conn = post_purge(v.tenant.slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id)
      assert conn.status == 409
      assert schema_exists?(v.schema_name)
      assert lifecycle!(v.tenant_id).purged_at == nil
    end

    test "P3 unknown slug, no lifecycle row and the platform tenant are one 404", ctx do
      bare = TenantFixture.provisioned_tenant!(slug_prefix: "req580-bare")

      statuses =
        for slug <- ["no-such-slug", bare.tenant.slug, ctx.platform.tenant.slug] do
          post_purge(slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id)
        end

      assert Enum.all?(statuses, &(&1.status == 404))
      assert statuses |> Enum.map(& &1.resp_body) |> Enum.uniq() |> length() == 1
      assert schema_exists?(bare.schema_name)
    end

    test "N1-N4 TENANT_ADMIN, no role, and an operator of another tenant are refused", ctx do
      v = victim!()
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req580-other")

      for {roles, tenant_id} <- [
            {["TENANT_ADMIN"], v.tenant_id},
            {["TENANT_ADMIN"], other.tenant_id},
            {[], ctx.platform.tenant_id},
            {["PLATFORM_ADMIN"], other.tenant_id}
          ] do
        conn = post_purge(v.tenant.slug, roles, tenant_id)
        assert conn.status in [403, 404], "#{inspect(roles)}: #{conn.status}"
      end

      assert schema_exists?(v.schema_name)
      assert lifecycle!(v.tenant_id).purged_at == nil
    end

    test "RA1 reactivate of a purged tenant is 409 and the row stays inactive", ctx do
      v = victim!()
      assert post_purge(v.tenant.slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id).status == 200

      conn =
        conn(:post, "/#{v.tenant.slug}/reactivate")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: ctx.platform.tenant_id,
          roles: ["PLATFORM_ADMIN"]
        })
        |> assign(:trace_id, "t")
        |> Letflow.Routers.Tenants.call(@opts)

      assert conn.status == 409
      assert Repo.get!(Tenant, v.tenant_id).status == :inactive
    end
  end
end
