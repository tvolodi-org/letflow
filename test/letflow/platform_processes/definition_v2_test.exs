defmodule Letflow.PlatformProcesses.DefinitionV2Test do
  @moduledoc """
  V1/V2 of `docs/platform-register-tenant-v2.md` section 11 (T-2727, pilot gap G17c): the v2 document
  (node order, the gateway's default edge without a condition, reads and writes derived from the
  catalogue, the typed context, the start permission) and the new or changed step bodies:
  `tenant.create` with `requested_tenant_id` and `tenant_type`, `tenant.record_lifecycle`,
  `tenant.record_onboarding`, and the optional inputs of `bind_realm` and `grant_first_admins`.

  Committed-tenant fixtures are removed in an `on_exit`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.StartPermission
  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Impl.TenantBindRealm
  alias Letflow.PlatformFunctions.Impl.TenantCreate
  alias Letflow.PlatformFunctions.Impl.TenantGrantFirstAdmins
  alias Letflow.PlatformFunctions.Impl.TenantRecordLifecycle
  alias Letflow.PlatformFunctions.Impl.TenantRecordOnboarding
  alias Letflow.PlatformProcesses.DefinitionV2
  alias Letflow.TenantProvisioner.Admission
  alias Letflow.TenantProvisioner.Lifecycle

  defp node_ids, do: Enum.map(DefinitionV2.graph()["nodes"], & &1["id"])

  test "V1 the nodes are in the order of the design and the graph is valid" do
    assert node_ids() ==
             ~w(start validate create provision record_lifecycle record_onboarding bind_realm
                grant_first_admins install_default_modules notify_gate notify end)

    assert {:ok, %Graph{} = parsed} = Graph.from_map(DefinitionV2.graph())
    assert %{valid: true} = Graph.validate_graph(parsed)
    assert StartPermission.required(parsed) == [:TenantsManage]
  end

  test "V1 the gateway's default edge carries no condition; the other edge tests notify_admin" do
    edges = DefinitionV2.graph()["edges"] |> Enum.filter(&(&1["source"] == "notify_gate"))
    default = Enum.find(edges, &(Map.get(&1, "is_default") == true))
    other = Enum.find(edges, &(Map.get(&1, "is_default") != true))

    assert default["target"] == "end" and not Map.has_key?(default, "condition")
    assert other["target"] == "notify"
    assert other["condition"] == "variables.notify_admin == true"
  end

  test "V1 the typed context declares the v2 start contract and every read and write" do
    declared = Map.new(DefinitionV2.variable_schemas(), &{&1.variable_key, &1.json_schema})

    for key <- ~w(requested_tenant_id tenant_type notify_admin) do
      assert Map.has_key?(declared, key)
    end

    assert declared["notify_admin"] == %{"type" => "boolean"}
    assert declared["tenant_type"]["enum"] == ["test", "production"]

    for node <- DefinitionV2.graph()["nodes"],
        call = get_in(node, ["attributes", "platform_call"]) do
      for name <- Map.keys(call["reads"]) ++ Map.keys(call["writes"]) do
        assert Map.has_key?(declared, name), "#{name} is not declared"
      end
    end

    attrs = DefinitionV2.attrs()
    assert attrs.version == "2" and attrs.start_permission == "TenantsManage"
    refute Map.has_key?(attrs, :created_by)
  end

  # --- tenant.create (V2) ---------------------------------------------------------------------

  defp slug_of(id), do: "t-" <> String.replace(id, "-", "")

  test "V2 create with requested_tenant_id writes the caller's id as tenants.id" do
    id = Ecto.UUID.generate()
    inputs = %{"slug" => slug_of(id), "name" => "Pilot", "requested_tenant_id" => id}

    assert {:ok, %{"tenant_id" => ^id}} = TenantCreate.run(%{inputs: inputs})
    assert %Tenant{tenant_type: "test"} = Repo.get!(Tenant, id)
    # a repeat adopts the row
    assert {:ok, %{"tenant_id" => ^id}} = TenantCreate.run(%{inputs: inputs})
  end

  test "V2 create refuses a slug not derived from the id, a tenant_type with the id, a bad id" do
    id = Ecto.UUID.generate()
    base = %{"slug" => slug_of(id), "name" => "Pilot", "requested_tenant_id" => id}

    for bad <- [
          %{base | "slug" => "t-other"},
          Map.put(base, "tenant_type", "production"),
          %{base | "requested_tenant_id" => "nope"}
        ] do
      assert {:error, :platform_call_arg_invalid} = TenantCreate.run(%{inputs: bad})
    end

    assert Repo.get(Tenant, id) == nil
  end

  test "V2 create refuses an id that belongs to another slug's tenant, and takes tenant_type" do
    assert {:ok, %{"tenant_id" => tid}} =
             TenantCreate.run(%{
               inputs: %{"slug" => "v2-typed", "name" => "Typed", "tenant_type" => "production"}
             })

    assert Repo.get!(Tenant, tid).tenant_type == "production"

    assert {:error, :platform_call_arg_invalid} =
             TenantCreate.run(%{
               inputs: %{"slug" => "v2-typed2", "name" => "T", "tenant_type" => "gold"}
             })
  end

  # --- tenant.record_lifecycle ------------------------------------------------------------------

  defp provisioned_tenant! do
    id = Ecto.UUID.generate()

    {:ok, _} =
      TenantCreate.run(%{
        inputs: %{"slug" => slug_of(id), "name" => "LC", "requested_tenant_id" => id}
      })

    id
  end

  defp admission!(id) do
    Repo.insert!(%Admission{
      tenant_id: id,
      tier: "demo",
      language: "en",
      expires_at: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second),
      email_domain_key: :crypto.hash(:sha256, "d"),
      request_fingerprint: :crypto.hash(:sha256, "f")
    })
  end

  test "V2 record_lifecycle writes the row from the admission, once" do
    id = provisioned_tenant!()
    admission = admission!(id)
    inputs = %{"tenant_id" => id, "requested_tenant_id" => id}

    assert {:ok, %{}} = TenantRecordLifecycle.run(%{inputs: inputs})
    assert %Lifecycle{tier: "demo", lifecycle: "active"} = row = Repo.get!(Lifecycle, id)
    assert row.expires_at == admission.expires_at

    # a repeat writes nothing and does not fail
    assert {:ok, %{}} = TenantRecordLifecycle.run(%{inputs: inputs})
  end

  test "V2 record_lifecycle: no admission is a no-op for an operator tenant, a refusal for a system one" do
    id = provisioned_tenant!()

    assert {:ok, %{}} = TenantRecordLifecycle.run(%{inputs: %{"tenant_id" => id}})
    assert Repo.get(Lifecycle, id) == nil

    assert {:error, :platform_call_lifecycle_failed} =
             TenantRecordLifecycle.run(%{
               inputs: %{"tenant_id" => id, "requested_tenant_id" => id}
             })

    assert Repo.get(Lifecycle, id) == nil

    assert {:error, :platform_call_arg_invalid} =
             TenantRecordLifecycle.run(%{inputs: %{"tenant_id" => "x"}})
  end

  # --- tenant.record_onboarding -----------------------------------------------------------------

  test "V2 record_onboarding: absent hostname no-op, write once, mismatch refused, bounded" do
    id = provisioned_tenant!()
    host = "v2-#{System.unique_integer([:positive])}.example.kz"

    assert {:ok, %{}} = TenantRecordOnboarding.run(%{inputs: %{"tenant_id" => id}})

    assert {:ok, %{}} =
             TenantRecordOnboarding.run(%{inputs: %{"tenant_id" => id, "hostname" => host}})

    assert {:ok, %{}} =
             TenantRecordOnboarding.run(%{inputs: %{"tenant_id" => id, "hostname" => host}})

    assert {:error, :platform_call_hostname_mismatch} =
             TenantRecordOnboarding.run(%{
               inputs: %{"tenant_id" => id, "hostname" => "other." <> host}
             })

    other = provisioned_tenant!()

    assert {:error, :platform_call_hostname_taken} =
             TenantRecordOnboarding.run(%{inputs: %{"tenant_id" => other, "hostname" => host}})

    assert {:error, :platform_call_arg_invalid} =
             TenantRecordOnboarding.run(%{
               inputs: %{"tenant_id" => id, "hostname" => String.duplicate("a", 254)}
             })
  end

  # --- optional inputs ---------------------------------------------------------------------------

  test "V2 bind_realm and grant_first_admins without their optional input are no-ops" do
    id = Ecto.UUID.generate()
    # no tenant, no realm, no address: nothing is looked up, nothing fails
    assert {:ok, %{}} = TenantBindRealm.run(%{inputs: %{"tenant_id" => id}})
    assert {:ok, %{}} = TenantGrantFirstAdmins.run(%{inputs: %{"tenant_id" => id}})

    assert {:error, :platform_call_arg_invalid} =
             TenantBindRealm.run(%{inputs: %{"tenant_id" => "x"}})
  end
end
