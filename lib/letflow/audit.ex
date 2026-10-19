defmodule Letflow.Audit do
  @moduledoc """
  Tenant-wide, resource-typed compliance audit trail (REQ-195, OBS-03,
  XC-02). Records every covered mutation to `audit_entries`
  (`Letflow.Audit.Entry`) as an immutable, tamper-evident, hash-chained row
  carrying both the prior and resulting state of the mutation it describes.
  See `lib/letflow/design/req195-audit-entry-storage.md` for the full design
  this module implements; this moduledoc restates, in its own words, the
  three points AC7/AC8/AC10 require the shipped module itself to state.

  ## Capture mechanism: Elixir context-function-boundary, not a Postgres trigger (AC8)

  Two approaches exist for capturing an audit row: (a) a database-level
  `BEFORE`-trigger on each covered business table, deriving the action name
  from the row's own status transition and reading the acting user from a
  Postgres session variable (the classic audit-trigger pattern); (b)
  capturing inside the Elixir context-function boundary that already
  performs the mutation (`Letflow.Definitions.activate/2`,
  `Letflow.Engine.cancel_instance/3`, etc.), as one more step in the same
  transaction as the mutation itself.

  **This module implements (b).**

  *What the trigger approach would buy, and why it isn't worth it here:* a
  trigger cannot miss a write, no matter what code path reaches the table --
  a future direct-SQL script or an unrelated bug that bypasses the context
  module entirely would still be audited. That guarantee costs two things
  this codebase is not willing to pay for right now: (1) it requires a
  session-level mechanism (a Postgres `SET LOCAL` GUC or equivalent) to make
  the acting user's id visible to a trigger function -- a new cross-cutting
  mechanism this codebase's tenancy decision record has already considered
  and explicitly deferred, not something this requirement has the authority
  to introduce unilaterally; and (2) it puts business logic (deriving an
  `action` string from a status transition) into SQL, in a codebase whose
  only precedent for "an accompanying side effect must commit or roll back
  with its own mutation" is `Ecto.Multi` composed inline in the same Elixir
  module as the mutation -- no migration in this codebase uses `CREATE
  TRIGGER` for business logic anywhere else.

  *The residual risk this decision accepts:* a write that reaches a covered
  table through a path that bypasses its owning context module entirely
  (e.g. a future raw `Repo.insert_all/3`) would not be audited. This mirrors
  every other cross-cutting side effect this codebase already accepts the
  same risk for (event emission, webhook dispatch), and is the reason
  REVIEWER's idiom gate screens future changes to these tables for exactly
  this class of bypass.

  ## Canonical hashed form (AC7)

  `chain_hash` is the lowercase-hex SHA-256 digest of a canonical string built
  from exactly these 11 fields, in this exact order, each length-prefixed
  ("netstring" form: `<decimal-byte-length>:<raw-UTF-8-bytes>`, with no bytes
  between fields beyond what each field's own encoding contributes):

    1. `id` -- canonical lowercase-hyphenated UUID string. Never NULL.
    2. `tenant_id` -- canonical UUID string. Never NULL.
    3. `actor_id` -- canonical UUID string, or the NULL sentinel.
    4. `action` -- literal string. Never NULL.
    5. `resource_type` -- literal string. Never NULL.
    6. `resource_id` -- literal string. Never NULL.
    7. `timestamp` -- decimal ASCII integer, `DateTime.to_unix(ts, :microsecond)`
       formatted with `Integer.to_string/1` (microseconds since the Unix
       epoch, no leading zeros, no sign). Never NULL.
    8. `before_state` -- canonical JSON string (object keys sorted
       lexicographically at every nesting level, no insignificant
       whitespace), or the NULL sentinel when there is no prior state.
    9. `after_state` -- canonical JSON string, same rules, or the NULL
       sentinel.
    10. `trace_id` -- literal string, or the NULL sentinel when absent.
    11. `prev_chain_hash` -- the previous entry's lowercase-hex `chain_hash`,
        or the NULL sentinel for the first entry in a tenant's chain.

  A missing/absent optional value (fields 3, 8, 9, 10, 11) is encoded as the
  fixed 3-byte literal `-1:` -- never as a zero-length field (`0:`, which
  means "an empty string," a distinct value) and never by omitting the field
  from the concatenation. `-1` can never be a valid byte length, so this
  sentinel cannot collide with any real field's own encoding.

  `chain_hash` itself is `Base.encode16(:crypto.hash(:sha256, canonical_string),
  case: :lower)` -- 64 lowercase hex characters.

  ## Verification recomputes; it does not just check linkage (AC6)

  `verify_chain/2` recomputes each entry's hash from that entry's own
  currently-stored column values and compares it against the stored
  `chain_hash` *before* checking that entry's `prev_chain_hash` against the
  previous entry's own recomputed hash. This is deliberately NOT the R-Co
  behavior it replaces: that prior chain-verification function reads every
  content column and then only ever compares `prev_chain_hash` linkage,
  never recomputing a digest from the content it just read -- so an operator
  who edits a persisted `after_state` directly (bypassing the application)
  while leaving both hash columns untouched passes a linkage-only check
  outright, undetected.
  This module's `verify_chain/2` catches exactly that case, immediately, at
  the tampered entry itself, and reports it as `{:error, {:hash_mismatch,
  entry_id}}` distinct from `{:error, {:chain_broken, entry_id}}` (a linkage
  break -- deletion, reordering, or a corrupted `prev_chain_hash`).

  ## `lua_script_execution_audit` is a separate, narrower trail (AC10)

  `lib/letflow/engine/lua_script_audit.ex` (REQ-058/153/158) is a narrow,
  single-purpose trail for Lua script executions inside `SERVICE_TASK`
  nodes -- it records an `instance_id`, an executor-reported `manifest_hash`,
  and an execution outcome, with no `before_state`/`after_state`/chain
  concept at all. `audit_entries` (this module) is the general, tenant-wide,
  resource-typed compliance trail covering definition/instance/task/identity
  mutations. **`Letflow.Audit` does not read, write, call, or get called by
  `Letflow.Engine.LuaScriptAudit`; `audit_entries` does not replace or
  absorb `lua_script_execution_audit`,** and no migration in this
  requirement touches that table.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit.ChainLock
  alias Letflow.Audit.Entry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type entry_attrs :: %{
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:action) => String.t(),
          required(:resource_type) => String.t(),
          required(:resource_id) => String.t(),
          required(:before_state) => map() | nil,
          required(:after_state) => map() | nil,
          optional(:trace_id) => String.t() | nil
        }

  @typedoc """
  Input to `list_entries/1` (REQ-196, design `req196-audit-route.md` §1.1).

  `:prefix` is not listed in the design's own `list_params()` type sketch,
  but §1.3 is explicit that `prefix` reaches this function "the same way
  `insert_entry/3` accepts `prefix` today (an explicit argument, not read
  from process/application config)" -- and this function has a single map
  argument, so the only way to satisfy both statements is for `:prefix` to
  be a required key of that map. Making it required (not `optional/1`)
  keeps tenant scoping structural: there is no code path through this
  function that queries `Entry` without an explicit schema prefix.

  `:cursor` is an already-decoded `{timestamp, id}` seek pair -- decoding
  the opaque cursor string itself stays a router-owned concern (design §1.1,
  OQ-2), matching `Letflow.Routers.Audit`'s existing division of labor.
  """
  @type list_params :: %{
          required(:prefix) => String.t(),
          required(:page_size) => pos_integer(),
          optional(:cursor) => {DateTime.t(), Ecto.UUID.t()} | nil,
          optional(:from) => DateTime.t() | nil,
          optional(:to) => DateTime.t() | nil,
          optional(:actor_id) => Ecto.UUID.t() | nil,
          optional(:resource_id) => String.t() | nil,
          optional(:resource_type) => String.t() | nil
        }

  @doc """
  Converts an Ecto struct into a plain map suitable for a `before_state`/
  `after_state` value -- drops `:__meta__` (never JSON-representable) and
  any caller-named `exclude` fields (e.g. `:password_hash`, `:token_hash` --
  a credential-bearing column no audit row should ever carry, INV-4). Every
  covered context function in this codebase builds its `before_state`/
  `after_state` maps this way rather than passing a raw struct through.
  """
  @spec struct_state(struct :: struct(), exclude :: [atom()]) :: map()
  def struct_state(struct, exclude \\ []) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__ | exclude])
  end

  @doc """
  Appends one `Ecto.Multi.run/3` step named `step_name` to `multi`, that
  inserts one `Letflow.Audit.Entry` row for `attrs`, scoped to the tenant
  schema named by `prefix`. Placed after the step(s) that perform the actual
  mutation and before the `Multi` is submitted to `Repo.transaction/1` --
  a failure here (a changeset error, or any other reason) aborts and rolls
  back every other step already in `multi` (AC3), via `Ecto.Multi`'s own
  all-or-nothing transaction semantics.
  """
  @spec append_multi(
          multi :: Multi.t(),
          step_name :: atom(),
          attrs :: entry_attrs(),
          prefix :: String.t()
        ) ::
          Multi.t()
  def append_multi(%Multi{} = multi, step_name, attrs, prefix) when is_atom(step_name) do
    Multi.run(multi, step_name, fn repo, _changes -> insert_entry(repo, attrs, prefix) end)
  end

  @doc """
  Inserts one `Letflow.Audit.Entry` row for `attrs`, scoped to the tenant
  schema named by `prefix`, using `repo` for every query/insert it issues.

  Takes an explicit `repo` (a module implementing `Ecto.Repo`'s callbacks --
  in practice `Letflow.Repo` itself, or the `repo` argument an
  `Ecto.Multi.run/3` step function receives) rather than calling
  `Letflow.Repo` directly, so this function can be called either as this
  module's own `append_multi/4` does (inside a caller's already-open
  `Ecto.Multi`) or directly inside a caller's own `Repo.transaction/1`
  anonymous function -- both are "the same transaction as the mutation it
  accompanies" (AC3), just built with different Ecto idioms. Every covered
  context function in this codebase uses one of these two shapes; see
  `Letflow.Definitions`, `Letflow.Engine`, `Letflow.Tasks`,
  `Letflow.Identity` for both call shapes in use.

  Implements the append algorithm (design §3.3, ISS-0979): resolves
  `tenant_id` from `prefix`, then -- inside one `repo.transaction/1` call --
  locks the tenant's `audit_chain_locks` sentinel row (insert-if-absent, then
  `SELECT ... FOR UPDATE`, mirroring `Letflow.EventStore.assign_sequence/3`'s
  own two-step protocol verbatim) before fetching the tenant's current chain
  tail, so two concurrent callers for the same tenant can never both observe
  the same tail and fork the chain (ISS-0979). Computes `chain_hash` per the
  canonical form (this module's moduledoc §"Canonical hashed form") and
  inserts the row, still under the held lock.

  `repo.transaction/1` here either nests inline inside a caller's own
  already-open transaction (every `append_multi/4` call site, and the two
  call sites that already wrap `insert_entry/3` in their own
  `Repo.transaction/1`) or opens a brand-new, short-lived one (the two
  call sites -- `tenant_settings.ex`, `instances.ex` -- that call
  `insert_entry/3` directly with no surrounding transaction). Either way the
  lock taken below is held until the outermost transaction commits or rolls
  back. A raise from inside the transaction function propagates out of
  `repo.transaction/1` and out of `insert_entry/3` exactly as it would have
  before this change -- `repo.transaction/1` does not catch or convert
  raises, it only guarantees the DB-side rollback happens first.
  """
  @spec insert_entry(repo :: module(), attrs :: entry_attrs(), prefix :: String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def insert_entry(repo, attrs, prefix) when is_map(attrs) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      case repo.transaction(fn -> do_insert_entry(repo, attrs, prefix, tenant_id) end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_insert_entry(repo, attrs, prefix, tenant_id) do
    lock_chain_tail!(repo, prefix, tenant_id)

    id = Ecto.UUID.generate()
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    prev_chain_hash = fetch_chain_tail(repo, prefix)

    fields = %{
      id: id,
      tenant_id: tenant_id,
      actor_id: Map.get(attrs, :actor_id),
      action: Map.fetch!(attrs, :action),
      resource_type: Map.fetch!(attrs, :resource_type),
      resource_id: Map.fetch!(attrs, :resource_id),
      timestamp: timestamp,
      before_state: Map.get(attrs, :before_state),
      after_state: Map.get(attrs, :after_state),
      trace_id: Map.get(attrs, :trace_id),
      prev_chain_hash: prev_chain_hash
    }

    chain_hash = compute_hash(fields)

    insert_attrs = Map.put(fields, :chain_hash, chain_hash)

    %Entry{}
    |> Entry.changeset(insert_attrs)
    |> repo.insert(prefix: prefix)
  end

  # ISS-0979 -- the two-step "insert-if-absent, then re-SELECT-and-lock from
  # the table itself" protocol, copied verbatim from
  # Letflow.EventStore.assign_sequence/3 + lock_and_increment_sequence/3
  # (lib/letflow/event_store.ex:598-636). Step (i) is one atomic statement,
  # not a racy check-then-insert; whichever of two concurrent first-writers
  # for a brand-new tenant loses the race gets `on_conflict: :nothing`'s
  # silent no-op, not an error. Step (ii) locks the now-guaranteed-to-exist
  # row -- never the insert's own possibly-stale returned struct -- via
  # Ecto's `lock/2` query composition (INV-7: never a hand-written SQL
  # string). This call blocks until any other transaction currently holding
  # this same tenant's lock row commits or rolls back -- the serialization
  # point that prevents the chain from forking (design §3.4).
  defp lock_chain_tail!(repo, prefix, tenant_id) do
    insert_changeset = ChainLock.insert_changeset(%ChainLock{}, %{tenant_id: tenant_id})

    {:ok, _} =
      repo.insert(insert_changeset,
        on_conflict: :nothing,
        conflict_target: :tenant_id,
        prefix: prefix
      )

    %ChainLock{} =
      ChainLock
      |> where([l], l.tenant_id == ^tenant_id)
      |> lock("FOR UPDATE")
      |> repo.one(prefix: prefix)

    maybe_apply_post_lock_delay()
  end

  # Test-only timing seam (ISS-0979 regression test, design §5.2) -- mirrors
  # Letflow.Engine.ServiceTaskDispatcher.http_transport/3's own
  # Application.get_env/3-based test seam idiom
  # (lib/letflow/engine/service_task_dispatcher.ex:54,309): defaults to a
  # no-op in every environment; only the regression test below ever sets
  # `:audit_chain_lock_post_lock_delay_fun` to a `(-> any())` zero-arity
  # function, scoped to individual tests via `Application.put_env/3` +
  # `on_exit/1`. Called after the lock in lock_chain_tail!/3 is acquired and
  # before fetch_chain_tail/2 reads the tail (between design §3.3 steps 4 and
  # 5), so a test can force one racer to hold the lock for an artificially
  # widened window and prove the other racers actually blocked at the lock
  # rather than never having collided by chance.
  defp maybe_apply_post_lock_delay do
    case Application.get_env(:letflow, :audit_chain_lock_post_lock_delay_fun, nil) do
      nil -> :ok
      delay_fun when is_function(delay_fun, 0) -> delay_fun.()
    end
  end

  @doc """
  Filtered, cursor-paginated read of `audit_entries` for the tenant schema
  named by `params.prefix` (REQ-196, design `req196-audit-route.md` §1).
  Backs `Letflow.Routers.Audit`'s `GET /audit` handler -- the only reader of
  this function; nothing else in this codebase lists `Entry` rows.

  Each filter in `params` (`:from`, `:to`, `:actor_id`, `:resource_id`,
  `:resource_type`, `:cursor`) contributes a predicate only when present;
  an absent filter narrows nothing (design §1.3's table). Ordered
  `timestamp DESC, id DESC` -- REQ-195's own index #1
  (`lib/letflow/design/req195-audit-entry-storage.md` §1.3) already backs
  this ordering with no new migration; index #2 (`actor_id, timestamp,
  id`) and index #3 (`resource_type, resource_id, timestamp, id`) back the
  filtered paths.

  `has_more` uses the same `page_size + 1`-fetch/drop-the-extra-row idiom
  `Letflow.ServiceCatalog.list_all/1` and the former
  `Letflow.EventStore.read_global/1` both use: `limit: page_size + 1`, and
  if more than `page_size` rows come back, the extra row is dropped and
  `has_more` is `true`.

  `actor_id`, being `Entry.actor_id`'s `:binary_id` column, would raise an
  `Ecto.Query.CastError` if handed a non-UUID string directly in an
  equality predicate -- this function catches that ahead of the query via
  `Ecto.UUID.cast/1` and returns `{:error, :invalid_actor_id}` instead
  (design §1.2). `resource_id` is a plain `:string` column with no
  analogous cast risk (REQ-195 design §1.2), so no `:invalid_resource_id`
  clause exists here -- design §8 OQ-1 flags this as dead code if kept, and
  it is omitted rather than kept unreachable.
  """
  @spec list_entries(list_params()) ::
          {:ok, %{items: [Entry.t()], has_more: boolean()}}
          | {:error, :invalid_actor_id}
  def list_entries(params) when is_map(params) do
    prefix = Map.fetch!(params, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, actor_id} <- validate_actor_id(Map.get(params, :actor_id)) do
      rows =
        Entry
        |> where_from(Map.get(params, :from))
        |> where_to(Map.get(params, :to))
        |> where_actor_id(actor_id)
        |> where_resource_id(Map.get(params, :resource_id))
        |> where_resource_type(Map.get(params, :resource_type))
        |> where_cursor_seek(Map.get(params, :cursor))
        |> order_by([e], desc: e.timestamp, desc: e.id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {items, has_more} = split_list_page(rows, page_size)

      {:ok, %{items: items, has_more: has_more}}
    end
  end

  @doc """
  REQ-519 2f-a (design 4.5/4.6): the LATEST entry of the tenant schema `prefix` for
  `resource_type` / `resource_id` whose `action` is one of `actions`, or `nil`. One query,
  `ORDER BY timestamp DESC, id DESC LIMIT 1`, served by index #3 (resource_type,
  resource_id, timestamp, id). Read-only; the caller reads `after_state` from the entry.
  """
  @spec latest_matching(
          prefix :: String.t(),
          resource_type :: String.t(),
          resource_id :: String.t(),
          actions :: [String.t()]
        ) :: Entry.t() | nil
  def latest_matching(prefix, resource_type, resource_id, actions)
      when is_binary(prefix) and is_binary(resource_type) and is_binary(resource_id) and
             is_list(actions) do
    from(e in Entry,
      where:
        e.resource_type == ^resource_type and e.resource_id == ^resource_id and
          e.action in ^actions,
      order_by: [desc: e.timestamp, desc: e.id],
      limit: 1
    )
    |> Repo.one(prefix: prefix)
  end

  defp validate_actor_id(nil), do: {:ok, nil}
  defp validate_actor_id(""), do: {:ok, nil}

  defp validate_actor_id(actor_id) when is_binary(actor_id) do
    case Ecto.UUID.cast(actor_id) do
      {:ok, _} -> {:ok, actor_id}
      :error -> {:error, :invalid_actor_id}
    end
  end

  defp where_from(query, nil), do: query
  defp where_from(query, %DateTime{} = from), do: where(query, [e], e.timestamp >= ^from)

  defp where_to(query, nil), do: query
  defp where_to(query, %DateTime{} = to), do: where(query, [e], e.timestamp <= ^to)

  defp where_actor_id(query, nil), do: query
  defp where_actor_id(query, actor_id), do: where(query, [e], e.actor_id == ^actor_id)

  defp where_resource_id(query, nil), do: query
  defp where_resource_id(query, ""), do: query
  defp where_resource_id(query, resource_id), do: where(query, [e], e.resource_id == ^resource_id)

  defp where_resource_type(query, nil), do: query
  defp where_resource_type(query, ""), do: query

  defp where_resource_type(query, resource_type),
    do: where(query, [e], e.resource_type == ^resource_type)

  defp where_cursor_seek(query, nil), do: query

  defp where_cursor_seek(query, {%DateTime{} = cursor_ts, cursor_id}) do
    where(
      query,
      [e],
      e.timestamp < ^cursor_ts or (e.timestamp == ^cursor_ts and e.id < ^cursor_id)
    )
  end

  # Same idiom as `Letflow.ServiceCatalog.list_all/1`'s `split_list_page/2`
  # and the former `Letflow.EventStore.read_global/1`: fetch `page_size + 1`
  # rows, and if the extra row came back, drop it and report `has_more`.
  defp split_list_page(rows, page_size) do
    if length(rows) > page_size do
      {Enum.take(rows, page_size), true}
    else
      {rows, false}
    end
  end

  defp fetch_chain_tail(repo, prefix) do
    query =
      from(e in Entry,
        order_by: [desc: e.timestamp, desc: e.id],
        limit: 1,
        select: e.chain_hash
      )

    repo.one(query, prefix: prefix)
  end

  @doc """
  Recomputes and verifies every `audit_entries` row for the tenant named by
  `prefix` (or, when `opts[:limit]` is a positive integer, the most recent
  `limit` entries -- verified oldest-first within that window; `:all`, the
  default, verifies the whole chain).

  Per entry, in append order (`timestamp ASC, id ASC`):

    1. **Recomputes** `chain_hash` from that entry's own currently-stored
       column values and compares it against the stored `chain_hash`. A
       mismatch returns `{:error, {:hash_mismatch, entry.id}}` immediately --
       this is the check the prior, replaced chain-verification approach
       never performed (see this module's moduledoc).
    2. Compares the entry's stored `prev_chain_hash` against the *previous*
       entry's own just-recomputed `chain_hash` (never that previous entry's
       stored `prev_chain_hash`) -- so a tampered entry is reported against
       itself, not deferred to a linkage failure on the entry after it. A
       mismatch (including a non-nil `prev_chain_hash` on the tenant's first
       entry, or a nil `prev_chain_hash` on any later entry) returns
       `{:error, {:chain_broken, entry.id}}`.

  Stops at the first bad entry -- a hash computed over corrupted content has
  no meaning for verifying anything chained after it.
  """
  @spec verify_chain(prefix :: String.t(), opts :: [limit: pos_integer() | :all]) ::
          {:ok, :valid}
          | {:error, {:hash_mismatch, entry_id :: Ecto.UUID.t()}}
          | {:error, {:chain_broken, entry_id :: Ecto.UUID.t()}}
  def verify_chain(prefix, opts \\ []) when is_binary(prefix) do
    entries = load_entries_for_verification(prefix, Keyword.get(opts, :limit, :all))
    do_verify_chain(entries, nil)
  end

  defp load_entries_for_verification(prefix, :all) do
    from(e in Entry, order_by: [asc: e.timestamp, asc: e.id])
    |> Repo.all(prefix: prefix)
  end

  defp load_entries_for_verification(prefix, limit) when is_integer(limit) and limit > 0 do
    from(e in Entry, order_by: [desc: e.timestamp, desc: e.id], limit: ^limit)
    |> Repo.all(prefix: prefix)
    |> Enum.reverse()
  end

  defp do_verify_chain([], _prev_recomputed_hash), do: {:ok, :valid}

  defp do_verify_chain([%Entry{} = entry | rest], prev_recomputed_hash) do
    recomputed = compute_hash(fields_from_entry(entry))

    cond do
      recomputed != entry.chain_hash ->
        {:error, {:hash_mismatch, entry.id}}

      entry.prev_chain_hash != prev_recomputed_hash ->
        {:error, {:chain_broken, entry.id}}

      true ->
        do_verify_chain(rest, recomputed)
    end
  end

  @doc """
  Reports whether `earlier` was chain-committed strictly before `later`,
  within the tenant chain named by `prefix`, by walking `later.prev_chain_hash`
  backward until it either reaches `earlier.id` or runs out of chain
  (ISS-0972). This is a narrower, two-entry question than `verify_chain/2`'s
  whole-chain verification -- it answers "does this chain's linkage prove
  `earlier` precedes `later`", not "is this chain internally consistent."

  `audit_entries` has no `sequence_number`/`global_seq`-equivalent column
  (unlike `events`, ISS-0970's precedent) -- `id` is a random UUID, not a
  sequence, and `inserted_at` is strictly less precise than `timestamp`
  itself. The one genuinely monotonic, non-timestamp ordering primitive this
  table offers is the `chain_hash`/`prev_chain_hash` hash-chain linkage
  itself: a structural, backward-linked-list fact about what each row's
  `prev_chain_hash` points to, not an inference from any clock reading.

  Returns `{:ok, false}` both when `earlier` is `later`'s own descendant (it
  was inserted *after* `later`) and when `earlier` does not appear anywhere
  in `later`'s ancestry at all (e.g. a different tenant's chain entirely --
  callers are expected to have already guarded same-prefix membership, same
  as `require_same_prefix/2` does at this function's one call site today).
  `earlier.id == later.id` is handled as a defensive `{:ok, false}` guard (an
  entry does not precede itself) rather than assumed never to happen.

  Bounded by `@max_chain_walk_hops` so a malformed/corrupted chain reports an
  error instead of looping unboundedly; a broken link (a `prev_chain_hash`
  pointing at a `chain_hash` with no matching row -- which the table's own
  immutability triggers should make impossible in practice) reports an error
  rather than raising.
  """
  @max_chain_walk_hops 10_000

  @spec chain_precedes?(prefix :: String.t(), earlier :: Entry.t(), later :: Entry.t()) ::
          {:ok, boolean()}
          | {:error, {:max_hops_exceeded, pos_integer()}}
          | {:error, {:broken_chain_link, chain_hash :: String.t()}}
  def chain_precedes?(prefix, %Entry{} = earlier, %Entry{} = later) when is_binary(prefix) do
    if earlier.id == later.id do
      {:ok, false}
    else
      walk_chain_for_ancestor(prefix, later.prev_chain_hash, earlier.id, 0)
    end
  end

  defp walk_chain_for_ancestor(_prefix, nil, _earlier_id, _hops), do: {:ok, false}

  defp walk_chain_for_ancestor(_prefix, _chain_hash, _earlier_id, hops)
       when hops >= @max_chain_walk_hops do
    {:error, {:max_hops_exceeded, @max_chain_walk_hops}}
  end

  defp walk_chain_for_ancestor(prefix, chain_hash, earlier_id, hops) do
    case Repo.get_by(Entry, [chain_hash: chain_hash], prefix: prefix) do
      nil ->
        {:error, {:broken_chain_link, chain_hash}}

      %Entry{id: ^earlier_id} ->
        {:ok, true}

      %Entry{prev_chain_hash: next_chain_hash} ->
        walk_chain_for_ancestor(prefix, next_chain_hash, earlier_id, hops + 1)
    end
  end

  defp fields_from_entry(%Entry{} = entry) do
    %{
      id: entry.id,
      tenant_id: entry.tenant_id,
      actor_id: entry.actor_id,
      action: entry.action,
      resource_type: entry.resource_type,
      resource_id: entry.resource_id,
      timestamp: entry.timestamp,
      before_state: entry.before_state,
      after_state: entry.after_state,
      trace_id: entry.trace_id,
      prev_chain_hash: entry.prev_chain_hash
    }
  end

  # -----------------------------------------------------------------------
  # Canonical hashed form (design §5) -- shared by insert_entry/3 (over
  # pre-insert field values) and do_verify_chain/2 (over a stored Entry's
  # own currently-persisted field values). Both call sites build the same
  # `fields` shape first (see fields_from_entry/1 above), so this is the
  # single implementation of the canonical form -- there is no second,
  # independently-drifting copy.
  # -----------------------------------------------------------------------

  defp compute_hash(fields) do
    fields
    |> canonical_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_string(fields) do
    [
      netstring_required(uuid_string(fields.id)),
      netstring_required(uuid_string(fields.tenant_id)),
      netstring_optional(optional_uuid_string(fields.actor_id)),
      netstring_required(fields.action),
      netstring_required(fields.resource_type),
      netstring_required(fields.resource_id),
      netstring_required(Integer.to_string(DateTime.to_unix(fields.timestamp, :microsecond))),
      netstring_optional(canonical_json_or_nil(fields.before_state)),
      netstring_optional(canonical_json_or_nil(fields.after_state)),
      netstring_optional(fields.trace_id),
      netstring_optional(fields.prev_chain_hash)
    ]
    |> IO.iodata_to_binary()
  end

  defp uuid_string(uuid) when is_binary(uuid), do: uuid

  defp optional_uuid_string(nil), do: nil
  defp optional_uuid_string(uuid) when is_binary(uuid), do: uuid

  defp canonical_json_or_nil(nil), do: nil
  defp canonical_json_or_nil(map) when is_map(map), do: Jason.encode!(canonicalize(map))

  # Recursively rebuilds every map as a Jason.OrderedObject whose keys are
  # sorted lexicographically (byte-wise ascending), at every nesting level --
  # design §5.2. Lists are mapped over (order preserved -- JSON arrays are
  # already order-significant). Every other value is already
  # JSON-representable as-is (these maps are built only from allowlisted
  # struct fields, never arbitrary Elixir terms -- design §3.2).
  # Struct values (DateTime, NaiveDateTime, Decimal, ...) are left as-is --
  # `is_map/1` is true for a struct too, but a struct's own field order is
  # not "object key order" in the JSON sense (Jason.Encoder renders it as a
  # scalar/string, e.g. DateTime -> its ISO-8601 string), so it must not be
  # recursed into as if it were a plain map. This clause must come before the
  # plain-map clause below.
  defp canonicalize(%_struct_module{} = struct), do: struct

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp netstring_required(value) when is_binary(value) do
    "#{byte_size(value)}:#{value}"
  end

  defp netstring_optional(nil), do: "-1:"
  defp netstring_optional(value) when is_binary(value), do: netstring_required(value)
end
