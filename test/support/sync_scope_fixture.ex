defmodule Letflow.Support.SyncScopeFixture do
  @moduledoc """
  Test support for REQ-519 slice 2e-b (GH #2535; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3.8, 3.9, 3.9a and 8.2;
  spec `test/specs/REQ-519-2e-b.md`): platform-role groups built RAW (a binding plus the grant
  rows the test wants, so a group can be tenant-wide, scoped or row-less in an `on` tenant, which
  no writer can produce any more), an `IdentityContext` carrying claimed roles, one call of the
  IdP sync, and small readers (memberships, marker, audit entries).

  Built on `Letflow.Support.EnforcedWritersFixture` (provisioned tenants stored in a given mode)
  and `Letflow.Support.RoleScopeGrantsFixture` (raw rows, nodes, users). The tenant fixture
  leaves the sandbox in `:auto` mode, so every caller is `async: false`. Nothing here is
  compiled outside `:test`.
  """

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @trace "req519-2eb-trace-0001"
  @realm "req519-2eb-realm"

  @type row_spec :: :tenant_wide | {:node, String.t()}

  @doc "The trace id the sync helper assigns."
  @spec trace() :: String.t()
  def trace, do: @trace

  @doc "The realm string every claims context carries (a claim value no audit entry may hold)."
  @spec realm() :: String.t()
  def realm, do: @realm

  @doc "The identity context a token carrying `roles` produces (all enforced keys)."
  @spec claims([String.t()]) :: IdentityContext.t()
  def claims(roles) do
    sub = "sub-req519-" <> Ecto.UUID.generate()

    %IdentityContext{
      external_user_id: sub,
      tenant_id: nil,
      realm: @realm,
      roles: roles,
      email: sub <> "@claims.example.com",
      preferred_username: "claimed-" <> sub,
      display_name: "Claimed Display " <> sub,
      email_verified: true
    }
  end

  @doc "One run of the typed sync for `user` with `roles` claimed, under the fixed trace id."
  @spec sync(String.t(), User.t(), [String.t()]) ::
          {:ok, User.t()} | {:suppressed, User.t(), map()}
  def sync(schema, %User{} = user, roles) do
    Identity.sync_role_claims_report(user, claims(roles),
      prefix: schema,
      audit_context: %{trace_id: @trace}
    )
  end

  @doc "The user (struct) of either result shape of the typed sync."
  @spec result_user({:ok, User.t()} | {:suppressed, User.t(), map()}) :: User.t()
  def result_user({:ok, %User{} = user}), do: user
  def result_user({:suppressed, %User{} = user, _summary}), do: user

  @doc """
  A fresh group bound as the PLATFORM role `role` (raw binding), with one raw group row per
  entry of `rows`: `:tenant_wide` or `{:node, node_id}`. An empty `rows` is a row-less binding.
  """
  @spec platform_group!(String.t(), String.t(), [row_spec()]) :: Group.t()
  def platform_group!(schema, role, rows) do
    group = RSG.fresh_group!(schema)
    _binding = RSG.raw_binding!(schema, role, :platform_role, group.id)
    add_rows!(schema, group.id, role, rows)
    group
  end

  @doc """
  Binds `role` as a PLATFORM role to an EXISTING group (a second binding of the same group),
  with the given raw group rows.
  """
  @spec bind_platform!(String.t(), Group.t(), String.t(), [row_spec()]) :: Group.t()
  def bind_platform!(schema, %Group{} = group, role, rows) do
    _binding = RSG.raw_binding!(schema, role, :platform_role, group.id)
    add_rows!(schema, group.id, role, rows)
    group
  end

  @doc "Binds `role` as a PROCESS-ROUTING role to an existing group, with the given raw rows."
  @spec bind_routing!(String.t(), Group.t(), String.t(), [row_spec()]) :: Group.t()
  def bind_routing!(schema, %Group{} = group, role, rows) do
    _binding = RSG.raw_binding!(schema, role, :process_routing_role, group.id)
    add_rows!(schema, group.id, role, rows)
    group
  end

  defp add_rows!(schema, group_id, role, rows) do
    Enum.each(rows, fn
      :tenant_wide -> :ok = RSG.raw_tenant_wide_row!(schema, group_id, role)
      {:node, node_id} -> :ok = RSG.raw_scoped_row!(schema, group_id, role, node_id)
    end)
  end

  @doc "The group ids the user is a member of, sorted."
  @spec memberships(String.t(), Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def memberships(schema, user_id) do
    Repo.all(from(m in GroupMember, where: m.user_id == ^user_id, select: m.group_id),
      prefix: schema
    )
    |> Enum.sort()
  end

  @doc "The user's `role_claims_synced_at` marker, read from the table."
  @spec marker(String.t(), Ecto.UUID.t()) :: DateTime.t() | nil
  def marker(schema, user_id), do: Repo.get!(User, user_id, prefix: schema).role_claims_synced_at

  @doc "Every audit entry of the schema, oldest first."
  @spec all_entries(String.t()) :: [Entry.t()]
  def all_entries(schema),
    do: Repo.all(from(e in Entry, order_by: [e.timestamp, e.id]), prefix: schema)

  @doc "The sorted key list of an entry's `after_state`."
  @spec after_keys(Entry.t()) :: [String.t()]
  def after_keys(%Entry{after_state: after_state}), do: after_state |> Map.keys() |> Enum.sort()

  @doc """
  Runs `fun` with the test-only application key `:scope_mode_lenient_for_tests` set to `value`
  (`:unset` removes it), restoring the original afterwards.
  """
  @spec with_lenient_key(true | false | :unset, (-> term())) :: term()
  def with_lenient_key(value, fun) do
    key = :scope_mode_lenient_for_tests
    original = Application.fetch_env(:letflow, key)

    case value do
      :unset -> Application.delete_env(:letflow, key)
      other -> Application.put_env(:letflow, key, other)
    end

    try do
      fun.()
    after
      case original do
        {:ok, v} -> Application.put_env(:letflow, key, v)
        :error -> Application.delete_env(:letflow, key)
      end
    end
  end

  @doc """
  Renames the fixture schema to a well-formed name that has NO `tenants` row (committed DDL,
  restored afterwards), so the mode read answers "unregistered" and raises when the lenient key
  is unset. `fun` receives the renamed prefix.
  """
  @spec with_unregistered_schema(String.t(), (String.t() -> term())) :: term()
  def with_unregistered_schema(schema, fun) do
    renamed = "tenant_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    Repo.query!(~s|ALTER SCHEMA "#{schema}" RENAME TO "#{renamed}"|)

    try do
      fun.(renamed)
    after
      Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{schema}"|)
    end
  end

  @doc """
  A `BEFORE INSERT` trigger on the schema's `audit_entries` that raises when `condition` (SQL
  over `NEW`) holds. Returns the trigger and function name for `drop_audit_fault!/2`.
  """
  @spec create_audit_fault!(String.t(), String.t(), String.t()) :: String.t()
  def create_audit_fault!(schema, name, condition) do
    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF #{condition} THEN RAISE EXCEPTION 'injected fault (REQ-519 2e-b test)'; END IF; | <>
        ~s|RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    name
  end

  @doc "Drops a trigger installed by `create_audit_fault!/3`."
  @spec drop_audit_fault!(String.t(), String.t()) :: :ok
  def drop_audit_fault!(schema, name) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    :ok
  end
end
