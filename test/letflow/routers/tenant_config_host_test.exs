defmodule Letflow.Routers.TenantConfigHostTest do
  @moduledoc """
  T-1359: public sign-in bootstrap resolves a company hostname through the global onboarding
  registry. Requests use the real router without authorization; all fixtures stay in the rolled-back
  sandbox and touch only global identity tables.
  """

  use Letflow.DataCase, async: true

  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.TenantSlugFixture

  @router_opts Letflow.Router.init([])
  @expected_keys ["branding", "client_id", "oidc_authority", "tenant_type"]
  @expected_branding_keys ["app_name", "brand_colors", "logo_url"]

  defp raw(path) do
    request = conn(:get, path)
    assert Plug.Conn.get_req_header(request, "authorization") == []
    conn = Letflow.Router.call(request, @router_opts)
    assert conn.status == 200
    conn.resp_body
  end

  defp by_host(host), do: raw("/api/tenant-config?host=#{URI.encode_www_form(host)}")
  defp by_slug(slug), do: raw("/api/tenant-config?realm=#{URI.encode_www_form(slug)}")

  defp insert_tenant!(prefix, attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    base = %{
      slug: TenantSlugFixture.unique_slug(prefix),
      display_name: "#{prefix}-display-#{n}",
      idp_realm_id: "#{prefix}-realm-#{n}",
      tenant_type: "test"
    }

    %Tenant{}
    |> Tenant.create_changeset(Map.merge(base, attrs), :disabled)
    |> Repo.insert!()
  end

  defp bind_host!(%Tenant{} = tenant, hostname) do
    %OnboardingRecord{}
    |> OnboardingRecord.insert_changeset(%{
      tenant_id: tenant.id,
      slug: tenant.slug,
      hostname: hostname
    })
    |> Repo.insert!()
  end

  defp set_branding!(%Tenant{} = tenant, app_name, primary) do
    assert {:ok, _} =
             Identity.update_tenant_settings(tenant.slug, %{
               "settings" => %{
                 "app_name" => app_name,
                 "brand_colors" => %{"primary" => primary}
               }
             })

    tenant
  end

  test "H1: a bound active production host returns its own public sign-in config" do
    tenant = insert_tenant!("h1", %{tenant_type: "production"})
    host = "#{tenant.slug}.ai-letflow.com"
    bind_host!(tenant, host)
    set_branding!(tenant, "Smart Security Systems", "#1864ab")

    body = raw("/api/tenant-config?host=#{host}")
    decoded = Jason.decode!(body)

    assert decoded["oidc_authority"] =~ "/realms/#{tenant.idp_realm_id}"
    assert decoded["client_id"] == "letflow-web"
    assert decoded["tenant_type"] == "production"
    assert decoded["branding"]["app_name"] == "Smart Security Systems"
    assert decoded["branding"]["brand_colors"] == %{"primary" => "#1864ab"}
    assert Enum.sort(Map.keys(decoded)) == @expected_keys
    assert Enum.sort(Map.keys(decoded["branding"])) == @expected_branding_keys
    assert body == by_slug(tenant.slug)
  end

  test "H2: request and legacy stored hostname case and padding normalize to one tenant" do
    lowercase = insert_tenant!("h2-lower")
    uppercase = insert_tenant!("h2-upper")
    lowercase_host = "#{lowercase.slug}.ai-letflow.com"
    uppercase_host = "#{uppercase.slug}.ai-letflow.com"
    bind_host!(lowercase, lowercase_host)
    bind_host!(uppercase, "  #{String.upcase(uppercase_host)}  ")

    assert by_host("  #{String.upcase(lowercase_host)}  ") == by_slug(lowercase.slug)
    assert by_host(uppercase_host) == by_slug(uppercase.slug)
  end

  test "H3: two companies receive only their own realm and branding" do
    a = insert_tenant!("h3-a") |> set_branding!("Company A", "#1864ab")
    b = insert_tenant!("h3-b") |> set_branding!("Company B", "#c92a2a")
    host_a = "#{a.slug}.ai-letflow.com"
    host_b = "#{b.slug}.ai-letflow.com"
    bind_host!(a, host_a)
    bind_host!(b, host_b)

    body_a = by_host(host_a)
    body_b = by_host(host_b)
    decoded_a = Jason.decode!(body_a)
    decoded_b = Jason.decode!(body_b)

    assert decoded_a["oidc_authority"] =~ "/realms/#{a.idp_realm_id}"
    assert decoded_a["branding"]["app_name"] == "Company A"
    assert decoded_b["oidc_authority"] =~ "/realms/#{b.idp_realm_id}"
    assert decoded_b["branding"]["app_name"] == "Company B"

    for {body, own, other, own_host, other_host} <- [
          {body_a, a, b, host_a, host_b},
          {body_b, b, a, host_b, host_a}
        ] do
      for tenant <- [own, other],
          private_value <- [tenant.id, tenant.slug, tenant.display_name] do
        refute body =~ private_value
      end

      refute body =~ own_host
      refute body =~ other_host
      refute body =~ other.idp_realm_id
    end
  end

  test "H4: an explicit realm wins, an unknown realm falls through to a bound host" do
    a = insert_tenant!("h4-a")
    b = insert_tenant!("h4-b")
    host_a = "#{a.slug}.ai-letflow.com"
    bind_host!(a, host_a)

    explicit =
      raw(
        "/api/tenant-config?realm=#{URI.encode_www_form(b.slug)}&host=#{URI.encode_www_form(host_a)}"
      )

    assert explicit == by_slug(b.slug)

    fallback =
      raw("/api/tenant-config?realm=no-such-tenant&host=#{URI.encode_www_form(host_a)}")

    assert fallback == by_host(host_a)
    assert Jason.decode!(raw("/api/tenant-config"))["oidc_authority"] =~ "/realms/bpm-default"
  end

  test "H5: unknown, malformed, overlong and failed host lookups equal the default response" do
    default = raw("/api/tenant-config")

    for host <- [
          "unknown.ai-letflow.com",
          "",
          "   ",
          String.duplicate("a", 254) <> ".ai-letflow.com",
          "https://sss.ai-letflow.com",
          "sss.ai-letflow.com:443/path",
          <<0>>
        ] do
      assert by_host(host) == default
    end
  end

  test "H6: inactive, migrating and realm-less host and slug lookups share the default response" do
    inactive = insert_tenant!("h6-inactive", %{status: :inactive})
    migrating = insert_tenant!("h6-migrating", %{status: :migrating})
    nil_realm = insert_tenant!("h6-nil", %{idp_realm_id: nil})
    empty_realm = insert_tenant!("h6-empty", %{idp_realm_id: ""})

    for tenant <- [inactive, migrating, nil_realm, empty_realm] do
      host = "#{tenant.slug}.ai-letflow.com"
      bind_host!(tenant, host)
      assert by_host(host) == raw("/api/tenant-config")
      assert by_slug(tenant.slug) == raw("/api/tenant-config")
    end
  end

  test "H7: ambiguous legacy hostname case variants fall back instead of choosing a tenant" do
    a = insert_tenant!("h7-a")
    b = insert_tenant!("h7-b")
    host = "ambiguous-#{System.unique_integer([:positive])}.ai-letflow.com"
    bind_host!(a, host)
    bind_host!(b, String.upcase(host))

    assert by_host(host) == raw("/api/tenant-config")
    assert by_host(String.upcase(host)) == raw("/api/tenant-config")
  end
end
