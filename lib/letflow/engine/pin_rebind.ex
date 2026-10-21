defmodule Letflow.Engine.PinRebind do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  PIN-05 (REQ-060) — explicit instance pin rebind. Ports `src/engine/pin_rebind.zig`
  (R-Co, 388 lines). At design/implementation time R-Co's source tree was believed
  unreachable, so every behavioural claim in this module traced to REQ-060's own requirement text
  or to already-shipped Letflow code, cited by file/line, never to a second,
  independent read of R-Co. That gap is closed: the R-Co tree at
  `c:\Users\tvolo\dev\ai-dala\R-Co` is reachable, and REQ-110 read
  `src/engine/pin_rebind.zig` and `src/api/routes/pin_rebind.zig` directly, confirming
  this module's behaviour is `divergent_doc_only` against R-Co (no engine-behaviour
  change needed). See `lib/letflow/design/req060-pin-rebind.md` (the gate-approved
  design this module implements, its OQ-4/OQ-5) for the full call-order
  specification, error taxonomy, and open questions this moduledoc restates the
  load-bearing parts of.

  This module is **the sole write path to an instance's effective pin set after
  `INSTANCE_STARTED`**. No scheduled job, catalog publication, or definition
  promotion may change a running instance's pins through any other route — pins
  are otherwise immutable by design (`Letflow.Engine.PinResolver`'s own "no
  fallback, ever" section) — this module exists specifically to be the one
  deliberate, audited, explicit exception.

  ## Terminal-status naming note

  PIN-05's own requirement text says "FAILED", but neither R-Co's `InstanceStatus`
  enum nor Letflow's own `Letflow.EventStore.InstanceProjection.status`
  (`:active | :completed | :cancelled | :error`) has a `FAILED` variant — `ERROR`
  is the status PIN-05's text means, and `ERROR` (unlike `Letflow.Engine.cancel_instance/3`'s
  own EE-08 scope) counts as **terminal for rebind purposes specifically** — a
  running-but-halted-on-error instance's pins must not be silently changeable via
  this path either. This module does **not** call
  `Letflow.EventStore.InstanceProjection.terminal?/1` (which excludes `:error`) —
  it defines its own three-way eligibility check (`check_rebind_eligibility/1`,
  below).

  ## `Reconstruction`/`PinResolver` reuse

  This module calls `Letflow.Engine.PinResolver.reconstruct_effective_pins/2`
  (REQ-059, arity unchanged) to obtain the instance's current effective pin
  set, and appends its own `INSTANCE_PINS_REBOUND` event in a payload shape
  `Letflow.Engine.PinResolver.merge_effective_pins/3` folds — every
  `INSTANCE_PINS_REBOUND` event found, not just the most recent. That fold's
  provenance handling (rebound `source`/`resolved_id`/`source_event_id`) was
  fixed under ISS-0078 (GH#299) after this requirement shipped; see
  `pin_resolver.ex`'s own moduledoc and
  `lib/letflow/design/iss-0078-pin-rebind-provenance.md` — no change to this
  module was needed for that fix, the loss was entirely on the read side.

  ## `NOWAIT` locking convention

  Ported from `Letflow.Engine.Reconstruction`'s own `lock_projection_nowait/2`
  (`reconstruction.ex:706-720`), the only existing precedent in this codebase,
  chosen over `Letflow.Engine.cancel_instance/3`'s own blocking `lock("FOR UPDATE")`
  convention because REQ-060's own requirement text explicitly asks for
  immediate, distinct contention surfacing rather than blocking — see REQ-055's
  zero-cross-instance-contention rule (the lock here is `instance_id`-scoped
  only, same discipline as every other lock `Letflow.Engine`'s own EE-12 section
  inventories; that inventory should be extended with this module's own lock).

  ## Event-type registration is the caller's responsibility

  This module does **not** call `Letflow.EventStore.Registry.register_type/2` for
  `"INSTANCE_PINS_REBOUND"` — matching the `TASK_COMPLETED`/`INSTANCE_CANCELLED`
  precedent (registered by the caller/test fixture, not by provisioning or by the
  writing module itself), not the `INSTANCE_STARTED` precedent (auto-seeded by
  `Letflow.TenantProvisioning.replay_migrations/2`, which seeds no other event
  type — `tenant_provisioning.ex:508-544`'s own comment). See
  `test/letflow/engine_cancel_instance_test.exs:63-97` for the established
  register-your-own-event-type pattern this module's own callers/fixtures must
  follow.

  ## All-or-nothing invariant

  No `Repo` write of any kind happens until every requested entry has been
  validated against the current effective pin set — an `UnknownPinRef` on entry N
  means entries `1..N-1` (even if individually valid) are also not applied,
  because validation is a separate, complete pass over the whole request before
  the `Ecto.Multi`'s one event-append step ever runs.
  """

  alias Ecto.Multi
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine.IdempotentReplay
  alias Letflow.Engine.PinResolver
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceVisibility
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  import Ecto.Query

  @typedoc "Reused verbatim from REQ-059 — never redefined here."
  @type entry_kind :: PinResolver.kind()

  @typedoc "Caller-supplied request entry. `kind` may arrive as either the atom or its string form."
  @type rebind_entry :: %{
          kind: entry_kind() | String.t(),
          ref: String.t(),
          version: String.t()
        }

  @type rebind_attrs :: %{
          required(:entries) => [rebind_entry()],
          required(:reason) => String.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t()
        }

  @type rebind_opts :: [prefix: String.t()]

  @type changed_entry :: %{
          kind: entry_kind(),
          ref: String.t(),
          prior_version: String.t(),
          new_version: String.t()
        }

  @type rebind_result :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:changed) => [changed_entry()],
          required(:rebound_at) => DateTime.t(),
          optional(:replayed) => true
        }

  @type rebind_error ::
          {:error, :invalid_instance_id}
          | {:error, :idempotency_key_reuse}
          | {:error, :invalid_schema_name}
          | {:error, :missing_actor_id}
          | {:error, :missing_idempotency_key}
          | {:error, :invalid_reason}
          | {:error, :empty_entries}
          | {:error, {:malformed_entry, index :: non_neg_integer(), reason :: term()}}
          | {:error, :instance_not_found}
          | {:error, {:instance_not_rebindable, status :: :completed | :cancelled | :error}}
          | {:error, {:rebind_refused_owned_definition, :module, ref :: String.t()}}
          | {:error, {:unknown_pin_ref, entry_kind(), ref :: String.t()}}
          | {:error, {:concurrent_modification, instance_id :: Ecto.UUID.t()}}
          | {:error, {:event_append_failed, term()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @doc """
  The sole write path to an instance's effective pin set after `INSTANCE_STARTED`
  (PIN-05). Validates `attrs` entirely before opening any transaction (design doc
  §4 pre-transaction phase), then, inside one `Ecto.Multi`/`Repo.transaction/1`:
  locks the instance's `instance_projections` row `FOR UPDATE NOWAIT`, checks
  eligibility (`:active` only — `:completed`/`:cancelled`/`:error` all rejected as
  `:instance_not_rebindable`), reconstructs the current effective pin set
  (`Letflow.Engine.PinResolver.reconstruct_effective_pins/2`), resolves every
  requested entry against it (all-or-nothing — a single `UnknownPinRef` aborts
  the whole request), and appends exactly one `INSTANCE_PINS_REBOUND` event
  carrying only the entries whose requested version differs from the current
  pinned version.

  This is the module's **only** public entry point — `Letflow.Engine` gains no
  new `rebind_*` function of its own; a future HTTP route calls
  `rebind_pins/3` directly, the same way S4 calls
  `Letflow.Engine.Reconstruction.reconstruct_instance/2` directly for its own
  read route.
  """
  @spec rebind_pins(
          instance_id :: Ecto.UUID.t() | String.t(),
          attrs :: rebind_attrs(),
          opts :: rebind_opts()
        ) :: {:ok, rebind_result()} | rebind_error()
  def rebind_pins(instance_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, instance_id} <- cast_instance_id(instance_id),
         {:ok, actor_id, idempotency_key} <- fetch_actor_and_idempotency_key(attrs),
         {:ok, reason} <- fetch_reason(attrs),
         {:ok, entries} <- fetch_entries(attrs),
         {:ok, normalized_entries} <- normalize_and_validate_entries(entries),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      rebound_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      run_rebind_pins(
        instance_id,
        normalized_entries,
        actor_id,
        reason,
        idempotency_key,
        rebound_at,
        prefix
      )
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §4, M0.1-M0.6) -- zero Repo calls.
  # ---------------------------------------------------------------------

  # Defensive INV-8 guard, mirroring Letflow.Engine.cancel_instance/3's own
  # cast_instance_id/1 verbatim -- instance_id flows into a
  # `where p.instance_id == ^instance_id` query (M1, below); a malformed,
  # non-UUID-shaped value there must never reach it raw.
  defp cast_instance_id(instance_id) do
    case Ecto.UUID.cast(instance_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  # Mirrors Letflow.Engine.cancel_instance/3's own helper of the same name
  # verbatim.
  defp fetch_actor_and_idempotency_key(attrs) do
    case {Map.get(attrs, :actor_id), Map.get(attrs, :idempotency_key)} do
      {nil, _idempotency_key} -> {:error, :missing_actor_id}
      {_actor_id, nil} -> {:error, :missing_idempotency_key}
      {actor_id, idempotency_key} -> {:ok, actor_id, idempotency_key}
    end
  end

  # PIN-05 AC4's "missing or empty reason" collapsed into one distinct atom
  # (design doc §4 M0.3, §9 OQ-2) -- a nil reason and an empty/blank-string
  # reason are indistinguishable in the returned error.
  defp fetch_reason(attrs) do
    case Map.get(attrs, :reason) do
      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> {:error, :invalid_reason}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, :invalid_reason}
    end
  end

  # A missing :entries key and an empty list are the same "nothing to
  # rebind" condition (design doc §4 M0.4) -- one atom covers both.
  defp fetch_entries(attrs) do
    case Map.get(attrs, :entries) do
      entries when is_list(entries) and entries != [] -> {:ok, entries}
      _other -> {:error, :empty_entries}
    end
  end

  # design doc §4 M0.5 -- first failure for the whole list halts
  # immediately, index-tagged. On success, the whole list is normalized
  # (kind as atom, ref/version trimmed).
  defp normalize_and_validate_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case normalize_entry(entry, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_entry(entry, index) when is_map(entry) do
    with {:ok, raw_kind, raw_ref, raw_version} <- fetch_required_entry_fields(entry, index),
         {:ok, kind} <- validate_entry_kind(raw_kind, index),
         {:ok, ref} <- validate_entry_string(raw_ref, :invalid_ref, index),
         {:ok, version} <- validate_entry_string(raw_version, :invalid_version, index) do
      {:ok, %{kind: kind, ref: ref, version: version}}
    end
  end

  defp normalize_entry(_entry, index) do
    {:error, {:malformed_entry, index, :missing_or_unexpected_keys}}
  end

  # Step 1 of M0.5 -- exactly the three required keys, each non-nil, no
  # extra/unexpected key, tolerating either atom or string key form.
  defp fetch_required_entry_fields(entry, index) do
    normalized_keys =
      entry
      |> Map.keys()
      |> Enum.map(&normalize_entry_key/1)
      |> Enum.uniq()
      |> Enum.sort()

    raw_kind = Map.get(entry, :kind, Map.get(entry, "kind"))
    raw_ref = Map.get(entry, :ref, Map.get(entry, "ref"))
    raw_version = Map.get(entry, :version, Map.get(entry, "version"))

    if normalized_keys == [:kind, :ref, :version] and not is_nil(raw_kind) and
         not is_nil(raw_ref) and not is_nil(raw_version) do
      {:ok, raw_kind, raw_ref, raw_version}
    else
      {:error, {:malformed_entry, index, :missing_or_unexpected_keys}}
    end
  end

  defp normalize_entry_key(:kind), do: :kind
  defp normalize_entry_key(:ref), do: :ref
  defp normalize_entry_key(:version), do: :version
  defp normalize_entry_key("kind"), do: :kind
  defp normalize_entry_key("ref"), do: :ref
  defp normalize_entry_key("version"), do: :version
  defp normalize_entry_key(_other), do: :__unknown__

  # Step 2 of M0.5 -- mirrors PinResolver.normalize_kind/1's own tolerance
  # for both atom and string kind values (pin_resolver.ex:468-471).
  defp validate_entry_kind(kind, _index)
       when kind in [:catalog_entry, :module, :variable_schema] do
    {:ok, kind}
  end

  defp validate_entry_kind("catalog_entry", _index), do: {:ok, :catalog_entry}
  defp validate_entry_kind("module", _index), do: {:ok, :module}
  defp validate_entry_kind("variable_schema", _index), do: {:ok, :variable_schema}

  defp validate_entry_kind(value, index) do
    {:error, {:malformed_entry, index, {:invalid_kind, value}}}
  end

  # Steps 3/4 of M0.5 -- ref/version must each be a non-empty
  # (post-trim) binary.
  defp validate_entry_string(value, error_tag, index) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:malformed_entry, index, {error_tag, value}}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_entry_string(value, error_tag, index) do
    {:error, {:malformed_entry, index, {error_tag, value}}}
  end

  # ---------------------------------------------------------------------
  # Atomic phase (design doc §4, M1-M6) -- one Ecto.Multi.
  # ---------------------------------------------------------------------

  defp run_rebind_pins(
         instance_id,
         normalized_entries,
         actor_id,
         reason,
         idempotency_key,
         rebound_at,
         prefix
       ) do
    Multi.new()
    |> Multi.run(:instance_projection, fn repo, _changes ->
      lock_projection_nowait(repo, instance_id, prefix)
    end)
    |> Multi.run(:replay_check, fn repo, _changes ->
      # GH #2577 -- under the projection lock, ahead of :eligibility (a replay of an applied
      # rebind answers the original result even after the instance became terminal).
      replay_check(
        repo,
        instance_id,
        normalized_entries,
        actor_id,
        reason,
        idempotency_key,
        prefix
      )
    end)
    |> Multi.run(:eligibility, fn _repo, %{instance_projection: projection} ->
      check_rebind_eligibility(projection)
    end)
    |> Multi.run(:owner_guard, fn repo, _changes ->
      check_owned_definition_guard(repo, instance_id, normalized_entries, prefix)
    end)
    |> Multi.run(:effective_pins, fn _repo, _changes ->
      PinResolver.reconstruct_effective_pins(instance_id, prefix: prefix)
    end)
    |> Multi.run(:resolved_entries, fn _repo, %{effective_pins: effective_pins} ->
      resolve_entries_against_effective_pins(normalized_entries, effective_pins)
    end)
    |> Multi.run(:changed_entries, fn _repo, %{resolved_entries: resolved_entries} ->
      {:ok, compute_changed_entries(resolved_entries)}
    end)
    |> Multi.run(:event, fn _repo, %{changed_entries: changed_entries} ->
      append_pins_rebound_event(
        instance_id,
        changed_entries,
        actor_id,
        reason,
        idempotency_key,
        prefix
      )
    end)
    |> Repo.transaction()
    |> interpret_rebind_result(instance_id, rebound_at)
  end

  # GH #2590 / REQ-501 R3 (decision 0054 D6 property 4; design 4.9 Option N, D-R.14, OQ-R1):
  # a `:module` entry is refused ONLY for an instance whose PINNED definition is stamped by a
  # module install AND whose pinned snapshot graph declares `module_writes`. Every other
  # request, and every non-`:module` entry, is byte-identical to before: one extra read, only
  # for a request that carries a `:module` entry (a rare admin action). Fail closed: if the
  # snapshot declares module_writes and the pinned definition row cannot be read (deleted),
  # the entry is refused too. Runs under the projection lock M1 holds.
  defp check_owned_definition_guard(repo, instance_id, normalized_entries, prefix) do
    case Enum.find(normalized_entries, &(&1.kind == :module)) do
      nil ->
        {:ok, :not_applicable}

      %{ref: ref} ->
        snapshot = repo.get(InstanceDefinitionSnapshot, instance_id, prefix: prefix)

        if snapshot_declares_module_writes?(snapshot) and
             stamped_or_unreadable?(repo, snapshot.definition_id, prefix) do
          {:error, {:rebind_refused_owned_definition, :module, ref}}
        else
          {:ok, :allowed}
        end
    end
  end

  defp snapshot_declares_module_writes?(%InstanceDefinitionSnapshot{graph: %{"nodes" => nodes}})
       when is_list(nodes) do
    Enum.any?(nodes, fn
      %{"attributes" => %{"module_writes" => writes}} -> writes not in [nil, []]
      _other -> false
    end)
  end

  defp snapshot_declares_module_writes?(_no_snapshot_or_graph), do: false

  defp stamped_or_unreadable?(repo, definition_id, prefix) do
    case repo.one(
           from(d in ProcessDefinition, where: d.id == ^definition_id, select: {d.owner_module}),
           prefix: prefix
         ) do
      nil -> true
      {nil} -> false
      {_module_id} -> true
    end
  end

  # M1 -- ported from Letflow.Engine.Reconstruction's own
  # lock_projection_nowait/2 (reconstruction.ex:706-720), the only existing
  # NOWAIT precedent, against InstanceProjection instead of the
  # already-reconstructed InstanceState. Postgres surfaces NOWAIT contention
  # as SQLSTATE 55P03 (lock_not_available), raised by Postgrex as
  # %Postgrex.Error{postgres: %{code: :lock_not_available}} -- rescued here
  # specifically; any other Postgrex.Error re-raises unrescued (same
  # scope-limiting discipline the ported precedent itself documents). This
  # lock is held for the remainder of the transaction.
  defp lock_projection_nowait(repo, instance_id, prefix) do
    query =
      InstanceProjection
      |> where([p], p.instance_id == ^instance_id)
      |> InstanceVisibility.exclude_synthetic(prefix)
      |> lock("FOR UPDATE NOWAIT")

    case repo.one(query, prefix: prefix) do
      nil -> {:error, :instance_not_found}
      %InstanceProjection{} = projection -> {:ok, projection}
    end
  rescue
    error in Postgrex.Error ->
      if match?(%Postgrex.Error{postgres: %{code: :lock_not_available}}, error) do
        {:error, {:concurrent_modification, instance_id}}
      else
        reraise error, __STACKTRACE__
      end
  end

  # M2 -- pure, no I/O. This module's own three-way eligibility predicate --
  # deliberately NOT InstanceProjection.terminal?/1, whose scope excludes
  # :error and is therefore wrong for this call site (moduledoc's
  # "Terminal-status naming note").
  defp check_rebind_eligibility(%InstanceProjection{status: status})
       when status in [:completed, :cancelled, :error] do
    {:error, {:instance_not_rebindable, status}}
  end

  defp check_rebind_eligibility(%InstanceProjection{status: :active} = projection) do
    {:ok, projection}
  end

  # M4 -- per-entry {kind, ref} lookup against effective_pins (pure, no
  # I/O), ALL entries checked before ANY is accepted (PIN-05 AC2,
  # all-or-nothing). The first entry whose PinResolver.pin_for/3 call
  # returns {:error, {:pin_missing, ...}} halts the whole pass -- no entries
  # from this request are applied, including any that were individually
  # found.
  defp resolve_entries_against_effective_pins(normalized_entries, effective_pins) do
    normalized_entries
    |> Enum.reduce_while({:ok, []}, fn %{kind: kind, ref: ref} = entry, {:ok, acc} ->
      case PinResolver.pin_for(effective_pins, kind, ref) do
        {:ok, effective_pin} -> {:cont, {:ok, [{entry, effective_pin} | acc]}}
        {:error, {:pin_missing, kind, ref}} -> {:halt, {:error, {:unknown_pin_ref, kind, ref}}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _reason} = error -> error
    end
  end

  # M5 -- pure, no I/O. An entry whose requested version equals the current
  # pinned version is not a change and contributes no payload entry
  # (PIN-05 AC1).
  defp compute_changed_entries(resolved_entries) do
    resolved_entries
    |> Enum.filter(fn {entry, effective_pin} -> entry.version != effective_pin.version end)
    |> Enum.map(fn {entry, effective_pin} ->
      %{
        kind: entry.kind,
        ref: entry.ref,
        prior_version: effective_pin.version,
        new_version: entry.version
      }
    end)
  end

  # M6 -- appends the INSTANCE_PINS_REBOUND event (design doc §5). Every key
  # present in every entry is exactly the set
  # PinResolver.apply_rebind_event/2 already reads ("kind", "ref",
  # "new_version") plus "prior_version" (carried for audit/AC1 purposes,
  # never read by the fold). changed_entries may legitimately be [] --
  # exactly one event is always appended on a successful, valid, in-range
  # rebind call (design doc §9 OQ-3).
  defp append_pins_rebound_event(
         instance_id,
         changed_entries,
         actor_id,
         reason,
         idempotency_key,
         prefix
       ) do
    payload =
      Jason.encode!(%{
        entries:
          Enum.map(changed_entries, &Map.take(&1, [:kind, :ref, :prior_version, :new_version])),
        actor: actor_id,
        reason: reason
      })

    event_attrs = %{
      instance_id: instance_id,
      event_type: "INSTANCE_PINS_REBOUND",
      payload: payload,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }

    # GH #2577 -- last expression of the Multi step (see IdempotentReplay).
    case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
      {:ok, result} -> {:ok, result}
      {:error, {:idempotent_replay, _original}} = replay -> replay
      {:error, append_error} -> {:error, {:event_append_failed, append_error}}
    end
  end

  # GH #2577 -- is `idempotency_key` already claimed? Same request = the INSTANCE_PINS_REBOUND
  # of this instance by this actor with this reason whose stored (changed) entries are consistent
  # with the requested entries. The payload keeps only the CHANGED entries, so the binding is
  # best-effort: every stored entry must be requested at its `new_version`, and a requested
  # entry that is not stored must not be a stored {kind, ref} (it was a no-op). Anything else is
  # `:idempotency_key_reuse` and writes nothing.
  defp replay_check(repo, instance_id, entries, actor_id, reason, idempotency_key, prefix) do
    case IdempotentReplay.lookup(repo, idempotency_key, prefix) do
      :none ->
        {:ok, nil}

      {:ok, %EventStore.Event{} = original} ->
        if same_rebind_request?(original, instance_id, entries, actor_id, reason) do
          {:error, {:idempotent_replay, original}}
        else
          {:error, :idempotency_key_reuse}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp same_rebind_request?(
         %EventStore.Event{payload: payload} = original,
         instance_id,
         entries,
         actor_id,
         reason
       )
       when is_map(payload) do
    stored = Map.get(payload, "entries", [])

    original.event_type == "INSTANCE_PINS_REBOUND" and original.instance_id == instance_id and
      IdempotentReplay.same_uuid?(original.actor_id, actor_id) and
      Map.get(payload, "reason") == reason and is_list(stored) and
      Enum.all?(stored, &stored_entry_requested?(&1, entries)) and
      Enum.all?(entries, &request_entry_consistent?(&1, stored))
  end

  defp same_rebind_request?(_original, _instance_id, _entries, _actor_id, _reason), do: false

  defp stored_entry_requested?(stored, entries) do
    Enum.any?(entries, fn entry ->
      Atom.to_string(entry.kind) == stored["kind"] and entry.ref == stored["ref"] and
        entry.version == stored["new_version"]
    end)
  end

  # A requested entry is either one of the stored (changed) entries, or a no-op whose
  # {kind, ref} is absent from them.
  defp request_entry_consistent?(entry, stored) do
    case Enum.find(stored, &(&1["kind"] == Atom.to_string(entry.kind) and &1["ref"] == entry.ref)) do
      nil -> true
      match -> match["new_version"] == entry.version
    end
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §4's rebind_result()).
  # ---------------------------------------------------------------------

  # GH #2577: `rebound_at` is the appended event's own timestamp, so a same-key replay (which
  # answers the stored event's `created_at`) returns the identical value.
  defp interpret_rebind_result(
         {:ok, %{changed_entries: changed_entries, event: %{event: %{created_at: created_at}}}},
         instance_id,
         _rebound_at
       ) do
    {:ok, %{instance_id: instance_id, changed: changed_entries, rebound_at: created_at}}
  end

  # GH #2577 -- a same-key replay of an applied rebind: the stored (changed) entries and the
  # original event's timestamp, nothing written.
  defp interpret_rebind_result(
         {:error, :replay_check, {:idempotent_replay, original}, _changes},
         instance_id,
         _rebound_at
       ) do
    changed =
      original.payload
      |> Map.get("entries", [])
      |> Enum.map(fn entry ->
        %{
          kind: String.to_existing_atom(entry["kind"]),
          ref: entry["ref"],
          prior_version: entry["prior_version"],
          new_version: entry["new_version"]
        }
      end)

    {:ok,
     %{
       instance_id: instance_id,
       changed: changed,
       rebound_at: original.created_at,
       replayed: true
     }}
  end

  # Catch-all -- every Multi step's own callback above already maps its
  # failure to the exact error shape rebind_error() promises; this just
  # unwraps Ecto.Multi's {:error, failed_step, reason, changes_so_far}
  # envelope around whatever reason each step already produced.
  defp interpret_rebind_result(
         {:error, _failed_step, reason, _changes},
         _instance_id,
         _rebound_at
       ) do
    {:error, reason}
  end
end
