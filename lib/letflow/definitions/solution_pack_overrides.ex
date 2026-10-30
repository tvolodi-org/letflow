defmodule Letflow.Definitions.SolutionPackOverrides do
  @moduledoc """
  A tenant's named, versioned, append-only deviation from an installed solution pack
  (REQ-596 / GH #3353 part A, decision 0069 D2/D3/D5). This slice is storage and the writer only:
  no route, no permission, no HTTP, and only the REQ-610 activation reads the table (the update plan
  is a later slice). HTTP mapping of the error tuples below is part B.

  Functions (every one takes the tenant schema name `prefix` first, INV-1):

    * `create/5`, `new_version/6`, `retire/4` -- each writes one new row and one audit entry in
      one transaction; no row is ever updated or deleted (a source-scan test pins this).
    * `latest/2`, `history/2` -- reads.
    * `closed_list/0` -- the closed list of overridable properties (one module attribute).

  Results are `{:ok, %SolutionPackOverride{}}` or `{:error, reason}`, `reason` one of
  `:reason_required`, `:property_not_overridable`, `:invalid_patch_value`, `:not_found`,
  `:override_exists`, `:override_version_taken`, `:override_retired`, `:busy`, `:invalid_input`,
  `:audit_failed`. `:audit_failed` covers EVERY write-transaction failure (the audit table being
  gone is the usual cause, but any other database error maps to it too); part B maps it to a 503,
  not a 422 or a 500. `new_version`/`retire` serialise on a per-artefact advisory lock; with
  `base_version: nil` two concurrent callers write consecutive versions, so part B must always send
  `base_version` to get `:override_version_taken` for the loser.

  ## Closed list (D2)

  `closed_list/0`. Only the listed dotted paths of a `process_definition` patch are accepted; graph
  structure, gateway expressions, variable names and types, scripts and every unlisted path return
  `{:error, :property_not_overridable}` and write nothing; a mixed patch is refused whole.
  `settings.<key>` is accepted only for a key of the `settings_schema` of the module that wraps the
  pack. `variable_schema` has no safe overridable path (open question 3), so every
  `variable_schema` patch is refused. Any other `artefact_type` returns the same error tuple.

  ## Storage and audit

  The patch is stored in the tenant row only. The audit entry carries `pack_id`, `artefact_type`,
  `artefact_id`, `override_id`, `override_version`, `patch_hash`, and the reason, with the actor on
  the entry, and never a patch value (INV-4 style rule of D5). The two reads of the global pack
  tables (active install version, artefact base existence) select a version string and `1`, never
  patch or base content, and run with an explicit `prefix: "public"`.

  Decision 0006 D2 wins over 0069 D6: no `tenant_id` column (open question 4).
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Letflow.Audit
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.SolutionPackOverride
  alias Letflow.Modules.Catalog
  alias Letflow.Repo

  require Logger

  @node_id "[A-Za-z0-9_-]{1,255}"

  # Closed list of overridable properties, pinned by a test. `{regex, value_kind}` per artefact
  # type; patch keys are flat dotted strings and must match a regex on the whole string.
  @overridable %{
    "process_definition" => [
      {"\\Anodes\\.#{@node_id}\\.label\\z", :text},
      {"\\Anodes\\.#{@node_id}\\.attributes\\.role\\z", :text},
      {"\\Anodes\\.#{@node_id}\\.attributes\\.escalation_role\\z", :text},
      {"\\Anodes\\.#{@node_id}\\.attributes\\.escalation_timer_duration\\z", :duration},
      {"\\Anodes\\.#{@node_id}\\.attributes\\.duration_iso8601\\z", :duration},
      {"\\Asettings\\.[^.\\s][^\\s]{0,254}\\z", :setting}
    ],
    "variable_schema" => []
  }

  @max_patch_keys 100
  @max_patch_bytes 16_384
  @max_reason 2000
  @duration_source ~S"\AP(?:\d+Y)?(?:\d+M)?(?:\d+W)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+S)?)?\z"

  @type error ::
          :reason_required
          | :property_not_overridable
          | :invalid_patch_value
          | :not_found
          | :override_exists
          | :override_version_taken
          | :override_retired
          | :busy
          | :invalid_input
          | :audit_failed

  @doc "The closed list of overridable properties, as `%{artefact_type => [{regex_source, value_kind}]}`."
  @spec closed_list() :: %{String.t() => [{String.t(), atom()}]}
  def closed_list, do: @overridable

  # -- reads --------------------------------------------------------------------------------

  @doc "The newest row of `override_id`."
  @spec latest(String.t(), term()) :: {:ok, SolutionPackOverride.t()} | {:error, :not_found}
  def latest(prefix, override_id) when is_binary(prefix) do
    with {:ok, id} <- cast_uuid(override_id),
         %SolutionPackOverride{} = row <- latest_row(prefix, id) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Every row of `override_id`, oldest version first."
  @spec history(String.t(), term()) :: [SolutionPackOverride.t()]
  def history(prefix, override_id) when is_binary(prefix) do
    case cast_uuid(override_id) do
      {:ok, id} ->
        Repo.all(
          from(o in SolutionPackOverride,
            where: o.override_id == ^id,
            order_by: [asc: o.override_version]
          ),
          prefix: prefix
        )

      :error ->
        []
    end
  end

  @doc """
  The newest row per `override_id` of `pack_id` (retired ones included, with their status), oldest
  override first. `{:error, :not_found}` when `tenant_id` has no active install of `pack_id`.
  """
  @spec list(String.t(), term(), String.t()) ::
          {:ok, [SolutionPackOverride.t()]} | {:error, :not_found}
  def list(prefix, tenant_id, pack_id) when is_binary(prefix) and is_binary(pack_id) do
    with {:ok, tenant} <- cast_tenant(tenant_id),
         {:ok, _version} <- active_install_version(tenant, pack_id) do
      rows =
        Repo.all(
          from(o in SolutionPackOverride,
            where: o.pack_id == ^pack_id,
            distinct: o.override_id,
            order_by: [asc: o.override_id, desc: o.override_version]
          ),
          prefix: prefix
        )

      first_inserted =
        Map.new(
          Repo.all(
            from(o in SolutionPackOverride,
              where: o.pack_id == ^pack_id and o.override_version == 1,
              select: {o.override_id, o.inserted_at}
            ),
            prefix: prefix
          )
        )

      {:ok, Enum.sort_by(rows, &{Map.get(first_inserted, &1.override_id), &1.override_id})}
    end
  end

  def list(_prefix, _tenant_id, _pack_id), do: {:error, :not_found}

  @doc """
  The newest row of `override_id`, only when it belongs to `pack_id` and `tenant_id` has an active
  install of that pack; otherwise `{:error, :not_found}` (an absent id, another pack's override and
  a pack without install are indistinguishable, INV-5).
  """
  @spec fetch(String.t(), term(), String.t(), term()) ::
          {:ok, SolutionPackOverride.t()} | {:error, :not_found}
  def fetch(prefix, tenant_id, pack_id, override_id)
      when is_binary(prefix) and is_binary(pack_id) do
    with {:ok, tenant} <- cast_tenant(tenant_id),
         {:ok, row} <- latest(prefix, override_id),
         true <- row.pack_id == pack_id,
         {:ok, _version} <- active_install_version(tenant, pack_id) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  def fetch(_prefix, _tenant_id, _pack_id, _override_id), do: {:error, :not_found}

  defp cast_tenant(tenant_id) do
    case cast_uuid(tenant_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # -- writes -------------------------------------------------------------------------------

  @doc """
  Creates version 1 of a new override for `(pack_id, artefact_type, artefact_id)`.

  `tenant_id` comes from the auth context of the caller, never from `input`; it is used only for
  the two reads of the global pack tables. Options: `:modules` (test seam for the settings lookup,
  default `Catalog.entry_modules()`; never forward request data into it).
  """
  @spec create(String.t(), term(), term(), map(), keyword()) ::
          {:ok, SolutionPackOverride.t()} | {:error, error()}
  def create(prefix, tenant_id, actor, input, opts \\ [])
      when is_binary(prefix) and is_map(input) do
    with {:ok, reason} <- check_reason(input),
         {:ok, type} <- check_type(input),
         {:ok, pack_id} <- check_text(Map.get(input, :pack_id)),
         {:ok, artefact_id} <- check_text(Map.get(input, :artefact_id)),
         {:ok, patch} <- check_patch(type, pack_id, Map.get(input, :patch), opts),
         {:ok, tenant} <- cast_uuid_input(tenant_id),
         {:ok, actor} <- cast_uuid_input(actor) do
      transact(prefix, fn ->
        lock!(prefix, [pack_id, type, artefact_id])

        with :ok <- no_active_override(prefix, pack_id, type, artefact_id),
             {:ok, version} <- active_install_version(tenant, pack_id),
             :ok <- artefact_covered(tenant, pack_id, type, artefact_id) do
          write(prefix, actor, "solution_pack.override_created", %{
            override_id: Ecto.UUID.generate(),
            override_version: 1,
            pack_id: pack_id,
            artefact_type: type,
            artefact_id: artefact_id,
            made_against: version,
            patch: patch,
            status: "active",
            reason: reason
          })
        end
      end)
    end
  end

  @doc """
  Writes the next version of `override_id` with a new patch. `base_version` (a positive integer or
  nil) is the version the caller read; a different latest version returns `:override_version_taken`.
  """
  @spec new_version(String.t(), term(), term(), term(), map(), keyword()) ::
          {:ok, SolutionPackOverride.t()} | {:error, error()}
  def new_version(prefix, tenant_id, actor, override_id, input, opts \\ [])
      when is_binary(prefix) and is_map(input) do
    with {:ok, reason} <- check_reason(input),
         {:ok, id} <- cast_override_id(override_id),
         {:ok, base} <- check_base_version(input),
         {:ok, tenant} <- cast_uuid_input(tenant_id),
         {:ok, actor} <- cast_uuid_input(actor),
         %SolutionPackOverride{} = first <- latest_row(prefix, id) || {:error, :not_found},
         {:ok, patch} <-
           check_patch(first.artefact_type, first.pack_id, Map.get(input, :patch), opts) do
      transact(prefix, fn ->
        lock!(prefix, [first.pack_id, first.artefact_type, first.artefact_id])

        with {:ok, current} <- locked_latest(prefix, id, base),
             {:ok, version} <- active_install_version(tenant, current.pack_id) do
          write(prefix, actor, "solution_pack.override_version_written", %{
            override_id: id,
            override_version: current.override_version + 1,
            pack_id: current.pack_id,
            artefact_type: current.artefact_type,
            artefact_id: current.artefact_id,
            made_against: version,
            patch: patch,
            status: "active",
            reason: reason
          })
        end
      end)
    end
  end

  @doc "Retires `override_id`: appends a row with status `retired` and an empty patch."
  @spec retire(String.t(), term(), term(), map()) ::
          {:ok, SolutionPackOverride.t()} | {:error, error()}
  def retire(prefix, actor, override_id, input) when is_binary(prefix) and is_map(input) do
    with {:ok, reason} <- check_reason(input),
         {:ok, id} <- cast_override_id(override_id),
         {:ok, base} <- check_base_version(input),
         {:ok, actor} <- cast_uuid_input(actor),
         %SolutionPackOverride{} = first <- latest_row(prefix, id) || {:error, :not_found} do
      transact(prefix, fn ->
        lock!(prefix, [first.pack_id, first.artefact_type, first.artefact_id])

        with {:ok, current} <- locked_latest(prefix, id, base) do
          write(prefix, actor, "solution_pack.override_retired", %{
            override_id: id,
            override_version: current.override_version + 1,
            pack_id: current.pack_id,
            artefact_type: current.artefact_type,
            artefact_id: current.artefact_id,
            made_against: current.made_against,
            patch: %{},
            status: "retired",
            reason: reason
          })
        end
      end)
    end
  end

  # -- the transaction ----------------------------------------------------------------------

  defp transact(prefix, fun) do
    case Repo.transaction(
           fn ->
             SQL.query!(Repo, "SET LOCAL lock_timeout = '2s'")
             SQL.query!(Repo, "SET LOCAL statement_timeout = '15s'")

             case fun.() do
               {:ok, row} -> row
               {:error, reason} -> Repo.rollback(reason)
             end
           end,
           prefix: prefix
         ) do
      {:ok, row} -> {:ok, row}
      {:error, {:audit_failed, _}} -> {:error, :audit_failed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :lock_not_available} ->
          {:error, :busy}

        %{code: :query_canceled} ->
          {:error, :busy}

        %{code: :unique_violation} ->
          {:error, :override_version_taken}

        other ->
          # the transaction is rolled back; nothing was written (INV-8). Only the code is logged.
          Logger.error("solution pack override write failed: #{inspect(Map.get(other, :code))}")
          {:error, :audit_failed}
      end
  end

  # One lock per (schema, pack, type, artefact); the key is a bound parameter (INV-7).
  defp lock!(prefix, parts) do
    key = Enum.join([prefix | parts], "|")
    SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp locked_latest(prefix, id, base) do
    case latest_row(prefix, id) do
      nil ->
        {:error, :not_found}

      %SolutionPackOverride{status: "retired"} ->
        {:error, :override_retired}

      %SolutionPackOverride{override_version: v} when not is_nil(base) and v != base ->
        {:error, :override_version_taken}

      row ->
        {:ok, row}
    end
  end

  defp write(prefix, actor, action, attrs) do
    patch_hash = hash_patch(attrs.patch)

    row =
      struct(
        SolutionPackOverride,
        Map.merge(attrs, %{
          patch_hash: patch_hash,
          created_by: actor,
          inserted_at: DateTime.utc_now()
        })
      )

    changeset =
      row
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:override_version,
        name: :uq_solution_pack_override_version
      )

    case Repo.insert(changeset, prefix: prefix) do
      {:ok, inserted} ->
        audit(prefix, actor, action, inserted)

      {:error, _changeset} ->
        {:error, :override_version_taken}
    end
  end

  defp audit(prefix, actor, action, row) do
    entry = %{
      actor_id: actor,
      action: action,
      resource_type: "solution_pack_override",
      resource_id: row.override_id,
      before_state: nil,
      after_state: %{
        "pack_id" => row.pack_id,
        "artefact_type" => row.artefact_type,
        "artefact_id" => row.artefact_id,
        "override_id" => row.override_id,
        "override_version" => row.override_version,
        "patch_hash" => row.patch_hash,
        "reason" => row.reason
      }
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> {:ok, row}
      {:error, reason} -> {:error, {:audit_failed, reason}}
    end
  end

  # -- queries ------------------------------------------------------------------------------

  defp latest_row(prefix, id) do
    Repo.one(
      from(o in SolutionPackOverride,
        where: o.override_id == ^id,
        order_by: [desc: o.override_version],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp no_active_override(prefix, pack_id, type, artefact_id) do
    rows =
      Repo.all(
        from(o in SolutionPackOverride,
          where:
            o.pack_id == ^pack_id and o.artefact_type == ^type and o.artefact_id == ^artefact_id,
          distinct: o.override_id,
          order_by: [asc: o.override_id, desc: o.override_version]
        ),
        prefix: prefix
      )

    if Enum.any?(rows, &(&1.status == "active")), do: {:error, :override_exists}, else: :ok
  end

  # Global pack tables: existence and the version string only, never patch or base content.
  defp active_install_version(tenant_id, pack_id) do
    query =
      from(i in SolutionPackInstall,
        where: i.tenant_id == ^tenant_id and i.pack_id == ^pack_id and i.status == :active,
        select: i.installed_version
      )

    case Repo.one(query, prefix: "public") do
      version when is_binary(version) -> {:ok, version}
      nil -> {:error, :not_found}
    end
  end

  defp artefact_covered(tenant_id, pack_id, type, artefact_id) do
    query =
      from(b in SolutionPackArtefactBase,
        where:
          b.tenant_id == ^tenant_id and b.pack_id == ^pack_id and b.artefact_type == ^type and
            b.artefact_id == ^artefact_id,
        select: 1,
        limit: 1
      )

    if Repo.one(query, prefix: "public") == 1, do: :ok, else: {:error, :not_found}
  end

  # -- input checks -------------------------------------------------------------------------

  defp check_reason(input) do
    case Map.get(input, :reason) do
      reason when is_binary(reason) ->
        trimmed = String.trim(reason)

        cond do
          trimmed == "" -> {:error, :reason_required}
          String.length(reason) > @max_reason -> {:error, :invalid_input}
          true -> {:ok, reason}
        end

      _ ->
        {:error, :reason_required}
    end
  end

  defp check_type(input) do
    case Map.get(input, :artefact_type) do
      type when is_map_key(@overridable, type) -> {:ok, type}
      _ -> {:error, :property_not_overridable}
    end
  end

  defp check_text(value) when is_binary(value) do
    if String.trim(value) != "" and String.length(value) <= 255,
      do: {:ok, value},
      else: {:error, :invalid_input}
  end

  defp check_text(_), do: {:error, :invalid_input}

  defp check_base_version(input) do
    case Map.get(input, :base_version) do
      nil -> {:ok, nil}
      v when is_integer(v) and v > 0 -> {:ok, v}
      _ -> {:error, :invalid_input}
    end
  end

  defp check_patch(type, pack_id, patch, opts) when is_map(patch) do
    cond do
      map_size(patch) == 0 -> {:error, :invalid_patch_value}
      map_size(patch) > @max_patch_keys -> {:error, :invalid_patch_value}
      true -> check_patch_entries(type, pack_id, patch, opts)
    end
  end

  defp check_patch(_type, _pack_id, _patch, _opts), do: {:error, :invalid_patch_value}

  defp check_patch_entries(type, pack_id, patch, opts) do
    rules = Map.fetch!(@overridable, type)
    modules = Keyword.get(opts, :modules, Catalog.entry_modules())

    # all-or-nothing: a path error beats a value error, and the first offender decides
    kinds =
      Enum.reduce_while(patch, {:ok, []}, fn {path, value}, {:ok, acc} ->
        case path_kind(rules, path, pack_id, modules) do
          {:ok, kind} -> {:cont, {:ok, [{kind, value} | acc]}}
          :error -> {:halt, {:error, :property_not_overridable}}
        end
      end)

    with {:ok, pairs} <- kinds,
         true <- Enum.all?(pairs, fn {kind, value} -> valid_value?(kind, value) end),
         true <- byte_size(canonical_json(patch)) <= @max_patch_bytes do
      {:ok, patch}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_patch_value}
    end
  end

  defp path_kind(rules, path, pack_id, modules) when is_binary(path) do
    case Enum.find(rules, fn {source, _kind} -> Regex.match?(Regex.compile!(source), path) end) do
      {_source, :setting} ->
        "settings." <> key = path
        if key in settings_keys(pack_id, modules), do: {:ok, :setting}, else: :error

      {_source, kind} ->
        {:ok, kind}

      nil ->
        :error
    end
  end

  defp path_kind(_rules, _path, _pack_id, _modules), do: :error

  defp valid_value?(:text, v), do: is_binary(v) and String.length(v) in 1..255
  defp valid_value?(:duration, v), do: is_binary(v) and valid_duration?(v)
  defp valid_value?(:setting, v), do: is_number(v) or is_boolean(v) or is_binary(v)

  defp valid_duration?(v) do
    Regex.match?(Regex.compile!(@duration_source), v) and v != "P" and
      not String.ends_with?(v, "T")
  end

  # Keys of the `settings_schema` "properties" of the module(s) that wrap `pack_id`. No such
  # module, no schema or an unreadable pack file: no key (every `settings.*` path is refused).
  defp settings_keys(pack_id, modules) do
    Enum.flat_map(modules, fn module ->
      manifest = module.manifest()

      with pack_path when is_binary(pack_path) <- manifest.pack,
           {:ok, contents} <-
             File.read(Path.join(Application.app_dir(:letflow, "priv"), pack_path)),
           {:ok, %{"pack_id" => ^pack_id}} <- Jason.decode(contents),
           %{"properties" => props} when is_map(props) <- manifest.settings_schema do
        Map.keys(props)
      else
        _ -> []
      end
    end)
  end

  # -- hashing ------------------------------------------------------------------------------

  defp hash_patch(patch),
    do: Base.encode16(:crypto.hash(:sha256, canonical_json(patch)), case: :lower)

  # keys sorted, no whitespace; the patch is a flat map of scalars
  defp canonical_json(patch) do
    body =
      patch
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} ->
        Jason.encode!(to_string(k)) <> ":" <> Jason.encode!(v)
      end)

    "{" <> body <> "}"
  end

  # -- casting ------------------------------------------------------------------------------

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

  defp cast_override_id(value) do
    case cast_uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_uuid_input(value) do
    case cast_uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_input}
    end
  end
end
