defmodule Letflow.Routers.SolutionPacksVersionTest do
  @moduledoc """
  REQ-573 part 2 (decision 0069 D1/D7), router level: `update-review` and `update-apply`
  against the tenant's install-time version. Same dispatch convention as
  `solution_packs_update_test.exs`. Context-level cases are in
  `test/letflow/definitions/solution_pack_version_check_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.SolutionPacks.init([])
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

    if status != :active do
      Repo.update_all(from(i in SolutionPackInstall, where: i.id == ^install.id),
        set: [status: status, uninstalled_at: DateTime.truncate(DateTime.utc_now(), :microsecond)]
      )
    end

    install
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

  # Request body (string keys): one clean update and one conflict with a keep_local resolution.
  defp body!(tenant_id, pack_id, target) do
    clean = Ecto.UUID.generate()
    conflict = Ecto.UUID.generate()
    insert_base!(tenant_id, pack_id, clean, "base-clean")
    insert_base!(tenant_id, pack_id, conflict, "base-conflict")

    art = fn id, content ->
      %{"artefact_type" => @type_name, "artefact_id" => id, "content" => content}
    end

    %{
      "target_version" => target,
      "theirs_artefacts" => [art.(clean, "base-clean"), art.(conflict, "theirs-conflict")],
      "incoming_artefacts" => [art.(clean, "incoming-clean"), art.(conflict, "incoming-conflict")],
      "resolutions" => [
        %{
          "artefact_type" => @type_name,
          "artefact_id" => conflict,
          "resolution" => "keep_local"
        }
      ]
    }
  end

  defp post(tenant, pack_id, action, body) do
    conn(:post, "/#{pack_id}/#{action}")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "req573-test-trace-id")
    |> Letflow.Routers.SolutionPacks.call(@opts)
  end

  defp with_target(body, target), do: Map.put(body, "target_version", target)

  defp detail(resp) do
    json = Jason.decode!(resp.resp_body)
    json["detail"] || json["message"] || Jason.encode!(json)
  end

  defp snapshot(tenant_id) do
    {Repo.all(from(r in PackUpdateResolution, where: r.tenant_id == ^tenant_id, order_by: r.id)),
     Repo.all(
       from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id, order_by: b.id)
     ),
     Repo.all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id, order_by: i.id))}
  end

  test "V2: downgrade is 422 version_downgrade on apply and review; tables unchanged" do
    tenant = new_tenant!("req573-r2")
    pack_id = unique("req573-r2-pack")
    insert_install!(tenant.tenant_id, pack_id, "2.0.0")
    body = body!(tenant.tenant_id, pack_id, "1.9.0")
    before = snapshot(tenant.tenant_id)

    for action <- ["update-apply", "update-review"] do
      resp = post(tenant, pack_id, action, body)
      assert resp.status == 422
      assert detail(resp) =~ "version_downgrade"
    end

    assert snapshot(tenant.tenant_id) == before
  end

  test "V3/V4: equal target is 422 version_not_newer on apply, review answers the plan" do
    tenant = new_tenant!("req573-r3")
    pack_id = unique("req573-r3-pack")
    insert_install!(tenant.tenant_id, pack_id, "2.0.0")
    body = body!(tenant.tenant_id, pack_id, "2.0.0")
    before = snapshot(tenant.tenant_id)

    apply_resp = post(tenant, pack_id, "update-apply", body)
    assert apply_resp.status == 422
    assert detail(apply_resp) =~ "version_not_newer"
    assert snapshot(tenant.tenant_id) == before

    # The plan for the equal target is the plan the same input gets for a newer target.
    review = post(tenant, pack_id, "update-review", body)
    newer = post(tenant, pack_id, "update-review", with_target(body, "2.0.1"))
    assert review.status == 200
    assert newer.status == 200

    plan = fn resp -> resp.resp_body |> Jason.decode!() |> Map.drop(["target_version"]) end
    assert plan.(review) == plan.(newer)
  end

  test "V5: 2.0.1 and 10.0.0 are accepted against 2.0.0" do
    tenant = new_tenant!("req573-r5")
    pack_id = unique("req573-r5-pack")
    insert_install!(tenant.tenant_id, pack_id, "2.0.0")
    body = body!(tenant.tenant_id, pack_id, "2.0.1")

    for target <- ["2.0.1", "10.0.0"] do
      assert post(tenant, pack_id, "update-review", with_target(body, target)).status == 200
      assert post(tenant, pack_id, "update-apply", with_target(body, target)).status == 200
    end
  end

  test "V6: non-semver installed or target behaves as before, installed_version untouched" do
    tenant = new_tenant!("req573-r6")
    legacy = unique("req573-r6-legacy")
    semver = unique("req573-r6-semver")
    insert_install!(tenant.tenant_id, legacy, "legacy-2024")
    insert_install!(tenant.tenant_id, semver, "2.0.0")
    legacy_body = body!(tenant.tenant_id, legacy, "2.0.0")
    semver_body = body!(tenant.tenant_id, semver, "next")

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

    for {pack, body} <- [{legacy, legacy_body}, {semver, semver_body}] do
      assert post(tenant, pack, "update-review", body).status == 200
      assert post(tenant, pack, "update-apply", body).status == 200
    end

    assert versions.() == before
  end

  test "V7: no active install ignores versions, including a non-semver target" do
    tenant = new_tenant!("req573-r7")
    never = unique("req573-r7-never")
    gone = unique("req573-r7-gone")
    insert_install!(tenant.tenant_id, gone, "5.0.0", :uninstalled)

    for pack <- [never, gone], target <- ["2.0.0", "next"] do
      body = body!(tenant.tenant_id, pack, target)
      assert post(tenant, pack, "update-review", body).status == 200
      assert post(tenant, pack, "update-apply", body).status == 200
    end
  end

  test "V9: INV-1/INV-10 another tenant's install never decides this tenant's request" do
    tenant_a = new_tenant!("req573-r9a")
    tenant_b = new_tenant!("req573-r9b")
    pack_id = unique("req573-r9-pack")
    insert_install!(tenant_a.tenant_id, pack_id, "5.0.0")
    body_a = body!(tenant_a.tenant_id, pack_id, "2.0.0")
    body_b = body!(tenant_b.tenant_id, pack_id, "2.0.0")
    a_before = snapshot(tenant_a.tenant_id)

    # B has no install: A's 5.0.0 is invisible.
    assert post(tenant_b, pack_id, "update-review", body_b).status == 200
    assert post(tenant_b, pack_id, "update-apply", body_b).status == 200

    # B with its own install at 1.0.0: allowed; at 3.0.0: its own downgrade.
    install_b = insert_install!(tenant_b.tenant_id, pack_id, "1.0.0")
    assert post(tenant_b, pack_id, "update-apply", body_b).status == 200

    Repo.update_all(from(i in SolutionPackInstall, where: i.id == ^install_b.id),
      set: [installed_version: "3.0.0"]
    )

    assert detail(post(tenant_b, pack_id, "update-apply", body_b)) =~ "version_downgrade"

    # A is decided from A's own row.
    assert detail(post(tenant_a, pack_id, "update-apply", body_a)) =~ "version_downgrade"
    assert snapshot(tenant_a.tenant_id) == a_before
  end
end
