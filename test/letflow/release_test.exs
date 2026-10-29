defmodule Letflow.ReleaseTest do
  @moduledoc """
  GH #2567 -- `Letflow.Release` backfill wrappers: created = N on a fresh tenant set, a re-run
  reports already present = N and created = 0, one failing tenant gives failed = 1 and an
  `{:error, _}` result (`halt: false` keeps the VM alive; production halts non-zero), and no
  secret, email or tenant id appears in the output (INV-4).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO
  import Ecto.Query

  alias Letflow.Identity.User
  alias Letflow.Secrets.Secret
  alias Letflow.TenantFixture
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @opts [start: false, halt: false]

  defp run(fun) do
    parent = self()
    out = capture_io(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, out}
  end

  describe "backfill_script_hmac_secrets/1" do
    setup do
      tenants = for _ <- 1..3, do: TenantFixture.provisioned_tenant!(slug_prefix: "gh2567-hmac")
      ids = Enum.map(tenants, & &1.tenant_id)
      on_exit(fn -> Repo.delete_all(from(s in Secret, where: s.tenant_id in ^ids)) end)
      %{ids: ids, registrations: Enum.map(ids, &%{tenant_id: &1})}
    end

    test "T-2567-hmac-fresh-and-rerun", %{registrations: regs, ids: ids} do
      opts = [registrations: regs] ++ @opts

      {result, out} = run(fn -> Letflow.Release.backfill_script_hmac_secrets(opts) end)
      assert result == {:ok, %{processed: 3, created: 3, already_present: 0, failed: 0}}
      assert out =~ "3 tenant(s) processed, 3 created, 0 already present, 0 failed"

      {result, out} = run(fn -> Letflow.Release.backfill_script_hmac_secrets(opts) end)
      assert result == {:ok, %{processed: 3, created: 0, already_present: 3, failed: 0}}
      assert out =~ "0 created, 3 already present"
      refute Enum.any?(ids, &(out =~ &1))
    end

    test "T-2567-hmac-failing-tenant", %{registrations: regs} do
      bogus = %{tenant_id: Ecto.UUID.generate()}
      opts = [registrations: regs ++ [bogus]] ++ @opts

      {result, out} = run(fn -> Letflow.Release.backfill_script_hmac_secrets(opts) end)
      assert {:error, %{processed: 4, created: 3, failed: 1}} = result
      assert out =~ "1 failed"
      refute out =~ bogus.tenant_id
    end
  end

  describe "backfill_login_directory/1" do
    defp insert_user!(tenant, email) do
      %User{}
      |> Ecto.Changeset.change(%{
        username: "rel-#{System.unique_integer([:positive])}",
        display_name: "Release Person",
        email: email,
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)
    end

    test "T-2567-login-fresh-rerun-and-failure" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      broken = Fx.tenant!()
      insert_user!(a, "rel-a@example.test")
      insert_user!(b, "rel-b@example.test")
      insert_user!(broken, "rel-broken@example.test")
      Repo.query!(~s(DROP TABLE "#{broken.schema_name}".users CASCADE))

      {{status, first}, out} = run(fn -> Letflow.Release.backfill_login_directory(@opts) end)
      assert status == :error
      assert first.failed == 1
      assert first.created >= 2
      assert out =~ "1 failed"
      refute out =~ "example.test"
      refute out =~ broken.tenant_id

      {{status, second}, _out} = run(fn -> Letflow.Release.backfill_login_directory(@opts) end)
      assert status == :error
      assert second.created == 0
      assert second.already_present >= first.created
      assert second.failed == 1
    end

    test "T-2567-login-rerun-clean" do
      a = Fx.tenant!()
      insert_user!(a, "rel-clean@example.test")
      {{:ok, first}, _} = run(fn -> Letflow.Release.backfill_login_directory(@opts) end)
      assert first.failed == 0
      {{:ok, rerun}, out} = run(fn -> Letflow.Release.backfill_login_directory(@opts) end)
      assert rerun.created == 0
      assert rerun.already_present >= 1
      refute out =~ "rel-clean"
    end
  end

  describe "platform role groups (T-0934)" do
    alias Letflow.Identity.RoleBackfill
    alias Letflow.Identity.RoleRegistry
    alias Letflow.Identity.TenantRole

    alias Letflow.Identity.Tenant
    alias Letflow.TenantOnboarding
    alias Letflow.TenantProvisioning
    alias Letflow.TenantProvisioning.Registration

    # The real onboarding path (`POST /onboarding` creates the row `migrating`); the pooled
    # fixture clones the template and does not seed roles, so it cannot prove this.
    setup do
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      on_exit(fn -> Letflow.Test.SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)

      tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{
            slug: Letflow.TenantSlugFixture.unique_slug("t0934-roles"),
            display_name: "T-0934 role groups",
            status: "migrating"
          },
          :disabled
        )
        |> Repo.insert!()

      assert {:ok, %Registration{schema_name: schema}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      on_exit(fn ->
        Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)

      %{schema: schema, regs: [%{tenant_id: tenant.id, schema_name: schema}]}
    end

    test "T0934-1 a freshly provisioned tenant holds every seedable role", %{
      schema: schema,
      regs: regs
    } do
      held =
        from(t in TenantRole, where: t.kind == :platform_role, select: t.name)
        |> Repo.all(prefix: schema)

      assert Enum.sort(held) == Enum.sort(RoleRegistry.seedable_role_names(schema))
      assert "TENANT_ADMIN" in held and "TENANT_AUDITOR" in held
      assert {:ok, []} = RoleBackfill.missing_role_groups(registrations: regs)

      {result, out} =
        run(fn -> Letflow.Release.check_platform_role_groups([registrations: regs] ++ @opts) end)

      assert result == {:ok, %{tenants: 1, with_missing_role_groups: 0}}
      refute out =~ "MISSING_ROLE_GROUPS"
    end

    test "T0934-2 a missing TENANT_AUDITOR is reported, then healed by the backfill", %{
      schema: schema,
      regs: regs
    } do
      Repo.delete_all(from(t in TenantRole, where: t.name == "TENANT_AUDITOR"), prefix: schema)

      assert {:ok, [%{schema_name: ^schema, missing: ["TENANT_AUDITOR"]}]} =
               RoleBackfill.missing_role_groups(registrations: regs)

      {result, out} =
        run(fn -> Letflow.Release.check_platform_role_groups([registrations: regs] ++ @opts) end)

      assert {:error, %{with_missing_role_groups: 1}} = result
      assert out =~ "MISSING_ROLE_GROUPS schema=#{schema} roles=TENANT_AUDITOR"

      {result, out} = run(fn -> Letflow.Release.backfill_platform_roles(@opts) end)
      assert {:ok, %{failed: 0, created: created}} = result
      assert created >= 1
      assert out =~ "platform role backfill:"

      assert {:ok, []} = RoleBackfill.missing_role_groups(registrations: regs)
    end
  end
end
