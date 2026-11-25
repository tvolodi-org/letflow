defmodule Letflow.Routers.OnboardingClientConfigTest do
  @moduledoc """
  REQ-468 (supersedes Q-1088 / GH #2450's disposition) -- `POST /api/v1/onboarding` ignores `client_config`
  and `realm_config` BY NAME: they are ordinary undeclared body keys (like `redirect_uris`). No value is
  read, stored or echoed.

  T-2704 (pilot gap G17b): the route starts the `platform.register_tenant` process and answers 202
  `{instance_id, status, slug}`; the old 201 body (with `ignored_fields`) is gone. What stays true, and
  is proven here: the keys are not echoed anywhere in the answer, and they are NOT start variables of
  the instance (the start carries the form's known fields only).

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.EventStore.Event
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RegisterTenantProcessFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantSlugFixture

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "q1088-plat")
    Fixture.pin!(platform.tenant_id)
    token = Fixture.mint_token!(platform, ["PLATFORM_ADMIN"])
    RegisterTenantProcessFixture.seed!(platform.schema_name)
    %{platform: platform, token: token}
  end

  defp call(ctx, body) do
    :post
    |> Fixture.api_conn("/api/v1/onboarding", ctx.token, ctx.platform.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp new_body(extra) do
    Map.merge(
      %{
        "slug" => TenantSlugFixture.unique_slug("q1088"),
        "display_name" => "Q-1088 Tenant",
        "hostname" => "q1088-#{Ecto.UUID.generate()}.example.com"
      },
      extra
    )
  end

  defp started_event!(ctx, instance_id) do
    Repo.one!(
      from(e in Event,
        where: e.instance_id == ^instance_id and e.event_type == "INSTANCE_STARTED"
      ),
      prefix: ctx.platform.schema_name
    )
  end

  test "client_config and realm_config are ignored by name: 202, not echoed, not start variables",
       ctx do
    conn =
      call(
        ctx,
        new_body(%{
          "client_config" => %{
            "redirect_uris" => ["https://zz-req468-sentinel.example.test/cb"],
            "service_account_enabled" => true
          },
          "realm_config" => %{"realm_display_name" => "ZZ-REQ468-SENTINEL"}
        })
      )

    assert conn.status == 202, conn.resp_body

    # Case-insensitive, and the response headers too: an echo in any case or any header is a leak.
    refute String.downcase(conn.resp_body) =~ "zz-req468-sentinel"

    refute Enum.any?(conn.resp_headers, fn {_name, value} ->
             String.downcase(value) =~ "zz-req468-sentinel"
           end)

    body = Jason.decode!(conn.resp_body)
    refute Map.has_key?(body, "client_config")
    refute Map.has_key?(body, "realm_config")
    refute Map.has_key?(body, "ignored_fields")

    # The instance's own start event carries no value of the ignored keys.
    event = started_event!(ctx, body["instance_id"])
    refute String.downcase(inspect(event.payload)) =~ "zz-req468-sentinel"
  end

  test "the per-key disposition is gone from the router source" do
    source = File.read!("lib/letflow/routers/onboarding.ex")

    for gone <- ["@not_stored_keys", "@not_stored_next", "dispositions(", ~s("disposition" =>)] do
      refute source =~ gone, "lib/letflow/routers/onboarding.ex still contains #{inspect(gone)}"
    end
  end
end
