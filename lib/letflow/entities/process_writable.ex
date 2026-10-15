defmodule Letflow.Entities.ProcessWritable do
  @moduledoc """
  Pure policy for the `writable_by_process` entity-definition flag (GH #2587,
  REQ-499 PR A4, decision 0054 D4a.2). No query, no persistence, never raises.

  The flag is an optional top-level boolean of the entity definition document
  (`Letflow.Entities.Definition`). `true` declares that a process step may
  write records of the type; absent or `false` means it may not. This module
  answers the three questions the rest of the system asks about it:

    * `declared?/1` -- does a definition document carry `true`?
    * `check_settable/2` -- may it be set on this definition? Called from
      `Letflow.Entities.Definitions.create_definition/3` (the type-definition
      write path, not the UI) and from the solution-pack installer.
    * `writable?/1` -- the run-time predicate PR B calls on the CURRENT active
      definition row (flag true, not managed, name not denied).

  ## Interim denied-name rule (OQ-2 ruling, fail closed)

  No metadata classifies entity types today, so a type is refused the flag
  when it is module-managed (`managed_by` stamp) or its name matches the
  closed denied list below (org, user/role/permission-adjacent and
  attachment-metadata types). The refusal is the stable rule code
  `:writable_by_process_not_permitted`; only the message varies and it NAMES
  the matched rule, so a false positive such as `user_feedback` explains
  itself. The list is interim: GH #2618 replaces it with a type
  classification. Adding an entry is a reviewed diff. The list is documented
  verbatim in the "Process-writable entity types (`writable_by_process`)"
  section (5b) of `docs/guides/adding-an-application-module.md`.

  A solution pack cannot carry the flag at all (GH #2619); an administrator
  sets it after install, by creating and activating a new version under the
  `:EntitiesDefinitionsWrite` permission.
  """

  alias Letflow.Entities.Definition.Validator
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.EntityDefinition

  @denied_prefixes [
    "org_",
    "user_",
    "users_",
    "role_",
    "roles_",
    "permission_",
    "permissions_",
    "principal_",
    "principals_",
    "group_",
    "groups_",
    "membership_",
    "attachment_",
    "attachments_"
  ]

  @denied_exact [
    "org",
    "orgs",
    "user",
    "users",
    "role",
    "roles",
    "permission",
    "permissions",
    "principal",
    "principals",
    "group",
    "groups",
    "membership",
    "memberships",
    "attachment",
    "attachments"
  ]

  @rule :writable_by_process_not_permitted

  @doc "The closed list of denied name prefixes (interim, GH #2618)."
  @spec denied_prefixes() :: [String.t()]
  def denied_prefixes, do: @denied_prefixes

  @doc "The closed list of denied exact names (interim, GH #2618)."
  @spec denied_exact() :: [String.t()]
  def denied_exact, do: @denied_exact

  @doc """
  True iff `:writable_by_process` or `"writable_by_process"` is literally
  `true` in `definition`. Any other value (absent, `false`, non-boolean) and
  any non-map term is `false`.
  """
  @spec declared?(term()) :: boolean()
  def declared?(%{} = definition) when not is_struct(definition) do
    Map.get(definition, :writable_by_process) == true or
      Map.get(definition, "writable_by_process") == true
  end

  def declared?(_other), do: false

  @doc """
  True iff the lower-cased `name` is a denied exact name or starts with a
  denied prefix.
  """
  @spec denied_name?(term()) :: boolean()
  def denied_name?(name), do: matched_rule(name) != nil

  @doc """
  The first matching denied prefix (list order) or exact name; `nil` when
  none matches or `name` is not a binary.
  """
  @spec matched_rule(term()) :: {:prefix, String.t()} | {:exact, String.t()} | nil
  def matched_rule(name) when is_binary(name) do
    lowered = String.downcase(name)

    case Enum.find(@denied_prefixes, &String.starts_with?(lowered, &1)) do
      nil ->
        if lowered in @denied_exact, do: {:exact, lowered}, else: nil

      prefix ->
        {:prefix, prefix}
    end
  end

  def matched_rule(_other), do: nil

  @doc """
  Whether `writable_by_process: true` may be set on `definition`.

  `:ok` when the definition does not declare the flag. Otherwise `:ok` only
  when `managed_stamp` is `nil` (the type is not module-managed) and the name
  matches no denied rule; else one `:writable_by_process_not_permitted`
  violation at `[:writable_by_process]` whose message names the matched rule.
  """
  @spec check_settable(term(), managed_stamp :: String.t() | nil) ::
          :ok | {:error, {:validation, [Validator.violation()]}}
  def check_settable(definition, managed_stamp) do
    if declared?(definition) do
      case refusal_message(definition, managed_stamp) do
        nil -> :ok
        message -> {:error, {:validation, [violation(message)]}}
      end
    else
      :ok
    end
  end

  @doc """
  The refusal violation for a solution pack that carries the flag
  (decision D-A4.6): a pack never carries `writable_by_process: true`.
  """
  @spec pack_refusal() :: {:error, {:validation, [Validator.violation()]}}
  def pack_refusal do
    {:error,
     {:validation,
      [violation("writable_by_process cannot be set by a solution pack; set it after install")]}}
  end

  @doc """
  Run-time predicate for PR B: the definition row's document declares the
  flag, the type is not module-managed, and its name is not denied.
  """
  @spec writable?(EntityDefinition.t()) :: boolean()
  def writable?(%EntityDefinition{} = row) do
    declared?(row.definition_json) and is_nil(row.managed_by) and
      not denied_name?(row.name)
  end

  defp refusal_message(_definition, managed_stamp) when is_binary(managed_stamp) do
    "writable_by_process cannot be set: the entity type is managed by a module"
  end

  defp refusal_message(definition, nil) do
    name = Map.get(definition, :name) || Map.get(definition, "name")

    case matched_rule(name) do
      {:prefix, prefix} ->
        "writable_by_process cannot be set: the name matches the denied prefix \"#{prefix}\""

      {:exact, exact} ->
        "writable_by_process cannot be set: the name \"#{exact}\" is denied"

      nil ->
        nil
    end
  end

  defp violation(message),
    do: %Violation{rule: @rule, path: [:writable_by_process], message: message}
end
