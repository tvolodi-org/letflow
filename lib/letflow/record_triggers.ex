defmodule Letflow.RecordTriggers do
  @moduledoc """
  REQ-570 slice T-1 part 1 (GH #3248, decision 0067 D4/D5/D9) -- the pin of one published
  `entity_event` script version to one (entity type, record event) pair: a record trigger.

  **Nothing runs and nothing is queued.** This module stores, replaces, removes and lists pins and
  refuses a bad pin at bind time. No record write, step write or handler write reads the table yet
  (later slices), and the routes are part 2. `enabled?/0` is the single reader of the
  `:record_triggers_enabled` flag; `bind/5`, `rebind/5`, `unbind/4` and `list/1` do not call it, the
  routes of part 2 act on it.

  `bind/5`, `rebind/5` and `unbind/4` each run one `Ecto.Multi`: the checks first, the row change
  second, `Letflow.Audit.append_multi/4` last, so the audit entry and the row change commit or roll
  back together. A real audit failure RAISES inside `Audit.insert_entry/3`, so `run_multi/2` rescues
  it and returns `{:error, {:transaction_failed, exception}}`; the transaction has rolled back (INV-8).

  Locks: the transaction takes the type's `instance_sequences` row `FOR UPDATE` (decision 0061 item 5;
  it serialises every bind, rebind and unbind of the type) and then, inside `Audit.append_multi/4`, the
  tenant's `audit_chain_locks` row `FOR UPDATE` (item 6). Every other read is a plain read: no advisory
  lock, no lock on the script row, no lock on the binding row. A retire between the script read and the
  commit is allowed (this slice adds no retire block; the run-time re-check of a later slice refuses).

  Check order: credential, input shape (both say nothing about existence, so an invalid body answers
  `:invalid_input` for an existing and an absent type alike), type exists, type not managed (authority is
  `Letflow.Entities.ManagedTypes`, never request data), the type's sequence row, the binding row, the
  script version (found, published, `entity_event`, sha256), the declared write lines (decision 0067 D5),
  bound-state. A valid body on a type absent in this tenant answers `:not_found` whatever else the
  request holds (INV-5/INV-10). Error values never carry the type, field or label.

  Every `Repo` call passes `prefix:` (INV-1, INV-6), `tenant_id` comes from the prefix, and every query
  uses bound parameters (INV-7).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Engine.VariableLabels
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.HiddenLabels
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ScopeBearingField
  alias Letflow.EventStore
  alias Letflow.RecordTriggers.Binding
  alias Letflow.Repo
  alias Letflow.Scripts.Runtime
  alias Letflow.Scripts.ScriptRule
  alias Letflow.TenantProvisioning

  require Logger

  @hook_kind "entity_event"
  @events ~w(created updated deleted)
  @max_version 2_147_483_647
  @sha ~r/\A[0-9a-f]{64}\z/
  @index :record_trigger_bindings_entity_type_event_index

  # Fields a trigger script may never write, whatever the type declares (closed list: no shared
  # definition of the system fields exists).
  @system_fields ~w(id record_id tenant_id entity_type managed_by version source metadata
                    external_ref external_system external_id record_number deleted inserted_at
                    updated_at created_at created_by updated_by)

  @type actor :: %{
          required(:user_id) => String.t() | nil,
          required(:credential) => atom(),
          optional(:trace_id) => String.t() | nil
        }
  @type error ::
          :api_token_not_allowed
          | :invalid_input
          | :not_found
          | :entity_type_managed
          | :script_not_found
          | :script_not_published
          | :hook_kind_mismatch
          | :sha_mismatch
          | :already_bound
          | :write_target_invalid
          | :write_field_forbidden
          | :write_restriction_widened
          | {:transaction_failed, term()}

  @doc "True when record triggers are switched on (`:record_triggers_enabled`, default false)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:letflow, :record_triggers_enabled, false) == true

  @doc "The tenant's bindings, ordered by entity type then event."
  @spec list(String.t()) :: [Binding.t()]
  def list(prefix) when is_binary(prefix) do
    Repo.all(from(b in Binding, order_by: [asc: b.entity_type, asc: b.event]), prefix: prefix)
  end

  @doc "Pins `params` (`script_key`, `script_version`, `script_sha256`) to `entity_type` and `event`."
  @spec bind(String.t(), term(), term(), term(), actor()) ::
          {:ok, Binding.t()} | {:error, error()}
  def bind(prefix, entity_type, event, params, actor),
    do: write(:bind, prefix, entity_type, event, params, actor)

  @doc "Replaces the pin of an already bound `(entity_type, event)`."
  @spec rebind(String.t(), term(), term(), term(), actor()) ::
          {:ok, Binding.t()} | {:error, error()}
  def rebind(prefix, entity_type, event, params, actor),
    do: write(:rebind, prefix, entity_type, event, params, actor)

  @doc "Removes the pin of `(entity_type, event)`; `{:error, :not_found}` when none exists."
  @spec unbind(String.t(), term(), term(), actor()) :: {:ok, Binding.t()} | {:error, error()}
  def unbind(prefix, entity_type, event, actor),
    do: write(:unbind, prefix, entity_type, event, nil, actor)

  # ── shared path ──────────────────────────────────────────────────────────────

  defp write(mode, prefix, entity_type, event, params, actor) do
    with :ok <- require_interactive(actor),
         {:ok, pin} <- parse_params(mode, params),
         {:ok, event} <- parse_event(event),
         {:ok, type} <- type_name(entity_type),
         {:ok, tenant_id} <- tenant_id(prefix) do
      run_multi(prefix, multi(mode, prefix, tenant_id, type, event, pin, actor))
    end
  end

  # One Multi: the checks run as the first step (so their locks are held until commit), then the
  # row write, then the audit entry (`Audit.append_multi/4`) built from the written row.
  defp multi(mode, prefix, tenant_id, type, event, pin, actor) do
    Multi.new()
    |> Multi.run(:checked, fn _repo, _changes -> checks(mode, prefix, type, event, pin) end)
    |> Multi.merge(fn %{checked: existing} ->
      write_multi(mode, prefix, tenant_id, type, event, pin, existing, actor)
    end)
  end

  defp checks(mode, prefix, type, event, pin) do
    with :ok <- require_type(prefix, type),
         :ok <- require_unmanaged(prefix, type),
         :ok <- lock_type_sequence(prefix, type),
         existing = Repo.one(binding_query(type, event), prefix: prefix),
         {:ok, rule} <- require_pin(mode, prefix, pin),
         :ok <- require_writes(prefix, rule),
         :ok <- require_mode(mode, existing) do
      {:ok, existing}
    end
  end

  defp write_multi(:bind, prefix, tenant_id, type, event, pin, nil, actor) do
    changeset =
      %Binding{tenant_id: tenant_id, entity_type: type, event: event, bound_by: actor.user_id}
      |> Ecto.Changeset.change(Map.put(pin_fields(pin), :status, :active))
      |> Ecto.Changeset.unique_constraint(:entity_type, name: @index)

    Multi.new()
    |> Multi.insert(:binding, changeset, prefix: prefix)
    |> audit("record_trigger.bound", nil, :after, actor, prefix)
  end

  defp write_multi(:rebind, prefix, _tenant_id, _type, _event, pin, existing, actor) do
    changeset =
      existing
      |> Ecto.Changeset.change(
        pin
        |> pin_fields()
        |> Map.merge(%{status: :active, bound_by: actor.user_id})
      )
      |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())

    Multi.new()
    |> Multi.update(:binding, changeset, prefix: prefix)
    |> audit("record_trigger.rebound", state(existing), :after, actor, prefix)
  end

  defp write_multi(:unbind, prefix, _tenant_id, _type, _event, _pin, existing, actor) do
    Multi.new()
    |> Multi.delete(:binding, existing, prefix: prefix)
    |> audit("record_trigger.unbound", state(existing), :none, actor, prefix)
  end

  defp audit(multi, action, before_state, after_mode, actor, prefix) do
    Multi.merge(multi, fn %{binding: binding} ->
      Audit.append_multi(
        Multi.new(),
        :audit,
        %{
          actor_id: actor.user_id,
          action: action,
          resource_type: "record_trigger_binding",
          resource_id: binding.id,
          before_state: before_state,
          after_state: if(after_mode == :after, do: state(binding)),
          trace_id: Map.get(actor, :trace_id)
        },
        prefix
      )
    end)
  end

  # A real audit failure RAISES inside `Audit.insert_entry/3`; the transaction has rolled back, so
  # no row remains. Only the exception module is logged (INV-4), never its message.
  defp run_multi(prefix, multi) do
    case Repo.transaction(multi, prefix: prefix) do
      {:ok, %{binding: binding}} -> {:ok, binding}
      {:error, :checked, reason, _} -> {:error, reason}
      {:error, :binding, %Ecto.Changeset{}, _} -> {:error, :already_bound}
      {:error, _step, reason, _} -> {:error, {:transaction_failed, reason}}
    end
  rescue
    error ->
      Logger.error("record trigger write failed: #{inspect(error.__struct__)}")
      {:error, {:transaction_failed, error}}
  end

  # ── input ────────────────────────────────────────────────────────────────────

  defp require_interactive(%{credential: :oidc}), do: :ok
  defp require_interactive(_actor), do: {:error, :api_token_not_allowed}

  defp type_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp type_name(_name), do: {:error, :not_found}

  defp parse_event(event) when is_binary(event) and event in @events,
    do: {:ok, String.to_existing_atom(event)}

  defp parse_event(event) when event in [:created, :updated, :deleted], do: {:ok, event}
  defp parse_event(_event), do: {:error, :invalid_input}

  defp tenant_id(prefix) when is_binary(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp tenant_id(_prefix), do: {:error, :not_found}

  defp parse_params(:unbind, _params), do: {:ok, nil}

  defp parse_params(_mode, %{
         "script_key" => key,
         "script_version" => version,
         "script_sha256" => sha
       })
       when is_binary(key) and key != "" and is_binary(sha) do
    with {:ok, version} <- parse_version(version),
         true <- Regex.match?(@sha, sha) do
      {:ok, %{key: key, version: version, sha: sha}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp parse_params(_mode, _params), do: {:error, :invalid_input}

  defp parse_version(v) when is_integer(v) and v >= 1 and v <= @max_version, do: {:ok, v}

  defp parse_version(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 1 and n <= @max_version -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_version(_v), do: :error

  # ── checks ───────────────────────────────────────────────────────────────────

  defp require_type(prefix, type) do
    if Repo.exists?(active_definition(type), prefix: prefix), do: :ok, else: {:error, :not_found}
  end

  defp active_definition(type),
    do: from(d in EntityDefinition, where: d.name == ^type and d.status == :active)

  defp require_unmanaged(prefix, type) do
    case ManagedTypes.check_tenant_write(type, prefix) do
      :ok -> :ok
      {:error, :entity_type_managed} -> {:error, :entity_type_managed}
      {:error, _} -> {:error, :not_found}
    end
  end

  # Decision 0061 item 5: the type's `instance_sequences` row FOR UPDATE, the only data-row lock
  # taken here. A type with no registry row yet gets one (idempotent, rolled back with a refusal).
  defp lock_type_sequence(prefix, type) do
    with {:ok, instance_id} <- EntityTypeInstance.get_or_create(type, prefix),
         {:ok, :locked} <- EventStore.lock_instance_sequence(Repo, instance_id, prefix) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp binding_query(type, event),
    do: from(b in Binding, where: b.entity_type == ^type and b.event == ^event)

  defp require_pin(:unbind, _prefix, _pin), do: {:ok, nil}

  defp require_pin(_mode, prefix, %{key: key, version: version, sha: sha}) do
    rule =
      Repo.one(from(r in ScriptRule, where: r.key == ^key and r.version == ^version),
        prefix: prefix
      )

    cond do
      is_nil(rule) or rule.status == :discarded -> {:error, :script_not_found}
      rule.status != :published -> {:error, :script_not_published}
      rule.hook_kind != @hook_kind -> {:error, :hook_kind_mismatch}
      rule.sha256 != sha -> {:error, :sha_mismatch}
      true -> {:ok, rule}
    end
  end

  defp require_mode(:bind, nil), do: :ok
  defp require_mode(:bind, %Binding{}), do: {:error, :already_bound}
  defp require_mode(_mode, nil), do: {:error, :not_found}
  defp require_mode(_mode, %Binding{}), do: :ok

  # Decision 0067 D5: every declared write line is checked at bind time.
  defp require_writes(_prefix, nil), do: :ok

  defp require_writes(prefix, %ScriptRule{manifest: manifest}) do
    lines = declared_lines(manifest)

    with :ok <- check_targets(prefix, lines),
         :ok <- check_fields(prefix, lines) do
      check_restrictions(prefix, manifest, lines)
    end
  end

  defp declared_lines(%{"writes" => lines}) when is_list(lines), do: lines
  defp declared_lines(_manifest), do: []

  defp check_targets(prefix, lines) do
    lines
    |> Enum.map(& &1["entity_type"])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn type, :ok ->
      if Repo.exists?(active_definition(type), prefix: prefix) and
           ManagedTypes.check_tenant_write(type, prefix) == :ok,
         do: {:cont, :ok},
         else: {:halt, {:error, :write_target_invalid}}
    end)
  end

  defp check_fields(prefix, lines) do
    Enum.reduce_while(lines, :ok, fn %{"entity_type" => type, "fields" => fields}, :ok ->
      definition = Repo.one(active_definition(type), prefix: prefix)
      declared = declared_field_names(definition)

      if Enum.all?(fields, &field_writable?(&1, definition, declared, prefix)),
        do: {:cont, :ok},
        else: {:halt, {:error, :write_field_forbidden}}
    end)
  end

  defp field_writable?(field, definition, declared, prefix) do
    field in declared and field not in @system_fields and
      not ScopeBearingField.scope_bearing?(definition, field, prefix)
  end

  defp declared_field_names(%EntityDefinition{definition_json: %{"fields" => fields}})
       when is_list(fields) do
    for %{"name" => name} <- fields, is_binary(name), do: name
  end

  defp declared_field_names(_definition), do: []

  # Decision 0062 R5: a field must not end with fewer restrictions than the script's taint.
  defp check_restrictions(prefix, manifest, lines) do
    labels = for %{"entity_type" => t, "fields" => fs} <- lines, f <- fs, do: t <> "." <> f

    if labels == [] do
      :ok
    else
      taint = Runtime.manifest_taint(manifest)

      case HiddenLabels.load_platform_hidden_labels(prefix) do
        {:ok, restricted} ->
          if Enum.all?(labels, &VariableLabels.write_allowed?(taint, &1, restricted)),
            do: :ok,
            else: {:error, :write_restriction_widened}

        _ ->
          {:error, :write_restriction_widened}
      end
    end
  end

  defp pin_fields(%{key: key, version: version, sha: sha}),
    do: %{script_key: key, script_version: version, script_sha256: sha}

  defp state(%Binding{} = b),
    do: %{
      "entity_type" => b.entity_type,
      "event" => Atom.to_string(b.event),
      "script_key" => b.script_key,
      "script_version" => b.script_version,
      "script_sha256" => b.script_sha256,
      "status" => Atom.to_string(b.status)
    }
end
