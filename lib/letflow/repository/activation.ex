defmodule Letflow.Repository.Activation do
  @moduledoc """
  Per-tenant artifact activation: the current-pointer half of REQ-203
  (REPO-08/09/10). See `lib/letflow/design/req203-artifact-activation.md` for
  the full design this module implements: §3 (`resolve/3`'s not-found
  semantics), §4 (`activate_group/4`'s `Ecto.Multi` shape and REPO-08's
  observability argument), §6 (`list_history/4`'s REQ-067 cursor contract).

  Tenant scoping follows the same convention every other context module in
  this codebase uses (`Letflow.Repository`, `Letflow.Audit`): every public
  function takes an explicit `prefix :: String.t()` argument and derives
  `tenant_id` from it via `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`.
  No function in this module accepts a separately-trusted, caller-supplied
  `tenant_id`.

  ## `artifact_activations` is one table with a real update path (design §2.1)

  Unlike `Letflow.Repository.Artifact`/`ArtifactVersion` (immutable at the DB
  level) and this module's own `Letflow.Repository.ActivationHistory`/
  `ActivationGroup` (append-only by construction, no update/delete function
  exposed), `artifact_activations` IS legitimately updated in place:
  activating a new version for an already-activated `(tenant, kind, name)`
  triple updates the existing row's `active_version_id`/`activated_at`/
  `activator_user_id` rather than inserting a new row. This is the mutable
  current-pointer half of this schema; `artifact_activation_history` is the
  immutable trail half.

  ## Relationship to REQ-195's `audit_entries` (AC10, design §7)

  An artifact activation produces BOTH a domain history row (this module's
  `artifact_activation_history`, via `activate_group/4`) AND a general audit
  entry (REQ-195's `audit_entries`, via `Letflow.Audit.append_multi/4`,
  called once per artifact activated). **These are not duplicates serving
  the same purpose:**

  | | `artifact_activation_history` (this module) | `audit_entries` (`Letflow.Audit`, REQ-195) |
  |---|---|---|
  | Scope | Subsystem-specific: only artifact activations. | Tenant-wide compliance trail across every audited resource type. |
  | Shape | Denormalized, purpose-built, typed columns (`previous_version_id`/`new_version_id`/`new_version_number`), directly joinable against `artifact_versions`. | Generic `resource_type`/`resource_id`/`before_state`/`after_state` (`jsonb`) shape covering every resource type. |
  | Mandatory field unique to it | `rationale` -- required, non-empty (REPO-10's free-text justification requirement). | No equivalent required-free-text field. |
  | Tamper-evidence | None -- no hash chain, no `verify_chain/2` equivalent. Protected instead by FK `on_delete: :restrict` (a version referenced here can never be deleted) and by having no exposed mutation path. | Hash-chained (`chain_hash`/`prev_chain_hash`), with a dedicated `verify_chain/2` recompute-based verification function. |
  | Consumer | `resolve/3` and this subsystem's own callers -- the artifact subsystem's own queryable lineage. | `Letflow.Routers.Audit` (REQ-196) -- the tenant-wide compliance/audit-log surface. |

  Both are populated by the same real-world activation event, independently
  -- `Letflow.Repository.Activation` never queries `audit_entries`, and
  `Letflow.Audit` never queries `artifact_activation_history`. **Neither
  table is ever deleted or replaced as "redundant with the other"** -- they
  serve different consumers, and only `audit_entries` carries
  tamper-evidence.

  One `Letflow.Audit.append_multi/4` call is made per artifact activated
  (not one summary row per group), matching this table's own one-row-
  per-artifact granularity and `req195`'s own per-resource-instance audit
  convention (design §7). `resource_id` is the activated version's own
  `artifact_id` (REQ-202 OQ-4's stable per-`(kind, name)` handle) -- it
  identifies the artifact, not this particular activation event.

  ## Functions deliberately NOT built (scope discipline, design §8)

  There is no `update/1`/`delete/1` on `artifact_activation_history` or
  `artifact_activation_groups` (append-only by construction). There is no
  general `update/1` on `artifact_activations` outside `activate_group/4`'s
  own internal upsert step -- the only legitimate way to change an
  activation is to activate a (possibly different) version through the full
  transactional path, which also produces the required history row. No
  route or controller is added by this requirement.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Api.Pagination
  alias Letflow.Audit
  alias Letflow.Repo
  alias Letflow.Repository.ActivationGroup
  alias Letflow.Repository.ActivationHistory
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.TenantProvisioning

  @primary_key {:activation_id, :binary_id, autogenerate: true}
  schema "artifact_activations" do
    field(:tenant_id, :binary_id)
    field(:artifact_kind, Ecto.Enum, values: Letflow.Repository.ArtifactKind.values())
    field(:artifact_name, :string)
    field(:active_version_id, :binary_id)
    field(:activated_at, :utc_datetime_usec)
    field(:activator_user_id, :binary_id)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @artifact_history_cursor_prefix "AH:"

  @type artifact_kind :: Letflow.Repository.artifact_kind()

  @type activation_input :: %{
          required(:artifact_kind) => artifact_kind(),
          required(:artifact_name) => String.t(),
          required(:version_id) => Ecto.UUID.t()
        }

  @type activate_group_result :: %{
          group: ActivationGroup.t(),
          activations: [t()],
          history: [ActivationHistory.t()]
        }

  @typedoc "REQ-067's opts shape for `list_history/4` -- see design §6."
  @type list_history_opts :: [cursor: String.t() | nil, page_size: pos_integer() | nil]

  @required_fields [
    :tenant_id,
    :artifact_kind,
    :artifact_name,
    :active_version_id,
    :activated_at,
    :activator_user_id
  ]

  @doc """
  Structural insert/update changeset for the `artifact_activations`
  current-pointer row, used by both branches of `upsert_activation_pointer/8`
  (the first-activation `repo.insert` and the re-activation `repo.update`).

  `foreign_key_constraint/3` on `:active_version_id` translates a real
  Postgres FK violation (a `version_id` with no matching `artifact_versions`
  row -- a plausible caller mistake, not a theoretical one, per REQ-203's
  Step 3b test-design-validator rework) into a changeset error instead of
  letting it propagate as an unhandled `Ecto.ConstraintError`, matching
  `active_group/4`'s own `@spec`-documented `{:error, {atom(),
  Ecto.Changeset.t()}}` contract. Constraint name matches the explicit name
  given to this FK in `priv/repo/migrations/20260831000001_create_artifact_activations.exs`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = activation, attrs) do
    activation
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:active_version_id,
      name: :artifact_activations_active_version_id_fkey
    )
  end

  @doc """
  Resolves the currently active version for `(artifact_kind, artifact_name)`,
  scoped to the tenant schema named by `prefix` (design §3).

  Returns `{:error, :not_activated}` -- never an arbitrary version, e.g.
  never falling back to "the latest version by `version_number`" -- when no
  `artifact_activations` row exists for the triple (AC8).
  """
  @spec resolve(artifact_kind(), String.t(), String.t()) ::
          {:ok, ArtifactVersion.t()}
          | {:error, :not_activated}
          | {:error, :invalid_schema_name}
  def resolve(artifact_kind, artifact_name, prefix)
      when is_binary(artifact_name) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(a in __MODULE__,
          where: a.artifact_kind == ^artifact_kind and a.artifact_name == ^artifact_name
        )

      case Repo.one(query, prefix: prefix) do
        nil ->
          {:error, :not_activated}

        %__MODULE__{active_version_id: version_id} ->
          version = Repo.get!(ArtifactVersion, version_id, prefix: prefix)
          {:ok, version}
      end
    end
  end

  @doc """
  Atomically activates a group of one or more artifacts (REPO-08), scoped to
  the tenant schema named by `prefix` (design §4).

  `activations` must be non-empty (`{:error, :empty_group}` otherwise) and
  contain no duplicate `(artifact_kind, artifact_name)` pair
  (`{:error, :duplicate_artifact_in_group}` otherwise, checked before any
  `Ecto.Multi` step is built -- design §4.2 step 1b). `rationale` must be
  non-blank (a validation-error tuple otherwise, via `validate_required/2`'s
  trim-leading/empty-value pipeline, which also rejects a whitespace-only
  string -- design §2.4).

  A single-artifact activation is the `length(activations) == 1` case of
  this same function (design §4.4) -- no separate entry point exists.

  For every artifact in the group, in order: locks (or, on first activation,
  finds no row to lock) the existing `artifact_activations` row for
  `(tenant_id, artifact_kind, artifact_name)` via `FOR UPDATE`, records
  `previous_version_id` (`nil` on first activation), upserts the pointer,
  inserts one `artifact_activation_history` row, and appends one
  `Letflow.Audit.append_multi/4` audit entry. All of this, plus the one
  `artifact_activation_groups` envelope row, is submitted to
  `Repo.transaction/1` exactly once (design §4.2 step 4) -- REPO-08's atomic,
  all-or-nothing guarantee: any step's failure rolls back every prior step,
  including every already-processed artifact in the group.
  """
  # TEST-ONLY seam (added by TEST-DESIGNER at REQ-203 Step 3, flagged for
  # REVIEWER; see design §4.3 and `test/letflow/repository/activation_test.exs`
  # AC1/AC2's concurrency test). No production call site passes this option,
  # and this type is deliberately `@typep` (private) rather than public: the
  # public `@spec activate_group/5` below types its 5th argument as plain
  # `keyword()`, not `test_opts()`, so a caller reading only the public
  # contract (`h Letflow.Repository.Activation.activate_group/5`, or editor
  # autocomplete against the `@spec`) genuinely does not see
  # `test_pause_after`/`test_pause_fun` -- this doc's shape is visible only to
  # a reader of this module's source (a `@typedoc` here would be discarded
  # anyway, since typedocs are only ever kept for public `@type`s -- hence a
  # plain comment, not `@typedoc`). `:test_pause_after` is the 1-based index
  # (in `activations` order) after whose `Multi.run/3` steps a pause step is
  # inserted; `:test_pause_fun` is a 0-arity function invoked synchronously
  # *inside the open transaction* at that point (expected to signal a waiting
  # test process and then block on a reply), giving a concurrent reader a real
  # window to observe the partially-applied, still-uncommitted state. Omitting
  # both opts (the default, `[]`) reproduces the exact `Multi` shape design
  # §4.2 describes, byte-for-byte -- this seam adds nothing to the production
  # path.
  #
  # Beyond the discoverability limit above, `maybe_add_test_pause_step/4`'s
  # functional clause (the only place `test_pause_fun` is ever invoked) is
  # additionally gated behind `@activation_test_hooks_enabled?`, resolved once
  # at compile time via `Application.compile_env(:letflow,
  # :activation_test_hooks_enabled?, false)` and defaulting to `false`. Only
  # `config/test.exs` sets it to `true` -- `config/dev.exs`/`config/prod.exs`
  # neither set it (so the `false` default holds) -- so a dev/prod build can
  # never execute the pause step regardless of what opts a caller supplies.
  # Matches this codebase's own established pattern for a test-only production
  # seam: `lib/letflow/design/req021-auth-plug-pipeline.md`'s OQ-5 (config-
  # resolved indirection, not ad hoc `Mix.env()` branching).
  @typep test_opts :: [test_pause_after: pos_integer(), test_pause_fun: (-> any())]

  # See @typep test_opts above for the full rationale. Resolved once at
  # compile time (not a runtime Mix.env() call, which is unavailable in a
  # compiled release) -- becomes a literal `true`/`false` in the compiled
  # BEAM code.
  @activation_test_hooks_enabled? Application.compile_env(
                                    :letflow,
                                    :activation_test_hooks_enabled?,
                                    false
                                  )

  @spec activate_group(
          [activation_input()],
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, activate_group_result()}
          | {:error, :empty_group}
          | {:error, :duplicate_artifact_in_group}
          | {:error, :invalid_schema_name}
          | {:error, {:group, Ecto.Changeset.t()}}
          | {:error, {atom(), Ecto.Changeset.t()}}
          | {:error, {:transaction_failed, Exception.t()}}
  def activate_group(activations, activator_user_id, rationale, prefix, opts \\ [])
      when is_list(activations) and is_binary(prefix) and is_list(opts) do
    try do
      with :ok <- validate_non_empty_group(activations),
           :ok <- validate_no_duplicate_artifacts(activations),
           {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
        activated_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        group_id = Ecto.UUID.generate()

        group_changeset =
          ActivationGroup.changeset(%ActivationGroup{}, %{
            group_id: group_id,
            tenant_id: tenant_id,
            activated_at: activated_at,
            activator_user_id: activator_user_id,
            rationale: rationale
          })

        if group_changeset.valid? do
          multi =
            Multi.new()
            |> Multi.insert(:group, group_changeset, prefix: prefix)

          multi =
            activations
            |> Enum.with_index(1)
            |> Enum.reduce(multi, fn {activation, index}, acc ->
              acc
              |> add_activation_steps(
                activation,
                index,
                tenant_id,
                activator_user_id,
                rationale,
                activated_at,
                group_id,
                prefix
              )
              |> maybe_add_test_pause_step(index, opts)
            end)

          multi
          |> Repo.transaction()
          |> format_activate_group_result(activations)
        else
          {:error, {:group, group_changeset}}
        end
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # TEST-ONLY (see @typep test_opts above) -- a no-op unless
  # @activation_test_hooks_enabled? is compiled in as `true` (only
  # config/test.exs does this) AND a test explicitly supplies both
  # `test_pause_after`/`test_pause_fun`. The `if @activation_test_hooks_enabled?`
  # below (a compile-time-constant branch, not a guard) is what makes this a
  # genuine no-op in a dev/prod build regardless of what opts a caller
  # supplies -- it is deliberately NOT expressed as a guard clause
  # (`when ... and @activation_test_hooks_enabled?`) because the compiler
  # statically proves a guard ANDed with a literal `false` can never succeed
  # and rejects the module under `--warnings-as-errors`; an `if` on the same
  # literal has no such restriction and still compiles away to nothing
  # (`unquote(@activation_test_hooks_enabled?)`'s `false` branch is the only
  # one reachable) in a dev/prod build.
  @spec maybe_add_test_pause_step(Multi.t(), pos_integer(), test_opts()) :: Multi.t()
  defp maybe_add_test_pause_step(multi, index, opts) do
    pause_after = Keyword.get(opts, :test_pause_after)
    pause_fun = Keyword.get(opts, :test_pause_fun)

    if @activation_test_hooks_enabled? and index == pause_after and is_function(pause_fun, 0) do
      Multi.run(multi, :__test_pause__, fn _repo, _changes -> {:ok, pause_fun.()} end)
    else
      multi
    end
  end

  defp validate_non_empty_group([]), do: {:error, :empty_group}
  defp validate_non_empty_group([_ | _]), do: :ok

  defp validate_no_duplicate_artifacts(activations) do
    pairs = Enum.map(activations, fn %{artifact_kind: k, artifact_name: n} -> {k, n} end)

    if length(pairs) == length(Enum.uniq(pairs)) do
      :ok
    else
      {:error, :duplicate_artifact_in_group}
    end
  end

  # One `Multi.run/3` step for the activation-pointer upsert, one for the
  # history-row insert, then an `Ecto.Multi.merge/2` step for the audit
  # entry -- `merge/2` is the idiom used here specifically because
  # `Letflow.Audit.append_multi/4`'s `attrs` argument is a fixed map, but the
  # audit entry's `before_state` depends on whether a prior
  # `artifact_activations` row existed, which is only known once the
  # activation step has actually run inside the transaction (design §4.2
  # step 3e). `merge/2`'s callback receives the accumulated `changes` map, so
  # `Audit.append_multi/4` can still be called with a fully-resolved `attrs`
  # map, built at merge-time rather than at pipeline-build-time.
  defp add_activation_steps(
         multi,
         %{artifact_kind: artifact_kind, artifact_name: artifact_name, version_id: version_id},
         index,
         tenant_id,
         activator_user_id,
         rationale,
         activated_at,
         group_id,
         prefix
       ) do
    activation_step = {:activation, artifact_kind, artifact_name}
    history_step = {:history, artifact_kind, artifact_name}
    # `Letflow.Audit.append_multi/4`'s own @spec constrains `step_name` to a
    # bare `atom()` (unlike this module's own `Multi.run/3` step names, which
    # may be any term) -- an index-derived atom keeps the atom table bounded
    # by the group's own (small, caller-supplied-length) size rather than by
    # caller-supplied `artifact_name` content, avoiding unbounded dynamic
    # atom creation from untrusted input.
    audit_step = :"audit_step_#{index}"

    multi
    |> Multi.run(activation_step, fn repo, _changes ->
      upsert_activation_pointer(
        repo,
        tenant_id,
        artifact_kind,
        artifact_name,
        version_id,
        activator_user_id,
        activated_at,
        prefix
      )
    end)
    |> Multi.run(history_step, fn repo, changes ->
      insert_activation_history(
        repo,
        changes,
        activation_step,
        tenant_id,
        artifact_kind,
        artifact_name,
        version_id,
        activator_user_id,
        activated_at,
        rationale,
        group_id,
        prefix
      )
    end)
    |> Multi.merge(fn changes ->
      {previous, activation} = Map.fetch!(changes, activation_step)
      {_history, artifact_id} = Map.fetch!(changes, history_step)

      Audit.append_multi(
        Multi.new(),
        audit_step,
        %{
          actor_id: activator_user_id,
          action: "artifact.activate",
          resource_type: "artifact",
          resource_id: artifact_id,
          before_state: previous && Audit.struct_state(previous),
          after_state: Audit.struct_state(activation)
        },
        prefix
      )
    end)
  end

  defp upsert_activation_pointer(
         repo,
         tenant_id,
         artifact_kind,
         artifact_name,
         version_id,
         activator_user_id,
         activated_at,
         prefix
       ) do
    query =
      from(a in __MODULE__,
        where: a.artifact_kind == ^artifact_kind and a.artifact_name == ^artifact_name,
        lock: "FOR UPDATE"
      )

    case repo.one(query, prefix: prefix) do
      nil ->
        %__MODULE__{}
        |> changeset(%{
          tenant_id: tenant_id,
          artifact_kind: artifact_kind,
          artifact_name: artifact_name,
          active_version_id: version_id,
          activated_at: activated_at,
          activator_user_id: activator_user_id
        })
        |> repo.insert(prefix: prefix)
        |> case do
          {:ok, activation} -> {:ok, {nil, activation}}
          {:error, changeset} -> {:error, changeset}
        end

      %__MODULE__{} = existing ->
        existing
        |> changeset(%{
          active_version_id: version_id,
          activated_at: activated_at,
          activator_user_id: activator_user_id
        })
        |> repo.update(prefix: prefix)
        |> case do
          {:ok, updated} -> {:ok, {existing, updated}}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  # No `foreign_key_constraint/3` is added to `ActivationHistory.changeset/2`
  # for this table's three FKs -- unlike `Activation.changeset/2`'s
  # `:active_version_id` fix above, each is unreachable by construction
  # within this same `Ecto.Multi` transaction (Postgres FKs are checked
  # IMMEDIATE, not DEFERRABLE, by default -- this migration never opts into
  # deferred checking):
  #   * `new_version_id` is the same `version_id` `upsert_activation_pointer/8`
  #     just wrote into `artifact_activations.active_version_id` earlier in
  #     this same transaction (`activation_step` runs before `history_step`
  #     in `add_activation_steps/9`) -- if that FK check had failed, this
  #     step would never run at all.
  #   * `previous_version_id` is read back from an *existing*
  #     `artifact_activations` row's `active_version_id`, which was itself
  #     already FK-validated at that row's own insert/update time, and
  #     `on_delete: :restrict` means a referenced version can never
  #     disappear later.
  #   * `group_id` is the group row's own primary key, generated by this same
  #     call and inserted as the Multi's `:group` step *before* any
  #     `add_activation_steps/9` step runs -- if that insert had failed, the
  #     `with` chain's `Multi.insert(:group, ...)` failure would abort the
  #     whole transaction before this function is ever reached.
  defp insert_activation_history(
         repo,
         changes,
         activation_step,
         tenant_id,
         artifact_kind,
         artifact_name,
         version_id,
         activator_user_id,
         activated_at,
         rationale,
         group_id,
         prefix
       ) do
    {previous, _activation} = Map.fetch!(changes, activation_step)
    previous_version_id = previous && previous.active_version_id

    %ArtifactVersion{artifact_id: artifact_id, version_number: version_number} =
      repo.get!(ArtifactVersion, version_id, prefix: prefix)

    %ActivationHistory{}
    |> ActivationHistory.changeset(%{
      tenant_id: tenant_id,
      artifact_kind: artifact_kind,
      artifact_name: artifact_name,
      previous_version_id: previous_version_id,
      new_version_id: version_id,
      new_version_number: version_number,
      activator_user_id: activator_user_id,
      activated_at: activated_at,
      rationale: rationale,
      group_id: group_id
    })
    |> repo.insert(prefix: prefix)
    |> case do
      {:ok, history} -> {:ok, {history, artifact_id}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp format_activate_group_result({:ok, changes}, activations) do
    history =
      Enum.map(activations, fn %{artifact_kind: k, artifact_name: n} ->
        {history_row, _artifact_id} = Map.fetch!(changes, {:history, k, n})
        history_row
      end)

    activation_rows =
      Enum.map(activations, fn %{artifact_kind: k, artifact_name: n} ->
        {_previous, activation} = Map.fetch!(changes, {:activation, k, n})
        activation
      end)

    {:ok, %{group: changes.group, activations: activation_rows, history: history}}
  end

  defp format_activate_group_result(
         {:error, _failed_step, %Ecto.Changeset{} = changeset, _changes},
         _activations
       ) do
    {:error, {:validation, changeset}}
  end

  defp format_activate_group_result({:error, failed_step, reason, _changes}, _activations) do
    {:error, {failed_step, reason}}
  end

  @doc """
  Chronological, paginated activation history (REPO-10, REQ-067's cursor
  contract -- design §6), scoped to the tenant schema named by `prefix`.

  Two call shapes: `artifact_kind`/`artifact_name` both `nil` lists the
  whole tenant's activation history; both non-`nil` lists history for
  exactly that one `(artifact_kind, artifact_name)` pair. Both are ordered
  newest-first (`activated_at desc, history_id desc`).
  """
  @spec list_history(
          artifact_kind() | nil,
          String.t() | nil,
          String.t(),
          list_history_opts()
        ) ::
          {:ok, Pagination.Page.t(ActivationHistory.t())}
          | {:error, :invalid_schema_name}
          | {:error, :page_size_too_large}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :invalid_cursor}
  def list_history(artifact_kind, artifact_name, prefix, opts \\ [])
      when is_binary(prefix) and is_list(opts) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, page_size} <- Pagination.validate_page_size(Keyword.get(opts, :page_size)),
         {:ok, cursor_seek} <- decode_history_cursor(Keyword.get(opts, :cursor)) do
      rows =
        ActivationHistory
        |> filter_by_artifact(artifact_kind, artifact_name)
        |> filter_by_history_cursor(cursor_seek)
        |> order_by([h], desc: h.activated_at, desc: h.history_id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page, next_cursor} = split_history_page(rows, page_size)

      {:ok, Pagination.page_response(page, next_cursor)}
    end
  end

  defp filter_by_artifact(query, nil, nil), do: query

  defp filter_by_artifact(query, artifact_kind, artifact_name) do
    where(query, [h], h.artifact_kind == ^artifact_kind and h.artifact_name == ^artifact_name)
  end

  defp filter_by_history_cursor(query, nil), do: query

  defp filter_by_history_cursor(query, {activated_at, history_id}) do
    from(h in query,
      where: {h.activated_at, h.history_id} < {^activated_at, ^history_id}
    )
  end

  defp decode_history_cursor(nil), do: {:ok, nil}

  defp decode_history_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @artifact_history_cursor_prefix,
           byte_size(@artifact_history_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_history_seek(cursor)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"AH:<mint_time_us>:<history_id>:<activated_at_us>"` -- the
  # first slot after the prefix is always the mint-time timestamp
  # decode_cursor/4's expiry check reads, never a domain value (same idiom
  # `Letflow.Repository.list_versions/4`'s cursor helpers use).
  defp decode_history_seek(%Pagination.Cursor{inner: inner}) do
    case Pagination.decode_seek_parts(inner, @artifact_history_cursor_prefix, [
           :skip,
           :uuid,
           :datetime_us
         ]) do
      {:ok, [history_id, activated_at]} -> {:ok, {activated_at, history_id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp split_history_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_history_next_cursor(List.last(page))}
  end

  defp split_history_page(rows, _page_size), do: {rows, nil}

  defp build_history_next_cursor(%ActivationHistory{
         history_id: history_id,
         activated_at: activated_at
       }) do
    mint_time_us = System.system_time(:microsecond)
    activated_at_us = DateTime.to_unix(activated_at, :microsecond)

    @artifact_history_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, history_id, activated_at_us)
    |> Pagination.encode_cursor()
  end
end
