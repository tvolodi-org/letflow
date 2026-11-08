Code.require_file("codes_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)
Code.require_file("../locations/locations_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.UpgradeHttpTest do
  @moduledoc """
  T-1485 (W1, U1..U5): module `codes` has an upgrade window (`min_upgradable_from` 0.1.0, REQ-770), so a
  tenant installed on 0.3.0 gets a plan with a path and upgrades through the real HTTP routes with its data
  untouched. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CodesFixture, as: Fx
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.LocationsFixture, as: Loc
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Codes
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @old_hash String.duplicate("7", 64)
  @why "T-1485 test: apply the codes upgrade"
  @types ["code_tag", "code_assignment", "code_value_change"]

  setup do
    a = installed!("t1485a")
    b = installed!("t1485b")
    {:ok, hash} = Catalog.manifest_hash("codes")
    %{a: a, b: b, tok_a: user!(a), tok_b: user!(b), compiled_hash: hash}
  end

  defp installed!(prefix) do
    ctx = Fx.installed_tenant!(prefix)
    Fx.install_module!(ctx.tenant_id, "org")
    Fx.install_module!(ctx.tenant_id, "locations")
    Fx.install_module!(ctx.tenant_id, "catalog_items")
    ctx
  end

  defp user!(ctx) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t1485-user-#{Ecto.UUID.generate()}",
        display_name: "Codes Upgrade Test User",
        email: "t1485-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: ctx.schema
      )

    %{plaintext: plaintext, slug: ctx.slug}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────

  defp post_json(path, user, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    body(conn)
  end

  defp plan(user), do: post_json("/api/v1/tenant/modules/codes/upgrade/plan", user, %{})

  defp upgrade(user, plan_hash) do
    post_json("/api/v1/tenant/modules/codes/upgrade", user, %{
      "plan_hash" => plan_hash,
      "rationale" => @why
    })
  end

  defp receive_codes(user, value) do
    post_json("/api/v1/modules/codes/receive", user, %{
      "idempotency_key" => "k-" <> Ecto.UUID.generate(),
      "entries" => [%{"value" => value, "kind" => "barcode"}]
    })
  end

  defp age!(schema, version \\ "0.3.0", hash \\ @old_hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "codes"),
        [set: [version: version, manifest_hash: hash]],
        prefix: schema
      )
  end

  defp row(schema), do: Repo.get_by!(TenantModule, [module_id: "codes"], prefix: schema)

  defp audit_count(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'module.upgrade'|
      )

    n
  end

  defp data_snapshot(schema) do
    from(l in Letflow.Entities.Record.Latest,
      where: l.entity_type in ^@types,
      select: {l.entity_type, l.record_id, l.field_values}
    )
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  defp defs(schema) do
    from(d in EntityDefinition,
      where: d.name in ^@types,
      select: {d.name, d.id, d.content_hash}
    )
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  defp snapshot(schema) do
    m = row(schema)

    %{
      module: {m.version, m.manifest_hash, m.status},
      data: data_snapshot(schema),
      defs: defs(schema),
      audit: audit_count(schema)
    }
  end

  defp entity_row(report, name), do: Enum.find(report["entity_types"], &(&1["name"] == name))

  defp seed!(ctx) do
    node = Loc.node!(ctx.schema, "N1")
    tag = Fx.tag!(ctx.schema, "T1485-A")
    Fx.tag!(ctx.schema, "T1485-B")
    Fx.assign!(ctx.schema, tag, "location_node", node.record_id)
    :ok
  end

  # ── W1: the window ───────────────────────────────────────────────────────────────────

  test "W1 every version from 0.1.0 has an empty path, below the window has none" do
    m = Codes.manifest()

    for v <- ["0.1.0", "0.2.0", "0.3.0", "0.4.0"] do
      assert Catalog.upgrade_path(m, v, "0.4.0") == {:ok, []}
    end

    assert {:error, {:no_upgrade_path, _, _}} = Catalog.upgrade_path(m, "0.0.9", "0.4.0")
  end

  # ── U: the upgrade through the real HTTP path ────────────────────────────────────────

  test "U1 a 0.3.0 tenant gets a plan with a path, and unchanged types",
       ctx do
    seed!(ctx.a)
    age!(ctx.a.schema)
    before = snapshot(ctx.a.schema)

    report = plan(ctx.tok_a) |> status!(200)
    assert report["from_version"] == "0.3.0"
    assert report["to_version"] == "0.4.0"
    assert report["upgrade_path_available"] == true
    assert report["path_error"] == nil
    assert report["steps"] == []

    for t <- @types do
      assert %{"change" => "unchanged"} = entity_row(report, t)
    end

    assert snapshot(ctx.a.schema) == before
  end

  test "U2 apply keeps every record and definition and writes one audit row", ctx do
    seed!(ctx.a)
    age!(ctx.a.schema)
    before = snapshot(ctx.a.schema)
    assert length(before.data) == 3

    report = plan(ctx.tok_a) |> status!(200)
    applied = upgrade(ctx.tok_a, report["plan_hash"]) |> status!(200)
    assert applied["entity_versions_created"] == 0

    m = row(ctx.a.schema)
    assert m.version == "0.4.0"
    assert m.manifest_hash == ctx.compiled_hash
    assert data_snapshot(ctx.a.schema) == before.data
    assert defs(ctx.a.schema) == before.defs
    assert audit_count(ctx.a.schema) == before.audit + 1
  end

  test "U3 after the upgrade writes work and the plan is up to date", ctx do
    age!(ctx.a.schema)
    report = plan(ctx.tok_a) |> status!(200)
    upgrade(ctx.tok_a, report["plan_hash"]) |> status!(200)

    assert [%{"value" => "AFTER"}] = receive_codes(ctx.tok_a, "AFTER") |> status!(201)
    assert plan(ctx.tok_a) |> status!(200) |> Map.fetch!("up_to_date") == true
  end

  test "U4 tenants installed on 0.1.0 and 0.2.0 also have a path", ctx do
    for v <- ["0.1.0", "0.2.0"] do
      age!(ctx.a.schema, v)
      report = plan(ctx.tok_a) |> status!(200)
      assert report["from_version"] == v
      assert report["upgrade_path_available"] == true
    end
  end

  test "U5a the plan hash of tenant B against a codes A does not have is a 404", ctx do
    age!(ctx.a.schema)
    age!(ctx.b.schema)
    report_b = plan(ctx.tok_b) |> status!(200)

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "codes"),
        [set: [status: :uninstalled]],
        prefix: ctx.a.schema
      )

    before_b = snapshot(ctx.b.schema)
    assert upgrade(ctx.tok_a, report_b["plan_hash"]).status == 404
    assert snapshot(ctx.b.schema) == before_b
  end

  test "U5b the plan hash of tenant B against A's own codes is a 409 plan_mismatch", ctx do
    age!(ctx.a.schema)
    age!(ctx.b.schema)
    report_b = plan(ctx.tok_b) |> status!(200)

    before_a = snapshot(ctx.a.schema)
    before_b = snapshot(ctx.b.schema)
    conn = upgrade(ctx.tok_a, report_b["plan_hash"])

    assert conn.status == 409
    assert %{"code" => "plan_mismatch"} = body(conn)
    refute conn.resp_body =~ ctx.b.schema
    assert snapshot(ctx.a.schema) == before_a
    assert snapshot(ctx.b.schema) == before_b
  end
end
