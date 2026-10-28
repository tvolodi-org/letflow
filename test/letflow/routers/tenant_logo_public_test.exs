defmodule Letflow.Routers.TenantLogoPublicTest do
  @moduledoc """
  REQ-591 / GH #3337 part 2 -- the public `GET /api/tenant-config/logo` and the uploaded logo
  replacing `branding.logo_url` in `GET /api/tenant-config` and `GET /api/mobile/tenant-config`.
  Test IDs R1..R4, W1..W6, M1, I1, E1 follow the task design.

  Requests go through the real `Letflow.Router` with no token. `async: false`: the flag is
  application env, `TenantFixture` flips the SQL sandbox to `:auto`, and the default-realm cases
  displace the migration-seeded `bpm-default` tenant (restored on exit).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantLogo
  alias Letflow.Routers.TenantConfig
  alias Letflow.Support.BpmDefaultRealmDisplacement
  alias Letflow.TenantFixture

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 1, 2, 3, 4>>
  @png_script @png <> "<script>alert(1)</script>"
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>
  @stored_url "https://example.com/l.png"

  setup do
    old = Application.get_env(:letflow, :tenant_logo_upload_enabled)
    Application.put_env(:letflow, :tenant_logo_upload_enabled, true)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:letflow, :tenant_logo_upload_enabled),
        else: Application.put_env(:letflow, :tenant_logo_upload_enabled, old)
    end)

    :ok
  end

  defp call(path), do: Letflow.Router.call(conn(:get, path), Letflow.Router.init([]))
  defp json(path), do: path |> call() |> Map.fetch!(:resp_body) |> Jason.decode!()
  defp flag(value), do: Application.put_env(:letflow, :tenant_logo_upload_enabled, value)
  defp q(slug), do: URI.encode_www_form(slug)

  defp tenant!(prefix, opts \\ []) do
    realm = Keyword.get(opts, :idp_realm_id, "realm-#{System.unique_integer([:positive])}")
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: prefix, idp_realm_id: realm)
    if opts[:status], do: set_status!(fixture, opts[:status]), else: fixture
  end

  defp change!(fixture, changes) do
    %{fixture | tenant: fixture.tenant |> Ecto.Changeset.change(changes) |> Repo.update!()}
  end

  defp set_status!(fixture, status), do: change!(fixture, status: status)
  defp set_realm!(fixture, realm), do: change!(fixture, idp_realm_id: realm)

  defp upload!(fixture, bytes \\ @png, type \\ "image/png") do
    {:ok, _} = TenantLogo.put(fixture.schema_name, fixture.tenant_id, nil, type, bytes, nil)
    fixture
  end

  defp store_url!(fixture, url) do
    {:ok, _} =
      Identity.update_tenant_settings(fixture.tenant.slug, %{"settings" => %{"logo_url" => url}})

    fixture
  end

  # The seeded bpm-default tenant is displaced; a provisioned tenant takes its slug and realm.
  defp default_tenant!() do
    BpmDefaultRealmDisplacement.displace!()
    "t0724-def" |> tenant!(idp_realm_id: "bpm-default") |> change!(slug: "bpm-default")
  end

  defp web(query), do: json("/api/tenant-config" <> query)
  defp mobile(query), do: json("/api/mobile/tenant-config" <> query)
  defp logo_path(slug), do: "/api/tenant-config/logo?slug=" <> q(slug)

  defp shape(conn),
    do: {conn.status, conn.resp_body, conn.resp_headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()}

  describe "R1 flag off" do
    test "the logo is the 404 and both bodies equal those of a tenant with no row" do
      with_row = tenant!("t0724-r1a") |> store_url!(@stored_url)
      without = tenant!("t0724-r1b") |> store_url!(@stored_url)
      upload!(with_row)
      flag(false)

      assert call(logo_path(with_row.tenant.slug)).status == 404
      assert shape(call(logo_path(with_row.tenant.slug))) == shape(call(logo_path("nope")))

      for {path, key} <- [
            {"/api/tenant-config?realm=", "branding"},
            {"/api/mobile/tenant-config?slug=", "branding"}
          ] do
        a = json(path <> q(with_row.tenant.slug))
        b = json(path <> q(without.tenant.slug))
        assert a[key]["logo_url"] == @stored_url
        assert a[key] == b[key]
      end
    end
  end

  describe "R2 serving" do
    test "200 with the exact bytes, stored type and the hardening headers" do
      t = tenant!("t0724-r2") |> upload!(@jpeg, "image/jpeg")
      conn = call(logo_path(t.tenant.slug))

      assert conn.status == 200
      assert conn.resp_body == @jpeg
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") ==
               ["default-src 'none'; sandbox"]

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == ["inline"]
    end

    test "a PNG ending in a script tag is returned byte-identical as image/png" do
      t = tenant!("t0724-r2s") |> upload!(@png_script)
      conn = call(logo_path(t.tenant.slug))

      assert conn.resp_body == @png_script
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
    end
  end

  describe "R3 one identical 404" do
    test "every miss, with the flag off too, has the same status, body and header names" do
      with_logo = tenant!("t0724-r3a") |> upload!()
      inactive = tenant!("t0724-r3b", status: :inactive) |> upload!()
      nil_realm = tenant!("t0724-r3c") |> upload!() |> set_realm!(nil)
      empty_realm = tenant!("t0724-r3d") |> upload!() |> set_realm!("")
      no_logo = tenant!("t0724-r3e")

      misses = [
        "/api/tenant-config/logo",
        logo_path("no-such-tenant"),
        "/api/tenant-config/logo?slug=%00",
        logo_path(inactive.tenant.slug),
        logo_path(nil_realm.tenant.slug),
        logo_path(empty_realm.tenant.slug),
        logo_path(no_logo.tenant.slug),
        "/api/tenant-config/logo?realm=" <> q(with_logo.tenant.slug),
        "/api/tenant-config/logo?host=example.test"
      ]

      shapes = Enum.map(misses, &shape(call(&1)))
      assert [{404, _, _}] = shapes |> Enum.uniq()

      flag(false)
      assert shape(call(logo_path(with_logo.tenant.slug))) == hd(shapes)
    end
  end

  describe "R4 tenant isolation" do
    test "each slug returns its own bytes" do
      a = tenant!("t0724-r4a") |> upload!(@png)
      b = tenant!("t0724-r4b") |> upload!(@jpeg, "image/jpeg")

      assert call(logo_path(a.tenant.slug)).resp_body == @png
      assert call(logo_path(b.tenant.slug)).resp_body == @jpeg
    end
  end

  describe "W web branches" do
    test "W1 ?realm= hit with an upload gets the path with the slug sent" do
      t = tenant!("t0724-w1") |> store_url!(@stored_url) |> upload!()

      assert web("?realm=" <> q(t.tenant.slug))["branding"]["logo_url"] ==
               logo_path(t.tenant.slug)
    end

    test "W2 ?realm= hit without an upload keeps the stored string" do
      t = tenant!("t0724-w2") |> store_url!(@stored_url)
      assert web("?realm=" <> q(t.tenant.slug))["branding"]["logo_url"] == @stored_url
    end

    test "W3 default branches use bpm-default when that tenant has an upload" do
      default_tenant!() |> upload!()
      expected = logo_path("bpm-default")

      for query <- ["?realm=unknown-slug", "?host=example.test", ""] do
        assert web(query)["branding"]["logo_url"] == expected
      end
    end

    test "W4 a forced lookup failure answers like an unknown slug" do
      default_tenant!() |> upload!()
      body = web("?realm=%00")
      assert body["branding"]["logo_url"] == logo_path("bpm-default")
      assert web("?realm=%00") == web("?realm=unknown-slug")
    end

    test "W5 an inactive or realm-less default tenant keeps today's value" do
      t = default_tenant!() |> store_url!(@stored_url) |> upload!()

      t = set_status!(t, :inactive)
      assert web("")["branding"]["logo_url"] == @stored_url

      Repo.update_all(from(x in Tenant, where: x.id == ^t.tenant_id), set: [status: :active])
      # nil/empty realm: default_realm_tenant/0 only returns a tenant bound to bpm-default,
      # so the guard is exercised through the shared servable?/1.
      refute TenantLogo.servable?(%{t.tenant | idp_realm_id: nil})
      refute TenantLogo.servable?(%{t.tenant | idp_realm_id: ""})
      assert TenantLogo.public_path(%{t.tenant | idp_realm_id: ""}, "bpm-default") == nil
    end

    test "W6 the key sets of the body and of branding are unchanged" do
      t = tenant!("t0724-w6") |> upload!()
      body = web("?realm=" <> q(t.tenant.slug))

      assert Map.keys(body) |> Enum.sort() ==
               ["branding", "client_id", "oidc_authority", "tenant_type"]

      assert Map.keys(body["branding"]) |> Enum.sort() == ["app_name", "brand_colors", "logo_url"]
    end
  end

  describe "M1 mobile" do
    test "a ?slug= hit with an upload gets the path; every other case is the platform default" do
      t = tenant!("t0724-m1") |> upload!()
      inactive = tenant!("t0724-m1i", status: :inactive) |> upload!()
      nil_realm = tenant!("t0724-m1n") |> upload!() |> set_realm!(nil)

      body = mobile("?slug=" <> q(t.tenant.slug))
      assert body["branding"]["logo_url"] == logo_path(t.tenant.slug)
      assert map_size(body) == 6

      default = mobile("")

      for query <- [
            "?slug=no-such-tenant",
            "?slug=%00",
            "?slug=" <> q(inactive.tenant.slug),
            "?slug=" <> q(nil_realm.tenant.slug)
          ] do
        assert mobile(query) == default
      end

      assert default["branding"]["logo_url"] == nil
    end
  end

  describe "I1 nothing of the row leaks" do
    test "neither body holds the bytes, hash, size or updated_by, by key or value" do
      t = tenant!("t0724-i1") |> upload!(@png_script)

      %{rows: [[hash, size]]} =
        Repo.query!(~s|SELECT content_hash, byte_size FROM "#{t.schema_name}".tenant_logos|)

      for raw <- [
            call("/api/tenant-config?realm=" <> q(t.tenant.slug)).resp_body,
            call("/api/mobile/tenant-config?slug=" <> q(t.tenant.slug)).resp_body
          ] do
        refute raw =~ hash
        refute raw =~ "<script>"
        refute raw =~ "content_hash"
        refute raw =~ "byte_size"
        refute raw =~ "updated_by"
        refute raw =~ "\"#{size}\""
      end
    end

    test "both moduledocs state the logo path, the slug rule and the 404 posture" do
      for file <- [
            "lib/letflow/routers/tenant_config.ex",
            "lib/letflow/routers/mobile_tenant_config.ex"
          ] do
        src = File.read!(file)
        assert src =~ "REQ-591"
        assert src =~ "/api/tenant-config/logo?slug="
        assert src =~ "uniform 404" or src =~ "identical 404"
      end
    end
  end

  describe "E1 existing logo_url values" do
    test "upload wins, the stored setting is untouched, delete and flag off restore it" do
      t = tenant!("t0724-e1") |> store_url!(@stored_url)
      slug = t.tenant.slug

      both = fn ->
        {web("?realm=" <> q(slug))["branding"]["logo_url"],
         mobile("?slug=" <> q(slug))["branding"]["logo_url"]}
      end

      assert both.() == {@stored_url, @stored_url}

      upload!(t)
      assert both.() == {logo_path(slug), logo_path(slug)}
      assert Repo.get!(Tenant, t.tenant_id).settings["logo_url"] == @stored_url

      flag(false)
      assert both.() == {@stored_url, @stored_url}

      flag(true)
      assert {:ok, _} = TenantLogo.delete(t.schema_name, t.tenant_id, nil, nil)
      assert both.() == {@stored_url, @stored_url}

      settings = Repo.get!(Tenant, t.tenant_id).settings
      assert TenantConfig.branding_from_settings(settings)["logo_url"] == @stored_url
    end
  end
end
