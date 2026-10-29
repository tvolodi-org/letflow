defmodule Letflow.Entities.TypeExtensions do
  @moduledoc """
  The only writer of the tenant `x_` extension layer (REQ-609 / GH #3417, decision
  0067-tenant-x, slice I2): `create_extension_audited/3`, `retire_extension_audited/3` and the
  reader `list_extensions/3`. The rows live in `entity_type_extensions` (slice I1); nothing here
  changes how a record is validated or stored (that is slice I3).

  ## The D4 refusals

  1. The type must be extensible by the caller: it has an active definition, it is module-managed
     (`managed_by` set), not append-only, and the caller is not denied by a type restriction.
     Every failure is the one `{:error, :not_found}`, so a caller cannot tell an unknown type from
     one it may not extend (INV-5).
  2. The key is `x_` plus a valid identifier (`Letflow.Entities.Definition.DDL.valid_identifier?/1`).
  3. The key is not a field name of the module definition.
  4. The key is not taken for the type (active or retired).
  5. The spec is one of the six simple types with the allowed keys (`validate_spec/1`).

  A type holds at most `max_per_type/0` rows; retired rows count, so retiring does not free a
  slot. The cap is counted under a transaction advisory lock keyed by schema and type, so two
  concurrent creators cannot both take the last slot.

  ## Retire, not delete

  `retire_extension_audited/3` sets `status = "retired"`; the row and its name stay (decision D3).
  Retiring a retired row answers the row unchanged and writes no audit entry.

  ## Lock position (decision 0061)

  The advisory lock is taken first and is not part of the numbered row-lock order; no sequence or
  counter row is taken. The retire path locks the extension row, and the audit chain row (item 6)
  is taken last by `Letflow.Audit.append_multi/4`.

  ## Tenant scoping (INV-1, INV-6)

  Every Repo call carries the tenant `prefix`; the tenant id is derived from it by
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` and no function accepts one.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeExtension
  alias Letflow.Entities.TypeAccess
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @max_per_type 50
  @spec_keys ~w(type required default enum_values min max non_negative)
  @spec_types ~w(string integer boolean date datetime enum)

  @type actor :: %{
          required(:user_id) => String.t() | nil,
          optional(:trace_id) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "The most extensions one entity type can hold, retired ones included."
  @spec max_per_type() :: pos_integer()
  def max_per_type, do: @max_per_type

  @doc """
  Creates an extension of `attrs["entity_type"]` named `attrs["name"]` with `attrs["spec"]` and
  its audit entry in one transaction. Only those three keys are read (string or atom keys).

  Errors: `:not_found`, `{:extension_key_invalid, name}`, `{:extension_key_reserved, name}`,
  `:extension_key_taken`, `:invalid_extension_spec`, `:extension_limit_reached`,
  `{:transaction_failed, reason}`.
  """
  @spec create_extension_audited(map(), actor(), schema_prefix :: String.t()) ::
          {:ok, EntityTypeExtension.t()} | {:error, term()}
  def create_extension_audited(attrs, actor, prefix)
      when is_map(attrs) and is_map(actor) and is_binary(prefix) do
    entity_type = fetch_attr(attrs, :entity_type)
    name = fetch_attr(attrs, :name)
    spec = fetch_attr(attrs, :spec)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, definition} <- check_extensible(entity_type, Map.get(actor, :user_id), prefix),
         :ok <- check_key(entity_type, name),
         :ok <- check_reserved(definition, name),
         :ok <- check_not_taken(tenant_id, entity_type, name, prefix),
         {:ok, spec} <- validate_spec(spec) do
      attrs = %{tenant_id: tenant_id, entity_type: entity_type, name: name, spec: spec}

      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_type!(prefix, entity_type)
        {:ok, :locked}
      end)
      |> Multi.run(:position, fn repo, _changes -> next_position(repo, attrs, prefix) end)
      |> Multi.insert(
        :row,
        fn %{position: position} -> insert_changeset(attrs, position) end,
        prefix: prefix
      )
      |> Multi.merge(fn %{row: row} ->
        Audit.append_multi(
          Multi.new(),
          :audit,
          audit_attrs(actor, "entity_type_extension.create", row, nil, row),
          prefix
        )
      end)
      |> run_audited(prefix, :create)
    else
      {:error, :invalid_schema_name} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Retires the extension `id`. A type that is no longer extensible for the actor answers
  `{:error, :not_found}` like an unknown id. An already retired row answers `{:ok, row}` with no
  write and no audit entry.
  """
  @spec retire_extension_audited(term(), actor(), schema_prefix :: String.t()) ::
          {:ok, EntityTypeExtension.t()} | {:error, term()}
  def retire_extension_audited(id, actor, prefix)
      when is_map(actor) and is_binary(prefix) do
    with {:ok, tenant_id} <- tenant_id(prefix),
         {:ok, uuid} <- cast_id(id),
         %EntityTypeExtension{} = row <- load_row(tenant_id, uuid, prefix),
         {:ok, _definition} <- check_extensible(row.entity_type, Map.get(actor, :user_id), prefix) do
      if row.status == "retired" do
        {:ok, row}
      else
        retire_locked(row, actor, prefix)
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The extensions of `entity_type` ordered by position, retired ones included. `{:error,
  :not_found}` when the type is not extensible for `actor_id` (same check as create).
  """
  @spec list_extensions(term(), String.t() | nil, schema_prefix :: String.t()) ::
          {:ok, [EntityTypeExtension.t()]} | {:error, :not_found}
  def list_extensions(entity_type, actor_id, prefix) when is_binary(prefix) do
    with {:ok, tenant_id} <- tenant_id(prefix),
         {:ok, _definition} <- check_extensible(entity_type, actor_id, prefix) do
      rows =
        Repo.all(
          from(e in EntityTypeExtension,
            where: e.tenant_id == ^tenant_id and e.entity_type == ^entity_type,
            order_by: [asc: e.position]
          ),
          prefix: prefix
        )

      {:ok, rows}
    end
  end

  @doc """
  Validates and normalises an extension spec: `{:ok, string-keyed map}` or `{:error,
  :invalid_extension_spec}`. Pure.
  """
  @spec validate_spec(term()) :: {:ok, map()} | {:error, :invalid_extension_spec}
  def validate_spec(spec) when is_map(spec) and not is_struct(spec) do
    with {:ok, spec} <- stringify_keys(spec),
         true <- Map.keys(spec) -- @spec_keys == [],
         {:ok, type} <- spec_type(spec),
         true <- spec_flags_ok?(spec),
         true <- spec_enum_ok?(spec, type),
         true <- spec_default_ok?(spec, type) do
      {:ok, Map.put(spec, "type", type)}
    else
      _ -> {:error, :invalid_extension_spec}
    end
  end

  def validate_spec(_spec), do: {:error, :invalid_extension_spec}

  # --- D4 refusal 1 ---------------------------------------------------------------------

  defp check_extensible(entity_type, actor_id, prefix)
       when is_binary(entity_type) and is_binary(actor_id) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, %EntityDefinition{managed_by: nil}} ->
        {:error, :not_found}

      {:ok, %EntityDefinition{definition_json: %{"append_only" => true}}} ->
        {:error, :not_found}

      {:ok, %EntityDefinition{} = definition} ->
        case TypeAccess.authorized?(actor_id, entity_type, prefix) do
          {:ok, :denied} -> {:error, :not_found}
          {:ok, _allowed} -> {:ok, definition}
          {:error, _reason} -> {:error, :not_found}
        end

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp check_extensible(_entity_type, _actor_id, _prefix), do: {:error, :not_found}

  # --- D4 refusals 2..4 -----------------------------------------------------------------

  defp check_key(entity_type, name) do
    if is_binary(name) and String.starts_with?(name, "x_") and DDL.valid_identifier?(name) and
         DDL.valid_identifier?(entity_type) do
      :ok
    else
      {:error, {:extension_key_invalid, name}}
    end
  end

  defp check_reserved(%EntityDefinition{definition_json: json}, name) do
    fields =
      case json do
        %{"fields" => fields} when is_list(fields) -> fields
        _ -> []
      end

    if Enum.any?(fields, &(is_map(&1) and Map.get(&1, "name") == name)) do
      {:error, {:extension_key_reserved, name}}
    else
      :ok
    end
  end

  defp check_not_taken(tenant_id, entity_type, name, prefix) do
    taken? =
      Repo.exists?(
        from(e in EntityTypeExtension,
          where: e.tenant_id == ^tenant_id and e.entity_type == ^entity_type and e.name == ^name
        ),
        prefix: prefix
      )

    if taken?, do: {:error, :extension_key_taken}, else: :ok
  end

  # --- spec -----------------------------------------------------------------------------

  defp stringify_keys(spec) do
    Enum.reduce_while(spec, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp spec_type(%{"type" => type}) when is_atom(type) and not is_nil(type),
    do: spec_type(%{"type" => Atom.to_string(type)})

  defp spec_type(%{"type" => type}) when type in @spec_types, do: {:ok, type}
  defp spec_type(_spec), do: :error

  defp spec_flags_ok?(spec) do
    Enum.all?(~w(required non_negative), fn key ->
      not Map.has_key?(spec, key) or is_boolean(spec[key])
    end) and
      Enum.all?(~w(min max), fn key ->
        not Map.has_key?(spec, key) or is_number(spec[key])
      end) and
      (spec["required"] != true or not is_nil(spec["default"]))
  end

  defp spec_enum_ok?(spec, "enum") do
    case spec["enum_values"] do
      [_ | _] = values -> Enum.all?(values, &is_binary/1)
      _ -> false
    end
  end

  defp spec_enum_ok?(spec, _type), do: not Map.has_key?(spec, "enum_values")

  defp spec_default_ok?(%{"default" => default} = spec, type) when not is_nil(default),
    do: default_matches?(type, default, spec)

  defp spec_default_ok?(_spec, _type), do: true

  defp default_matches?("string", value, _spec), do: is_binary(value)
  defp default_matches?("integer", value, _spec), do: is_integer(value)
  defp default_matches?("boolean", value, _spec), do: is_boolean(value)

  defp default_matches?("date", value, _spec),
    do: is_binary(value) and match?({:ok, _}, Date.from_iso8601(value))

  defp default_matches?("datetime", value, _spec),
    do: is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp default_matches?("enum", value, spec), do: value in spec["enum_values"]

  # --- create transaction ---------------------------------------------------------------

  defp lock_type!(prefix, entity_type) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      prefix <> ":entity_type_extensions:" <> entity_type
    ])
  end

  defp next_position(repo, attrs, prefix) do
    {count, max_position} =
      repo.one(
        from(e in EntityTypeExtension,
          where: e.tenant_id == ^attrs.tenant_id and e.entity_type == ^attrs.entity_type,
          select: {count(e.id), coalesce(max(e.position), 0)}
        ),
        prefix: prefix
      )

    if count >= @max_per_type do
      {:error, :extension_limit_reached}
    else
      {:ok, max_position + 1}
    end
  end

  defp insert_changeset(attrs, position) do
    %EntityTypeExtension{}
    |> Ecto.Changeset.change(%{
      tenant_id: attrs.tenant_id,
      entity_type: attrs.entity_type,
      kind: "field",
      name: attrs.name,
      spec: attrs.spec,
      position: position,
      status: "active"
    })
    |> Ecto.Changeset.unique_constraint(:name,
      name: :entity_type_extensions_tenant_type_name_index
    )
  end

  # --- retire transaction ---------------------------------------------------------------

  defp retire_locked(row, actor, prefix) do
    Multi.new()
    |> Multi.run(:current, fn repo, _changes ->
      case repo.one(
             from(e in EntityTypeExtension, where: e.id == ^row.id, lock: "FOR UPDATE"),
             prefix: prefix
           ) do
        nil -> {:error, :not_found}
        current -> {:ok, current}
      end
    end)
    |> Multi.merge(fn %{current: current} ->
      if current.status == "retired" do
        Multi.new() |> Multi.put(:row, current)
      else
        Multi.new()
        |> Multi.update(
          :row,
          Ecto.Changeset.change(current, %{
            status: "retired",
            updated_at: DateTime.utc_now()
          }),
          prefix: prefix
        )
        |> Multi.merge(fn %{row: updated} ->
          Audit.append_multi(
            Multi.new(),
            :audit,
            audit_attrs(actor, "entity_type_extension.retire", updated, current, updated),
            prefix
          )
        end)
      end
    end)
    |> run_audited(prefix, :retire)
  end

  # --- shared ---------------------------------------------------------------------------

  # Audit.insert_entry raises on a database failure and Repo.transaction does not convert a
  # raise, so it is rescued here (INV-8); only the exception module is logged (INV-4).
  defp run_audited(multi, prefix, op) do
    case Repo.transaction(multi, prefix: prefix) do
      {:ok, %{row: row}} ->
        {:ok, row}

      {:error, :position, :extension_limit_reached, _changes} ->
        {:error, :extension_limit_reached}

      {:error, :current, :not_found, _changes} ->
        {:error, :not_found}

      {:error, :row, %Ecto.Changeset{}, _changes} ->
        {:error, :extension_key_taken}

      {:error, _step, reason, _changes} ->
        {:error, {:transaction_failed, reason}}
    end
  rescue
    error ->
      Logger.error("entity type extension #{op} failed: #{inspect(error.__struct__)}")
      {:error, {:transaction_failed, error}}
  end

  defp audit_attrs(actor, action, row, before_row, after_row) do
    %{
      actor_id: Map.get(actor, :user_id),
      action: action,
      resource_type: "entity_type_extension",
      resource_id: row.id,
      before_state: state(before_row),
      after_state: state(after_row),
      trace_id: Map.get(actor, :trace_id)
    }
  end

  defp state(nil), do: nil

  defp state(row) do
    %{
      entity_type: row.entity_type,
      name: row.name,
      kind: row.kind,
      spec: row.spec,
      position: row.position,
      status: row.status
    }
  end

  defp tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_id), do: {:error, :not_found}

  defp load_row(tenant_id, id, prefix) do
    Repo.one(
      from(e in EntityTypeExtension, where: e.id == ^id and e.tenant_id == ^tenant_id),
      prefix: prefix
    )
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
