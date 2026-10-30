defmodule Letflow.Definitions.SolutionPackOverrideActivation do
  @moduledoc """
  Turns the latest version of a tenant solution-pack override into a real process-definition
  version (REQ-610 / GH #3419, decision 0069 D8 S3).

  The installed definition (`artefact_id` of the override row) is merged with the override patch
  by `SolutionPackOverrideMerge`, the result is written through the unchanged
  `Definitions.create_with_variable_schemas/3` as the new version `"<installed version>+ov<n>"` and
  made active by the unchanged `Definitions.activate/2`; the installed row is only deprecated by
  that activation (status, nothing else). Running instances read their write-once
  `instance_definition_snapshots` row and are not touched.

  Everything runs in ONE transaction under a per-override advisory lock, so a draft can never be
  left behind and the audit entry `solution_pack.override_activated` commits with the definition.
  The entry carries ids, versions, `patch_hash` and the reason, never a patch value (INV-4).

  Results: `{:ok, %{definition:, previous_id:, override_version:}}` or `{:error, reason}`, with
  `reason` one of `:reason_required`, `:not_found`, `:artefact_type_not_supported`,
  `:module_owned_definition_not_supported`, `:property_not_overridable`,
  `:override_changes_structure`, `:override_already_activated`, `:override_version_clash`,
  `:busy`, `:audit_failed`, or an error of `Definitions.create/2` / `activate/2` unchanged.

  ## Version clash

  The version string is unique only within one `override_id`. After a `retire`, a new override of
  the same artefact starts at version 1 again; its activation meets the existing `+ov1` row. If
  the stored graph equals the effective graph the answer is `:override_already_activated`;
  otherwise `:override_version_clash` and nothing is written (write a further `new_version` of the
  override until its number is unused).

  Q3/Q5: `variable_schema` overrides and `settings.*` thresholds take no effect. Q6: a
  module-owned definition is refused, since `create/2` would drop the owner stamp.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackOverrideMerge
  alias Letflow.Definitions.SolutionPackOverrides
  alias Letflow.Engine.VariableSchema
  alias Letflow.Repo

  require Logger

  @max_reason 2000

  @spec activate(
          String.t(),
          term(),
          term(),
          term(),
          String.t(),
          term(),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def activate(prefix, tenant_id, actor_id, activator, pack_id, override_id, input, opts \\ [])
      when is_binary(prefix) and is_binary(pack_id) and is_map(input) do
    with {:ok, reason} <- check_reason(input),
         {:ok, row} <- SolutionPackOverrides.fetch(prefix, tenant_id, pack_id, override_id),
         :ok <- check_type(row) do
      transact(prefix, row, fn ->
        run(prefix, actor_id, activator, row, reason, opts)
      end)
    end
  end

  defp check_reason(input) do
    case Map.get(input, :reason) do
      reason when is_binary(reason) ->
        trimmed = String.trim(reason)

        if trimmed != "" and String.length(trimmed) <= @max_reason,
          do: {:ok, trimmed},
          else: {:error, :reason_required}

      _other ->
        {:error, :reason_required}
    end
  end

  defp check_type(%{artefact_type: "process_definition"}), do: :ok
  defp check_type(_row), do: {:error, :artefact_type_not_supported}

  defp transact(prefix, row, fun) do
    case Repo.transaction(
           fn ->
             SQL.query!(Repo, "SET LOCAL lock_timeout = '2s'")
             SQL.query!(Repo, "SET LOCAL statement_timeout = '15s'")

             SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
               Enum.join(["activate", prefix, row.pack_id, row.override_id], "|")
             ])

             case fun.() do
               {:ok, result} -> result
               {:error, reason} -> Repo.rollback(reason)
             end
           end,
           prefix: prefix
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:lock_not_available, :query_canceled] ->
          {:error, :busy}

        other ->
          Logger.error("override activation failed: #{inspect(Map.get(other, :code))}")
          {:error, :audit_failed}
      end

    _error ->
      Logger.error("override activation failed")
      {:error, :audit_failed}
  end

  defp run(prefix, actor_id, activator, row, reason, opts) do
    with {:ok, latest} <- SolutionPackOverrides.latest(prefix, row.override_id),
         {:ok, installed} <- load_installed(prefix, latest.artefact_id),
         {:ok, effective} <- SolutionPackOverrideMerge.merge(installed.graph, latest.patch),
         version = installed.version <> "+ov" <> Integer.to_string(latest.override_version),
         :ok <- check_version_free(prefix, installed.name, version, effective),
         previous_id = active_id(prefix, installed.name),
         {:ok, created} <- create(prefix, actor_id, installed, version, effective),
         {:ok, %{definition: activated}} <-
           Definitions.activate(
             created.id,
             prefix: prefix,
             activator: activator,
             service_scope_validator: Keyword.get(opts, :service_scope_validator)
           ),
         :ok <- audit(prefix, actor_id, latest, activated, reason) do
      {:ok,
       %{
         definition: activated,
         previous_id: previous_id,
         override_version: latest.override_version
       }}
    else
      {:error, :duplicate_name_version} -> {:error, :override_version_clash}
      {:error, _reason} = error -> error
    end
  end

  defp load_installed(prefix, artefact_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(artefact_id),
         %ProcessDefinition{} = installed <- Repo.get(ProcessDefinition, uuid, prefix: prefix) do
      if is_nil(installed.owner_module),
        do: {:ok, installed},
        else: {:error, :module_owned_definition_not_supported}
    else
      _ -> {:error, :not_found}
    end
  end

  defp check_version_free(prefix, name, version, effective) do
    case Repo.one(
           from(d in ProcessDefinition,
             where: d.name == ^name and d.version == ^version,
             select: d.graph
           ),
           prefix: prefix
         ) do
      nil -> :ok
      ^effective -> {:error, :override_already_activated}
      _other -> {:error, :override_version_clash}
    end
  end

  defp active_id(prefix, name) do
    Repo.one(
      from(d in ProcessDefinition, where: d.name == ^name and d.status == :active, select: d.id),
      prefix: prefix
    )
  end

  defp create(prefix, actor_id, installed, version, effective) do
    entries =
      Repo.all(
        from(vs in VariableSchema,
          where: vs.definition_id == ^installed.id,
          order_by: vs.variable_key,
          select: %{
            variable_key: vs.variable_key,
            json_schema: vs.json_schema,
            description: vs.description
          }
        ),
        prefix: prefix
      )

    Definitions.create_with_variable_schemas(
      %{
        name: installed.name,
        version: version,
        description: installed.description,
        stage: installed.stage,
        graph: effective,
        created_by: actor_id
      },
      entries,
      prefix: prefix
    )
  end

  defp audit(prefix, actor_id, latest, activated, reason) do
    entry = %{
      actor_id: actor_id,
      action: "solution_pack.override_activated",
      resource_type: "solution_pack_override",
      resource_id: latest.override_id,
      before_state: nil,
      after_state: %{
        "pack_id" => latest.pack_id,
        "artefact_type" => latest.artefact_type,
        "artefact_id" => latest.artefact_id,
        "override_id" => latest.override_id,
        "override_version" => latest.override_version,
        "patch_hash" => latest.patch_hash,
        "definition_id" => activated.id,
        "definition_version" => activated.version,
        "reason" => reason
      }
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, _reason} -> {:error, :audit_failed}
    end
  end
end
