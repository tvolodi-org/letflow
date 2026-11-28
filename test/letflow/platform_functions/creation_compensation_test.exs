defmodule Letflow.PlatformFunctions.CreationCompensationTest do
  @moduledoc """
  T-3233: a registration chain that ends in a terminal failure does not leave a half-made tenant
  (a schema and a `tenant_schemas` row, no lifecycle or onboarding rows) behind.

  Test IDs: C1 `tenant.record_onboarding` fails (the host is taken); C2 `tenant.record_lifecycle`
  fails; C3 a crash between provision and record_onboarding (the attempt cap, the dead letter);
  C4 an ADOPTED tenant (a replay of an existing slug, an older tenant, an earlier instance) is never
  purged; C5 the platform tenant and an unrelated tenant are never touched (INV-1/INV-10);
  C6 a failure of another step keeps the tenant; C7 `TenantPurge.compensate_creation/1` edges;
  C8 the old create path (`TenantProvisioner.create/2`, host conflict) compensates a `:created`
  tenant and not an `:existing` one.

  The dispatch rows are written directly (the dispatcher's own table), so the test needs no
  definition: what is under test is the terminal-failure hook and the proof "this instance created
  the tenant". `async: false`: the platform tenant pin is VM-global and the tenants are committed.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.TenantPurge

  @token "write-credential-for-tests-0123456789abcdef0123456789abcdef"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t3233-plat")
    Fixture.pin!(platform.tenant_id)
    %{platform: platform}
  end

  # A provisioned tenant the chain "created": it has a schema and a `tenant_schemas` row and, like
  # a chain that stopped after `tenant.provision`, no lifecycle and no onboarding row.
  defp half_made! do
    f = TenantFixture.provisioned_tenant!(slug_prefix: "t3233-half")
    id = f.tenant_id

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
    end)

    f
  end

  defp dispatch!(ctx, instance_id, function, attrs) do
    now = DateTime.utc_now()
    {:ok, id} = Ecto.UUID.cast(Ecto.UUID.generate())

    base = %{
      id: id,
      tenant_id: ctx.platform.tenant_id,
      instance_id: instance_id,
      definition_id: Ecto.UUID.generate(),
      node_id: "n-" <> function,
      function_name: function,
      call_key: "t3233-#{Ecto.UUID.generate()}",
      input_fingerprint: "fp",
      status: :pending,
      attempt_index: 0,
      next_attempt_at: now,
      created_at: now
    }

    attrs = Map.merge(base, attrs)

    row =
      %StepDispatch{}
      |> StepDispatch.arm_changeset(attrs)
      |> Repo.insert!(prefix: ctx.platform.schema_name)

    # The arming changeset does not take the outputs: an advanced row carries them from its run.
    from(d in StepDispatch, where: d.id == ^row.id)
    |> Repo.update_all([set: [outputs: Map.get(attrs, :outputs)]],
      prefix: ctx.platform.schema_name
    )

    Repo.get!(StepDispatch, row.id, prefix: ctx.platform.schema_name)
  end

  # The advanced `tenant.create` row of the instance, armed `armed_at` (the tenant row of the fixture
  # was written at about "now": an earlier arming means this instance wrote it).
  defp create_row!(ctx, instance_id, tenant_id, armed_at) do
    dispatch!(ctx, instance_id, "tenant.create", %{
      status: :advanced,
      outputs: %{"tenant_id" => tenant_id},
      created_at: armed_at
    })
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # A step of the instance that is RUNNING (attempt 1) and fails with `reason`.
  defp fail_step!(ctx, instance_id, function, reason) do
    row = dispatch!(ctx, instance_id, function, %{status: :running, attempt_index: 1})
    assert :ok = Dispatcher.record_outcome(row, ctx.platform.schema_name, {:error, reason})
    Repo.get!(StepDispatch, row.id, prefix: ctx.platform.schema_name)
  end

  defp schema_exists?(schema) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM pg_namespace WHERE nspname = $1", [schema])

    n == 1
  end

  defp registry_rows(id),
    do: Repo.aggregate(from(r in Registration, where: r.tenant_id == ^id), :count)

  defp assert_undone(f) do
    refute schema_exists?(f.schema_name)
    assert registry_rows(f.tenant_id) == 0

    assert %Lifecycle{lifecycle: "deleted", purged_at: %DateTime{}} =
             Repo.get(Lifecycle, f.tenant_id)

    assert Repo.get!(Tenant, f.tenant_id).status == :inactive
    assert Repo.get(OnboardingRecord, f.tenant_id) == nil
  end

  defp assert_kept(f) do
    assert schema_exists?(f.schema_name)
    assert registry_rows(f.tenant_id) == 1
    assert Repo.get(Lifecycle, f.tenant_id) == nil
  end

  describe "chain failures" do
    test "C1 record_onboarding fails (host taken): the tenant the instance created is undone",
         ctx do
      f = half_made!()
      instance = Ecto.UUID.generate()
      create_row!(ctx, instance, f.tenant_id, ago(3600))
      dispatch!(ctx, instance, "tenant.provision", %{status: :advanced, outputs: %{}})

      row = fail_step!(ctx, instance, "tenant.record_onboarding", :platform_call_hostname_taken)

      assert row.status == :given_up
      assert row.last_failure_kind == "platform_call_hostname_taken"
      assert_undone(f)
    end

    test "C2 record_lifecycle fails: the tenant the instance created is undone", ctx do
      f = half_made!()
      instance = Ecto.UUID.generate()
      create_row!(ctx, instance, f.tenant_id, ago(3600))

      fail_step!(ctx, instance, "tenant.record_lifecycle", :platform_call_lifecycle_failed)

      assert_undone(f)
    end

    test "C3 a crash between provision and record_onboarding: the dead letter undoes it", ctx do
      f = half_made!()
      instance = Ecto.UUID.generate()
      create_row!(ctx, instance, f.tenant_id, ago(3600))

      # The run of the step died `max_attempts` times: the lease took over until the cap.
      stuck =
        dispatch!(ctx, instance, "tenant.record_onboarding", %{
          attempt_index: Dispatcher.max_attempts(),
          next_attempt_at: DateTime.utc_now()
        })

      assert {:error, :platform_step_max_attempts} =
               Dispatcher.attempt_dispatch(stuck.id, ctx.platform.schema_name)

      assert_undone(f)
    end

    test "C4a a replay of an existing tenant's create (an older tenant) never purges it", ctx do
      f = half_made!()
      instance = Ecto.UUID.generate()
      # The dispatch row was armed AFTER the tenant row existed: the create step adopted it.
      create_row!(ctx, instance, f.tenant_id, DateTime.add(DateTime.utc_now(), 3600, :second))

      fail_step!(ctx, instance, "tenant.record_onboarding", :platform_call_hostname_taken)

      assert_kept(f)
    end

    test "C4b a tenant an EARLIER instance created is not purged by a later instance", ctx do
      f = half_made!()
      first = Ecto.UUID.generate()
      second = Ecto.UUID.generate()
      create_row!(ctx, first, f.tenant_id, ago(7200))
      create_row!(ctx, second, f.tenant_id, ago(3600))

      fail_step!(ctx, second, "tenant.record_lifecycle", :platform_call_lifecycle_failed)

      assert_kept(f)
    end

    test "C4c an instance with no tenant.create output touches nothing", ctx do
      f = half_made!()

      fail_step!(
        ctx,
        Ecto.UUID.generate(),
        "tenant.record_onboarding",
        :platform_call_hostname_taken
      )

      assert_kept(f)
    end

    test "C5 the platform tenant and an unrelated tenant are never touched (INV-1/INV-10)", ctx do
      other = half_made!()
      instance = Ecto.UUID.generate()
      # A chain whose create output names the PLATFORM tenant, armed long before it.
      create_row!(ctx, instance, ctx.platform.tenant_id, ago(86_400 * 365))

      fail_step!(ctx, instance, "tenant.record_onboarding", :platform_call_hostname_taken)

      assert schema_exists?(ctx.platform.schema_name)
      assert Repo.get(Lifecycle, ctx.platform.tenant_id) == nil
      assert Repo.get!(Tenant, ctx.platform.tenant_id).status == :active
      assert_kept(other)

      # A chain that DID create its own tenant leaves the unrelated one alone as well.
      mine = half_made!()
      second = Ecto.UUID.generate()
      create_row!(ctx, second, mine.tenant_id, ago(3600))
      fail_step!(ctx, second, "tenant.record_lifecycle", :platform_call_lifecycle_failed)
      assert_undone(mine)
      assert_kept(other)
    end

    test "C6 a failure of a later step keeps the tenant (a repeat completes it)", ctx do
      f = half_made!()
      instance = Ecto.UUID.generate()
      create_row!(ctx, instance, f.tenant_id, ago(3600))

      for step <- ["tenant.notify_admin", "tenant.bind_realm", "tenant.install_default_modules"] do
        fail_step!(ctx, instance, step, :platform_call_failed)
      end

      assert_kept(f)
    end
  end

  describe "TenantPurge.compensate_creation/1" do
    test "C7 unknown id, non-id, platform tenant; a purged tenant is idempotent", ctx do
      assert {:error, :not_found} = TenantPurge.compensate_creation(Ecto.UUID.generate())
      assert {:error, :not_found} = TenantPurge.compensate_creation("nope")
      assert {:error, :not_found} = TenantPurge.compensate_creation(ctx.platform.tenant_id)
      assert schema_exists?(ctx.platform.schema_name)

      f = half_made!()
      assert {:ok, :purged} = TenantPurge.compensate_creation(f.tenant_id)
      assert_undone(f)
      assert {:ok, :already_purged} = TenantPurge.compensate_creation(f.tenant_id)
      assert {:error, :tenant_purged} = Identity.reactivate_tenant(f.tenant.slug)
    end
  end

  describe "old create path" do
    setup do
      previous = %{
        auth: Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth),
        prov: Application.get_env(:letflow, Letflow.TenantProvisioner),
        url: Application.get_env(:letflow, :provisioner_public_base_url)
      }

      Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth,
        write_sha256: :crypto.hash(:sha256, @token) |> Base.encode16(case: :lower)
      )

      Application.put_env(:letflow, Letflow.TenantProvisioner,
        allowed_hostname_suffixes: ["qa.example"],
        demo_lifetime_days: 14,
        default_modules: []
      )

      Application.put_env(:letflow, :provisioner_public_base_url, "https://letflow.qa.example")
      Letflow.Plugs.ProvisionerAuth.RateLimiter.reset()

      on_exit(fn ->
        restore(Letflow.Plugs.ProvisionerAuth, previous.auth)
        restore(Letflow.TenantProvisioner, previous.prov)
        restore(:provisioner_public_base_url, previous.url)
        Letflow.Plugs.ProvisionerAuth.RateLimiter.reset()
      end)

      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:letflow, key)
    defp restore(key, value), do: Application.put_env(:letflow, key, value)

    defp body(host) do
      id = Ecto.UUID.generate()

      %{
        "tenant_id" => id,
        "name" => "T-3233 Demo",
        "language" => "en",
        "tier" => "demo",
        "owner_email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "hostname" => host,
        "idp_realm_id" => "t-" <> String.slice(String.replace(id, "-", ""), 0, 20)
      }
    end

    defp post(body) do
      conn(:post, "/admin/v1/tenants", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> Letflow.Router.call(Letflow.Router.init([]))
    end

    defp drop_on_exit(id) do
      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

        case TenantProvisioning.schema_name_for_tenant(id) do
          {:ok, schema} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
          _invalid -> :ok
        end

        Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
        Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^id))
        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^id))
      end)
    end

    # The race of the old path, made deterministic: a trigger on the schema registry takes the host for
    # ANOTHER tenant while the new tenant is being provisioned, after the front gate looked at it.
    defp steal_host_on_provision!(tenant_id, host, holder_id) do
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      {:ok, holder} = Ecto.UUID.dump(holder_id)
      fun = "t3233_steal_#{System.unique_integer([:positive])}"

      Repo.query!("""
      CREATE FUNCTION public.#{fun}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO onboarding_registry (id, tenant_id, slug, hostname, inserted_at)
        VALUES (gen_random_uuid(), '#{holder_id}'::uuid, 't3233-holder-#{fun}', '#{host}', now());
        RETURN NEW;
      END $$
      """)

      Repo.query!("""
      CREATE TRIGGER #{fun} AFTER INSERT ON public.tenant_schemas
      FOR EACH ROW WHEN (NEW.tenant_id = '#{tenant_id}'::uuid) EXECUTE FUNCTION public.#{fun}()
      """)

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
        Repo.query!("DROP TRIGGER IF EXISTS #{fun} ON public.tenant_schemas")
        Repo.query!("DROP FUNCTION IF EXISTS public.#{fun}()")
        Repo.query!("DELETE FROM onboarding_registry WHERE tenant_id = $1", [holder])
      end)
    end

    test "C8 a host conflict of a NEW create leaves no half-made tenant; a replay never purges",
         ctx do
      host = "h#{System.unique_integer([:positive])}.qa.example"
      first = body("h#{System.unique_integer([:positive])}.qa.example")
      drop_on_exit(first["tenant_id"])
      assert post(first).status == 201

      second = body(host)
      drop_on_exit(second["tenant_id"])
      steal_host_on_provision!(second["tenant_id"], host, ctx.platform.tenant_id)
      assert post(second).status == 409

      {:ok, schema} = TenantProvisioning.schema_name_for_tenant(second["tenant_id"])
      refute schema_exists?(schema)
      assert registry_rows(second["tenant_id"]) == 0
      assert %Lifecycle{lifecycle: "deleted"} = Repo.get(Lifecycle, second["tenant_id"])
      assert Repo.get!(Tenant, second["tenant_id"]).status == :inactive

      # The replay of the FIRST (complete) tenant is `:existing`: it is answered and never purged.
      assert post(first).status == 200
      {:ok, first_schema} = TenantProvisioning.schema_name_for_tenant(first["tenant_id"])
      assert schema_exists?(first_schema)
      assert %Lifecycle{lifecycle: "active"} = Repo.get(Lifecycle, first["tenant_id"])
    end
  end
end
