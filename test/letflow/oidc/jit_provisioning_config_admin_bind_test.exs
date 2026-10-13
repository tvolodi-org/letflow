defmodule Letflow.Oidc.JitProvisioningConfigAdminBindTest do
  @moduledoc """
  ISS-1030 PR 2 -- the per-realm, operator-set, DEFAULT-OFF
  `accept_unverified_email_for_admin_bind` setting of
  `Letflow.Oidc.JitProvisioningConfig` (design section 4.4; decision 0048), and the boot
  validation of the one variable that can turn it on,
  `LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS` (`config/runtime.exs`).

  The binding tests use real Postgres and real tenant schemas
  (`Letflow.Support.PendingAdminHelper`); the config tests are pure, but share the file so the
  VM-global application env they set is restored in one place. `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Support.PendingAdminHelper, as: H

  @env_var "LETFLOW_OIDC_ADMIN_BIND_UNVERIFIED_REALMS"

  # Sets the operator list for the calling test; the original value is restored on exit.
  defp put_unverified_realms!(realms) do
    original = Application.fetch_env(:letflow, :oidc_admin_bind_unverified_realms)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:letflow, :oidc_admin_bind_unverified_realms, value)
        :error -> Application.delete_env(:letflow, :oidc_admin_bind_unverified_realms)
      end
    end)

    Application.put_env(:letflow, :oidc_admin_bind_unverified_realms, realms)
  end

  # Evaluates the REAL config/runtime.exs with the variable set to `value` (nil = unset).
  defp read_runtime(value) do
    original = System.get_env(@env_var)

    try do
      if is_nil(value), do: System.delete_env(@env_var), else: System.put_env(@env_var, value)
      Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    after
      if is_nil(original),
        do: System.delete_env(@env_var),
        else: System.put_env(@env_var, original)
    end
  end

  defp runtime_realms(value) do
    value
    |> read_runtime()
    |> Keyword.fetch!(:letflow)
    |> Keyword.fetch!(:oidc_admin_bind_unverified_realms)
  end

  # --- default and sources ---------------------------------------------------

  test "accept_unverified_email_for_admin_bind defaults to false" do
    bare =
      struct!(JitProvisioningConfig,
        realm: "r",
        enabled: true,
        default_status: :active,
        default_roles: []
      )

    assert bare.accept_unverified_email_for_admin_bind == false

    assert JitProvisioningConfig.default("any-realm").accept_unverified_email_for_admin_bind ==
             false

    # The shipped realm entry and a realm nobody configured.
    assert JitProvisioningConfig.for_realm("bpm-default").accept_unverified_email_for_admin_bind ==
             false

    assert JitProvisioningConfig.for_realm("a-realm-nobody-configured").accept_unverified_email_for_admin_bind ==
             false

    # And with nothing in the environment list at all.
    assert runtime_realms(nil) == []
    assert runtime_realms("") == []
    assert runtime_realms(" , ,") == []
  end

  test "a configured realm entry without the key keeps it false" do
    original = Application.fetch_env!(:letflow, :oidc_jit_provisioning)
    on_exit(fn -> Application.put_env(:letflow, :oidc_jit_provisioning, original) end)

    Application.put_env(
      :letflow,
      :oidc_jit_provisioning,
      Map.put(original, "explicit-realm", %{
        enabled: true,
        default_status: :active,
        default_roles: ["VIEWER"]
      })
    )

    config = JitProvisioningConfig.for_realm("explicit-realm")
    assert config.default_roles == ["VIEWER"]
    assert config.accept_unverified_email_for_admin_bind == false

    # Even a configured entry that spells the key out cannot turn it on: the only source is the list.
    Application.put_env(
      :letflow,
      :oidc_jit_provisioning,
      Map.put(original, "explicit-realm", %{
        enabled: true,
        default_status: :active,
        default_roles: [],
        accept_unverified_email_for_admin_bind: true
      })
    )

    assert JitProvisioningConfig.for_realm("explicit-realm").accept_unverified_email_for_admin_bind ==
             false
  end

  test "the setting is true only for realms named in the operator environment list" do
    put_unverified_realms!(["realm-on", "other-on"])

    assert JitProvisioningConfig.for_realm("realm-on").accept_unverified_email_for_admin_bind
    assert JitProvisioningConfig.for_realm("other-on").accept_unverified_email_for_admin_bind

    # Exact names only: no prefix, no case folding, no pattern.
    for realm <- ["realm-off", "realm-on-2", "Realm-On", "REALM-ON", "realm"] do
      assert JitProvisioningConfig.for_realm(realm).accept_unverified_email_for_admin_bind ==
               false,
             realm
    end

    # The list is what config/runtime.exs builds from the variable, names trimmed.
    assert runtime_realms("realm-a, realm-b ,realm-c") == ["realm-a", "realm-b", "realm-c"]
    assert runtime_realms("only-one") == ["only-one"]
  end

  test "boot refuses a malformed realm name in the environment list without echoing it" do
    bad_values = [
      "bad realm!",
      "has.dot",
      "../etc",
      "-leading-dash",
      "_leading-underscore",
      String.duplicate("a", 65),
      "master",
      "Master",
      "good-realm,bad/realm",
      "göd-realm"
    ]

    for value <- bad_values do
      error = assert_raise RuntimeError, fn -> read_runtime(value) end

      # Names the variable; never repeats the value. (The fixed rule text itself says "not master",
      # which is the rule, not an echo, so that one value is exempt from the echo check.)
      assert error.message =~ @env_var
      if String.downcase(value) != "master", do: refute(error.message =~ value)
    end
  end

  # --- structural: nothing else can set it -----------------------------------

  test "no tenant setting, claim or request field can set the flag" do
    # 1. Source scan: the key is read in exactly one place besides its own definition, and the
    #    application key that feeds it is read in exactly one module.
    key_files =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "accept_unverified_email_for_admin_bind"))
      |> Enum.sort()

    assert key_files == [
             "lib/letflow/identity/pending_admin_grants.ex",
             "lib/letflow/oidc/jit_provisioning_config.ex"
           ]

    env_key_files =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ":oidc_admin_bind_unverified_realms"))
      |> Enum.sort()

    assert env_key_files == ["lib/letflow/oidc/jit_provisioning_config.ex"]

    # ... and the only config file that writes it is runtime.exs, from the environment variable.
    config_files =
      "config/*.exs"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "oidc_admin_bind_unverified_realms"))

    assert config_files == ["config/runtime.exs"]

    # 2. No router reads or writes the key (request fields are only what routers read).
    for path <- Path.wildcard("lib/letflow/routers/**/*.ex") do
      refute File.read!(path) =~ "unverified_email_for_admin_bind", path
      refute File.read!(path) =~ "oidc_admin_bind", path
    end

    # 3. No tenant changeset can carry it: it is not a tenant field, and the settings vocabulary is closed.
    refute :accept_unverified_email_for_admin_bind in Tenant.__schema__(:fields)

    changeset =
      Tenant.settings_changeset(%Tenant{}, %{
        "settings" => %{"accept_unverified_email_for_admin_bind" => true}
      })

    refute changeset.valid?

    patch =
      Tenant.admin_patch_changeset(%Tenant{}, %{
        "accept_unverified_email_for_admin_bind" => true,
        "display_name" => "x"
      })

    assert Map.keys(patch.changes) == [:display_name]

    # 4. A claim of that name changes nothing: the mapped context has no such field and the
    #    realm's config is the same with or without it.
    realm = "claim-realm-#{System.unique_integer([:positive])}"

    claims = %{
      "iss" => "https://placeholder-keycloak.invalid/realms/#{realm}",
      "sub" => "s-1",
      "email" => "a@example.com",
      "accept_unverified_email_for_admin_bind" => true
    }

    assert {:ok, context} =
             ClaimMapping.map_verified_claims(ClaimMappingConfig.for_realm(realm), "s-1", claims)

    refute Map.has_key?(Map.from_struct(context), :accept_unverified_email_for_admin_bind)

    assert JitProvisioningConfig.for_realm(realm).accept_unverified_email_for_admin_bind == false
  end

  # --- behaviour with the setting on -----------------------------------------

  test "with the setting on, an unverified e-mail equal to the key binds and the audit entry says unverified_realm_setting" do
    w = H.world!()
    grant = H.create_grant!(w, "owner@example.com")

    # Off (the default): the same unverified claim does not bind.
    sub = "sub-setting-flip"
    assert %{result: :noop} = H.login(w, sub: sub, email: "owner@example.com", verified: false)
    assert H.member_count(w) == 0

    # On, for exactly this realm.
    put_unverified_realms!([w.realm])

    # The e-mail still has to EQUAL the key: a different address does not bind.
    assert %{result: :noop} = H.login(w, email: "someone.else@example.com", verified: false)
    assert H.member_count(w) == 0

    # The same person's next login (the marker is still unset, the stored address is the claim's).
    assert %{result: :bound, provisioned: %{user: user, created: false}} =
             H.login(w, sub: sub, email: "owner@example.com", verified: false)

    assert Letflow.Identity.PendingAdminGrant.state(H.grant(w, grant.id)) == :bound
    assert H.roles(w, user.id) == ["TENANT_ADMIN"]

    assert [entry] = H.entries(w.tenant.schema_name, "tenant.admin_grant.bound")
    assert entry.after_state["email_basis"] == "unverified_realm_setting"
    assert entry.after_state["created_via"] == "platform_operator_onboarding"
    assert entry.actor_id == user.id
    refute Jason.encode!(entry.after_state) =~ "owner@example.com"
  end

  test "with the setting on, preferred_username still never binds" do
    w = H.world!()
    grant = H.create_grant!(w, "owner@example.com")
    put_unverified_realms!([w.realm])

    # Username equal to the pending address, e-mail claim different (unverified AND verified).
    for {username, verified} <- [{"owner@example.com", false}, {"Owner@Example.com", true}] do
      assert %{result: :noop} =
               H.login(w,
                 username: username,
                 email: "someone.else@example.com",
                 verified: verified
               )
    end

    # And with an empty e-mail claim on a row that already exists.
    user = H.insert_user!(w, email: "", username: "OWNER@EXAMPLE.COM")

    ctx =
      H.identity_context(w,
        sub: user.external_id,
        username: "OWNER@EXAMPLE.COM",
        email: "",
        verified: false
      )

    jit = JitProvisioningConfig.for_realm(w.realm)
    assert jit.accept_unverified_email_for_admin_bind

    assert :noop ==
             Letflow.Identity.PendingAdminGrants.bind_on_login(
               H.tenant_row(w),
               %{user: user, created: true},
               ctx,
               jit,
               prefix: w.tenant.schema_name
             )

    stored = H.grant(w, grant.id)
    assert stored.consumed_at == nil
    assert stored.email_key == "owner@example.com"
    assert H.member_count(w) == 0
  end
end
