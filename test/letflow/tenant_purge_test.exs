defmodule Letflow.TenantPurgeTest do
  @moduledoc """
  REQ-580 / GH #3292: `Letflow.TenantPurge` and the platform route `POST /tenants/:slug/purge`, against
  real Postgres and real tenant schemas. Test IDs: E (eligibility), R (what is removed), K (what is
  kept), F (failure), I (idempotence), S (settings), X (no cross-tenant deletion), P (platform route),
  RA (reactivation), O (order).

  `async: false`: provisioning flips the sandbox to `:auto`, and the platform-tenant pin and the
  retention setting are VM-global. Tests C1 (two purges at once) relies on that `:auto` mode: each Task
  gets its own pool connection, so the advisory lock and the row lock really contend.
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

  # A deactivated, provisioned demo tenant whose deletion was requested `requested` days ago, with one
  # row in every table of `TenantPurge.removed_tables/0` (a rollout outcome that references the
  # tenant's column promotion included), an onboarding_registry row, and a user and an instance
  # projection in its own schema. `:email_key` lets two tenants hold the same login-directory key.
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

    hostname = "purge-#{Ecto.UUID.generate()}.example.com"
    rollout = Ecto.UUID.bingenerate()

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      {:ok, bin} = Ecto.UUID.dump(id)

      # tenant_schemas stays: the fixture's own cleanup reads it to find the schema.
      for {table, column} <- TenantPurge.removed_tables(), table != "tenant_schemas" do
        Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [bin])
      end

      Repo.query!("DELETE FROM platform_migration_rollouts WHERE id = $1", [rollout])
      Repo.query!("DELETE FROM onboarding_registry WHERE tenant_id = $1", [bin])
      Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
    end)

    seed_global_rows!(id, rollout, Keyword.get(opts, :email_key, :crypto.strong_rand_bytes(32)))
    seed_registry!(id, fixture.tenant.slug, hostname)
    seed_schema_rows!(fixture.schema_name)
    Map.put(fixture, :hostname, hostname)
  end

  defp seed_registry!(id, slug, hostname) do
    {:ok, bin} = Ecto.UUID.dump(id)

    Repo.query!(
      "INSERT INTO onboarding_registry (id, tenant_id, slug, hostname, inserted_at) VALUES ($1, $2, $3, $4, now())",
      [Ecto.UUID.bingenerate(), bin, slug, hostname]
    )
  end

  # A user and an instance projection in the tenant's own schema.
  defp seed_schema_rows!(schema_name) do
    n = Ecto.UUID.generate()

    %Letflow.Identity.User{}
    |> Ecto.Changeset.change(%{
      username: "purge-user-#{n}",
      display_name: "Jane Doe",
      email: "jane.doe.#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)

    %Letflow.EventStore.InstanceProjection{}
    |> Ecto.Changeset.change(%{
      instance_id: Ecto.UUID.generate(),
      status: :active,
      definition_id: Ecto.UUID.generate(),
      last_event_seq: 0
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # One row in each removed table except tenant_schemas (provisioning wrote that one).
  defp seed_global_rows!(id, rollout, email_key) do
    {:ok, bin} = Ecto.UUID.dump(id)
    promotion = Ecto.UUID.bingenerate()
    uid = &Ecto.UUID.bingenerate/0
    tag = Ecto.UUID.generate()

    rows = [
      {"INSERT INTO platform_migration_rollouts (id, entity_type, attribute, column_spec, started_at) VALUES ($1, 'e-#{tag}', 'a', '{}', now())",
       [rollout]},
      {"INSERT INTO entity_column_promotions (id, tenant_id, entity_type, attribute, column_name, pg_type, status, query_eligible, inserted_at, updated_at) VALUES ($1, $2, 'e-#{tag}', 'a', 'c', 'text', 'active', false, now(), now())",
       [promotion, bin]},
      {"INSERT INTO platform_migration_rollout_outcomes (id, rollout_id, tenant_id, column_promotion_id) VALUES ($1, $2, $3, $4)",
       [uid.(), rollout, bin, promotion]},
      {"INSERT INTO secrets (id, tenant_id, namespace, name, key_id, purpose, algorithm, wrapped_key_algorithm, ciphertext, wrapped_data_key, nonce, wrap_nonce, auth_tag, wrap_auth_tag, aad, wrapping_key_ref, created_at, created_by) VALUES ($1, $2, 'ns', 'n', 1, 'p', 'a', 'w', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'r', now(), 'test')",
       [uid.(), bin]},
      {"INSERT INTO public_read_handles (id, handle_hash, tenant_id, kind, resource_id, inserted_at, updated_at) VALUES ($1, $2, $3, 'k', $4, now(), now())",
       [uid.(), "hash-#{tag}", bin, uid.()]},
      {"INSERT INTO entity_constraint_activations (id, tenant_id, entity_type, constraint_name, fields, status, inserted_at, updated_at) VALUES ($1, $2, 'e', 'c', ARRAY['a']::varchar[], 'active', now(), now())",
       [uid.(), bin]},
      {"INSERT INTO solution_pack_installs (id, tenant_id, pack_id, installed_version, installed_at, inserted_at, updated_at) VALUES ($1, $2, 'p', '1.0.0', now(), now(), now())",
       [uid.(), bin]},
      {"INSERT INTO solution_pack_artefact_bases (id, tenant_id, pack_id, artefact_type, artefact_id, base_version, base_content, captured_at, inserted_at, updated_at) VALUES ($1, $2, 'p', 't', 'a', '1.0.0', 'c', now(), now(), now())",
       [uid.(), bin]},
      {"INSERT INTO pack_update_resolutions (id, tenant_id, pack_id, target_version, artefact_type, artefact_id, resolution, resolved_by, resolved_at, inserted_at, updated_at) VALUES ($1, $2, 'p', '1.0.1', 't', 'a', 'keep', $3, now(), now(), now())",
       [uid.(), bin, uid.()]},
      {"INSERT INTO service_catalog (service_id, endpoint_url, timeout_ms, scope, owner_tenant_id, created_at, updated_at, published_at) VALUES ($1, 'https://svc.example.com', 1000, 'tenant', $2, now(), now(), now())",
       ["svc-#{tag}", bin]},
      {"INSERT INTO tenant_login_directory (email_key, tenant_id, key_id, inserted_at) VALUES ($1, $2, 'k1', now())",
       [email_key, bin]},
      {"INSERT INTO tenant_memberships (id, subject_key, tenant_id, display_label, inserted_at, updated_at) VALUES ($1, $2, $3, 'Jane Doe', now(), now())",
       [uid.(), "subject-#{id}", bin]}
    ]

    for {sql, params} <- rows, do: Repo.query!(sql, params)
  end

  # {row count, md5 of the rows} per removed table, for one tenant.
  defp global_snapshot(id) do
    {:ok, bin} = Ecto.UUID.dump(id)

    for {table, column} <- TenantPurge.removed_tables(), into: %{} do
      %{rows: [[n, digest]]} =
        Repo.query!(
          "SELECT count(*), coalesce(md5(string_agg(t::text, ',' ORDER BY t::text)), '') FROM #{table} t WHERE #{column} = $1",
          [bin]
        )

      {table, {n, digest}}
    end
  end

  defp global_counts(id),
    do: id |> global_snapshot() |> Map.new(fn {table, {n, _digest}} -> {table, n} end)

  # Row count of every base table in a tenant schema.
  defp schema_counts(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
        [schema]
      )

    for [table] <- rows, into: %{} do
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".\"#{table}\"")
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
      key = :crypto.strong_rand_bytes(32)
      v = victim!(email_key: key)
      # B holds a login-directory row with the SAME e-mail key as A.
      b = victim!(email_key: key)
      id = v.tenant_id
      slug = v.tenant.slug
      realm_before = Repo.get!(Tenant, id).idp_realm_id
      original_name = Repo.get!(Tenant, id).display_name
      actor = Ecto.UUID.generate()

      before_a = global_snapshot(id)
      before_b = global_snapshot(b.tenant_id)
      removed = Enum.map(TenantPurge.removed_tables(), &elem(&1, 0))
      assert Map.keys(before_a) |> Enum.sort() == Enum.sort(removed)
      # Every removed table holds a row of A (so "0 after" proves a delete) and of B.
      assert Enum.all?(before_a, fn {_table, {n, _}} -> n >= 1 end), inspect(before_a)
      assert Enum.all?(before_b, fn {_table, {n, _}} -> n >= 1 end)
      assert schema_exists?(v.schema_name)

      assert {:ok, :purged} = TenantPurge.purge(id, :platform_admin, actor_id: actor)

      refute schema_exists?(v.schema_name)
      assert Enum.all?(global_counts(id), fn {_table, n} -> n == 0 end)
      assert global_snapshot(b.tenant_id) == before_b
      assert schema_exists?(b.schema_name)

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
      assert entry.actor_id == actor

      serialized = inspect(entry)
      refute serialized =~ "Jane Doe"
      refute serialized =~ "jane.doe"
      refute serialized =~ original_name
    end

    test "R3 the provisioner trigger writes an audit entry with no actor", ctx do
      v = victim!()
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)

      assert [entry] =
               Enum.filter(
                 entries(ctx, "platform.tenant.purged"),
                 &(&1.resource_id == v.tenant_id)
               )

      assert entry.actor_id == nil
      assert entry.after_state["trigger"] == "provisioner"
    end

    test "R7 a purged tenant keeps its slug and hostname reserved (registry row kept)" do
      v = victim!()
      {:ok, bin} = Ecto.UUID.dump(v.tenant_id)
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)

      assert %{rows: [[slug, hostname]]} =
               Repo.query!(
                 "SELECT slug, hostname FROM onboarding_registry WHERE tenant_id = $1",
                 [
                   bin
                 ]
               )

      assert slug == v.tenant.slug and hostname == v.hostname
    end

    test "R8 a deletion-requested tenant is already unreachable before the purge" do
      key = :crypto.strong_rand_bytes(32)
      v = victim!(email_key: key)
      assert Repo.get!(Tenant, v.tenant_id).status == :inactive
      assert {:ok, []} = Letflow.LoginDirectory.lookup_by_keys([key])
    end

    test "R6 every public table with a tenant column is removed or on the kept list" do
      # iss060_tenant_schemas_guard_backup is a scratch table another test file (identity_migration_test) leaves in public.
      kept =
        ~w(tenant_lifecycles onboarding_registry event_history_retirement_outcomes iss060_tenant_schemas_guard_backup)

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

    test "C1 two concurrent purges: one :purged, one :already_purged, one audit entry", ctx do
      v = victim!()
      id = v.tenant_id
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> TenantPurge.purge(id, :provisioner)
            end
          end)
        end

      pids =
        for _ <- 1..2 do
          receive do
            {:ready, pid} -> pid
          after
            10_000 -> flunk("a purge task did not start")
          end
        end

      Enum.each(pids, &send(&1, :go))

      assert tasks |> Task.await_many(120_000) |> Enum.sort() ==
               [{:ok, :already_purged}, {:ok, :purged}]

      assert [_one] =
               Enum.filter(entries(ctx, "platform.tenant.purged"), &(&1.resource_id == id))

      refute schema_exists?(v.schema_name)
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
    test "X1 purging A by each trigger leaves every row, table and the schema of B unchanged",
         ctx do
      b = victim!()
      b_before = {global_snapshot(b.tenant_id), schema_counts(b.schema_name)}
      b_rows = {lifecycle!(b.tenant_id), Repo.get!(Tenant, b.tenant_id)}
      assert b_before |> elem(1) |> Map.values() |> Enum.sum() >= 2

      for trigger <- [:provisioner, :platform_admin, :sweep] do
        a = victim!()
        assert {:ok, :purged} = TenantPurge.purge(a.tenant_id, trigger)
        refute schema_exists?(a.schema_name)

        assert schema_exists?(b.schema_name)
        assert b_before == {global_snapshot(b.tenant_id), schema_counts(b.schema_name)}
        assert b_rows == {lifecycle!(b.tenant_id), Repo.get!(Tenant, b.tenant_id)}
      end

      # and through the platform route
      a = victim!()
      assert post_purge(a.tenant.slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id).status == 200
      assert b_before == {global_snapshot(b.tenant_id), schema_counts(b.schema_name)}
      assert b_rows == {lifecycle!(b.tenant_id), Repo.get!(Tenant, b.tenant_id)}
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

    defp mint!(fixture, roles) do
      n = Ecto.UUID.generate()

      user =
        %Letflow.Identity.User{}
        |> Ecto.Changeset.change(%{
          username: "purge-caller-#{n}",
          display_name: "Purge Caller",
          email: "purge-caller-#{n}@example.com",
          password_hash: "__NO_PASSWORD_SET__",
          status: :active,
          auth_source: :internal
        })
        |> Repo.insert!(prefix: fixture.schema_name)

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: roles, expires_at: nil},
          prefix: fixture.schema_name
        )

      plaintext
    end

    defp api(method, path, token, slug, body \\ nil) do
      conn =
        if body,
          do:
            conn(method, path, Jason.encode!(body))
            |> put_req_header("content-type", "application/json"),
          else: conn(method, path)

      conn =
        if token,
          do:
            conn
            |> put_req_header("authorization", "Bearer " <> token)
            |> put_req_header("x-tenant-slug", slug),
          else: conn

      Letflow.Router.call(conn, Letflow.Router.init([]))
    end

    test "N1-N4 no token, a foreign admin, a role-less caller and a foreign platform admin are refused",
         ctx do
      v = victim!()
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req580-other")
      path = "/api/v1/tenants/#{v.tenant.slug}/purge"
      before = {global_snapshot(v.tenant_id), lifecycle!(v.tenant_id)}

      assert api(:post, path, nil, nil).status == 401

      for roles <- [["TENANT_ADMIN"], ["PROCESS_DESIGNER"]] do
        conn = api(:post, path, mint!(other, roles), other.tenant.slug)
        assert conn.status == 403, "#{inspect(roles)}: #{conn.status} #{conn.resp_body}"
      end

      # the same refusal for a caller of the platform tenant without the platform role
      conn = api(:post, path, mint!(ctx.platform, ["TENANT_ADMIN"]), ctx.platform.tenant.slug)
      assert conn.status == 403

      # a PLATFORM_ADMIN whose resolved tenant is not the platform tenant (cannot be minted as a
      # token, so the auth_context is assigned): the 403 of the existing scope rule
      foreign = post_purge(v.tenant.slug, ["PLATFORM_ADMIN"], other.tenant_id)
      assert foreign.status == 403

      assert schema_exists?(v.schema_name)
      assert before == {global_snapshot(v.tenant_id), lifecycle!(v.tenant_id)}
    end

    test "P4 a failing purge answers 500 internal_error with no database text and rolls back",
         ctx do
      v = victim!()
      table = ~s("#{ctx.platform.schema_name}".audit_entries)
      Repo.query!("ALTER TABLE #{table} RENAME TO audit_entries_gone")

      conn =
        try do
          post_purge(v.tenant.slug, ["PLATFORM_ADMIN"], ctx.platform.tenant_id)
        after
          Repo.query!(
            ~s(ALTER TABLE "#{ctx.platform.schema_name}".audit_entries_gone RENAME TO audit_entries)
          )
        end

      assert conn.status == 500

      assert %{"status" => 500, "type" => "https://bpm.example.com/problems/internal-error"} =
               Jason.decode!(conn.resp_body)

      refute conn.resp_body =~ ~r/audit_entries|relation|SELECT|DELETE|DROP|postgres/i
      assert schema_exists?(v.schema_name)
      assert %Lifecycle{purged_at: nil} = lifecycle!(v.tenant_id)
    end

    test "SL1/HN1 a purged slug and hostname stay taken: onboarding answers 409", ctx do
      v = victim!()
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)
      token = mint!(ctx.platform, ["PLATFORM_ADMIN"])
      slug = ctx.platform.tenant.slug
      fresh = Letflow.TenantSlugFixture.unique_slug("req580-fresh")

      same_slug =
        api(:post, "/api/v1/onboarding", token, slug, %{
          "slug" => v.tenant.slug,
          "display_name" => "Reuse",
          "hostname" => "fresh-#{Ecto.UUID.generate()}.example.com"
        })

      same_host =
        api(:post, "/api/v1/onboarding", token, slug, %{
          "slug" => fresh,
          "display_name" => "Reuse",
          "hostname" => v.hostname
        })

      assert same_slug.status == 409, same_slug.resp_body
      assert same_host.status == 409, same_host.resp_body
      assert Repo.aggregate(from(t in Tenant, where: t.slug == ^fresh), :count) == 0
    end

    test "TK1 a former user's token of a purged tenant answers 403 tenant_inactive" do
      v = victim!()
      token = mint!(v, ["TENANT_ADMIN"])
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)

      # through the real router: AuthPipeline must not query the dropped schema (INV-8)
      conn = api(:get, "/api/v1/me", token, v.tenant.slug)

      assert conn.status == 403, conn.resp_body
      assert Jason.decode!(conn.resp_body)["error"] == "tenant_inactive"
    end

    test "PT1 PATCH of a purged tenant is refused and display_name stays purged", ctx do
      v = victim!()
      assert {:ok, :purged} = TenantPurge.purge(v.tenant_id, :provisioner)
      name = Repo.get!(Tenant, v.tenant_id).display_name

      conn =
        conn(:patch, "/#{v.tenant.slug}", Jason.encode!(%{"display_name" => "Back"}))
        |> put_req_header("content-type", "application/json")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: ctx.platform.tenant_id,
          roles: ["PLATFORM_ADMIN"]
        })
        |> assign(:trace_id, "t")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Letflow.Routers.Tenants.call(@opts)

      assert conn.status == 409
      assert Repo.get!(Tenant, v.tenant_id).display_name == name
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
