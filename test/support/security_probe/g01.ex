defmodule Letflow.SecurityProbe.G01 do
  @moduledoc """
  G-01 of the team repo's `docs/security-coverage.md` §4: the generated
  **real-HTTP route x role x tenant x request-shape matrix** (class table:
  `docs/security-probes/G-01.md`).

  Every case is generated, none is listed by hand:

    * **routes** -- `Letflow.Support.RouteInventory.routes/0`: every
      `{method, path, policy key}` of every router mounted by
      `Letflow.Plugs.ApiPipeline` and of every catalogue module router. The
      oracle covers the core routes and the routes of every module the
      golden's `# modules:` header names (`matrix_routes/0`); the rest are
      test-only / QA-only modules (`excluded_routes/0`, pinned by a test);
    * **roles** -- `Letflow.Api.Authorization.roles/0`;
    * **expected decision** -- the committed permission golden
      `priv/permission_matrix/effective.golden` (role x permission), read
      through `Letflow.Api.Authorization.required_permission/1` (policy key
      -> permission), the platform rule (a platform-scope permission, and any
      grant of `PLATFORM_ADMIN`, needs the configured platform tenant) and the
      tenant's stored grant overlay (`Letflow.Api.TenantGrants.load/1`);
    * **callers** -- one real API token per role in an ordinary tenant A, and
      the platform tenant P's `PLATFORM_ADMIN` with and without the platform
      pin, every request through the FULL `Letflow.Router` pipeline (bearer
      token, `x-tenant-slug`);
    * **request shapes** -- `:missing`: a nonexistent id in every path
      parameter; `{:foreign, table}`: the same request with a real id of a
      populated foreign tenant B (one per table of B that has rows), for the
      first A caller the oracle allows; `{:own, table}`: every mutating route
      with a parameter again with a real id of the company tenant A itself
      (the write path on a real record; A's `process_definitions` id is a
      draft). Every mutating verb carries one privileged body
      (`privileged_body/1`): the definition and instance-start write shapes
      with a `platform_call` graph, and attributes that name B.

  The probe has an OBSERVE half (`observe/2`: send the generated requests and
  record status, content type, body and the tables each request wrote) and a
  CHECK half (`violations/2`: pure functions over the observations). The
  real-tree test and the seeded rogue router
  (`Letflow.SecurityProbe.G01RogueRouter`) go through the SAME two entry
  points, so a rule that is dropped or neutered fails the rogue test.

  Rules (the class-table ids):

    * `:M1` -- a caller the oracle denies gets the canonical authorization
      denial (status, content type and body bytes, `trace_id` removed): the
      403 "insufficient permissions", or for a concealed policy key
      (`Letflow.Plugs.Authorize`'s `@concealed_keys`, GH 2548, REQ-561) the
      plain 404 of a missing resource;
    * `:M2` -- a denied request writes nothing (any schema of A, B, P or
      `public`), except the caller's own `api_tokens` row (`last_used_at`);
    * `:M3` -- a caller the oracle allows is given the canonical denial (an
      over-denial: a second gate narrows the golden). Reported, and pinned
      by the ratchet file, never silently accepted;
    * `:M4` -- for an allowed caller, the answer for each of B's ids is
      byte-identical to the answer for the nonexistent id (status, content
      type, body with the id replaced by a placeholder): A learns nothing
      about B (INV-1, INV-5);
    * `:M5` -- no request of an A caller writes a row of B;
    * `:M6` -- no answer to an A caller carries one of B's ids, its slug or
      its schema name;
    * `:M7` -- no generated request crashes the pipeline or answers 5xx;
    * `:M8` -- no request of an A caller leaves a row of A (outside
      `api_tokens` and `audit_entries`) holding the privileged body's
      `platform_call` marker: a company tenant never stores a platform call
      (T-2588).

  Each request runs in a transaction that is always rolled back, so every
  request sees the same starting state (no order dependence) and nothing a
  request writes survives it.
  """

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  alias Letflow.Api.Authorization
  alias Letflow.Repo
  alias Letflow.Support.RouteInventory

  @golden_path "priv/permission_matrix/effective.golden"
  @ratchet_path "test/fixtures/security_probes/g01/ratchet.txt"
  @missing_id "00000000-0000-4000-8000-0000000000a1"
  @placeholder "<ID>"
  @marker "g01-platform-call-marker"

  @doc "The nonexistent id of the `:missing` shape."
  def missing_id, do: @missing_id

  @doc "The committed ratchet file (known findings and over-denials)."
  def ratchet_path, do: @ratchet_path

  # --- Inventory ------------------------------------------------------------

  @doc "Every mounted route, `%{method, path, key, router}`, sorted (no discovery-order dependence)."
  def routes do
    RouteInventory.routes()
    |> Enum.map(&Map.take(&1, [:method, :path, :key, :router]))
    |> Enum.sort_by(&{&1.path, &1.method})
  end

  @doc "The routes the golden is the oracle for: the core routes and the golden modules' routes."
  def matrix_routes, do: Enum.filter(routes(), &golden_route?(&1, golden_modules()))

  @shard_count 4

  @doc """
  The number of shard files the real-tree matrix is cut into (each one a
  tagged probe file, `test/letflow/security_probe/g01_matrix_shard_<i>_test.exs`).
  """
  def shard_count, do: @shard_count

  @doc "The matrix routes of shard `index`: those whose index in `matrix_routes/0` is `index` mod `shard_count/0`."
  def shard_routes(index) when is_integer(index) and index >= 0 and index < @shard_count do
    for {route, i} <- Enum.with_index(matrix_routes()), rem(i, @shard_count) == index, do: route
  end

  @doc "The routes outside the golden (test-only / QA-only modules that `config/test.exs` appends)."
  def excluded_routes, do: Enum.reject(routes(), &golden_route?(&1, golden_modules()))

  @doc "The module id of a module route, `nil` for a core route."
  def module_id("/modules/" <> rest), do: rest |> String.split("/") |> hd()
  def module_id(_path), do: nil

  defp golden_route?(route, modules) do
    case module_id(route.path) do
      nil -> true
      id -> id in modules
    end
  end

  @doc "The module ids the golden was generated for (its `# modules:` header)."
  def golden_modules do
    [header] = golden_lines() |> Enum.filter(&String.starts_with?(&1, "# modules: "))

    header
    |> String.replace_prefix("# modules: ", "")
    |> String.split(",", trim: true)
    |> Enum.map(fn pair -> pair |> String.split("@") |> hd() end)
  end

  @doc "The golden as a map `{role_string, permission_string} => boolean`."
  def golden do
    golden_lines()
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Map.new(fn line ->
      [role, permission, allowed | _rest] = String.split(line, " ")
      {{role, permission}, allowed == "true"}
    end)
  end

  defp golden_lines, do: @golden_path |> File.read!() |> String.split(["\r\n", "\n"], trim: true)

  @doc """
  The oracle: `:allow` or `:deny` for a caller holding `role` (a string) in a
  tenant that is (`platform?`) or is not the configured platform tenant, with
  the tenant's grant `overlay` (`%{role_atom => [permission]}`), on a route
  with policy key `key`. Raises when the golden has no row for the role and
  the key's permission: an unknown permission is a completeness failure.
  """
  def expected(golden, overlay, role, platform?, key) do
    permission = Authorization.required_permission(key)
    granted = overlay |> Map.get(String.to_existing_atom(role), []) |> Enum.member?(permission)

    cond do
      # Role-agnostic grants (`Authorization.evaluate_access/2`).
      key in [:MetricsRead, :MyAccessRead] ->
        :allow

      role == "PLATFORM_ADMIN" and not platform? ->
        :deny

      Authorization.permission_scope(permission) == :platform and
          not (role == "PLATFORM_ADMIN" and platform?) ->
        :deny

      granted ->
        :allow

      true ->
        case Map.fetch(golden, {role, Atom.to_string(permission)}) do
          {:ok, true} -> :allow
          {:ok, false} -> :deny
          :error -> raise "G-01: the golden has no row #{role} #{permission} (key #{key})"
        end
    end
  end

  @authorize_path "lib/letflow/plugs/authorize.ex"

  @doc """
  The policy keys `Letflow.Plugs.Authorize` denies with the plain 404 instead
  of the 403 (its `@concealed_keys`), read from the plug's source so a key
  added there is picked up without a change here.
  """
  def concealed_keys do
    [_all, list] = Regex.run(~r/@concealed_keys\s+\[([^\]]*)\]/, File.read!(@authorize_path))

    list
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":") |> String.to_existing_atom()))
  end

  @doc "`path` with every `:param` / `*glob` segment replaced by `id`."
  def concrete_path(path, id) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> id
      "*" <> _glob -> id
      segment -> segment
    end)
  end

  @doc "Whether `path` has a parameter segment."
  def param_route?(path), do: path |> String.split("/") |> Enum.any?(&param_segment?/1)

  defp param_segment?(":" <> _), do: true
  defp param_segment?("*" <> _), do: true
  defp param_segment?(_), do: false

  @doc "Whether the verb mutates."
  def mutating?(method), do: method in ["POST", "PUT", "PATCH", "DELETE"]

  # --- Fixture world ------------------------------------------------------------

  @doc """
  Installs every module the golden names into the tenant schema `prefix`, in
  dependency order (a module whose dependency is not installed yet is retried
  after the others), so a module route reaches its permission check instead
  of the not-installed 404. Raises when a module cannot be installed.
  """
  def install_golden_modules!(prefix) do
    modules = golden_modules()
    install_loop!(modules, prefix, length(modules) + 1)
  end

  defp install_loop!([], _prefix, _budget), do: :ok

  defp install_loop!(pending, prefix, 0),
    do: raise("G-01: could not install #{inspect(pending)} into #{prefix}")

  defp install_loop!(pending, prefix, budget) do
    left =
      Enum.reject(pending, fn module_id ->
        case Letflow.Modules.Installs.install(module_id, Ecto.UUID.generate(),
               prefix: prefix,
               rationale: "G-01 route x role probe"
             ) do
          {:ok, _} -> true
          {:error, {:dependency_not_installed, _}} -> false
          other -> raise "G-01: install #{module_id} into #{prefix}: #{inspect(other)}"
        end
      end)

    install_loop!(left, prefix, budget - 1)
  end

  @doc """
  The foreign id pool of schema `schema`: `[{table, id}]`, the smallest `id`
  of every table of the schema whose `id` column is a uuid and that has a
  row, sorted by table. Derived from the database, not listed by hand.
  """
  def foreign_pool(schema) do
    %{rows: tables} =
      Repo.query!(
        "SELECT c.table_name FROM information_schema.columns c JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE' WHERE c.table_schema = $1 AND c.column_name = 'id' AND c.data_type = 'uuid' ORDER BY c.table_name",
        [schema]
      )

    for [table] <- tables,
        %{rows: [[id]]} <-
          [Repo.query!(~s|SELECT min(id::text) FROM "#{schema}"."#{table}"|)],
        is_binary(id),
        do: {table, id}
  end

  @doc """
  The marker the privileged body's `platform_call` carries. It occurs in no row
  of the fixture world, so a row of a company tenant that contains it after a
  request is a stored platform call (rule `:M8`).
  """
  def marker, do: @marker

  @doc """
  The graph of the privileged body: START -> a SERVICE_TASK bound to a
  platform function (the `platform_call` node attribute, read by
  `Letflow.Definitions.PlatformCalls`) -> END. The only thing wrong with it is
  that a company tenant may not carry it (T-2588).
  """
  def privileged_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" => %{
              "function" => "tenant.create",
              "args" => %{"slug" => %{"const" => @marker}, "name" => %{"const" => @marker}}
            }
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }
  end

  @doc """
  A body for a mutating verb, the union of the route families' write shapes,
  every value privileged or naming the foreign tenant:

    * the definition write shape (`name`, `version`, `description`, `graph`):
      the graph carries a `platform_call` node (`privileged_graph/0`), so a
      definition create / PUT / PATCH reaches `check_platform_call_tenant`
      (T-2588);
    * the instance start shape (`initial_variables`, required by
      `POST /instances`) with tenant B's ids and definition id (T-2444 MS-S4);
    * top-level ids and grants naming B (`tenant_id`, `tenant_slug`,
      `definition_id`, `instance_id`, `record_id`, `roles: [PLATFORM_ADMIN]`).
  """
  def privileged_body(foreign) do
    ids = Map.new(foreign.pool)
    definition_id = Map.get(ids, "process_definitions", @missing_id)

    %{
      "name" => "g01-privileged",
      "version" => "1",
      "description" => "G-01 privileged body",
      "graph" => privileged_graph(),
      "initial_variables" => %{
        "tenant_id" => foreign.tenant_id,
        "definition_id" => definition_id
      },
      "tenant_id" => foreign.tenant_id,
      "tenant_slug" => foreign.slug,
      "definition_id" => definition_id,
      "instance_id" => Map.get(ids, "process_instances", @missing_id),
      "record_id" => Map.get(ids, "entity_records", @missing_id),
      "roles" => ["PLATFORM_ADMIN"],
      "platform_call" => %{"function" => "tenant.create"}
    }
  end

  # --- Observe ------------------------------------------------------------------

  @doc """
  Runs the generated requests and returns the observations, in a fixed order.

  `world` carries:

    * `:callers` -- `[%{label, role, platform?, token, slug, schema, tenant}]`
      (`tenant` is `:a` for the ordinary tenant's callers);
    * `:routes` -- the routes to probe;
    * `:golden`, `:overlay` -- the oracle inputs;
    * `:foreign` -- `%{tenant_id, slug, schema, pool}` of tenant B;
    * `:own` -- `%{schema, pool}` of the company tenant A (the own shape and
      the M8 search);
    * `:schemas` -- the schemas whose writes are recorded;
    * `:plug`, `:prefix` -- the plug under test and its path prefix
      (`Letflow.Router` and `"/api/v1"` for the real tree).
  """
  def observe(world) do
    # Thousands of denials each log an `authz_deny` warning; the probe reads
    # the answers, not the log, so the probe process logs errors only.
    Logger.put_process_level(self(), :error)

    try do
      world |> Map.put(:relations, relations(world.schemas)) |> do_observe()
    after
      Logger.delete_process_level(self())
      Process.delete({__MODULE__, :counters})
    end
  end

  defp do_observe(world) do
    body = privileged_body(world.foreign)

    matrix =
      for caller <- world.callers, route <- world.routes do
        expectation =
          expected(world.golden, world.overlay, caller.role, caller.platform?, route.key)

        obs(world, caller, route, expectation, :missing, @missing_id, body)
      end

    foreign =
      for route <- world.routes,
          param_route?(route.path),
          caller = first_allowed_a_caller(world, route),
          caller != nil,
          {table, id} <- world.foreign.pool do
        obs(world, caller, route, :allow, {:foreign, table}, id, body)
      end

    own =
      for route <- world.routes,
          mutating?(route.method),
          param_route?(route.path),
          caller = first_allowed_a_caller(world, route),
          caller != nil,
          {table, id} <- world.own.pool do
        obs(world, caller, route, :allow, {:own, table}, id, body)
      end

    matrix ++ foreign ++ own
  end

  defp first_allowed_a_caller(world, route) do
    Enum.find(world.callers, fn caller ->
      caller.tenant == :a and
        expected(world.golden, world.overlay, caller.role, caller.platform?, route.key) == :allow
    end)
  end

  defp obs(world, caller, route, expectation, shape, id, body) do
    path = concrete_path(route.path, id)
    req_body = if mutating?(route.method), do: body, else: nil

    %{
      caller: caller.label,
      tenant: caller.tenant,
      schema: caller.schema,
      method: route.method,
      path: route.path,
      key: route.key,
      expected: expectation,
      shape: shape,
      id: id,
      resp: request(world, route.method, path, caller, req_body)
    }
  end

  @doc """
  One request through `world.plug`, isolated in a transaction (a savepoint of
  the sandbox transaction) that is always rolled back. The transaction's own
  write counters (`pg_stat_get_xact_tuples_inserted/updated/deleted`, the
  functions behind `pg_stat_xact_user_tables`) are read for the tables of
  `world.schemas` before and after: PostgreSQL counts every attempted insert,
  update and delete, also a rolled-back one, so a write the request made is
  seen.

  Returns `%{status, type, body, crash, writes, stored_marker}`; `crash` is
  the exception message when the pipeline raised (a 500 in production);
  `writes` is the sorted `[{schema, table}]` list of written tables;
  `stored_marker` the tables of the company tenant that held the privileged
  body's `platform_call` marker before the rollback (rule `:M8`).
  """
  def request(world, method, path, caller, body) do
    # The counters only grow inside the sandbox transaction, and nothing but
    # these requests runs between two reads: the previous request's "after"
    # read is this request's "before" read.
    before =
      Process.get({__MODULE__, :counters}) || xact_writes(world)

    # A handler's own nested transaction may mark this one for rollback, and
    # `Repo.transaction/1` then drops the function's value: the response is
    # passed out through the process dictionary instead.
    Repo.transaction(fn ->
      resp = dispatch(world, method, path, caller, body)
      # Only a request with a body can carry the marker in.
      stored = if body, do: stored_marker(world, before), else: []
      Process.put({__MODULE__, :response}, Map.put(resp, :stored_marker, stored))
      Repo.rollback(:g01_isolated)
    end)

    resp = Process.delete({__MODULE__, :response})
    after_counts = xact_writes(world)
    Process.put({__MODULE__, :counters}, after_counts)
    Map.put(resp, :writes, diff_writes(before, after_counts))
  end

  # The tables of the company tenant A (`world.own.schema`) that the request
  # wrote and that now hold a row containing the privileged body's marker,
  # read inside the request's transaction (before the rollback).
  #
  # A handler whose own nested transaction failed leaves the request's
  # transaction aborted: it can commit nothing, and ANY query on it makes the
  # connection disconnect, which would drop the whole sandbox transaction (the
  # module installs with it). An empty nested transaction tells the two apart
  # without a query (DBConnection answers `{:error, :rollback}` on an aborted
  # transaction), so an aborted request answers `[]`. A handler that rescued a
  # database error leaves the transaction aborted on the PostgreSQL side only:
  # the first query answers 25P02 (`in_failed_sql_transaction`, no disconnect),
  # and that request can commit nothing either.
  #
  # `audit_entries` is not a store of definitions: the audit trail records
  # refused input by design (for example `tenant_settings.reject_unrecognized_keys`
  # keeps the rejected keys' values), so a marker there is not a stored call.
  defp stored_marker(world, before) do
    case Repo.transaction(fn -> :ok end) do
      {:ok, :ok} -> scan_marker(world, before)
      {:error, _aborted} -> []
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres && error.postgres.code == :in_failed_sql_transaction,
        do: [],
        else: reraise(error, __STACKTRACE__)
  end

  defp scan_marker(world, before) do
    schema = world.own.schema

    written =
      for {^schema, table} <- diff_writes(before, xact_writes(world)),
          table not in ["api_tokens", "audit_entries"],
          do: table

    for table <- written,
        %{rows: [[n]]} <- [
          Repo.query!(
            ~s|SELECT count(*) FROM "#{schema}"."#{table}" r WHERE r::text LIKE $1|,
            ["%" <> @marker <> "%"]
          )
        ],
        n > 0,
        do: {schema, table}
  end

  defp dispatch(world, method, path, caller, body) do
    encoded = if body, do: Jason.encode!(body), else: nil
    verb = method |> String.downcase() |> String.to_existing_atom()

    try do
      resp =
        conn(verb, world.prefix <> path, encoded)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> caller.token)
        |> put_req_header("x-tenant-slug", caller.slug)
        |> world.plug.call(world.plug.init([]))

      %{
        status: resp.status,
        type: get_resp_header(resp, "content-type"),
        body: resp.resp_body || "",
        crash: nil
      }
    rescue
      exception -> %{status: 500, type: [], body: "", crash: crash_message(exception)}
    end
  end

  defp crash_message(%Plug.Conn.WrapperError{reason: reason}), do: crash_message(reason)

  defp crash_message(exception) do
    exception |> Exception.message() |> String.split("\n") |> hd() |> String.slice(0, 200)
  end

  # The tables of `schemas`, `%{oid => {schema, table}}`, read once per
  # observation run: the per-request counter read then asks only for these
  # oids (about 1 ms, against about 4 ms for the `pg_stat_xact_user_tables`
  # view over the whole test database).
  defp relations(schemas) do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.oid, n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ANY($1) AND c.relkind IN ('r', 'p')",
        [schemas]
      )

    Map.new(rows, fn [oid, schema, table] -> {oid, {schema, table}} end)
  end

  # This transaction's write counters (attempted inserts + updates + deletes,
  # rolled-back ones included) of every table of `world.relations` that has
  # one, `%{{schema, table} => count}`.
  defp xact_writes(world) do
    %{rows: rows} =
      Repo.query!(
        "SELECT o, x FROM (SELECT o, pg_stat_get_xact_tuples_inserted(o) + pg_stat_get_xact_tuples_updated(o) + pg_stat_get_xact_tuples_deleted(o) AS x FROM unnest($1::oid[]) AS u(o)) s WHERE x > 0",
        [Map.keys(world.relations)]
      )

    Map.new(rows, fn [oid, count] -> {Map.fetch!(world.relations, oid), count} end)
  end

  defp diff_writes(before, after_counts) do
    for({key, count} <- after_counts, count != Map.get(before, key, 0), do: key)
    |> Enum.sort()
  end

  # --- Check --------------------------------------------------------------------

  @doc """
  The answer with the per-request `trace_id` removed and every id of `ids`
  replaced by a placeholder: `{status, content_type, body}`.
  """
  def normalise(resp, ids) do
    body =
      ids
      |> Enum.reduce(resp.body, fn id, acc -> String.replace(acc, id, @placeholder) end)
      |> then(&Regex.replace(~r/"trace_id":"[^"]*"/, &1, ~s("trace_id":"")))

    {resp.status, resp.type, body}
  end

  @doc """
  Every rule violation of `observations`: `[{rule, caller, method, path, detail}]`,
  sorted. `ctx` carries `:canonical_403` and `:canonical_404` (the normalised
  canonical denials), `:concealed_keys` (the policy keys whose denial is the
  404, `concealed_keys/0`) and `:foreign` (`%{schema, slug, tenant_id, pool}`
  of tenant B).
  """
  def violations(observations, ctx) do
    secrets = foreign_secrets(ctx.foreign)
    matrix = Enum.filter(observations, &(&1.shape == :missing))

    (Enum.flat_map(matrix, &matrix_rules(&1, ctx)) ++
       Enum.flat_map(observations, &write_and_crash_rules(&1, ctx, secrets)) ++
       identity_rule(observations))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp foreign_secrets(foreign),
    do: [foreign.schema, foreign.slug, foreign.tenant_id | Enum.map(foreign.pool, &elem(&1, 1))]

  defp matrix_rules(o, ctx) do
    answer = normalise(o.resp, [@missing_id])
    canonical = if o.key in ctx.concealed_keys, do: ctx.canonical_404, else: ctx.canonical_403

    case o.expected do
      :deny ->
        m1 =
          if answer != canonical,
            do: [{:M1, o.caller, o.method, o.path, "answered #{o.resp.status}"}],
            else: []

        allowed_writes = [{o.schema, "api_tokens"}]

        m2 =
          case o.resp.writes -- allowed_writes do
            [] -> []
            written -> [{:M2, o.caller, o.method, o.path, "wrote #{inspect(written)}"}]
          end

        m1 ++ m2

      # For a concealed key the canonical denial is the 404 a missing id gets
      # anyway, so an over-denial is only visible as the canonical 403.
      :allow ->
        if answer == ctx.canonical_403,
          do: [{:M3, o.caller, o.method, o.path, "canonical 403"}],
          else: []
    end
  end

  defp write_and_crash_rules(o, ctx, secrets) do
    foreign_writes =
      Enum.filter(o.resp.writes, fn {schema, _t} -> schema == ctx.foreign.schema end)

    m5 =
      if o.tenant == :a and foreign_writes != [],
        do: [{:M5, o.caller, o.method, o.path, "wrote B #{inspect(foreign_writes)}"}],
        else: []

    m6 =
      if o.tenant == :a and Enum.any?(secrets, &String.contains?(o.resp.body, &1)),
        do: [{:M6, o.caller, o.method, o.path, "answer names tenant B"}],
        else: []

    m7 =
      if o.resp.crash != nil or o.resp.status >= 500,
        do: [{:M7, o.caller, o.method, o.path, o.resp.crash || "status #{o.resp.status}"}],
        else: []

    m8 =
      if o.tenant == :a and Map.get(o.resp, :stored_marker, []) != [],
        do: [{:M8, o.caller, o.method, o.path, "stored #{inspect(o.resp.stored_marker)}"}],
        else: []

    m5 ++ m6 ++ m7 ++ m8
  end

  defp identity_rule(observations) do
    missing =
      for o <- observations, o.shape == :missing, into: %{} do
        {{o.caller, o.method, o.path}, normalise(o.resp, [o.id])}
      end

    for o <- observations,
        match?({:foreign, _}, o.shape),
        reference = Map.fetch!(missing, {o.caller, o.method, o.path}),
        normalise(o.resp, [o.id]) != reference do
      {:foreign, table} = o.shape

      {:M4, o.caller, o.method, o.path,
       "B #{table} id answered #{o.resp.status}, a missing id #{elem(reference, 0)}"}
    end
  end

  # --- Ratchet --------------------------------------------------------------------

  @doc "A violation as its ratchet line: `RULE CALLER METHOD PATH` (the detail is not pinned)."
  def ratchet_line({rule, caller, method, path, _detail}),
    do: Enum.join([rule, String.replace(caller, " ", "_"), method, path], " ")

  @doc "The `{method, path}` a ratchet line names."
  def ratchet_route(line) do
    [_rule, _caller, method, path] = String.split(line, " ")
    {method, path}
  end

  @doc "The committed ratchet lines that name one of `routes`."
  def ratchet_lines_for(routes) do
    keys = MapSet.new(routes, &{&1.method, &1.path})
    Enum.filter(read_ratchet(), &MapSet.member?(keys, ratchet_route(&1)))
  end

  @doc "The committed ratchet lines (comments and blank lines ignored)."
  def read_ratchet do
    @ratchet_path
    |> File.read!()
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end
