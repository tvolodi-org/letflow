defmodule Letflow.Support.RoleScopeGrantsFixture do
  @moduledoc """
  Test-only helpers shared by the REQ-497 / GH #2533 PR 1a tests
  (`test/letflow/identity/role_scope_grants_*_test.exs`; design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` section 6; spec
  `test/specs/REQ-497-1a.md`).

  Everything here either READS `role_scope_grants`, or writes it RAW on purpose to build a
  state a writer must react to (a gap, an orphan, a scoped row): the raw writes bypass
  `Letflow.Identity.RoleScopeGrants` exactly as pre-release data or stage-2 data would. The
  fault triggers make the grant write itself fail (design section 6.3, rollback form R2); they
  are installed only in a dedicated `TenantFixture.provisioned_tenant!/1` schema, never in a
  pooled one, and the schema is dropped by the fixture teardown either way.

  Callers are `async: false` (the tenant fixture flips the sandbox to `:auto`; writes are
  committed and cleaned up by the fixture teardown).
  """

  import ExUnit.Assertions
  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.RoleScopeGrant
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  @type row :: {atom(), Ecto.UUID.t(), String.t(), String.t() | nil, boolean()}

  @doc """
  The migration module under test. It lives in `priv/repo/migrations/` and is loaded by
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0`, not compiled into the app, so it is
  named through this function. `Module.concat/2` rather than the literal alias: the compiler's
  type inference sees through a function returning a literal module and would report every call
  on it as an undefined-module warning (fatal under `--warnings-as-errors`).
  """
  @spec migration() :: module()
  def migration, do: Module.concat(Letflow.Repo.Migrations, CreateRoleScopeGrants)

  @doc "The migration's version (the manifest entry)."
  @spec version() :: pos_integer()
  def version, do: 20_261_015_025_331

  @doc "Every grant row of the schema as `{type, principal_id, role, scope_node_id, tenant_wide}`, sorted."
  @spec rows(String.t()) :: [row()]
  def rows(schema) do
    Repo.all(
      from(g in RoleScopeGrant,
        select: {g.principal_type, g.principal_id, g.role, g.scope_node_id, g.tenant_wide}
      ),
      prefix: schema
    )
    |> Enum.sort()
  end

  @doc "The full grant structs of (`:group`, `group_id`), ordered by role then id."
  @spec group_structs(String.t(), Ecto.UUID.t()) :: [RoleScopeGrant.t()]
  def group_structs(schema, group_id) do
    Repo.all(
      from(g in RoleScopeGrant,
        where: g.principal_type == :group and g.principal_id == ^group_id,
        order_by: [g.role, g.id]
      ),
      prefix: schema
    )
  end

  @doc "The tenant-wide group row the backfill/writers produce for one binding."
  @spec tw(Ecto.UUID.t(), String.t()) :: row()
  def tw(group_id, role), do: {:group, group_id, role, nil, true}

  @doc "A scoped group row."
  @spec scoped(Ecto.UUID.t(), String.t(), String.t()) :: row()
  def scoped(group_id, role, node_id), do: {:group, group_id, role, node_id, false}

  @doc "A group, through the shipped get-or-create (no binding)."
  @spec group!(String.t(), String.t()) :: Group.t()
  def group!(schema, name) do
    {:ok, %Group{} = group} = RoleRegistry.get_or_create_group_by_name(name, prefix: schema)
    group
  end

  @doc "A group with a unique name."
  @spec fresh_group!(String.t()) :: Group.t()
  def fresh_group!(schema), do: group!(schema, "rsg-g-#{System.unique_integer([:positive])}")

  @doc """
  A `tenant_role` row inserted RAW (no writer, so no grant row): simulates pre-release data or a
  binding written by a pre-release node.
  """
  @spec raw_binding!(String.t(), String.t(), atom(), Ecto.UUID.t()) :: TenantRole.t()
  def raw_binding!(schema, name, kind, group_id) do
    %TenantRole{}
    |> TenantRole.changeset(%{name: name, kind: kind, group_id: group_id})
    |> Repo.insert!(prefix: schema)
  end

  @doc "A tenant-wide group row inserted RAW (bypassing the writers)."
  @spec raw_tenant_wide_row!(String.t(), Ecto.UUID.t(), String.t()) :: :ok
  def raw_tenant_wide_row!(schema, group_id, role),
    do: raw_row!(schema, group_id, role, nil, true)

  @doc "A scoped group row inserted RAW (stage-2 data; no route writes one in 1a)."
  @spec raw_scoped_row!(String.t(), Ecto.UUID.t(), String.t(), String.t()) :: :ok
  def raw_scoped_row!(schema, group_id, role, node_id),
    do: raw_row!(schema, group_id, role, node_id, false)

  @doc """
  A USER row inserted RAW (REQ-497 PR 1b tests; stage-2 data, no route writes one):
  tenant-wide when `node_id` is nil, scoped to `node_id` otherwise.
  """
  @spec raw_user_row!(String.t(), Ecto.UUID.t(), String.t(), String.t() | nil) :: :ok
  def raw_user_row!(schema, user_id, role, node_id),
    do: insert_raw_row!(schema, :user, user_id, role, node_id, is_nil(node_id))

  @doc """
  REQ-497 PR 1b tests: replaces every row of (`:group`, `group_id`, `role`) by ONE scoped row on
  a fresh root node, i.e. the group holds `role` only at that node. Returns the node id.
  """
  @spec make_group_scoped_only!(String.t(), Ecto.UUID.t(), String.t()) :: String.t()
  def make_group_scoped_only!(schema, group_id, role) do
    node_id = node!(schema)
    _deleted = raw_delete_rows!(schema, group_id, role)
    :ok = raw_scoped_row!(schema, group_id, role, node_id)
    node_id
  end

  defp raw_row!(schema, group_id, role, node_id, tenant_wide),
    do: insert_raw_row!(schema, :group, group_id, role, node_id, tenant_wide)

  defp insert_raw_row!(schema, principal_type, principal_id, role, node_id, tenant_wide) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        RoleScopeGrant,
        [
          %{
            id: Ecto.UUID.generate(),
            principal_type: principal_type,
            principal_id: principal_id,
            role: role,
            scope_node_id: node_id,
            tenant_wide: tenant_wide,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: schema
      )

    :ok
  end

  @doc "Deletes every row of (`:group`, `group_id`, `role`) RAW; returns the count."
  @spec raw_delete_rows!(String.t(), Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def raw_delete_rows!(schema, group_id, role) do
    {n, _} =
      Repo.delete_all(
        from(g in RoleScopeGrant,
          where: g.principal_type == :group and g.principal_id == ^group_id and g.role == ^role
        ),
        prefix: schema
      )

    n
  end

  @doc "A root `org_unit` node, created through the sole writer `ScopeNodePaths.write/2`."
  @spec node!(String.t()) :: String.t()
  def node!(schema) do
    id = "rsg-node-#{System.unique_integer([:positive])}"
    {:ok, _node} = ScopeNodePaths.write({:insert, id, nil}, schema)
    id
  end

  @doc "A plain internal user row."
  @spec user!(String.t()) :: User.t()
  def user!(schema) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "rsg-user-#{n}",
      display_name: "RSG User #{n}",
      email: "rsg-user-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  @doc "A membership inserted RAW."
  @spec member!(String.t(), Ecto.UUID.t(), User.t()) :: User.t()
  def member!(schema, group_id, user) do
    Repo.insert!(%GroupMember{group_id: group_id, user_id: user.id}, prefix: schema)
    user
  end

  @doc "The group id the binding named `name` points to (raises when there is none)."
  @spec group_of!(String.t(), String.t()) :: Ecto.UUID.t()
  def group_of!(schema, name) do
    Repo.one!(from(t in TenantRole, where: t.name == ^name, select: t.group_id), prefix: schema)
  end

  @doc "The binding named `name`, or nil."
  @spec binding(String.t(), String.t()) :: TenantRole.t() | nil
  def binding(schema, name),
    do: Repo.one(from(t in TenantRole, where: t.name == ^name), prefix: schema)

  @doc "Audit entries of one action, oldest first."
  @spec entries(String.t(), String.t()) :: [Entry.t()]
  def entries(schema, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp), prefix: schema)
  end

  @doc "`to_regclass` of `schema.name` as text, nil when absent."
  @spec regclass(String.t(), String.t()) :: String.t() | nil
  def regclass(schema, name) do
    %{rows: [[value]]} = Repo.query!("SELECT to_regclass($1)::text", [~s|"#{schema}".#{name}|])
    value
  end

  @doc "Runs the migration under test in one direction on the tenant schema."
  @spec migrate!(String.t(), :up | :down) :: [pos_integer()]
  def migrate!(schema, direction) do
    Ecto.Migrator.run(Repo, [{version(), migration()}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  @doc """
  The design's `assert_t9_zero!/1` (section 6): no `:platform_role` binding without a row, and no
  user row.
  """
  @spec assert_t9_zero!(String.t()) :: :ok
  def assert_t9_zero!(schema) do
    assert RoleScopeGrants.bindings_without_row(schema) == []
    assert RoleScopeGrants.bindings_without_row_count(schema) == 0
    assert RoleScopeGrants.user_row_count(schema) == 0
    :ok
  end

  @doc """
  Installs a `BEFORE <op> ON role_scope_grants FOR EACH ROW` trigger that always raises, so the
  grant write itself fails (R2). `op` is `"INSERT"`, `"UPDATE"` or `"DELETE"`. Returns the
  trigger name for `drop_fault_trigger!/2`.
  """
  @spec install_fault_trigger!(String.t(), String.t()) :: String.t()
  def install_fault_trigger!(schema, op) when op in ["INSERT", "UPDATE", "DELETE"] do
    name = "rsg_fault_#{String.downcase(op)}"

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN RAISE EXCEPTION 'injected grant-write fault (REQ-497 test)'; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE #{op} ON "#{schema}".role_scope_grants | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    name
  end

  @doc "Drops a trigger installed by `install_fault_trigger!/2`."
  @spec drop_fault_trigger!(String.t(), String.t()) :: :ok
  def drop_fault_trigger!(schema, name) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".role_scope_grants|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    :ok
  end
end
