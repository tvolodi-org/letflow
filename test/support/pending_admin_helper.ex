defmodule Letflow.Support.PendingAdminTokenVerifierDouble do
  @moduledoc """
  Test-only `Letflow.Oidc.TokenVerifier` for ISS-1030 PR 2 tests that drive the real
  `Letflow.Plugs.AuthPipeline` with a token whose `email`, `email_verified`,
  `preferred_username` and role claims the test chooses (the sibling
  `Letflow.Oidc.ConfigurableTokenVerifierDouble` derives its e-mail from the subject and
  cannot carry `email_verified`).

  The raw token is `"claims:" <> url-safe base64 of the JSON claims`; `token/2` builds it.
  Stateless and global-config-free: every claim comes from the token string itself. It
  must be selected per test with `Letflow.Support.PendingAdminHelper.use_double!/0`
  (the `:token_verifier` entry of `config :letflow, :oidc` is VM-global, so every module
  using it is `async: false`).
  """

  @behaviour Letflow.Oidc.TokenVerifier

  @issuer "https://placeholder-keycloak.invalid/realms/"

  @doc """
  A raw bearer token for `realm`. Options: `:sub`, `:email`, `:email_verified` (any JSON
  value, or `:omit` to leave the claim out; default `true`), `:preferred_username`,
  `:name`, `:roles`.
  """
  @spec token(String.t(), keyword()) :: String.t()
  def token(realm, opts \\ []) do
    sub = Keyword.get(opts, :sub, "sub-" <> Ecto.UUID.generate())

    base = %{
      "iss" => @issuer <> realm,
      "sub" => sub,
      "email" => Keyword.get(opts, :email, sub <> "@example.com"),
      "preferred_username" => Keyword.get(opts, :preferred_username, sub),
      "name" => Keyword.get(opts, :name, "Test " <> sub),
      "realm_access" => %{"roles" => Keyword.get(opts, :roles, [])}
    }

    claims =
      case Keyword.get(opts, :email_verified, true) do
        :omit -> base
        value -> Map.put(base, "email_verified", value)
      end

    "claims:" <> Base.url_encode64(Jason.encode!(claims), padding: false)
  end

  @impl Letflow.Oidc.TokenVerifier
  def verify_bearer_token("claims:" <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _invalid -> {:error, :invalid_test_token}
    end
  end

  def verify_bearer_token(_other), do: {:error, :invalid_test_token}
end

defmodule Letflow.Support.PendingAdminHelper do
  @moduledoc """
  Shared world builder for the ISS-1030 PR 2 pending-administrator tests
  (`test/letflow/identity/pending_admin_*`, `plugs/pending_admin_login_response_test.exs`,
  `oidc/jit_provisioning_config_admin_bind_test.exs`).

  `world!/1` provisions two REAL fixture tenants (a customer tenant bound to a fresh realm
  with the platform roles seeded, and a second tenant pinned as THE platform tenant, whose
  schema holds the platform audit chain) and returns a plain map. Everything else here is a
  thin, honest wrapper over the shipped functions: no stub of `PendingAdminGrants` or of the
  database. Callers are `async: false` (the fixture flips the sandbox to `:auto`, and the
  platform pin and `:oidc` config are VM-global).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.ClaimMapping
  alias Letflow.Oidc.ClaimMappingConfig
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Repo
  alias Letflow.Support.PendingAdminTokenVerifierDouble, as: Double
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantSlugFixture

  @type world :: %{
          platform: TenantFixture.tenant_fixture(),
          tenant: TenantFixture.tenant_fixture(),
          realm: String.t(),
          operator_id: Ecto.UUID.t()
        }

  @doc "Customer tenant (with `realm` bound, roles seeded) + pinned platform tenant."
  @spec world!(keyword()) :: world()
  def world!(opts \\ []) do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-pa-plat")
    Fixture.pin!(platform.tenant_id)

    realm = Keyword.get(opts, :realm) || TenantSlugFixture.unique_realm("iss1030pa")

    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "iss1030-pa",
        idp_realm_id: Keyword.get(opts, :idp_realm_id, realm)
      )

    if Keyword.get(opts, :seed_roles, true) do
      {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: tenant.schema_name)
    end

    %{platform: platform, tenant: tenant, realm: realm, operator_id: Ecto.UUID.generate()}
  end

  @doc "A second customer tenant (own realm, roles seeded) in place of the world's, same platform."
  @spec second_tenant!(world()) :: world()
  def second_tenant!(world) do
    realm = TenantSlugFixture.unique_realm("iss1030pb")

    tenant =
      TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-pb", idp_realm_id: realm)

    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: tenant.schema_name)
    %{world | tenant: tenant, realm: realm}
  end

  @doc "The group id the tenant's `TENANT_ADMIN` platform-role binding points to."
  @spec admin_group_id!(world()) :: Ecto.UUID.t()
  def admin_group_id!(world) do
    [prefix: world.tenant.schema_name]
    |> RoleRegistry.list_roles()
    |> Enum.find(&(&1.name == "TENANT_ADMIN" and &1.kind == :platform_role))
    |> Map.fetch!(:group_id)
  end

  @doc "Selects `PendingAdminTokenVerifierDouble` as the OIDC verifier for the calling test."
  @spec use_double!() :: :ok
  def use_double! do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, Double)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)
    :ok
  end

  # ── grants ────────────────────────────────────────────────────────────────

  @doc "Stores an open grant for `email` through the shipped `create/3`; returns the grant."
  @spec create_grant!(world(), String.t()) :: PendingAdminGrant.t()
  def create_grant!(world, email) do
    {:ok, key} = PendingAdminGrants.normalize_email(email)

    {:ok, grant} =
      PendingAdminGrants.create(key, %{user_id: world.operator_id},
        prefix: world.tenant.schema_name,
        platform_prefix: world.platform.schema_name,
        trace_id: "t-op",
        onboarding_id: nil
      )

    grant
  end

  @spec grants(world()) :: [PendingAdminGrant.t()]
  def grants(world),
    do:
      Repo.all(from(g in PendingAdminGrant, order_by: g.inserted_at),
        prefix: world.tenant.schema_name
      )

  @spec grant(world(), Ecto.UUID.t()) :: PendingAdminGrant.t()
  def grant(world, id), do: Repo.get!(PendingAdminGrant, id, prefix: world.tenant.schema_name)

  @doc "An onboarding record for the world's customer tenant (what the operator routes resolve it by)."
  @spec onboarding_record!(world()) :: Letflow.Identity.OnboardingRecord.t()
  def onboarding_record!(world) do
    {:ok, record} =
      Identity.create_onboarding(%{
        tenant_id: world.tenant.tenant_id,
        slug: world.tenant.tenant.slug,
        hostname: "iss1030-pa-#{Ecto.UUID.generate()}.example.com"
      })

    # Registered after the fixture's own teardown, so it runs first: `onboarding_registry` has a
    # foreign key to `tenants`, which the fixture deletes.
    ExUnit.Callbacks.on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Repo)
      Repo.delete_all(from(o in Letflow.Identity.OnboardingRecord, where: o.id == ^record.id))
    end)

    record
  end

  @doc """
  The entries of a captured log that are Letflow's own lines: Ecto's SQL debug echo (which prints
  bound query parameters, and so an e-mail written through a normal INSERT) is dropped.
  """
  @spec non_sql_entries(String.t()) :: [String.t()]
  def non_sql_entries(log) do
    log
    |> String.split(~r/\n(?=\d{2}:\d{2}:\d{2}\.\d{3} \[)/)
    |> Enum.reject(&(&1 =~ "QUERY"))
  end

  @spec tenant_row(world()) :: Tenant.t()
  def tenant_row(world), do: Repo.get!(Tenant, world.tenant.tenant_id)

  # ── login simulation ──────────────────────────────────────────────────────

  @doc """
  The shipped first-login path minus HTTP: `Identity.provision_oidc_user/4` (JIT) then
  `PendingAdminGrants.bind_on_login/5`, with the realm's real `JitProvisioningConfig`.
  Attributes: `:sub`, `:email`, `:username`, `:verified`, `:roles`, `:realm`.
  Returns `%{result: :bound | :noop, provisioned: map, ctx: IdentityContext.t()}`.
  """
  @spec login(world(), keyword()) :: %{result: :bound | :noop, provisioned: map(), ctx: struct()}
  def login(world, attrs \\ []), do: run_login(world, identity_context(world, attrs))

  @doc """
  Like `login/2`, but the identity context comes from a CLAIMS map through the shipped
  `ClaimMapping.map_verified_claims/3` (the same mapping the pipeline runs), so the
  `email_verified` rule is exercised as a token would exercise it. `overrides` replaces or,
  with the value `:omit`, removes a claim.
  """
  @spec login_from_claims(world(), map()) :: %{
          result: :bound | :noop,
          provisioned: map(),
          ctx: struct()
        }
  def login_from_claims(world, overrides \\ %{}) do
    sub = Map.get(overrides, "sub", "sub-" <> Ecto.UUID.generate())

    base = %{
      "iss" => "https://placeholder-keycloak.invalid/realms/" <> world.realm,
      "sub" => sub,
      "email" => sub <> "@example.com",
      "preferred_username" => "user-" <> sub,
      "name" => "Display " <> sub,
      "realm_access" => %{"roles" => []}
    }

    claims =
      overrides
      |> Enum.reduce(base, fn
        {key, :omit}, acc -> Map.delete(acc, key)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    {:ok, ctx} =
      ClaimMapping.map_verified_claims(
        ClaimMappingConfig.for_realm(world.realm),
        Map.fetch!(claims, "sub"),
        claims
      )

    run_login(world, ctx)
  end

  defp run_login(world, ctx) do
    jit = JitProvisioningConfig.for_realm(ctx.realm)

    {:ok, provisioned} =
      Identity.provision_oidc_user(ctx, world.tenant.tenant_id, jit,
        prefix: world.tenant.schema_name
      )

    result =
      PendingAdminGrants.bind_on_login(tenant_row(world), provisioned, ctx, jit,
        prefix: world.tenant.schema_name
      )

    %{result: result, provisioned: provisioned, ctx: ctx}
  end

  @spec identity_context(world(), keyword()) :: IdentityContext.t()
  def identity_context(world, attrs \\ []) do
    sub = Keyword.get(attrs, :sub, "sub-" <> Ecto.UUID.generate())

    %IdentityContext{
      external_user_id: sub,
      tenant_id: nil,
      realm: Keyword.get(attrs, :realm, world.realm),
      roles: Keyword.get(attrs, :roles, []),
      email: Keyword.get(attrs, :email, sub <> "@example.com"),
      preferred_username: Keyword.get(attrs, :username, "user-" <> sub),
      display_name: Keyword.get(attrs, :display_name, "Display " <> sub),
      email_verified: Keyword.get(attrs, :verified, true)
    }
  end

  @doc "Inserts a user row directly (bypassing JIT), e.g. one holding a particular stored e-mail."
  @spec insert_user!(world(), keyword()) :: User.t()
  def insert_user!(world, attrs) do
    suffix = Ecto.UUID.generate()

    %User{}
    |> Ecto.Changeset.change(%{
      username: Keyword.get(attrs, :username, "raw-" <> suffix),
      display_name: "Raw " <> suffix,
      email: Keyword.fetch!(attrs, :email),
      password_hash: "__OIDC_ONLY__",
      status: Keyword.get(attrs, :status, :active),
      auth_source: :oidc,
      external_realm: Keyword.get(attrs, :realm, world.realm),
      external_id: Keyword.get(attrs, :external_id, "raw-sub-" <> suffix)
    })
    |> Repo.insert!(prefix: world.tenant.schema_name)
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  @spec entries(String.t(), String.t()) :: [Entry.t()]
  def entries(schema, action),
    do:
      Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
        prefix: schema
      )

  @spec all_entries(String.t()) :: [Entry.t()]
  def all_entries(schema), do: Repo.all(from(e in Entry, order_by: e.timestamp), prefix: schema)

  @doc "Group ids the user belongs to, and the names of those groups."
  @spec memberships(world(), Ecto.UUID.t()) :: [String.t()]
  def memberships(world, user_id) do
    Repo.all(
      from(m in GroupMember,
        join: g in Letflow.Identity.Group,
        on: g.id == m.group_id,
        where: m.user_id == ^user_id,
        order_by: g.name,
        select: g.name
      ),
      prefix: world.tenant.schema_name
    )
  end

  @spec member_count(world()) :: non_neg_integer()
  def member_count(world),
    do: Repo.aggregate(GroupMember, :count, :user_id, prefix: world.tenant.schema_name)

  @doc "Effective role names of a user, read exactly as the auth pipeline reads them."
  @spec roles(world(), Ecto.UUID.t()) :: [String.t()]
  def roles(world, user_id),
    do: Identity.list_effective_role_names(user_id, prefix: world.tenant.schema_name)

  @doc """
  True once `count` backends are blocked on a lock behind a statement matching `table`
  and `FOR UPDATE`. Polls through the repo (each poll is a round trip; no sleep),
  bounded by `attempts`.
  """
  @spec lock_waiters?(String.t(), non_neg_integer(), pos_integer()) :: boolean()
  def lock_waiters?(table, count, attempts \\ 20_000)
  def lock_waiters?(_table, _count, 0), do: false

  def lock_waiters?(table, count, attempts) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock' " <>
          "AND query ILIKE '%FOR UPDATE%' AND query ILIKE $1",
        ["%" <> table <> "%"]
      )

    waiting >= count or lock_waiters?(table, count, attempts - 1)
  end
end
