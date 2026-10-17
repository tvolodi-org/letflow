defmodule Letflow.Modules.Exam.Snapshot.Rollout do
  @moduledoc """
  GH #2682 / REQ-511 (design 10.3, 17.2, 18.4) -- brings an exam-installed tenant to the state the
  snapshot code needs, per tenant, idempotently:

    1. the ACTIVE `session` entity definition declares the optional json field `exam_snapshot`
       (a new definition version = the tenant's active definition plus exactly that field,
       created and activated ONLY through `Letflow.Entities.Definitions.create_definition/3` and
       `activate_definition/4`; never a direct write of `entity_definitions`); and
    2. every pair of `Letflow.Modules.Exam.answer_key_fields/0` has an `entity_field_restrictions`
       row (`Letflow.Modules.Exam.ensure_answer_key_restrictions/1`).

  Same shape as `Letflow.Entities.ManagedTypes.Stamp`: sequential over
  `Letflow.TenantProvisioning.list_registrations/0`, ONE transaction per tenant and none across
  tenants, a per-tenant failure recorded as a tag (never a message or a value, INV-4) while the
  sweep continues, `dry_run: true` writes nothing. `tenant_id` always comes from
  `TenantProvisioning.tenant_id_for_schema_name/1`, never from input.

  The new definition is derived from the tenant's own ACTIVE definition, not from the pack, because
  existing tenants' rows can differ from the pack (hand-posted, foreign keys stripped).

  Actor: `create_definition/3` and `activate_definition/4` need a user id (`created_by` and the
  activation's `activator_user_id` are NOT NULL). The Stamp wrote its audit entry with a nil actor,
  which these two columns do not allow, so the fixed all-zero "system actor" uuid that
  `Letflow.Scheduler.RecordDeadlineSweep` already uses for its system writes is used here.

  Run it from a release (no Mix) through `Letflow.Release.ExamSnapshot.rollout/1`, or with
  `mix letflow.exam_snapshot_rollout [--dry-run]`.
  """

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Modules.Exam
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @system_actor_id "00000000-0000-0000-0000-000000000000"
  @field_name "exam_snapshot"
  @default_lock_timeout_ms 3_000
  @statement_timeout_ms 30_000
  @rationale "REQ-511: add the optional exam_snapshot field to the session entity (exam snapshot rollout)"

  @type opts :: [dry_run: boolean(), lock_timeout_ms: pos_integer()]

  @type tenant_status ::
          :upgraded
          | :already_current
          | :exam_not_installed
          | :skipped_schema_missing
          | :conflict
          | :managed_cannot_upgrade
          | :failed

  @type definition_status ::
          :added | :already_current | :conflict | :managed_cannot_upgrade | :skipped

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t() | nil,
          schema_name: String.t(),
          status: tenant_status(),
          definition: definition_status(),
          restrictions_added: non_neg_integer(),
          error:
            nil
            | :nested_transaction
            | :lock_timeout
            | {:definition_write_failed, atom()}
            | {:unexpected_exception, module()}
        }

  @type report :: %{
          dry_run: boolean(),
          tenants: [tenant_report()],
          upgraded_total: non_neg_integer(),
          conflict_total: non_neg_integer(),
          failed_total: non_neg_integer(),
          restrictions_added_total: non_neg_integer()
        }

  # Whitelists for the lossless string-key -> atom-key conversion of a stored definition_json.
  @top_keys %{
    "name" => :name,
    "display_name" => :display_name,
    "description" => :description,
    "fields" => :fields,
    "indexes" => :indexes,
    "foreign_keys" => :foreign_keys,
    "constraints" => :constraints,
    "append_only" => :append_only,
    "writable_by_process" => :writable_by_process
  }
  @field_keys %{
    "name" => :name,
    "type" => :type,
    "required" => :required,
    "queried" => :queried,
    "enum_values" => :enum_values,
    "decimal_precision" => :decimal_precision,
    "decimal_scale" => :decimal_scale,
    "default" => :default,
    "locales" => :locales,
    "search_strategy" => :search_strategy,
    "min" => :min,
    "max" => :max,
    "non_negative" => :non_negative
  }
  @field_types %{
    "string" => :string,
    "integer" => :integer,
    "decimal" => :decimal,
    "boolean" => :boolean,
    "date" => :date,
    "datetime" => :datetime,
    "enum" => :enum,
    "json" => :json,
    "localized_text" => :localized_text
  }
  @strategies %{"plain" => :plain, "fulltext" => :fulltext}
  @index_keys %{"name" => :name, "fields" => :fields, "unique" => :unique}
  @fk_keys %{
    "name" => :name,
    "field" => :field,
    "references_entity" => :references_entity,
    "references_field" => :references_field
  }
  @constraint_keys %{"name" => :name, "type" => :type, "fields" => :fields}

  @doc "Sweeps every registered tenant with `run_tenant/2`. Never halts on one tenant's failure."
  @spec run(opts()) :: {:ok, report()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    tenants =
      Letflow.Obs.Logger.with_trace(fn ->
        for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations() do
          run_tenant(schema, opts)
        end
      end)

    {:ok,
     %{
       dry_run: dry_run?,
       tenants: tenants,
       upgraded_total: Enum.count(tenants, &(&1.status == :upgraded)),
       conflict_total: Enum.count(tenants, &(&1.status in [:conflict, :managed_cannot_upgrade])),
       failed_total: Enum.count(tenants, &(&1.status == :failed)),
       restrictions_added_total: tenants |> Enum.map(& &1.restrictions_added) |> Enum.sum()
     }}
  end

  @doc """
  Rolls out one tenant schema. Never raises: any failure is a `status: :failed` report carrying a
  tag or an exception module. Inside an open transaction it returns `error: :nested_transaction`.
  """
  @spec run_tenant(schema_name :: String.t(), opts()) :: tenant_report()
  def run_tenant(schema_name, opts \\ []) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)
    report = base_report(tenant_id, schema_name)

    cond do
      Repo.in_transaction?() -> %{report | status: :failed, error: :nested_transaction}
      tenant_id == nil -> %{report | status: :skipped_schema_missing}
      true -> guarded_run(report, schema_name, opts)
    end
  end

  @type tenant_check :: %{
          schema_name: String.t(),
          session_definition: boolean(),
          answer_key_restrictions: boolean()
        }

  @doc """
  Read-only readiness check: for every exam-installed tenant, whether its active `session`
  definition declares `exam_snapshot` (json) and whether every pair of
  `Letflow.Modules.Exam.answer_key_fields/0` has a restriction row. `ready` is true when every
  such tenant has both (design 17.2).
  """
  @spec verify() :: %{ready: boolean(), tenants: [tenant_check()]}
  def verify do
    tenants =
      for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations(),
          check = check_tenant(schema),
          do: check

    %{
      ready: Enum.all?(tenants, &(&1.session_definition and &1.answer_key_restrictions)),
      tenants: tenants
    }
  end

  defp check_tenant(schema) do
    if exam_installed?(schema) do
      %{
        schema_name: schema,
        session_definition: session_definition_current?(schema),
        answer_key_restrictions: missing_restriction_count(schema) == 0
      }
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          nil

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp session_definition_current?(schema) do
    case Definitions.get_active_definition_by_name("session", schema) do
      {:ok, active} -> field_state(active.definition_json) == :current
      {:error, _reason} -> false
    end
  end

  defp guarded_run(report, schema, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    if exam_installed?(schema) do
      case Definitions.get_active_definition_by_name("session", schema) do
        {:ok, active} -> classify_and_run(report, schema, active, dry_run?, opts)
        {:error, _no_active_session} -> definition_failure(report, :no_active_session_definition)
      end
    else
      %{report | status: :exam_not_installed}
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          %{report | status: :skipped_schema_missing}

        _other ->
          %{report | status: :failed, error: {:unexpected_exception, Postgrex.Error}}
      end

    exception ->
      %{report | status: :failed, error: {:unexpected_exception, exception.__struct__}}
  end

  defp classify_and_run(report, schema, active, dry_run?, opts) do
    case field_state(active.definition_json) do
      :current ->
        finish_restrictions(%{report | definition: :already_current}, schema, dry_run?)

      :conflict ->
        %{report | status: :conflict, definition: :conflict}

      :absent when active.managed_by != nil ->
        %{report | status: :managed_cannot_upgrade, definition: :managed_cannot_upgrade}

      :absent when dry_run? ->
        finish_restrictions(%{report | definition: :added}, schema, true)

      :absent ->
        real_run(
          report,
          schema,
          active,
          Keyword.get(opts, :lock_timeout_ms, @default_lock_timeout_ms)
        )
    end
  end

  defp field_state(%{"fields" => fields}) when is_list(fields) do
    case Enum.find(fields, &(is_map(&1) and &1["name"] == @field_name)) do
      nil -> :absent
      %{"type" => "json"} -> :current
      _other_type -> :conflict
    end
  end

  defp field_state(_malformed), do: :absent

  # One transaction per tenant: the new definition version, its activation and the restriction rows
  # commit or roll back together.
  defp real_run(report, schema, active, lock_timeout) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('lock_timeout', $1, true)", ["#{lock_timeout}ms"])

        Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
          "#{@statement_timeout_ms}ms"
        ])

        with {:ok, document} <- build_document(active.definition_json),
             {:ok, _created} <-
               Definitions.create_definition(
                 %{definition: document, created_by: @system_actor_id},
                 schema,
                 :tenant
               ),
             {:ok, _activated} <-
               Definitions.activate_definition("session", @system_actor_id, @rationale, schema),
             {:ok, added} <- Exam.ensure_answer_key_restrictions(schema) do
          added
        else
          {:error, reason} -> Repo.rollback({:definition_write_failed, reason_tag(reason)})
        end
      end)

    case result do
      {:ok, added} ->
        %{report | status: :upgraded, definition: :added, restrictions_added: added}

      {:error, {:definition_write_failed, _tag} = error} ->
        %{report | status: :failed, definition: :skipped, error: error}

      # A rollback inside the nested create/activate transaction poisons the outer one, which
      # then reports a bare `:rollback` instead of the tagged value.
      {:error, _rolled_back} ->
        %{
          report
          | status: :failed,
            definition: :skipped,
            error: {:definition_write_failed, :rolled_back}
        }
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :lock_not_available}} ->
          %{report | status: :failed, definition: :skipped, error: :lock_timeout}

        _other ->
          %{
            report
            | status: :failed,
              definition: :skipped,
              error: {:unexpected_exception, Postgrex.Error}
          }
      end
  end

  # The definition is already current (or, in a dry run, would be): only the restriction rows are
  # left. A dry run counts the missing rows without inserting.
  defp finish_restrictions(report, schema, true = _dry_run?) do
    missing = missing_restriction_count(schema)

    status =
      cond do
        report.definition == :added -> :upgraded
        missing > 0 -> :upgraded
        true -> :already_current
      end

    %{report | status: status, restrictions_added: missing}
  end

  defp finish_restrictions(report, schema, false = _dry_run?) do
    result =
      Repo.transaction(fn ->
        case Exam.ensure_answer_key_restrictions(schema) do
          {:ok, added} -> added
          {:error, reason} -> Repo.rollback({:definition_write_failed, reason_tag(reason)})
        end
      end)

    case result do
      {:ok, 0} -> %{report | status: :already_current}
      {:ok, added} -> %{report | status: :upgraded, restrictions_added: added}
      {:error, error} -> %{report | status: :failed, error: error}
    end
  end

  defp missing_restriction_count(schema) do
    present =
      from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name})
      |> Repo.all(prefix: schema)
      |> MapSet.new()

    Exam.answer_key_fields() |> Enum.reject(&MapSet.member?(present, &1)) |> length()
  end

  defp definition_failure(report, tag),
    do: %{report | status: :failed, definition: :skipped, error: {:definition_write_failed, tag}}

  defp exam_installed?(schema) do
    Repo.exists?(from(m in "tenant_modules", where: m.module_id == "exam"), prefix: schema)
  end

  # -- definition document (stored string-keyed json -> the atom-keyed document create_definition
  #    takes), lossless over the keys the Validator knows --------------------------------------------

  defp build_document(definition_json) when is_map(definition_json) do
    with {:ok, top} <- translate(definition_json, @top_keys),
         {:ok, top} <- translate_list(top, :fields, &translate_field/1),
         {:ok, top} <- translate_list(top, :indexes, &translate(&1, @index_keys)),
         {:ok, top} <- translate_list(top, :foreign_keys, &translate(&1, @fk_keys)),
         {:ok, top} <- translate_list(top, :constraints, &translate_constraint/1) do
      {:ok, Map.update!(top, :fields, &(&1 ++ [snapshot_field()]))}
    end
  end

  defp snapshot_field, do: %{name: @field_name, type: :json, required: false, queried: false}

  defp translate(raw, whitelist) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(whitelist, key) do
        {:ok, atom_key} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
        :error -> {:halt, {:error, :unsupported_definition_key}}
      end
    end)
  end

  defp translate(_not_a_map, _whitelist), do: {:error, :unsupported_definition_shape}

  defp translate_list(map, key, translator) do
    case Map.get(map, key) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          case translator.(entry) do
            {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Map.put(map, key, Enum.reverse(reversed))}
          {:error, _reason} = error -> error
        end

      nil ->
        if key == :fields, do: {:error, :unsupported_definition_shape}, else: {:ok, map}

      _not_a_list ->
        {:error, :unsupported_definition_shape}
    end
  end

  defp translate_field(raw) do
    with {:ok, field} <- translate(raw, @field_keys),
         {:ok, field} <- atom_value(field, :type, @field_types),
         {:ok, field} <- optional_atom_value(field, :search_strategy, @strategies) do
      {:ok, field}
    end
  end

  defp translate_constraint(raw) do
    with {:ok, constraint} <- translate(raw, @constraint_keys) do
      atom_value(constraint, :type, %{"unique" => :unique})
    end
  end

  defp atom_value(map, key, whitelist) do
    case Map.fetch(whitelist, Map.get(map, key)) do
      {:ok, atom} -> {:ok, Map.put(map, key, atom)}
      :error -> {:error, :unsupported_definition_value}
    end
  end

  defp optional_atom_value(map, key, whitelist) do
    if Map.has_key?(map, key), do: atom_value(map, key, whitelist), else: {:ok, map}
  end

  # A tag or the exception module only, never the raw term (INV-4).
  defp reason_tag(%{__exception__: true, __struct__: module}), do: module
  defp reason_tag(%Ecto.Changeset{}), do: :invalid_changeset
  defp reason_tag(tag) when is_atom(tag), do: tag
  defp reason_tag({tag, _detail}) when is_atom(tag), do: tag
  defp reason_tag(_other), do: :unexpected_error

  defp base_report(tenant_id, schema_name) do
    %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      status: :already_current,
      definition: :skipped,
      restrictions_added: 0,
      error: nil
    }
  end

  defp tenant_id_or_nil(schema) do
    case TenantProvisioning.tenant_id_for_schema_name(schema) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> nil
    end
  end
end
