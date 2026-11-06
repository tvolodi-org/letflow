defmodule Letflow.Routers.MeUiSettingsTest do
  @moduledoc """
  T-1390: the tenant default `ui.document_layout_default` (tenant settings, written by the tenant
  admin through `PATCH /api/v1/tenant/settings`) and the effective layout read in
  `GET /api/v1/me/preferences` (user preference, else tenant default, else `row`). Real router,
  real tokens (D-098). `async: false`: tenant provisioning and the platform pin are VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.UserPreferences

  @prefs "/api/v1/me/preferences"
  @settings "/api/v1/tenant/settings"
  @key "ui.document_layout"
  @dkey "ui.document_layout_default"

  setup do
    Fixture.unpin!()
    %{a: a, b: b} = Fixture.two_tenants!()
    {:ok, a: a, b: b}
  end

  defp call(method, path, fixture, token, body) do
    method
    |> Fixture.api_conn(path, token, fixture.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp read(f, token), do: call(:get, @prefs, f, token, nil) |> json()
  defp set_default(f, token, v), do: call(:patch, @settings, f, token, %{@dkey => v})
  defp stored(f), do: Repo.get!(Tenant, f.tenant_id).settings || %{}

  test "E1 admin sets the default tabs", %{a: a} do
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    conn = set_default(a, admin, "tabs")
    assert conn.status == 200, conn.resp_body
    assert json(conn)["settings"][@dkey] == "tabs"
    assert stored(a)[@dkey] == "tabs"
  end

  test "E2 a user without a preference gets the tenant default", %{a: a} do
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    worker = Fixture.mint_token!(a, ["TASK_WORKER"])
    assert set_default(a, admin, "tabs").status == 200

    body = read(a, worker)
    assert body["preferences"] == %{}
    assert body["effective"] == %{@key => "tabs"}
    assert body["tenant_defaults"] == %{@key => "tabs"}
  end

  test "E3 a user preference wins over the tenant default", %{a: a} do
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    alice = Fixture.mint_token!(a, ["TASK_WORKER"])
    bob = Fixture.mint_token!(a, ["TASK_WORKER"])
    assert set_default(a, admin, "tabs").status == 200
    assert call(:put, @prefs, a, alice, %{"preferences" => %{@key => "row"}}).status == 200

    assert read(a, alice)["effective"] == %{@key => "row"}
    assert read(a, alice)["tenant_defaults"] == %{@key => "tabs"}
    assert read(a, bob)["effective"] == %{@key => "tabs"}
  end

  test "E4 a non-admin cannot set the default (403 with a reason)", %{a: a} do
    worker = Fixture.mint_token!(a, ["TASK_WORKER"])
    conn = set_default(a, worker, "tabs")
    assert conn.status == 403
    assert is_binary(json(conn)["detail"]) and json(conn)["detail"] != ""
    refute Map.has_key?(stored(a), @dkey)
  end

  test "E5 nothing stored reads row; null resets to row", %{a: a} do
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    assert read(a, admin)["effective"] == %{@key => "row"}
    assert set_default(a, admin, "tabs").status == 200
    assert read(a, admin)["effective"] == %{@key => "tabs"}
    assert set_default(a, admin, nil).status == 200
    assert read(a, admin)["effective"] == %{@key => "row"}
  end

  test "E6 an invalid value is refused with 422 and nothing changes", %{a: a} do
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])

    for bad <- ["grid", 5] do
      conn = set_default(a, admin, bad)
      assert conn.status == 422, conn.resp_body
      assert conn.resp_body =~ "ui.document_layout_default must be"
    end

    refute Map.has_key?(stored(a), @dkey)
  end

  test "E7 the default of tenant A does not reach tenant B", %{a: a, b: b} do
    admin = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    other = Fixture.mint_token!(b, ["TASK_WORKER"])
    assert set_default(a, admin, "tabs").status == 200
    assert read(b, other)["effective"] == %{@key => "row"}
  end

  test "E8 garbage values fall through to row without raising", %{a: a} do
    user_id = Ecto.UUID.generate()
    assert UserPreferences.tenant_defaults(%{@dkey => "grid"}) == %{@key => "row"}
    assert UserPreferences.tenant_defaults(nil) == %{@key => "row"}
    assert UserPreferences.effective(a.schema_name, user_id, %{@dkey => 7}) == %{@key => "row"}

    assert UserPreferences.effective(a.schema_name, user_id, %{@dkey => "tabs"}) == %{
             @key => "tabs"
           }
  end

  test "E9 the changeset accepts row, tabs and nil only" do
    tenant = %Tenant{settings: %{}}

    for ok <- ["row", "tabs", nil] do
      assert Tenant.settings_changeset(tenant, %{"settings" => %{@dkey => ok}}).valid?
    end

    for bad <- ["grid", "", 1, ["tabs"]] do
      refute Tenant.settings_changeset(tenant, %{"settings" => %{@dkey => bad}}).valid?
    end
  end
end
