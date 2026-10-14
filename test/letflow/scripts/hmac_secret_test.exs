defmodule Letflow.Scripts.HmacSecretTest do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D9, advisor Q2), design section 9: the per-tenant script-input
  HMAC key in `Letflow.Secrets` under the reserved `platform` namespace.

    * `put/2`, `resolve/2` and `disable/2` refuse the `platform` namespace without
      `platform: true`; only `Letflow.Scripts.HmacSecret` passes it (source scan);
    * `ensure/1` is idempotent, also under concurrency (one row);
    * only the `:script_runner` consumer can resolve it;
    * provisioning creates it; the mix task backfills a tenant without one.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Secrets
  alias Letflow.Secrets.Secret
  alias Letflow.TenantFixture
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Mix.Tasks.Letflow.BackfillScriptHmacSecrets

  setup do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-hmac")

    on_exit(fn ->
      Repo.delete_all(from(s in Secret, where: s.tenant_id == ^fixture.tenant_id))
    end)

    {:ok, fixture: fixture}
  end

  defp rows(tenant_id) do
    Repo.all(from(s in Secret, where: s.tenant_id == ^tenant_id and s.namespace == "platform"))
  end

  test "the reserved platform namespace is refused without platform: true (put, resolve, disable)",
       %{fixture: f} do
    attrs = %{
      tenant_id: f.tenant_id,
      namespace: "platform",
      name: "script-input-hmac",
      purpose: :generic,
      plaintext: "x",
      created_by: "test"
    }

    assert {:error, :reserved_namespace} = Secrets.put(attrs)
    ref = "sec://tenant/#{f.tenant.slug}/platform/script-input-hmac"
    assert {:error, :reserved_namespace} = Secrets.resolve(ref, tenant_id: f.tenant_id)
    assert {:error, :reserved_namespace} = Secrets.disable(ref <> "#1", tenant_id: f.tenant_id)
    assert rows(f.tenant_id) == []
  end

  test "ensure/1 creates exactly one key, is idempotent, and is safe under concurrency", %{
    fixture: f
  } do
    1..4
    |> Enum.map(fn _ -> Task.async(fn -> HmacSecret.ensure(%{id: f.tenant_id}) end) end)
    |> Enum.each(&assert(Task.await(&1, 15_000) == :ok))

    assert :ok = HmacSecret.ensure(%{id: f.tenant_id})
    assert [%Secret{purpose: :script_hmac, status: :active}] = rows(f.tenant_id)
    assert HmacSecret.exists?(f.tenant_id)
  end

  test "only the :script_runner consumer resolves the key (32 bytes); :generic and :webhook_dispatcher cannot",
       %{fixture: f} do
    :ok = HmacSecret.ensure(%{id: f.tenant_id})
    ref = "sec://tenant/#{f.tenant.slug}/platform/script-input-hmac"

    assert {:ok, %{plaintext: key, purpose: :script_hmac}} =
             Secrets.resolve(ref,
               tenant_id: f.tenant_id,
               consumer: :script_runner,
               platform: true
             )

    assert byte_size(key) == 32

    for consumer <- [:generic, :webhook_dispatcher] do
      assert {:error, :purpose_not_allowed} =
               Secrets.resolve(ref, tenant_id: f.tenant_id, consumer: consumer, platform: true)
    end
  end

  test "only Letflow.Scripts.HmacSecret passes platform: true (source scan)" do
    sources = Path.wildcard("lib/**/*.ex")
    # guard against a vacuous scan (wrong working directory)
    assert "lib/letflow/scripts/hmac_secret.ex" in sources
    assert File.read!("lib/letflow/scripts/hmac_secret.ex") =~ ~r/platform:\s*true/

    offenders =
      sources
      |> Enum.reject(&String.ends_with?(&1, "lib/letflow/scripts/hmac_secret.ex"))
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.any?(&String.match?(&1, ~r/platform:\s*true/))
      end)

    assert offenders == []
  end

  test "the backfill creates the key for a tenant without one and leaves an existing key alone",
       %{fixture: f} do
    refute HmacSecret.exists?(f.tenant_id)
    assert {1, 0, []} = BackfillScriptHmacSecrets.backfill([%{tenant_id: f.tenant_id}])
    assert HmacSecret.exists?(f.tenant_id)
    assert {0, 1, []} = BackfillScriptHmacSecrets.backfill([%{tenant_id: f.tenant_id}])
    assert length(rows(f.tenant_id)) == 1
  end

  test "real provisioning (TenantOnboarding.provision_and_migrate/1) creates the key" do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("gh2534-prov"),
          display_name: "GH 2534 HMAC"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(s in Secret, where: s.tenant_id == ^tenant.id))
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{}} = TenantOnboarding.provision_and_migrate(tenant.id)
    assert [%Secret{purpose: :script_hmac}] = rows(tenant.id)
  end
end
