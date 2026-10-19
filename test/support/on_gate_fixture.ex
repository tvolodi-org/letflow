defmodule Letflow.Support.OnGateFixture do
  @moduledoc """
  Test support for REQ-519 slice 2f-a (GH #2535; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.4 to 4.6 and 8.3; spec
  `test/specs/REQ-519-2f-a.md`): provisioned tenants for the `on` gate, built so that every fact
  can be satisfied or broken on its own.

    * `admin_tenant!/1` -- a tenant with one active, interactive, explicit tenant-wide
      `TENANT_ADMIN` (binding, group row and membership: facts 1 to 5 hold);
    * `shadow_tenant!/1` -- the same tenant flipped `off -> shadow` through the REAL
      `ScopeEnforcement.flip/4`, so the shadow start `t0` is a genuine audit entry (server
      assigned timestamp, a valid chain). `now` is `t0` plus seven days exactly, the default
      `min_days`, so no test reads the wall clock for a boundary;
    * `satisfy!/2` -- persisted `requests` counters on every date of the window, so fact 6
      holds at the given `now`;
    * raw helpers for the audit chain, the counters, tokens and an inconsistent scope tree.

  The tenant fixture leaves the sandbox in `:auto` mode (real commits, cleaned up by the fixture
  teardown), so every caller is `async: false`. Nothing here is compiled outside `:test`.
  """

  import Ecto.Query
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.Api.Scope.ShadowEvidence.Counter
  alias Letflow.Audit.Entry
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.SyncScopeFixture
  alias Letflow.Support.TokenMintFixture
  alias Letflow.ScopeEnforcement
  alias Letflow.TenantFixture

  @trace "req519-2fa-trace-0001"
  @day_seconds 86_400
  @default_min_days 7
  @flip_actions ["scope.enforcement_enabled", "scope.enforcement_disabled"]

  @doc "The trace id the helpers assign."
  @spec trace() :: String.t()
  def trace, do: @trace

  @doc "Seconds in one UTC day."
  @spec day_seconds() :: pos_integer()
  def day_seconds, do: @day_seconds

  @doc """
  A provisioned tenant (platform pin cleared) with one tenant-wide `TENANT_ADMIN` member under
  the key `:admin`. Mode `off`.
  """
  @spec admin_tenant!(String.t()) :: map()
  def admin_tenant!(slug_prefix) do
    PlatformTenantFixture.unpin!()
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    Map.put(fx, :admin, TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"]))
  end

  @doc "The flip attrs of the tenant's admin with the given reason."
  @spec attrs(map(), term()) :: map()
  def attrs(fx, reason), do: %{actor_id: fx.admin.id, reason: reason, trace_id: @trace}

  @doc """
  `admin_tenant!/1` flipped `off -> shadow` through the real flip. Adds `:t0` (the timestamp of
  the genuine `scope.enforcement_enabled` entry) and `:now` (`t0` + 7 days exactly).
  """
  @spec shadow_tenant!(String.t()) :: map()
  def shadow_tenant!(slug_prefix) do
    fx = admin_tenant!(slug_prefix)
    flip!(fx, :shadow, nil)
    t0 = latest_flip_entry!(fx).timestamp

    fx
    |> Map.put(:t0, t0)
    |> Map.put(:now, after_days(t0, @default_min_days))
  end

  @doc "A real flip that must succeed with a change."
  @spec flip!(map(), :off | :shadow, term()) :: map()
  def flip!(fx, target, reason) do
    {:ok, %{mode: ^target, changed: true} = result} =
      ScopeEnforcement.flip(fx.tenant_id, fx.schema_name, target, attrs(fx, reason))

    result
  end

  @doc "`instant` plus `days` whole days."
  @spec after_days(DateTime.t(), integer()) :: DateTime.t()
  def after_days(%DateTime{} = instant, days),
    do: DateTime.add(instant, days * @day_seconds, :second)

  @doc "The latest `scope.enforcement_enabled|disabled` audit entry of the tenant."
  @spec latest_flip_entry!(map()) :: Entry.t()
  def latest_flip_entry!(fx) do
    tenant_id = fx.tenant_id

    Repo.one!(
      from(e in Entry,
        where:
          e.resource_type == "tenant" and e.resource_id == ^tenant_id and
            e.action in ^@flip_actions,
        order_by: [desc: e.timestamp, desc: e.id],
        limit: 1
      ),
      prefix: fx.schema_name
    )
  end

  @doc "Every audit entry of one action, oldest first."
  @spec entries(map(), String.t()) :: [Entry.t()]
  def entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: [e.timestamp, e.id]),
      prefix: fx.schema_name
    )
  end

  @doc "The UTC dates of the window `date(now) - min_days .. date(now)`, inclusive."
  @spec window_dates(DateTime.t(), pos_integer()) :: Date.Range.t()
  def window_dates(%DateTime{} = now, min_days) do
    today = DateTime.to_date(now)
    Date.range(Date.add(today, -min_days), today)
  end

  @doc "Upserts one persisted shadow counter row (day, metric) of the tenant."
  @spec put_count!(map(), Date.t(), atom(), non_neg_integer()) :: :ok
  def put_count!(fx, %Date{} = day, metric, count) when is_atom(metric) do
    {1, _} =
      Repo.insert_all(
        Counter,
        [
          %{
            day: day,
            metric: Atom.to_string(metric),
            count: count,
            updated_at: DateTime.utc_now()
          }
        ],
        prefix: fx.schema_name,
        on_conflict: {:replace, [:count]},
        conflict_target: [:day, :metric]
      )

    :ok
  end

  @doc "`per_day` persisted `requests` on every date of the window of `now` / `min_days`."
  @spec seed_requests!(map(), DateTime.t(), pos_integer(), non_neg_integer()) :: :ok
  def seed_requests!(fx, now, min_days, per_day) do
    for day <- window_dates(now, min_days), do: :ok = put_count!(fx, day, :requests, per_day)
    :ok
  end

  @doc "Fact 6 satisfied at `now` with the default 7 day window (20 requests per date)."
  @spec satisfy!(map(), DateTime.t()) :: :ok
  def satisfy!(fx, now), do: seed_requests!(fx, now, @default_min_days, 20)

  @doc """
  A RAW audit entry (synthetic chain hashes, so never combine with `Audit.verify_chain/1`).
  `attrs` needs `:action`, `:resource_type`, `:resource_id`, `:timestamp`, `:after_state`;
  an optional `:id` fixes the row id (tie-break tests).
  """
  @spec raw_entry!(map(), map()) :: Ecto.UUID.t()
  def raw_entry!(fx, attrs) do
    n = System.unique_integer([:positive])
    id = Map.get(attrs, :id, Ecto.UUID.generate())

    row = %{
      id: id,
      tenant_id: fx.tenant_id,
      actor_id: nil,
      action: attrs.action,
      resource_type: attrs.resource_type,
      resource_id: attrs.resource_id,
      timestamp: attrs.timestamp,
      before_state: nil,
      after_state: attrs.after_state,
      trace_id: nil,
      chain_hash: "req519-2fa-synthetic-#{n}",
      prev_chain_hash: "req519-2fa-synthetic-prev-#{n}",
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    {1, _} = Repo.insert_all(Entry, [row], prefix: fx.schema_name)
    id
  end

  @doc "A RAW token with the given roles (no plaintext is needed by the gate)."
  @spec raw_token!(String.t(), Ecto.UUID.t(), [String.t()], Ecto.UUID.t()) :: ApiToken.t()
  def raw_token!(schema, owner_id, roles, issuer_id) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      %ApiToken{
        user_id: owner_id,
        name: "req519-2fa-#{n}",
        token_hash: Base.encode16(:crypto.hash(:sha256, "req519-2fa-#{n}"), case: :lower),
        roles: roles,
        issuer_user_id: issuer_id,
        expires_at: nil
      },
      prefix: schema
    )
  end

  @doc "An orphan scope node (its parent segment has no row): the tree becomes `:inconsistent`."
  @spec seed_orphan_node!(String.t()) :: :ok
  def seed_orphan_node!(schema) do
    now = NaiveDateTime.utc_now()

    {2, _} =
      Repo.insert_all(
        "scope_node_paths",
        [
          %{node_id: "r", path: "/r/", depth: 1, inserted_at: now, updated_at: now},
          %{node_id: "o", path: "/ghost/o/", depth: 2, inserted_at: now, updated_at: now}
        ],
        prefix: schema
      )

    :ok
  end

  @doc "Removes every group membership of the user (RAW)."
  @spec remove_memberships!(String.t(), Ecto.UUID.t()) :: :ok
  def remove_memberships!(schema, user_id) do
    {_n, _} =
      Repo.delete_all(from(m in GroupMember, where: m.user_id == ^user_id), prefix: schema)

    :ok
  end

  @doc "Sets the admin-flagged service-principal marker of the user."
  @spec flag_service_principal!(String.t(), Ecto.UUID.t()) :: :ok
  def flag_service_principal!(schema, user_id) do
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user_id),
        [set: [admin_flagged_service_principal: true]],
        prefix: schema
      )

    :ok
  end

  @doc "Sets the status of the user."
  @spec set_status!(String.t(), Ecto.UUID.t(), :active | :inactive) :: :ok
  def set_status!(schema, user_id, status) do
    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^user_id), [set: [status: status]],
        prefix: schema
      )

    :ok
  end

  @doc """
  An active user who holds `TASK_WORKER` ONLY through a scoped group row, and, when `routed?`,
  is a member of a group bound as a PROCESS-ROUTING role. The first call in a tenant creates the
  `TASK_WORKER` binding with one scoped row on a fresh node; later calls join the SAME group
  (a role name is bound once per tenant), so every worker of a tenant shares that scope.
  Returns `%{user, group, routing}` (`routing` is nil when not routed).
  """
  @spec scoped_task_worker!(String.t(), boolean()) :: map()
  def scoped_task_worker!(schema, routed?) do
    group =
      case RSG.binding(schema, "TASK_WORKER") do
        nil ->
          node = RSG.node!(schema)
          SyncScopeFixture.platform_group!(schema, "TASK_WORKER", [{:node, node}])

        %{group_id: group_id} ->
          Repo.get!(Group, group_id, prefix: schema)
      end

    user = RSG.member!(schema, group.id, RSG.user!(schema))
    routing = if routed?, do: route!(schema, user), else: nil
    %{user: user, group: group, routing: routing}
  end

  @doc "Makes the user a member of a fresh group bound as a process-routing role; returns the group."
  @spec route!(String.t(), User.t()) :: Group.t()
  def route!(schema, %User{} = user) do
    routing = RSG.fresh_group!(schema)
    name = "GATE_ROUTE_#{System.unique_integer([:positive])}"
    _bound = SyncScopeFixture.bind_routing!(schema, routing, name, [])
    _member = RSG.member!(schema, routing.id, user)
    routing
  end

  @doc """
  Runs `fun` with the application key set to `value` (`:unset` removes it) and restores the
  original afterwards.
  """
  @spec with_env(atom(), term(), (-> term())) :: term()
  def with_env(key, value, fun) do
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
  Renames the tenant schema to a name that is NOT `tenant_<32 hex>` (committed DDL, restored
  afterwards) so a read that validates the prefix raises while every table read still works.
  `fun` receives the renamed schema.
  """
  @spec with_plain_schema(map(), (String.t() -> term())) :: term()
  def with_plain_schema(fx, fun) do
    plain = "req519_plain_#{System.unique_integer([:positive])}"
    Repo.query!(~s|ALTER SCHEMA "#{fx.schema_name}" RENAME TO "#{plain}"|)

    # `on_exit` runs even when the test process is killed (an ExUnit timeout), where the `after`
    # below does not, and it runs BEFORE the tenant teardown (which drops the schema by its
    # original name), so a killed test cannot leave a renamed schema behind.
    on_exit(fn -> restore_schema(plain, fx.schema_name) end)

    try do
      fun.(plain)
    after
      restore_schema(plain, fx.schema_name)
    end
  end

  # Idempotent: renames `plain` back only while it still exists under that name.
  defp restore_schema(plain, schema_name) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [plain])
    if rows != [], do: Repo.query!(~s|ALTER SCHEMA "#{plain}" RENAME TO "#{schema_name}"|)
    :ok
  end

  @doc """
  Renames the tenant table `table` (COMMITTED DDL, restored in an `after`) and runs `fun`, which
  is expected to raise on its next read of it. A committed rename, not one inside a transaction:
  inside a transaction the failed statement would abort the transaction and every LATER read
  would raise too, so a mutant that swallowed the first raise could not be told apart.
  """
  @spec with_renamed_table!(map(), String.t(), (-> term())) :: :ok
  def with_renamed_table!(fx, table, fun) do
    renamed = "#{table}_req519_renamed"
    Repo.query!(~s|ALTER TABLE "#{fx.schema_name}".#{table} RENAME TO #{renamed}|)

    # see with_plain_schema/2: restored by `on_exit` too, for a killed test process
    on_exit(fn -> restore_table(fx.schema_name, renamed, table) end)

    try do
      fun.()
    after
      restore_table(fx.schema_name, renamed, table)
    end

    :ok
  end

  # Idempotent: `IF EXISTS`, so a table that is already restored (or a schema already dropped)
  # is a no-op.
  defp restore_table(schema_name, renamed, table) do
    Repo.query!(~s|ALTER TABLE IF EXISTS "#{schema_name}".#{renamed} RENAME TO #{table}|)
    :ok
  end

  @doc """
  Returns `value` unchanged through the process dictionary, so the compiler's type checker
  cannot see through it: used to pass a deliberately WRONG argument to a function whose head
  must reject it, without a compile-time type warning.
  """
  @spec opaque(term()) :: term()
  def opaque(value) do
    Process.put(:req519_2fa_opaque, value)
    Process.get(:req519_2fa_opaque)
  end

  @doc "The log lines of `log` that contain `marker`."
  @spec lines_with(String.t(), String.t()) :: [String.t()]
  def lines_with(log, marker) do
    log |> String.split("\n") |> Enum.filter(&String.contains?(&1, marker))
  end

  @doc "True when `text` contains something shaped like a UUID."
  @spec uuid_in?(String.t()) :: boolean()
  def uuid_in?(text),
    do: Regex.match?(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, text)
end
