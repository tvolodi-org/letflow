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
  alias Letflow.Support.ScriptTaskFixture, as: F

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

  test "only Letflow.Scripts.HmacSecret and Letflow.Definitions.ActivatedBy pass platform: true (source scan)" do
    sources = Path.wildcard("lib/**/*.ex")
    # guard against a vacuous scan (wrong working directory)
    assert "lib/letflow/scripts/hmac_secret.ex" in sources
    assert "lib/letflow/definitions/activated_by.ex" in sources
    assert File.read!("lib/letflow/scripts/hmac_secret.ex") =~ ~r/platform:\s*true/
    assert File.read!("lib/letflow/definitions/activated_by.ex") =~ ~r/platform:\s*true/

    # T-0250 (GH #2644): the activated_by signing key is the second reserved-namespace caller.
    allowed = [
      "lib/letflow/scripts/hmac_secret.ex",
      "lib/letflow/definitions/activated_by.ex"
    ]

    offenders =
      sources
      |> Enum.reject(&(&1 in allowed))
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

  # ── GH 2534 PR 7c-1 AC13 (design gh2534-7c-script-handler.md 7.2, 7.3, C15) ─────────────

  defp secret_rows(tenant_id) do
    Repo.all(
      from(s in Secret,
        where: s.tenant_id == ^tenant_id and s.namespace == "platform",
        order_by: s.key_id
      )
    )
    |> Enum.map(&Map.take(&1, [:id, :key_id, :status, :ciphertext]))
  end

  defp disable_all!(tenant_id) do
    from(s in Secret,
      where:
        s.tenant_id == ^tenant_id and s.namespace == "platform" and
          s.name == "script-input-hmac"
    )
    |> Repo.update_all(set: [status: :disabled])
  end

  defp start_bound(fixture) do
    F.bound!(fixture, F.doubling_source(), F.closed_manifest(), %{"amount" => 1})
  end

  defp alert_lines(log),
    do: log |> String.split("script HMAC secret missing") |> length() |> Kernel.-(1)

  describe "7c-1 AC13: the run path resolves the key, never creates one" do
    test "T-secret-present-none-created", %{fixture: f} do
      :ok = HmacSecret.ensure(%{id: f.tenant_id})
      before = secret_rows(f.tenant_id)
      assert [_one] = before

      b = start_bound(f)
      {_row, {:ok, :applied}} = F.run_next!(f.schema_name)
      assert F.projection(f.schema_name, b.instance_id).variables["total"] == 2
      assert secret_rows(f.tenant_id) == before
    end

    test "T-secret-missing-one-alert", %{fixture: f} do
      :ok = HmacSecret.ensure(%{id: f.tenant_id})
      {1, _} = disable_all!(f.tenant_id)
      before = secret_rows(f.tenant_id)
      first = start_bound(f)
      second = start_bound(f)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          {_r1, {:ok, :failed}} = F.run_next!(f.schema_name)
          {_r2, {:ok, :failed}} = F.run_next!(f.schema_name)
        end)

      for b <- [first, second] do
        row = F.row!(f.schema_name, b.instance_id)
        assert {row.outcome, row.outcome_detail} == {"script_rejected", "hmac_secret_missing"}
      end

      assert alert_lines(log) == 1
      assert secret_rows(f.tenant_id) == before
      refute HmacSecret.exists?(f.tenant_id)
    end

    test "rearm after restore", %{fixture: f} do
      :ok = HmacSecret.ensure(%{id: f.tenant_id})
      {1, _} = disable_all!(f.tenant_id)
      start_bound(f)

      log1 =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          {_r, {:ok, :failed}} = F.run_next!(f.schema_name)
        end)

      assert alert_lines(log1) == 1

      {1, _} =
        from(s in Secret, where: s.tenant_id == ^f.tenant_id and s.namespace == "platform")
        |> Repo.update_all(set: [status: :active])

      ok = start_bound(f)
      {_r, {:ok, :applied}} = F.run_next!(f.schema_name)
      assert F.projection(f.schema_name, ok.instance_id).variables["total"] == 2

      state =
        Repo.get(Letflow.Obs.AlertTriggerState, "script_hmac_secret_missing",
          prefix: f.schema_name
        )

      assert state.is_armed

      # re-armed: the next missing-key run alerts again, once
      {1, _} = disable_all!(f.tenant_id)
      start_bound(f)

      log2 =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          {_r, {:ok, :failed}} = F.run_next!(f.schema_name)
        end)

      assert alert_lines(log2) == 1
    end

    test "two key versions: every version disabled fails closed; re-activating one runs under it",
         %{fixture: f} do
      # v1, then (v1 disabled) a rotated v2 -- ensure/1 creates only when no ACTIVE key exists
      :ok = HmacSecret.ensure(%{id: f.tenant_id})
      {1, _} = disable_all!(f.tenant_id)
      :ok = HmacSecret.ensure(%{id: f.tenant_id})

      assert [%{key_id: 1, status: :disabled}, %{key_id: 2, status: :active}] =
               secret_rows(f.tenant_id)

      {2, _} = disable_all!(f.tenant_id)
      before = secret_rows(f.tenant_id)
      missing = start_bound(f)

      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        {_r, {:ok, :failed}} = F.run_next!(f.schema_name)
      end)

      row = F.row!(f.schema_name, missing.instance_id)
      assert row.outcome_detail == "hmac_secret_missing"
      assert secret_rows(f.tenant_id) == before

      {1, _} =
        from(s in Secret,
          where: s.tenant_id == ^f.tenant_id and s.namespace == "platform" and s.key_id == 1
        )
        |> Repo.update_all(set: [status: :active])

      ok = start_bound(f)
      {_r, {:ok, :applied}} = F.run_next!(f.schema_name)
      [record] = F.payloads(f.schema_name, ok.instance_id, "SCRIPT_RUN_RECORDED")
      assert record["input_hmac_key_version"] == 1
      assert length(secret_rows(f.tenant_id)) == 2
    end
  end
end
