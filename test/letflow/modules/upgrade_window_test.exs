Code.require_file("codes/codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.UpgradeWindowTest do
  @moduledoc """
  T-1860: a module version bump without `min_upgradable_from` strands every existing tenant
  (`no_upgrade_path`, 409 `upgrade_required` on its writes). G1..G2 are the CI guard: every manifest
  above 0.1.0 declares a window or a step chain, and the four modules that had none (catalog_items,
  assets, locations, org) are named. P1..P3 run the real plan and apply routes on a tenant aged to
  the version QA tenants hold (catalog_items 0.3.0, assets 0.9.0). Committed tenants, Sandbox
  `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @old_hash String.duplicate("7", 64)
  @fixed ["catalog_items", "assets", "locations", "org"]

  # ── G: the guard ─────────────────────────────────────────────────────────────────────

  defp stranded(manifest) do
    version = manifest.version

    cond do
      Version.compare(version, "0.1.0") != :gt -> false
      Map.has_key?(manifest, :min_upgradable_from) -> false
      true -> match?({:error, _}, Catalog.upgrade_path(manifest, "0.1.0", version))
    end
  end

  test "G1 no manifest above 0.1.0 is without an upgrade window or a covering step chain" do
    offenders = for m <- Catalog.all_manifests(), stranded(m), do: m.id

    assert offenders == [],
           "modules that strand every tenant on a version bump: #{inspect(offenders)}"
  end

  test "G2 the four modules of T-1860 declare a window that reaches their current version" do
    for id <- @fixed do
      {:ok, entry} = Catalog.fetch(id)
      m = entry.manifest()
      assert is_binary(Map.get(m, :min_upgradable_from)), "#{id} has no min_upgradable_from"
      assert {:ok, []} = Catalog.upgrade_path(m, m.min_upgradable_from, m.version)
    end

    {:ok, ci} = Catalog.fetch("catalog_items")
    assert {:ok, []} = Catalog.upgrade_path(ci.manifest(), "0.3.0", ci.manifest().version)
    {:ok, as} = Catalog.fetch("assets")
    assert {:ok, []} = Catalog.upgrade_path(as.manifest(), "0.9.0", as.manifest().version)
  end

  test "G3 the guard is sharp: a manifest with a version bump and no window is flagged" do
    assert stranded(%{id: "x", version: "0.2.0", migrations: []})
    refute stranded(%{id: "x", version: "0.2.0", min_upgradable_from: "0.1.0"})
    refute stranded(%{id: "x", version: "0.1.0"})
  end

  # ── P: plan and apply on an aged tenant ──────────────────────────────────────────────

  setup context do
    if context[:tenant] do
      ctx = Fx.installed_tenant!("t1860")

      for id <- ["org", "locations", "catalog_items", "stock", "assets"],
          do: Fx.install_module!(ctx.tenant_id, id)

      user =
        %User{}
        |> Ecto.Changeset.change(%{
          username: "t1860-user-#{Ecto.UUID.generate()}",
          display_name: "Upgrade Window Test User",
          email: "t1860-#{Ecto.UUID.generate()}@example.com",
          password_hash: "__NO_PASSWORD_SET__",
          status: :active,
          auth_source: :internal
        })
        |> Repo.insert!(prefix: ctx.schema)

      {:ok, %{plaintext: tok}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.schema
        )

      %{t: ctx, user: %{plaintext: tok, slug: ctx.slug}}
    else
      :ok
    end
  end

  defp post_json(path, user, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp plan(user, id), do: post_json("/api/v1/tenant/modules/#{id}/upgrade/plan", user, %{})

  defp age!(schema, id, version) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == ^id),
        [set: [version: version, manifest_hash: @old_hash]],
        prefix: schema
      )
  end

  @tag :tenant
  test "P1 catalog_items at 0.3.0: plan has a path, apply works, the next plan is up to date",
       %{t: t, user: user} do
    age!(t.schema, "catalog_items", "0.3.0")

    report = plan(user, "catalog_items") |> status!(200)
    assert report["from_version"] == "0.3.0"
    assert report["upgrade_path_available"] == true
    assert report["path_error"] == nil

    conn =
      post_json("/api/v1/tenant/modules/catalog_items/upgrade", user, %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1860 test: apply the catalog_items upgrade"
      })

    status!(conn, 200)

    m = Repo.get_by!(TenantModule, [module_id: "catalog_items"], prefix: t.schema)
    assert m.version == Catalog.fetch("catalog_items") |> elem(1) |> then(& &1.manifest().version)

    assert plan(user, "catalog_items") |> status!(200) |> Map.fetch!("up_to_date") == true
  end

  @tag :tenant
  test "P2 assets at 0.9.0 and locations/org at 0.1.0 have a path in the plan", %{
    t: t,
    user: user
  } do
    for {id, v} <- [{"assets", "0.9.0"}, {"locations", "0.1.0"}, {"org", "0.1.0"}] do
      age!(t.schema, id, v)
      report = plan(user, id) |> status!(200)
      assert report["from_version"] == v
      assert report["upgrade_path_available"] == true, "#{id}: #{inspect(report["path_error"])}"
    end
  end

  @tag :tenant
  test "P3 assets with a current card type: apply works and the next plan is up to date",
       %{t: t, user: user} do
    age!(t.schema, "assets", "0.9.0")
    report = plan(user, "assets") |> status!(200)
    assert report["upgrade_path_available"] == true

    conn =
      post_json("/api/v1/tenant/modules/assets/upgrade", user, %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1860 test: apply the assets upgrade"
      })

    status!(conn, 200)
    assert plan(user, "assets") |> status!(200) |> Map.fetch!("up_to_date") == true
  end
end
