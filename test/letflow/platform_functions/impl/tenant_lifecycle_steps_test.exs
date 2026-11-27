defmodule Letflow.PlatformFunctions.Impl.TenantLifecycleStepsTest do
  @moduledoc """
  The bodies of `tenant.suspend`, `tenant.reactivate` and `tenant.purge` (T-2972, BP-PLATFORM-02 G1)
  and the definition `platform.tenant_lifecycle` (G2).

  `async: false`: provisioning flips the sandbox to `:auto` and the platform-tenant pin and the
  retention setting are VM-global (same as `tenant_purge_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Impl.TenantPurge
  alias Letflow.PlatformFunctions.Impl.TenantReactivate
  alias Letflow.PlatformFunctions.Impl.TenantSuspend
  alias Letflow.PlatformFunctions.{Catalog, Registry}
  alias Letflow.PlatformProcesses.TenantLifecycleDefinition
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner.Lifecycle

  @day 86_400

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2972-plat")
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

  defp tenant!(opts \\ []) do
    f = TenantFixture.provisioned_tenant!(slug_prefix: "t2972")
    id = f.tenant_id
    days = Keyword.get(opts, :suspended_days_ago, 31)
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -days * @day, :second)

    Repo.update_all(from(t in Tenant, where: t.id == ^id),
      set: [
        status: Keyword.get(opts, :status, :inactive),
        tenant_type: Keyword.get(opts, :type, "test"),
        updated_at: old
      ]
    )

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
    end)

    f
  end

  defp slug(f), do: f.tenant.slug
  defp status(f), do: Repo.get!(Tenant, f.tenant_id).status

  describe "G1 catalogue and registry" do
    test "L1 the three entries are declared, platform-only, and have a body" do
      for name <- ["tenant.suspend", "tenant.reactivate", "tenant.purge"] do
        assert {:ok, entry} = Catalog.fetch(name)
        assert entry.platform_tenant_only
        assert entry.permission == :TenantsManage
        assert entry.idempotency_key == ["slug", "request_id"]
        assert {:ok, {_mod, :run, 1}} = Registry.fetch(name)
      end

      {:ok, purge} = Catalog.fetch("tenant.purge")
      assert Enum.map(purge.inputs, & &1.name) == ["slug", "confirm", "request_id"]
    end
  end

  describe "tenant.suspend and tenant.reactivate" do
    test "L2 suspend deactivates, a repeat is the same suspend, reactivate undoes it" do
      f = tenant!(status: :active)

      assert {:ok, %{}} = TenantSuspend.run(%{inputs: %{"slug" => slug(f)}})
      assert status(f) == :inactive
      assert {:ok, %{}} = TenantSuspend.run(%{inputs: %{"slug" => slug(f)}})
      assert status(f) == :inactive

      assert {:ok, %{}} = TenantReactivate.run(%{inputs: %{"slug" => slug(f)}})
      assert status(f) == :active
      assert {:ok, %{}} = TenantReactivate.run(%{inputs: %{"slug" => slug(f)}})
    end

    test "L3 unknown slug, bad input and the platform tenant are refused", %{platform: platform} do
      assert {:error, :platform_call_tenant_not_found} =
               TenantSuspend.run(%{inputs: %{"slug" => "t2972-nope"}})

      assert {:error, :platform_call_tenant_not_found} =
               TenantReactivate.run(%{inputs: %{"slug" => "t2972-nope"}})

      assert {:error, :platform_call_arg_invalid} = TenantSuspend.run(%{inputs: %{"slug" => 7}})
      assert {:error, :platform_call_arg_invalid} = TenantReactivate.run(%{})

      assert {:error, :platform_call_tenant_not_allowed} =
               TenantSuspend.run(%{inputs: %{"slug" => platform.tenant.slug}})

      assert status(platform) == :active
    end
  end

  describe "tenant.purge destructive guard" do
    test "L4 no confirmation, a wrong one or a non-string: refused, nothing dropped" do
      f = tenant!()

      for confirm <- [nil, "", "other", 5] do
        assert {:error, :platform_call_purge_unconfirmed} =
                 TenantPurge.run(%{inputs: %{"slug" => slug(f), "confirm" => confirm}})
      end

      assert {:error, :platform_call_purge_unconfirmed} =
               TenantPurge.run(%{inputs: %{"slug" => slug(f)}})

      assert Repo.get(Lifecycle, f.tenant_id) == nil
    end

    test "L5 an active tenant is refused (must be suspended first)" do
      f = tenant!(status: :active)

      assert {:error, :platform_call_purge_not_suspended} =
               TenantPurge.run(%{inputs: %{"slug" => slug(f), "confirm" => slug(f)}})
    end

    test "L6 a production tenant is refused even when suspended and confirmed" do
      f = tenant!(type: "production")

      assert {:error, :platform_call_purge_production_refused} =
               TenantPurge.run(%{inputs: %{"slug" => slug(f), "confirm" => slug(f)}})

      assert status(f) == :inactive
    end

    test "L7 inside the retention the purge is not eligible, unknown and platform are the one answer",
         %{platform: platform} do
      young = tenant!(suspended_days_ago: 1)

      assert {:error, :platform_call_purge_not_eligible} =
               TenantPurge.run(%{inputs: %{"slug" => slug(young), "confirm" => slug(young)}})

      assert {:error, :platform_call_tenant_not_found} =
               TenantPurge.run(%{inputs: %{"slug" => "t2972-nope", "confirm" => "t2972-nope"}})

      pslug = platform.tenant.slug

      assert {:error, :platform_call_tenant_not_found} =
               TenantPurge.run(%{inputs: %{"slug" => pslug, "confirm" => pslug}})
    end

    test "L8 a suspended, confirmed, past-retention test tenant is purged; a repeat is ok; no reactivation" do
      f = tenant!()
      input = %{inputs: %{"slug" => slug(f), "confirm" => slug(f)}}

      assert {:ok, %{}} = TenantPurge.run(input)

      assert %Lifecycle{lifecycle: "deleted", purged_at: %DateTime{}} =
               Repo.get!(Lifecycle, f.tenant_id)

      assert {:ok, %{}} = TenantPurge.run(input)

      assert {:error, :platform_call_tenant_purged} =
               TenantReactivate.run(%{inputs: %{"slug" => slug(f)}})

      assert Identity.tenant_purged?(f.tenant_id)
    end
  end

  describe "G2 the definition" do
    test "L9 the graph has one gate, one node per action, and only purge reads `confirm`" do
      graph = TenantLifecycleDefinition.graph()
      nodes = Map.new(graph["nodes"], &{&1["id"], &1})

      assert Map.keys(nodes) |> Enum.sort() ==
               ~w(action_gate end purge reactivate start suspend)

      call = fn id -> get_in(nodes, [id, "attributes", "platform_call"]) end
      assert call.("suspend")["function"] == "tenant.suspend"
      assert call.("reactivate")["function"] == "tenant.reactivate"
      assert call.("purge")["function"] == "tenant.purge"

      assert call.("purge")["reads"] ==
               %{"slug" => "string", "confirm" => "string", "request_id" => "string"}

      assert call.("suspend")["reads"] == %{"slug" => "string", "request_id" => "string"}

      conditions =
        graph["edges"]
        |> Enum.filter(&(&1["source"] == "action_gate"))
        |> Enum.map(& &1["condition"])

      assert ~s(variables.action == "purge") in conditions
      # the default edge never reaches a destructive node
      assert Enum.any?(graph["edges"], &(&1["is_default"] && &1["target"] == "end"))

      action =
        Enum.find(TenantLifecycleDefinition.variable_schemas(), &(&1.variable_key == "action"))

      assert action.json_schema["enum"] == ["suspend", "reactivate", "purge"]
      assert TenantLifecycleDefinition.start_permission() == "TenantsManage"
    end
  end
end
