defmodule Letflow.Definitions.SolutionPackVersionCheckTest do
  @moduledoc """
  REQ-573 part 2 (decision 0069 D1/D7), context level: `SolutionPack.check_target_version/3`
  and its call in `apply_pack_update/6`. Router-level cases are in
  `test/letflow/routers/solution_packs_version_test.exs`.

  Installs are inserted directly (global table, no FK from the base/resolution tables).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @type_name "process_definition"

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp new_tenant!(slug) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug)
    tenant_id = tenant.tenant_id

    on_exit(fn ->
      Repo.delete_all(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
    end)

    tenant
  end

  defp insert_install!(tenant_id, pack_id, version, status \\ :active) do
    install =
      %SolutionPackInstall{}
      |> SolutionPackInstall.insert_changeset(%{
        tenant_id: tenant_id,
        pack_id: pack_id,
        installed_version: version,
        installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
      })
      |> Repo.insert!()

    if status == :active do
      install
    else
      Repo.update_all(from(i in SolutionPackInstall, where: i.id == ^install.id),
        set: [status: status, uninstalled_at: DateTime.truncate(DateTime.utc_now(), :microsecond)]
      )

      Repo.get!(SolutionPackInstall, install.id)
    end
  end

  defp insert_base!(tenant_id, pack_id, artefact_id, content) do
    %SolutionPackArtefactBase{}
    |> SolutionPackArtefactBase.upsert_changeset(%{
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: @type_name,
      artefact_id: artefact_id,
      base_version: "1.0.0",
      base_content: content,
      captured_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.insert!()
  end

  # One clean-update artefact (theirs == base, incoming differs) plus one conflict.
  defp fixture!(tenant_id, pack_id) do
    clean = Ecto.UUID.generate()
    conflict = Ecto.UUID.generate()
    insert_base!(tenant_id, pack_id, clean, "base-clean")
    insert_base!(tenant_id, pack_id, conflict, "base-conflict")

    art = fn id, content ->
      %{artefact_type: @type_name, artefact_id: id, content: content}
    end

    %{
      theirs: [art.(clean, "base-clean"), art.(conflict, "theirs-conflict")],
      incoming: [art.(clean, "incoming-clean"), art.(conflict, "incoming-conflict")],
      resolutions: [
        %{
          artefact_type: @type_name,
          artefact_id: conflict,
          resolution: :keep_local,
          resolved_content: nil
        }
      ]
    }
  end

  defp apply!(tenant, pack_id, target, fx) do
    SolutionPack.apply_pack_update(
      pack_id,
      target,
      fx.theirs,
      fx.incoming,
      fx.resolutions,
      prefix: tenant.schema_name,
      actor_id: Ecto.UUID.generate()
    )
  end

  defp snapshot(tenant_id) do
    {Repo.all(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant_id, order_by: r.id)),
     Repo.all(
       from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id, order_by: b.id)
     ),
     Repo.all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id, order_by: i.id))}
  end

  test "V1: downgrade 1.9.0 against installed 2.0.0 is refused and writes nothing" do
    tenant = new_tenant!("req573-v1")
    pack_id = unique("req573-v1-pack")
    insert_install!(tenant.tenant_id, pack_id, "2.0.0")
    fx = fixture!(tenant.tenant_id, pack_id)
    before = snapshot(tenant.tenant_id)

    assert {:error, :version_downgrade} =
             SolutionPack.check_target_version(tenant.tenant_id, pack_id, "1.9.0")

    assert {:error, :version_downgrade} = apply!(tenant, pack_id, "1.9.0", fx)
    assert snapshot(tenant.tenant_id) == before
  end

  test "V3: equal target 2.0.0 is refused as version_not_newer and writes nothing" do
    tenant = new_tenant!("req573-v3")
    pack_id = unique("req573-v3-pack")
    insert_install!(tenant.tenant_id, pack_id, "2.0.0")
    fx = fixture!(tenant.tenant_id, pack_id)
    before = snapshot(tenant.tenant_id)

    assert {:error, :version_not_newer} =
             SolutionPack.check_target_version(tenant.tenant_id, pack_id, "2.0.0")

    assert {:error, :version_not_newer} = apply!(tenant, pack_id, "2.0.0", fx)
    assert snapshot(tenant.tenant_id) == before
  end

  test "V5: 2.0.1 and 10.0.0 pass against 2.0.0 (numeric comparison)" do
    tenant = new_tenant!("req573-v5")
    pack_id = unique("req573-v5-pack")
    insert_install!(tenant.tenant_id, pack_id, "2.0.0")
    fx = fixture!(tenant.tenant_id, pack_id)

    for target <- ["2.0.1", "10.0.0"] do
      assert :ok = SolutionPack.check_target_version(tenant.tenant_id, pack_id, target)
    end

    assert {:ok, _} = apply!(tenant, pack_id, "2.0.1", fx)
    assert {:ok, _} = apply!(tenant, pack_id, "10.0.0", fx)
  end

  test "V6: non-semver installed or target gives no check and leaves installed_version alone" do
    tenant = new_tenant!("req573-v6")
    legacy = unique("req573-v6-legacy")
    semver = unique("req573-v6-semver")
    insert_install!(tenant.tenant_id, legacy, "legacy-2024")
    insert_install!(tenant.tenant_id, semver, "2.0.0")
    fx_legacy = fixture!(tenant.tenant_id, legacy)
    fx_semver = fixture!(tenant.tenant_id, semver)

    versions = fn ->
      Repo.all(
        from(i in SolutionPackInstall,
          where: i.tenant_id == ^tenant.tenant_id,
          order_by: i.pack_id,
          select: {i.pack_id, i.installed_version}
        )
      )
    end

    before = versions.()

    assert :ok = SolutionPack.check_target_version(tenant.tenant_id, legacy, "2.0.0")
    assert :ok = SolutionPack.check_target_version(tenant.tenant_id, semver, "next")
    assert {:ok, _} = apply!(tenant, legacy, "2.0.0", fx_legacy)
    assert {:ok, _} = apply!(tenant, semver, "next", fx_semver)
    assert versions.() == before
  end

  test "V7: no active install (never installed, or uninstalled) is not checked" do
    tenant = new_tenant!("req573-v7")
    never = unique("req573-v7-never")
    gone = unique("req573-v7-gone")
    insert_install!(tenant.tenant_id, gone, "5.0.0", :uninstalled)
    fx = fixture!(tenant.tenant_id, never)

    for pack <- [never, gone], target <- ["2.0.0", "next"] do
      assert :ok = SolutionPack.check_target_version(tenant.tenant_id, pack, target)
    end

    assert {:ok, _} = apply!(tenant, never, "next", fx)
    assert {:ok, _} = apply!(tenant, never, "1.0.0", fx)
  end

  test "V8: documents install-time comparison: apply 1.0.0 -> 2.0.0 leaves installed_version at 1.0.0 and a second 2.0.0 is not refused" do
    tenant = new_tenant!("req573-v8")
    pack_id = unique("req573-v8-pack")
    insert_install!(tenant.tenant_id, pack_id, "1.0.0")
    fx = fixture!(tenant.tenant_id, pack_id)

    assert {:ok, _} = apply!(tenant, pack_id, "2.0.0", fx)

    assert Repo.one(
             from(i in SolutionPackInstall,
               where: i.tenant_id == ^tenant.tenant_id and i.pack_id == ^pack_id,
               select: i.installed_version
             )
           ) == "1.0.0"

    assert :ok = SolutionPack.check_target_version(tenant.tenant_id, pack_id, "2.0.0")
    assert {:ok, _} = apply!(tenant, pack_id, "2.0.0", fx)
  end

  test "V9: INV-1/INV-10 lookup is by the caller's own tenant_id, not another tenant's install" do
    tenant_a = new_tenant!("req573-v9a")
    tenant_b = new_tenant!("req573-v9b")
    pack_id = unique("req573-v9-pack")
    insert_install!(tenant_a.tenant_id, pack_id, "5.0.0")
    fx_a = fixture!(tenant_a.tenant_id, pack_id)
    fx_b = fixture!(tenant_b.tenant_id, pack_id)
    a_before = snapshot(tenant_a.tenant_id)

    assert :ok = SolutionPack.check_target_version(tenant_b.tenant_id, pack_id, "2.0.0")

    assert {:error, :version_downgrade} =
             SolutionPack.check_target_version(tenant_a.tenant_id, pack_id, "2.0.0")

    assert {:ok, _} = apply!(tenant_b, pack_id, "2.0.0", fx_b)

    insert_install!(tenant_b.tenant_id, pack_id, "3.0.0")
    assert {:error, :version_downgrade} = apply!(tenant_b, pack_id, "2.0.0", fx_b)
    assert {:error, :version_downgrade} = apply!(tenant_a, pack_id, "2.0.0", fx_a)
    assert snapshot(tenant_a.tenant_id) == a_before
  end
end
