defmodule Letflow.Api.PlatformMarkerNotWritableTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 3.1 and section 12 item 17 (ISS-0994 acceptance criterion e;
  specs `test/specs/ISS-0993-A1.md`, `ISS-0993-A2.md`): the platform-tenant pin is deployment configuration, not data;
  no `/api/v1` route can write it.

  Scope (A1 + A2): written in A1 and unchanged in what it asserts; the one A2 expectation it
  contains (a tenant administrator's follow-up call is 403) is enforced. Item 17(0), the check
  that `Tenant.update_changeset/2` was DELETED, is the separate A2 file
  `test/letflow/identity/tenant_update_changeset_removed_test.exs`; the cast-field lists below
  are literal, so the four remaining changesets are the only writers of a tenant row.

    * (a) the cast-field lists of `create_changeset`, `admin_patch_changeset`, `status_changeset`
      and `settings_changeset` equal literal expected lists, and the `Tenant` schema has no
      platform-like field: adding one fails this test and forces a conscious decision;
    * (b) the `PATCH /tenants/:slug` allowlist (`@patch_schema`) is exactly `display_name` and
      `login_disclosure_mode`;
    * (c) as the platform tenant's `PLATFORM_ADMIN`, `PATCH /tenants/<A slug>` with platform-like
      extra keys has the normal outcome and tenant A still is not the platform tenant;
    * (d) as A's `TENANT_ADMIN` (REQ-447 PR 2: an ordinary tenant's `PLATFORM_ADMIN` is dropped, so the
      ordinary administrator is `TENANT_ADMIN`), `PATCH /tenant/settings` with the same keys leaves A
      non-platform and stores none of them;
    * (e) `POST /tenants` and `Identity.create_tenant/1` with a body `id` equal to the configured
      pin create a tenant with a DIFFERENT id, and the pin is unchanged;
    * (f) source scans: nothing under `lib/` writes the pin through `Application.put_env` /
      `put_all_env`; nothing under `lib/letflow/routers/` or `lib/letflow/identity/` references
      `Letflow.PlatformTenant` except through its read functions; the `status_changeset` writers of
      a tenant are exactly `Identity.set_tenant_status/2` and `TenantOnboarding`.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin, DB writes).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.PlatformTenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantProvisioning

  @platform_like %{
    "is_platform" => true,
    "platform" => true,
    "platform_tenant" => true,
    "platform_scope" => true,
    "platform_tenant?" => true,
    "is_platform_tenant" => true
  }

  # --- source-scan helpers (comments and doc heredocs excluded) -------------

  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, number}, {in_doc?, acc} ->
      quotes = length(String.split(line, ~s(""")) |> tl())
      toggled? = rem(quotes, 2) == 1

      cond do
        in_doc? -> {not toggled?, acc}
        toggled? -> {true, acc}
        String.starts_with?(String.trim_leading(line), "#") -> {false, acc}
        true -> {false, [{number, line} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp lib_files(pattern \\ "lib/**/*.ex"),
    do: pattern |> Path.wildcard() |> Enum.reject(&String.contains?(&1, "lib/letflow/design/"))

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "(a) changeset cast lists and schema fields" do
    test "the Tenant schema has no platform-like field (literal field list)" do
      assert Enum.sort(Tenant.__schema__(:fields)) ==
               Enum.sort([
                 :id,
                 :slug,
                 :display_name,
                 :status,
                 :idp_realm_id,
                 :settings,
                 :storage_allowance_bytes,
                 :login_disclosure_mode,
                 # REQ-497 PR 1b (0051 D12): the per-tenant scope-enforcement flag (off|shadow),
                 # not a platform marker; cast only by Tenant.scope_enforcement_changeset/2.
                 :scope_enforcement,
                 # REQ-469: the tenant environment type (test|production); cast only by
                 # create_changeset/3 and admin_patch_changeset/2, not a platform marker.
                 :tenant_type,
                 :inserted_at,
                 :updated_at
               ])
    end

    @attrs Map.merge(@platform_like, %{
             "id" => "11111111-1111-4111-8111-111111111111",
             "slug" => "scope-slug",
             "display_name" => "Scope Name",
             "status" => "inactive",
             "idp_realm_id" => "scope-realm",
             "settings" => %{"app_name" => "Scope"},
             "storage_allowance_bytes" => 1,
             "login_disclosure_mode" => "redirect_single",
             "inserted_at" => ~N[2000-01-01 00:00:00]
           })

    test "create_changeset casts exactly slug, display_name, status, idp_realm_id" do
      changeset = Tenant.create_changeset(%Tenant{}, @attrs, :disabled)

      assert Enum.sort(Map.keys(changeset.changes)) ==
               Enum.sort([:slug, :display_name, :status, :idp_realm_id])
    end

    test "admin_patch_changeset casts exactly display_name and login_disclosure_mode" do
      changeset = Tenant.admin_patch_changeset(%Tenant{}, @attrs)

      assert Enum.sort(Map.keys(changeset.changes)) ==
               Enum.sort([:display_name, :login_disclosure_mode])
    end

    test "status_changeset casts exactly status" do
      assert Map.keys(Tenant.status_changeset(%Tenant{}, @attrs).changes) == [:status]
    end

    test "settings_changeset casts exactly settings" do
      assert Map.keys(Tenant.settings_changeset(%Tenant{}, @attrs).changes) == [:settings]
    end

    test "no changeset casts the primary key" do
      for changeset <- [
            Tenant.create_changeset(%Tenant{}, @attrs, :disabled),
            Tenant.admin_patch_changeset(%Tenant{}, @attrs),
            Tenant.status_changeset(%Tenant{}, @attrs),
            Tenant.settings_changeset(%Tenant{}, @attrs)
          ] do
        refute Map.has_key?(changeset.changes, :id)
      end
    end
  end

  describe "(b) the PATCH /tenants/:slug allowlist" do
    test "@patch_schema names exactly display_name, login_disclosure_mode and tenant_type" do
      source = File.read!("lib/letflow/routers/tenants.ex")

      [_before, after_marker] = String.split(source, "@patch_schema [", parts: 2)
      [block, _rest] = String.split(after_marker, "\n  ]\n", parts: 2)

      names = ~r/name:\s*"([^"]+)"/ |> Regex.scan(block) |> Enum.map(fn [_all, name] -> name end)

      assert Enum.sort(names) == ["display_name", "login_disclosure_mode", "tenant_type"]
    end
  end

  describe "(c) PATCH /tenants/:slug with platform-like extra keys" do
    test "the normal outcome; tenant A does not become the platform tenant", ctx do
      before = Repo.get!(Tenant, ctx.a.tenant_id)

      body =
        Map.merge(@platform_like, %{
          "id" => ctx.p.tenant_id,
          "status" => "inactive",
          "idp_realm_id" => "other-realm",
          "display_name" => "Renamed A"
        })

      resp =
        Letflow.Routers.Tenants.call(
          Fixture.router_conn(:patch, "/#{ctx.a.tenant.slug}", ctx.p, ["PLATFORM_ADMIN"], body),
          Letflow.Routers.Tenants.init([])
        )

      assert resp.status == 200

      after_row = Repo.get!(Tenant, ctx.a.tenant_id)
      assert after_row.id == before.id
      assert after_row.status == before.status
      assert after_row.idp_realm_id == before.idp_realm_id
      assert after_row.slug == before.slug
      assert after_row.display_name == "Renamed A"

      refute PlatformTenant.platform_tenant?(ctx.a.tenant_id)
      assert PlatformTenant.configured_id() == String.downcase(ctx.p.tenant_id)

      # a follow-up call as A's administrator is denied 403 (A2): A is not the platform tenant.
      followup =
        Letflow.Routers.Tenants.call(
          Fixture.router_conn(:get, "/", ctx.a, ["PLATFORM_ADMIN"], nil),
          Letflow.Routers.Tenants.init([])
        )

      assert followup.status == 403

      # REQ-447 PR 2: the same for A's TENANT_ADMIN (never platform scope) ...
      tenant_admin_followup =
        Letflow.Routers.Tenants.call(
          Fixture.router_conn(:get, "/", ctx.a, ["TENANT_ADMIN"], nil),
          Letflow.Routers.Tenants.init([])
        )

      assert tenant_admin_followup.status == 403
    end
  end

  describe "(d) PATCH /tenant/settings with platform-like keys" do
    test "they are not stored and tenant A stays non-platform", ctx do
      resp =
        Letflow.Routers.TenantSettings.call(
          Fixture.router_conn(:patch, "/", ctx.a, ["TENANT_ADMIN"], @platform_like),
          Letflow.Routers.TenantSettings.init([])
        )

      assert resp.status == 200

      # REQ-447 PR 2 (changed assertion): A's legacy PLATFORM_ADMIN is dropped, so the
      # same request is 403 and writes nothing.
      legacy =
        Letflow.Routers.TenantSettings.call(
          Fixture.router_conn(:patch, "/", ctx.a, ["PLATFORM_ADMIN"], @platform_like),
          Letflow.Routers.TenantSettings.init([])
        )

      assert legacy.status == 403

      settings = Repo.get!(Tenant, ctx.a.tenant_id).settings || %{}

      for key <- Map.keys(@platform_like) do
        refute Map.has_key?(settings, key)
      end

      refute PlatformTenant.platform_tenant?(ctx.a.tenant_id)
      assert PlatformTenant.configured_id() == String.downcase(ctx.p.tenant_id)
    end
  end

  describe "(e) a body id equal to the pin" do
    defp cleanup_tenant!(tenant_id) do
      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(
          from(r in TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
        )

        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
      end)
    end

    test "POST /tenants creates a tenant with a different id and leaves the pin unchanged", ctx do
      pin_before = PlatformTenant.configured_id()
      slug = "scope-create-#{Ecto.UUID.generate()}"

      resp =
        Letflow.Routers.Tenants.call(
          Fixture.router_conn(
            :post,
            "/",
            ctx.p,
            ["PLATFORM_ADMIN"],
            Map.merge(@platform_like, %{
              "slug" => slug,
              "display_name" => "Scope Create",
              "id" => ctx.p.tenant_id
            })
          ),
          Letflow.Routers.Tenants.init([])
        )

      assert resp.status == 201
      created_id = Jason.decode!(resp.resp_body)["id"]
      cleanup_tenant!(created_id)

      refute created_id == ctx.p.tenant_id
      refute String.downcase(created_id) == pin_before
      refute PlatformTenant.platform_tenant?(created_id)
      assert PlatformTenant.configured_id() == pin_before
    end

    test "Identity.create_tenant/1 (the writer behind POST /tenants and onboarding) ignores a supplied id",
         ctx do
      pin_before = PlatformTenant.configured_id()

      assert {:ok, tenant} =
               Identity.create_tenant(%{
                 "slug" => "scope-ident-#{Ecto.UUID.generate()}",
                 "display_name" => "Scope Identity",
                 "id" => ctx.p.tenant_id
               })

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)

      refute tenant.id == ctx.p.tenant_id
      refute PlatformTenant.platform_tenant?(tenant.id)
      assert PlatformTenant.configured_id() == pin_before
    end
  end

  describe "(f) source scans" do
    test "nothing under lib/ writes the pin through Application.put_env or put_all_env" do
      offenders =
        for file <- lib_files(),
            {number, line} <- code_lines(file),
            line =~ ~r/Application\.(put_env|put_all_env|delete_env)/,
            line =~ ~r/PlatformTenant/,
            do: "#{file}:#{number}"

      assert offenders == []
    end

    test "routers and identity code reference Letflow.PlatformTenant only through its read functions" do
      read_functions =
        ~w(parse_env uuid? configured_id platform_prefix platform_tenant? platform_prefix? scope_facts scope_facts_for
           cross_tenant_promotion_operator_only? check_registration)

      files =
        lib_files("lib/letflow/routers/**/*.ex") ++
          lib_files("lib/letflow/identity/**/*.ex") ++
          ["lib/letflow/identity.ex"]

      for file <- files, {number, line} <- code_lines(file) do
        for [_all, function] <- Regex.scan(~r/PlatformTenant\.([a-z_?!]+)/, line) do
          assert function in read_functions, "#{file}:#{number} calls PlatformTenant.#{function}"
        end
      end
    end

    test "the writers of a tenant's status are exactly Identity.set_tenant_status/2 and TenantOnboarding" do
      callers =
        for file <- lib_files(),
            {_number, line} <- code_lines(file),
            line =~ ~r/Tenant\.status_changeset\(/,
            uniq: true,
            do: file

      assert Enum.sort(callers) ==
               Enum.sort(["lib/letflow/identity.ex", "lib/letflow/tenant_onboarding.ex"])

      identity = File.read!("lib/letflow/identity.ex")
      [_before, tail] = String.split(identity, "defp set_tenant_status(", parts: 2)
      [function_body, _rest] = String.split(tail, ~r/\n  (def|defp|@doc|@spec) /, parts: 2)

      assert function_body =~ "Tenant.status_changeset("

      identity_callers =
        for {_number, line} <- code_lines("lib/letflow/identity.ex"),
            line =~ ~r/Tenant\.status_changeset\(/,
            do: line

      assert length(identity_callers) == 1
    end

    test "Letflow.PlatformTenant defines no function that writes configuration" do
      source = File.read!("lib/letflow/platform_tenant.ex")
      refute source =~ "put_env"
      refute source =~ "put_all_env"
      refute source =~ "delete_env"
    end
  end
end
