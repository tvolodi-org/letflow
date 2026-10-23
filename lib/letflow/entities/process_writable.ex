defmodule Letflow.Entities.ProcessWritable do
  @moduledoc """
  Pure policy for the `writable_by_process` entity-definition flag (GH #2587,
  REQ-499 PR A4, decision 0054 D4a.2). No query, no persistence, never raises.

  The flag is an optional top-level boolean of the entity definition document
  (`Letflow.Entities.Definition`). `true` declares that a process step may
  write records of the type; absent or `false` means it may not. This module
  answers the three questions the rest of the system asks about it:

    * `declared?/1` -- does a definition document carry `true`?
    * `check_settable/3` -- may it be set on this definition? Called from
      `Letflow.Entities.Definitions.create_definition/3` (the type-definition
      write path, not the UI) and from the solution-pack installer.
    * `writable?/1` -- the run-time predicate PR B calls on the CURRENT active
      definition row (flag true, class `ordinary`, not managed).

  ## Type classification (GH #2618, decision 0054 D4a.2 amendment)

  Each entity type carries a write class, stored in the `write_class` column of
  its `entity_definitions` rows and never in the tenant-writable document. The
  classes are `managed`, `org_tree`, `identity_adjacent`, `attachment_metadata`
  and `ordinary` (`classes/0`). `writable_by_process` is refused for every class
  except `ordinary`, and also for any row whose `managed_by` stamp is set. Core
  assigns the class in `create_definition/3`: a new version inherits its type's
  class, and a fresh type is `managed` when module-stamped and `ordinary`
  otherwise. Tenant input cannot assign or change it. The class of a legacy row
  was backfilled from the interim denied-name list this module replaced, so every
  type that list refused is still refused.

  The refusal is the stable rule code `:writable_by_process_not_permitted`. Only
  the message varies, and it names the class, so a false positive explains
  itself. A class is not a name, so a new type such as `user_feedback` created
  after the change is `ordinary` and may take the flag.

  A solution pack cannot carry the flag at all (GH #2619); an administrator
  sets it after install, by creating and activating a new version under the
  `:EntitiesDefinitionsWrite` permission.
  """

  alias Letflow.Entities.Definition.Validator
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.EntityDefinition

  @classes ~w(managed org_tree identity_adjacent attachment_metadata ordinary)

  @rule :writable_by_process_not_permitted

  @doc "The write classes of an entity type (GH #2618). Only `ordinary` may take the flag."
  @spec classes() :: [String.t()]
  def classes, do: @classes

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
  Whether `writable_by_process: true` may be set on `definition`.

  `:ok` when the definition does not declare the flag. Otherwise `:ok` only
  when `managed_stamp` is `nil` (the type is not module-managed) and
  `write_class` is `"ordinary"`; else one `:writable_by_process_not_permitted`
  violation at `[:writable_by_process]` whose message names the refusal.
  `managed_stamp` and `write_class` are the values the create path resolved for
  the type (see `Letflow.Entities.Definitions.create_definition/3`).
  """
  @spec check_settable(term(), managed_stamp :: String.t() | nil, write_class :: String.t() | nil) ::
          :ok | {:error, {:validation, [Validator.violation()]}}
  def check_settable(definition, managed_stamp, write_class) do
    if declared?(definition) do
      case refusal_message(managed_stamp, write_class) do
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
  flag, the row's write class is `ordinary`, and the type is not module-managed.
  """
  @spec writable?(EntityDefinition.t()) :: boolean()
  def writable?(%EntityDefinition{} = row) do
    declared?(row.definition_json) and row.write_class == "ordinary" and is_nil(row.managed_by)
  end

  defp refusal_message(managed_stamp, _write_class) when is_binary(managed_stamp),
    do: managed_message()

  defp refusal_message(nil, "ordinary"), do: nil
  defp refusal_message(nil, "managed"), do: managed_message()

  defp refusal_message(nil, write_class) do
    "writable_by_process cannot be set: the entity type is classified \"#{write_class}\""
  end

  defp managed_message,
    do: "writable_by_process cannot be set: the entity type is managed by a module"

  defp violation(message),
    do: %Violation{rule: @rule, path: [:writable_by_process], message: message}
end
