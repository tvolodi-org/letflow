defmodule Letflow.TenantProvisioner.DefaultModulesTest do
  @moduledoc """
  T-1580 / decision 0072 D8: default modules installed as part of a provisioner create. Test ids D1..D10
  and C1..C4 follow the design. `async: false`: provisioning flips the sandbox to `:auto` and the
  platform pin and credential hashes are VM-global (same shape as `admin_v1_test`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Installs
  alias Letflow.Plugs.ProvisionerAuth.RateLimiter
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.DefaultModules
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @token "write-credential-for-tests-0123456789abcdef0123456789abcdef"
  @var "LETFLOW_PROVISIONER_DEFAULT_MODULES"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t1580-plat")
    Fixture.pin!(platform.tenant_id)

    previous = %{
      auth: Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth),
      prov: Application.get_env(:letflow, Letflow.TenantProvisioner),
      url: Application.get_env(:letflow, :provisioner_public_base_url)
    }

    Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth, write_sha256: hash(@token))
    Application.put_env(:letflow, :provisioner_public_base_url, "https://letflow.qa.example")
    put_prov([])
    RateLimiter.reset()

    on_exit(fn ->
      restore(Letflow.Plugs.ProvisionerAuth, previous.auth)
      restore(Letflow.TenantProvisioner, previous.prov)
      restore(:provisioner_public_base_url, previous.url)
      RateLimiter.reset()
    end)

    :ok
  end

  defp put_prov(extra) do
    Application.put_env(
      :letflow,
      Letflow.TenantProvisioner,
      Keyword.merge([allowed_hostname_suffixes: ["qa.example"], demo_lifetime_days: 14], extra)
    )
  end

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)
  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp body do
    id = Ecto.UUID.generate()
    short = String.slice(String.replace(id, "-", ""), 0, 12)

    %{
      "tenant_id" => id,
      "name" => "T-1580 Demo",
      "language" => "en",
      "tier" => "demo",
      "owner_email" => "owner-#{System.unique_integer([:positive])}@example.com",
      "hostname" => "h#{short}.qa.example",
      "idp_realm_id" => "t-" <> String.slice(String.replace(id, "-", ""), 0, 20)
    }
  end

  defp post(payload) do
    conn(:post, "/admin/v1/tenants", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> @token)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp create!(extra_prov) do
    put_prov(extra_prov)
    payload = body()
    on_exit(fn -> drop_tenant!(payload["tenant_id"]) end)
    conn = post(payload)
    assert conn.status == 201, conn.resp_body
    payload
  end

  defp drop_tenant!(tenant_id) do
    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      _ -> :ok
    end

    # Module installs add global rows that reference the tenant (solution_pack_*, column promotions):
    # delete from every public table with a tenant_id foreign key before the lifecycle and tenant rows.
    %{rows: tables} =
      Repo.query!("""
      SELECT DISTINCT c.conrelid::regclass::text, a.attname FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
      WHERE c.contype = 'f' AND c.confrelid = 'public.tenants'::regclass
        AND c.conrelid::regclass::text NOT IN ('tenant_lifecycles', 'onboarding_registry', 'tenant_schemas')
      """)

    for [table, column] <- tables do
      Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [Ecto.UUID.dump!(tenant_id)])
    end

    Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^tenant_id))
    Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp installed(tenant_id) do
    {:ok, prefix} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    Installs.list_installed(prefix: prefix) |> Enum.map(& &1.module_id)
  end

  defp lifecycle(tenant_id), do: Repo.get!(Lifecycle, tenant_id)

  describe "install in the create call" do
    test "D1 default setting installs the closure, state done" do
      payload = create!(default_modules: Config.default_modules())
      ids = installed(payload["tenant_id"])
      assert Enum.sort(ids) == ["catalog_items", "codes", "locations", "org", "stock"]

      assert %Lifecycle{default_modules_state: "done", default_modules_failure: nil} =
               lifecycle(payload["tenant_id"])

      # installed_at order is a valid dependency order
      assert Enum.find_index(ids, &(&1 == "org")) < Enum.find_index(ids, &(&1 == "locations"))
      assert Enum.find_index(ids, &(&1 == "codes")) < Enum.find_index(ids, &(&1 == "stock"))
    end

    test "D2 the setting drives the list; assets is optional" do
      payload = create!(default_modules: ["assets"])

      assert Enum.sort(installed(payload["tenant_id"])) ==
               ["assets", "catalog_items", "codes", "locations", "org", "stock"]
    end

    test "D3 plan puts every module after its dependencies" do
      for ids <- [
            ["stock", "org", "locations", "catalog_items"],
            ["assets"],
            ["org", "stock", "assets", "locations"]
          ] do
        order = DefaultModules.plan(Enum.shuffle(ids))

        for id <- order do
          {:ok, entry} = Letflow.Modules.Catalog.fetch(id)
          pos = Enum.find_index(order, &(&1 == id))

          for dep <- entry.manifest().depends_on do
            assert Enum.find_index(order, &(&1 == dep)) < pos
          end
        end
      end
    end

    test "D4 a replay is idempotent; a failed state retries without double install" do
      payload = create!(default_modules: ["org", "locations"])
      id = payload["tenant_id"]
      before = installed(id)
      assert post(payload).status == 200
      assert installed(id) == before

      lifecycle(id) |> Ecto.Changeset.change(default_modules_state: "failed") |> Repo.update!()
      assert post(payload).status == 200
      assert installed(id) == before
      assert lifecycle(id).default_modules_state == "done"
    end
  end

  describe "failure handling" do
    test "D5 a failing install does not fail the create; replay recovers" do
      put_prov(
        default_modules: ["org"],
        default_modules_install: fn _, _, _ -> {:error, :boom} end
      )

      payload = body()
      on_exit(fn -> drop_tenant!(payload["tenant_id"]) end)

      log = capture_log([level: :error], fn -> assert post(payload).status == 201 end)
      id = payload["tenant_id"]
      assert log =~ "default module install failed"

      assert %Lifecycle{default_modules_state: "failed", default_modules_failure: "org:boom"} =
               lifecycle(id)

      assert installed(id) == []
      {:ok, prefix} = TenantProvisioning.schema_name_for_tenant(id)
      assert Repo.aggregate(PendingAdminGrant, :count, prefix: prefix) == 1

      put_prov(default_modules: ["org"])
      assert post(payload).status == 200
      assert installed(id) == ["org"]
      assert lifecycle(id).default_modules_state == "done"
    end

    test "D5b one module failing skips its dependents, keeps independent ones" do
      fail_catalog = fn
        "catalog_items", _, _ -> {:error, :module_install_ddl_failed}
        m, a, o -> Installs.install(m, a, o)
      end

      payload = create!(default_modules: ["stock"], default_modules_install: fail_catalog)
      id = payload["tenant_id"]
      assert Enum.sort(installed(id)) == ["codes", "locations", "org"]

      assert %Lifecycle{
               default_modules_state: "failed",
               default_modules_failure: "catalog_items:module_install_ddl_failed"
             } = lifecycle(id)
    end

    test "D5c a raising installer and an unknown id are recorded as codes" do
      assert {:error, "org:exception"} =
               DefaultModules.ensure(Ecto.UUID.generate(), ["org"],
                 install: fn _, _, _ -> raise "x" end
               )

      payload = create!(default_modules: ["no_such_module"])

      assert lifecycle(payload["tenant_id"]).default_modules_failure ==
               "no_such_module:unknown_module"
    end

    test "D9 the log and the record hold only ids and codes" do
      sql = fn _, _, _ -> raise "SELECT secret FROM x" end
      put_prov(default_modules: ["org"], default_modules_install: sql)
      payload = body()
      on_exit(fn -> drop_tenant!(payload["tenant_id"]) end)
      log = capture_log([level: :error], fn -> assert post(payload).status == 201 end)
      refute log =~ "SELECT"
      refute log =~ "Changeset"
      assert log =~ "module_id=org"
      assert lifecycle(payload["tenant_id"]).default_modules_failure == "org:exception"
    end
  end

  describe "fixed actor and isolation" do
    test "D6 the module reaches no grant, role or secret API" do
      src = File.read!("lib/letflow/tenant_provisioner/default_modules.ex")

      code =
        src
        |> String.split("@moduledoc", parts: 2)
        |> List.last()
        |> String.split("\"\"\"", parts: 3)
        |> List.last()

      for forbidden <- ~w(PendingAdminGrants Authorization Roles Secrets auth_context Credential) do
        refute code =~ forbidden, "default_modules.ex must not reference #{forbidden}"
      end

      assert code =~ "schema_name_for_tenant"
    end

    test "D7 the install writes no extra grant" do
      payload = create!(default_modules: ["org", "locations"])
      id = payload["tenant_id"]
      {:ok, prefix} = TenantProvisioning.schema_name_for_tenant(id)
      assert Repo.aggregate(PendingAdminGrant, :count, prefix: prefix) == 1
    end

    test "D8 two tenants with different lists do not see each other's modules" do
      a = create!(default_modules: ["org"])
      b = create!(default_modules: ["codes"])
      assert installed(a["tenant_id"]) == ["org"]
      assert installed(b["tenant_id"]) == ["codes"]
    end

    test "D10 a legacy row is not_applicable and a replay installs nothing" do
      payload = create!(default_modules: [])
      id = payload["tenant_id"]

      lifecycle(id)
      |> Ecto.Changeset.change(default_modules_state: "not_applicable")
      |> Repo.update!()

      put_prov(default_modules: ["org"])
      assert post(payload).status == 200
      assert installed(id) == []
      assert lifecycle(id).default_modules_state == "not_applicable"
    end
  end

  describe "setting parser" do
    defp parse(value), do: Config.parse(%{@var => value}, :test)

    test "C1 unset gives the default list" do
      assert {:ok, %{provisioner: prov}} = parse(nil)
      refute Keyword.has_key?(prov, :default_modules)
      assert Config.default_modules() == ["org", "locations", "catalog_items", "stock"]
    end

    test "C2 a list is trimmed and de-duplicated" do
      assert {:ok, %{provisioner: prov}} = parse(" org, locations ,org")
      assert prov[:default_modules] == ["org", "locations"]
    end

    test "C3 none means empty" do
      assert {:ok, %{provisioner: prov}} = parse("none")
      assert prov[:default_modules] == []
    end

    test "C4 bad ids and too many ids name the variable only" do
      assert {:error, @var} = parse("Org;DROP")
      assert {:error, @var} = parse(Enum.map_join(1..21, ",", &"m#{&1}"))
    end
  end
end
