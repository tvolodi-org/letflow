defmodule Letflow.Support.LastInteractiveAdminFixture do
  @moduledoc """
  Test support for GH #2869 parts (a) and (c) (the last-interactive-admin guard of an `on`
  tenant; design `lib/letflow/design/gh2869-last-interactive-admin-guard.md` section 5; spec
  `test/specs/GH2869-last-interactive-admin-guard.md`).

  The "last interactive" fixture (`on_tenant!/1`, `tenant_in_mode!/2`) is a real provisioned
  tenant schema stored in the given mode (default `on`, restored to `off` by an `on_exit`
  before the tenant teardown) with EXACTLY ONE interactive explicit tenant-wide admin:

    * `fx.admin` (A1): an active user, member of the group the `TENANT_ADMIN` platform binding
      points to, which holds the tenant-wide `TENANT_ADMIN` group row;
    * `fx.t1` (T1): a second ACTIVE user who owns a live `TENANT_ADMIN` API token and is in no
      group, so the OLD counted guard (`count_tenant_wide_admins/1`, which counts a token owner)
      sees TWO admins and would let the removal of A1 through. Only the new guard can refuse.
      Without T1 a per-path refusal test would be vacuous (the old guard would fire first).

  The variants (`add_admin!/1`, `flag!/2`, `userize_admin_row!/1`, `drop_token_owner!/1`,
  `at_zero!/1`) move that fixture into the shape one test needs, always through RAW writes (no
  audit noise, no writer under test involved).

  The tenant fixture leaves the sandbox in `:auto` mode (real commits), so every caller is
  `async: false`. Nothing here is compiled outside `:test`.
  """

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Repo
  alias Letflow.Support.BreakGlassFixture, as: BG
  alias Letflow.Support.EnforcedWritersFixture, as: EW
  alias Letflow.Support.OnGateFixture, as: F
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @slug_prefix "gh2869-"
  @trace "gh2869-trace-0001"
  @event "tenant_admin.guard_refused"
  @new_code "last_interactive_tenant_wide_admin"
  @old_code "last_tenant_wide_admin"
  @contract_keys ~w(action actor counted_admins reason_code target_id trace_id)
  @ta "TENANT_ADMIN"

  @doc "The slug prefix of every tenant of the GH #2869 tests (for the stale-tenant purge)."
  @spec slug_prefix() :: String.t()
  def slug_prefix, do: @slug_prefix

  @doc "The trace id the helpers assign."
  @spec trace() :: String.t()
  def trace, do: @trace

  @doc "The refusal event action."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The new `reason_code` / HTTP code."
  @spec new_code() :: String.t()
  def new_code, do: @new_code

  @doc "The old (N1) `reason_code` / HTTP code."
  @spec old_code() :: String.t()
  def old_code, do: @old_code

  @doc "The six keys of the refusal event, sorted."
  @spec contract_keys() :: [String.t()]
  def contract_keys, do: @contract_keys

  @doc "Heals the committed `on` leftovers of an earlier KILLED run of these tests."
  @spec purge_stale!() :: :ok
  def purge_stale! do
    _ = EW.purge_stale_enforced_tenants!(@slug_prefix)
    :ok
  end

  # --- building --------------------------------------------------------------------------------

  @doc "The last-interactive fixture stored `on`."
  @spec on_tenant!(String.t()) :: map()
  def on_tenant!(slug_suffix), do: tenant_in_mode!(slug_suffix, :on)

  @doc "The last-interactive fixture stored in `mode` (`:off`, `:shadow` or `:on`)."
  @spec tenant_in_mode!(String.t(), :off | :shadow | :on) :: map()
  def tenant_in_mode!(slug_suffix, mode) do
    PlatformTenantFixture.unpin!()
    fx = TenantFixture.provisioned_tenant!(slug_prefix: @slug_prefix <> slug_suffix)
    decorate!(fx, mode)
  end

  @doc """
  Turns an already provisioned tenant fixture (roles may or may not be seeded) into the
  last-interactive fixture: A1 as `:admin`, T1 as `:t1` with one live `TENANT_ADMIN` token as
  `:t1_token`, the TA group id and binding, and the stored mode.
  """
  @spec decorate!(map(), :off | :shadow | :on) :: map()
  def decorate!(fx, mode) do
    schema = fx.schema_name
    admin = TokenMintFixture.role_holder!(schema, [@ta])
    t1 = RSG.user!(schema)
    token = F.raw_token!(schema, t1.id, [@ta], admin.id)

    :ok = ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, mode)
    _ = BG.register_cleanup(fx)

    fx
    |> Map.put(:admin, admin)
    |> Map.put(:t1, t1)
    |> Map.put(:t1_token, token)
    |> Map.put(:ta_group_id, RSG.group_of!(schema, @ta))
    |> Map.put(:binding, RSG.binding(schema, @ta))
  end

  @doc """
  Asserts the premise every per-path test relies on: the stored mode, exactly one interactive
  explicit admin, and an OLD counted guard that would still see an admin after removing A1
  (the live token owner T1). Returns `fx`.
  """
  @spec assert_last_interactive!(map(), String.t()) :: map()
  def assert_last_interactive!(fx, mode) do
    assert EW.stored_mode(fx) == mode
    assert interactive(fx) == 1
    assert counted(fx) >= 2, "the live token owner must make the OLD counted guard pass"
    fx
  end

  @doc "A second interactive admin: a member of the TA group (which holds the group row)."
  @spec add_admin!(map()) :: Letflow.Identity.User.t()
  def add_admin!(fx), do: TokenMintFixture.role_holder!(fx.schema_name, [@ta])

  @doc "Flags a user as an admin service principal (RAW)."
  @spec flag!(map(), Letflow.Identity.User.t()) :: :ok
  def flag!(fx, user), do: F.flag_service_principal!(fx.schema_name, user.id)

  @doc "A flagged service principal who is a member of the TA group (counted by the old guard only)."
  @spec add_flagged_member!(map()) :: Letflow.Identity.User.t()
  def add_flagged_member!(fx) do
    user = add_admin!(fx)
    :ok = flag!(fx, user)
    user
  end

  @doc """
  The "zero-row admin group" shape: the group rows of the TA binding are deleted and A1's only
  explicit basis is a tenant-wide USER row. Any other member of the TA group is then a zero-row
  member (counted by the old guard, not interactive). Returns the user row id.
  """
  @spec userize_admin_row!(map()) :: Ecto.UUID.t()
  def userize_admin_row!(fx) do
    schema = fx.schema_name
    assert RSG.raw_delete_rows!(schema, fx.ta_group_id, @ta) >= 1
    :ok = RSG.raw_user_row!(schema, fx.admin.id, @ta, nil)
    user_row_id!(fx, fx.admin.id)
  end

  @doc "The id of the tenant-wide TENANT_ADMIN row of one USER principal."
  @spec user_row_id!(map(), Ecto.UUID.t()) :: Ecto.UUID.t()
  def user_row_id!(fx, user_id) do
    Repo.one!(
      from(g in RoleScopeGrant,
        where:
          g.principal_type == :user and g.principal_id == ^user_id and g.role == ^@ta and
            g.tenant_wide == true,
        select: g.id
      ),
      prefix: fx.schema_name
    )
  end

  @doc "The id of the (single) tenant-wide TENANT_ADMIN GROUP row of the TA group."
  @spec group_row_id!(map()) :: Ecto.UUID.t()
  def group_row_id!(fx) do
    Repo.one!(
      from(g in RoleScopeGrant,
        where:
          g.principal_type == :group and g.principal_id == ^fx.ta_group_id and g.role == ^@ta and
            g.tenant_wide == true,
        select: g.id
      ),
      prefix: fx.schema_name
    )
  end

  @doc "Deletes every token of T1 (RAW): the OLD guard then agrees with the interactive count."
  @spec drop_token_owner!(map()) :: :ok
  def drop_token_owner!(fx) do
    Repo.delete_all(from(t in ApiToken, where: t.user_id == ^fx.t1.id), prefix: fx.schema_name)
    :ok
  end

  @doc "Removes every membership of A1 (RAW): zero interactive admins, T1's token still counts."
  @spec at_zero!(map()) :: map()
  def at_zero!(fx) do
    :ok = F.remove_memberships!(fx.schema_name, fx.admin.id)
    assert interactive(fx) == 0
    fx
  end

  @doc "A group with ONE fresh member and NO grant row (the F3 shape of a rebind target)."
  @spec rowless_group_with_member!(map()) ::
          {Letflow.Identity.Group.t(), Letflow.Identity.User.t()}
  def rowless_group_with_member!(fx) do
    group = RSG.fresh_group!(fx.schema_name)
    user = RSG.member!(fx.schema_name, group.id, RSG.user!(fx.schema_name))
    {group, user}
  end

  # --- counts, snapshot, audit -----------------------------------------------------------------

  @doc "The interactive explicit count (the gate's fact 4 counter)."
  @spec interactive(map()) :: non_neg_integer()
  def interactive(fx), do: Identity.count_interactive_explicit_tenant_wide_admins(fx.schema_name)

  @doc "The OLD counted count (what the N1 guard measures)."
  @spec counted(map()) :: non_neg_integer()
  def counted(fx), do: Identity.count_tenant_wide_admins(fx.schema_name)

  @doc "The explicit count (`:explicit` N1 mode)."
  @spec explicit(map()) :: non_neg_integer()
  def explicit(fx), do: Identity.count_explicit_tenant_wide_admins(fx.schema_name)

  @doc "A content snapshot of every identity table (users, groups, memberships, bindings, grants, tokens)."
  @spec snapshot(map()) :: map()
  def snapshot(fx), do: BG.snapshot(fx)

  @doc "Whether the user is a member of the group (RAW read)."
  @spec member?(map(), Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def member?(fx, group_id, user_id) do
    Repo.exists?(
      from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: fx.schema_name
    )
  end

  @doc "Every audit entry id of the tenant schema."
  @spec entry_ids(map()) :: [Ecto.UUID.t()]
  def entry_ids(fx), do: EW.entry_ids(fx.schema_name)

  @doc "The audit entries written since `ids_before`, oldest first."
  @spec new_entries(map(), [Ecto.UUID.t()]) :: [Entry.t()]
  def new_entries(fx, ids_before), do: EW.new_entries(fx.schema_name, ids_before)

  @doc "Every refusal event of the tenant schema."
  @spec refusals(map()) :: [Entry.t()]
  def refusals(fx), do: RSG.entries(fx.schema_name, @event)

  @doc """
  Asserts that the ONLY audit entry written since `ids_before` is one `tenant_admin.guard_refused`
  entry with EXACTLY the six contract keys, the NEW `reason_code`, `counted_admins` 0, the given
  action and target. The guarded change and its own audit entry were rolled back with the
  transaction, so no other entry exists. Returns the entry.
  """
  @spec assert_only_refusal!(map(), [Ecto.UUID.t()], map()) :: Entry.t()
  def assert_only_refusal!(fx, ids_before, %{action: action, target_id: target_id} = expected) do
    assert [entry] = new_entries(fx, ids_before)

    assert entry.action == @event
    assert entry.resource_id == target_id
    assert entry.before_state == nil
    assert entry.after_state |> Map.keys() |> Enum.sort() == @contract_keys
    assert entry.after_state["action"] == action
    assert entry.after_state["target_id"] == target_id
    assert entry.after_state["reason_code"] == @new_code
    assert entry.after_state["counted_admins"] == 0

    if Map.has_key?(expected, :actor), do: assert(entry.after_state["actor"] == expected.actor)
    if Map.has_key?(expected, :trace), do: assert(entry.after_state["trace_id"] == expected.trace)

    entry
  end

  # --- unreadable mode (INV-8) -----------------------------------------------------------------

  @doc """
  Runs `fun` with the tenant schema renamed to a well-formed `tenant_<32 hex>` name that has NO
  `tenants` row and the test-only lenient key UNSET, so `ScopeEnforcement.mode_under_lock!/1`
  RAISES for it (never answers `off`). `fun` receives the fixture with `:schema_name` set to the
  renamed schema AND `:tenant_id` set to the id that schema name encodes, so a router that
  derives its prefix from the `auth_context` tenant id (`TenantProvisioning.schema_name_for_tenant/1`
  is a pure derivation) reaches the SAME renamed schema: every table read works and ONLY the mode
  read fails. (Renaming the schema without moving the tenant id would make the request fail on
  a missing table before the guard, a vacuous 500.) The rename is restored afterwards AND by an
  `on_exit` (a killed test process must not leave a renamed schema behind). Committed DDL: the
  caller is `async: false`.
  """
  @spec with_unreadable_mode(map(), (map() -> term())) :: term()
  def with_unreadable_mode(fx, fun) do
    renamed = "tenant_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {:ok, renamed_tenant_id} = TenantProvisioning.tenant_id_for_schema_name(renamed)

    Repo.query!(~s|ALTER SCHEMA "#{fx.schema_name}" RENAME TO "#{renamed}"|)
    on_exit(fn -> restore(renamed, fx.schema_name) end)

    try do
      F.with_env(:scope_mode_lenient_for_tests, :unset, fn ->
        fun.(%{fx | schema_name: renamed, tenant_id: renamed_tenant_id})
      end)
    after
      restore(renamed, fx.schema_name)
    end
  end

  # Idempotent: renames back only while the renamed schema still exists.
  defp restore(renamed, schema_name) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [renamed])
    if rows != [], do: Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{schema_name}"|)
    :ok
  end

  # --- call options ----------------------------------------------------------------------------

  @doc "The audit context of a function call: T1 is the acting user, the fixed trace id."
  @spec ctx(map()) :: map()
  def ctx(fx), do: %{actor_id: fx.t1.id, trace_id: @trace}

  @doc "Options of a membership / role write."
  @spec opts(map()) :: keyword()
  def opts(fx), do: [prefix: fx.schema_name, audit_context: ctx(fx)]

  @doc "The acting caller of `ScopedGrants` / `ServicePrincipal` functions."
  @spec actor(map()) :: map()
  def actor(fx), do: %{user_id: fx.t1.id, trace_id: @trace, credential: "oidc"}

  @doc "The reason text used by the flagging and rebind calls."
  @spec reason() :: String.t()
  def reason, do: "gh2869 last interactive admin test"
end
