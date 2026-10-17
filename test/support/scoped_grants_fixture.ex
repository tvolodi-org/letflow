defmodule Letflow.Support.ScopedGrantsFixture do
  @moduledoc """
  Test-only helpers shared by the REQ-517 / GH #2535 PR 2a tests (scoped role grant admin
  plane; design `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 6; spec
  `test/specs/REQ-517-2a.md`).

  Everything here builds real state in dedicated `TenantFixture.provisioned_tenant!/1`
  tenants (the sandbox is `:auto` there, writes are committed and cleaned up by the fixture
  teardown) and dispatches requests straight into a router's `call/2` with a hand-assigned
  `auth_context` (the style of the whole router suite), or through the FULL `Letflow.Router`
  pipeline with a real API token.

  Callers are `async: false`: committed writes, DDL (audit fault triggers) and cross-connection
  locks.
  """

  import ExUnit.Assertions
  import Ecto.Query
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @trace "req517-2a-trace-0001"

  @type fixture :: map()

  @doc "The trace id every hand-built request carries."
  @spec trace() :: String.t()
  def trace, do: @trace

  @doc """
  A provisioned tenant with the default platform-role groups seeded and an active
  TENANT_ADMIN group member under `:admin` (a real user, so the tenant-wide gate holds).
  """
  @spec tenant!(String.t()) :: fixture()
  def tenant!(slug_prefix) do
    Fixture.unpin!()
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    Map.put(fx, :admin, TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"]))
  end

  @doc "A hand-assigned `auth_context` for a real user of `fx`."
  @spec ctx(fixture(), Ecto.UUID.t(), [String.t()], :oidc | :api_token) :: map()
  def ctx(fx, user_id, roles, credential) do
    %{user_id: user_id, tenant_id: fx.tenant_id, roles: roles, credential: credential}
  end

  @doc "Dispatches one request into `router` carrying `auth_context`."
  @spec call(module(), atom(), String.t(), fixture(), map(), map() | nil) :: Plug.Conn.t()
  def call(router, method, path, fx, auth_context, body) do
    method
    |> Fixture.router_conn(path, fx, auth_context.roles, body)
    |> assign(:auth_context, auth_context)
    |> assign(:trace_id, @trace)
    |> router.call(router.init([]))
  end

  @doc "The same request as the tenant's interactive TENANT_ADMIN (`fx.admin`)."
  @spec as_admin(module(), atom(), String.t(), fixture(), map() | nil) :: Plug.Conn.t()
  def as_admin(router, method, path, fx, body),
    do: call(router, method, path, fx, ctx(fx, fx.admin.id, ["TENANT_ADMIN"], :oidc), body)

  @doc "The decoded JSON response body."
  @spec body(Plug.Conn.t()) :: term()
  def body(conn), do: Jason.decode!(conn.resp_body)

  @doc """
  The group a default platform role is bound to, with EVERY grant row of (group, role) removed
  RAW: a binding with zero rows, the starting point for a scoped create (what an operator
  reaches by deleting the tenant-wide row first).
  """
  @spec rowless_group!(fixture(), String.t()) :: Ecto.UUID.t()
  def rowless_group!(fx, role) do
    group_id = RSG.group_of!(fx.schema_name, role)
    assert RSG.raw_delete_rows!(fx.schema_name, group_id, role) >= 1
    group_id
  end

  @doc """
  A `:user` scope principal built exactly as `Letflow.Api.Scope.principal_from_conn/1` builds it,
  from the database (roles by membership, grants loaded now), for `Scope.allowed?/3` assertions.
  """
  @spec principal(fixture(), Ecto.UUID.t()) :: Scope.Principal.t()
  def principal(fx, user_id) do
    platform? = PlatformTenant.platform_tenant?(fx.tenant_id)

    %Scope.Principal{
      kind: :user,
      user_id: user_id,
      prefix: fx.schema_name,
      platform_tenant?: platform?,
      roles:
        Authorization.effective_roles(
          Identity.list_effective_role_names(user_id, prefix: fx.schema_name),
          platform?
        ),
      grants: Scope.load_grants(user_id, fx.schema_name)
    }
  end

  @doc "The `grant_view` body for a scoped-row create."
  @spec create_body(:user | :group, Ecto.UUID.t(), String.t(), String.t()) :: map()
  def create_body(type, principal_id, role, node_id) do
    %{
      "principal_type" => Atom.to_string(type),
      "principal_id" => principal_id,
      "role" => role,
      "scope_node_id" => node_id
    }
  end

  @doc "Every `audit_entries` row of one action, oldest first."
  @spec entries(fixture(), String.t()) :: [Letflow.Audit.Entry.t()]
  def entries(fx, action), do: RSG.entries(fx.schema_name, action)

  @doc "Every `tenant_role` row of the tenant."
  @spec bindings(fixture()) :: [TenantRole.t()]
  def bindings(fx), do: Repo.all(from(t in TenantRole), prefix: fx.schema_name)

  # --- audit fault trigger -----------------------------------------------------------------

  @doc """
  Runs `fun` with a trigger that makes the INSERT of an `audit_entries` row whose action equals
  `action` fail (the row it accompanies must roll back with it). Dropped afterwards either way.
  """
  @spec with_audit_fault(fixture(), String.t(), (-> result)) :: result when result: term()
  def with_audit_fault(fx, action, fun) when is_function(fun, 0) do
    schema = fx.schema_name
    name = "req517_audit_fault"

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = '#{action}' THEN | <>
        ~s|RAISE EXCEPTION 'injected audit fault (REQ-517 test)'; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    try do
      fun.()
    after
      Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
      Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    end
  end

  # --- cross-connection locks --------------------------------------------------------------

  @doc """
  A task that holds lock A (`Identity.lock_tenant_admins!/1`) in its own connection until it
  receives `:release` (or 10 s pass), then rolls back. Sends `{:admin_lock_held, prefix}` to
  `parent` once held.
  """
  @spec hold_admin_lock(String.t(), pid()) :: Task.t()
  def hold_admin_lock(prefix, parent) do
    Task.async(fn ->
      Repo.transaction(fn ->
        :ok = Identity.lock_tenant_admins!(prefix)
        send(parent, {:admin_lock_held, prefix})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end

        Repo.rollback(:released)
      end)
    end)
  end

  @doc """
  Bounded poll (at most about 5 s): true once a backend of the CURRENT database waits on a lock
  while running a statement matching `pattern` (the pg_stat_activity of the current database).
  """
  @spec lock_waiter?(String.t()) :: boolean()
  def lock_waiter?(pattern) do
    Enum.reduce_while(1..500, false, fn _attempt, _acc ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
            "AND wait_event_type = 'Lock' AND query ILIKE $1",
          ["%" <> pattern <> "%"]
        )

      if n >= 1 do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  @doc "Stops a still-running task."
  @spec stop_task(Task.t()) :: :ok
  def stop_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  @doc """
  The isolation level of the connection the calling process uses (`SHOW transaction_isolation`),
  asserted `read committed` by the lock-ordering tests (SEC A-4): a REPEATABLE READ default would
  break the lock-then-read argument.
  """
  @spec isolation() :: String.t()
  def isolation do
    %{rows: [[level]]} = Repo.query!("SHOW transaction_isolation")
    level
  end
end
