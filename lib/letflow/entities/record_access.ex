defmodule Letflow.Entities.RecordAccess do
  @moduledoc """
  The one gate for a caller's record WRITE request (GH #2784, INV-2, INV-5, INV-8;
  design `lib/letflow/design/gh2784-write-routes-typeaccess.md` sections 2-5). The model is
  `Letflow.Entities.RequestAccess` (GH #2700): do every read unconditionally, then make ONE
  decision from a closed value that carries nothing the caller could tell apart.

  `Letflow.Routers.Entities` calls `write/3` first in `create_record`, `update_record`,
  `delete_record` and `import_records` (and `Letflow.Entities.ImportUpsert.precheck/2` consumes
  its value). The decision is computed first but APPLIED last, at the exact point where
  `Letflow.Entities.Records` would run: a `:hidden` value is replaced by `hidden_result/1`, the
  result `Records` itself gives an absent type, so a type denied to the caller travels the same
  router code and renders the same bytes as an absent one.

  `Records` stays unchanged: engine step writes, module handlers, exam and scripts write through
  it with `:tenant`/`Owner` authority and must not gain a caller-principal gate.
  """

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.TypeAccess

  @typedoc """
  `:hidden`: denied by TypeAccess, OR no active definition, OR any failed read (one value, no
  payload). `:managed`: visible but module-managed. `{:open, restricted}`: writable, with the
  caller's restricted field set (empty when the caller holds every grant or none is restricted).
  """
  @type write_decision :: :hidden | :managed | {:open, MapSet.t(String.t())}

  @typedoc "The part of `t:write_decision/0` a handler body receives (`:managed` is answered earlier)."
  @type access :: :hidden | {:open, MapSet.t(String.t())}

  @doc """
  Makes ALL four reads, in this order and with no short-circuit and no branching on an earlier
  result: `ManagedTypes.owner_of/2`, `TypeAccess.authorized?/3`,
  `Definitions.get_active_definition_by_name/2`, `FieldGrants.load_restrictions/3`; then decides
  with the precedence hidden > managed > open. Total: a failed read is `:hidden` (fail closed).
  Writes nothing, logs nothing, audits nothing (INV-8).
  """
  @spec write(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          write_decision()
  def write(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    owner = ManagedTypes.owner_of(entity_type, prefix)
    access = TypeAccess.authorized?(user_id, entity_type, prefix)
    definition = Definitions.get_active_definition_by_name(entity_type, prefix)
    restrictions = FieldGrants.load_restrictions(user_id, entity_type, prefix)

    decide(owner, access, definition, restrictions)
  end

  # Denied, absent and any failed read are the one `:hidden`.
  defp decide(owner, {:ok, :allowed}, {:ok, _definition}, {:ok, restricted}) do
    case owner do
      {:ok, _module_id} -> :managed
      :unmanaged -> {:open, restricted}
      _failed_read -> :hidden
    end
  end

  defp decide(_owner, _access, _definition, _restrictions), do: :hidden

  @typedoc """
  `:hidden`: the type is denied to the caller, or the read failed (one value, no payload).
  `:open`: the attachment route proceeds as it always did.
  """
  @type attachment_decision :: :hidden | :open

  @doc """
  The gate of the four record ATTACHMENT routes (design section 7): ONE read,
  `TypeAccess.authorized?/3`; anything but `{:ok, :allowed}` (denied or a failed read) is
  `:hidden`. No definition-existence and no managed read on purpose: the attachment routes work on
  a type with no active definition, and `:hidden` is applied by substituting fresh UUIDs for the
  ids, which is the absent answer by construction, so existence needs no probe. Writes nothing,
  logs nothing, audits nothing (INV-8).
  """
  @spec attachment(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          attachment_decision()
  def attachment(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    case TypeAccess.authorized?(user_id, entity_type, prefix) do
      {:ok, :allowed} -> :open
      _denied_or_failed -> :hidden
    end
  end

  @typedoc """
  `:hidden`: denied by TypeAccess, or any failed read. `:managed`: visible but module-managed.
  `:open`: the attachment write proceeds.
  """
  @type attachment_write_decision :: :hidden | :managed | :open

  @doc """
  The gate of the record ATTACHMENT WRITE routes (upload, delete; GH #2582, decision 0050 D7):
  `attachment/3` plus the managed stamp. Both reads are always made, then decided with the
  precedence hidden > managed > open, so a managed refusal never reveals a type the caller may not
  see. No definition-existence read (see `attachment/3`). Writes nothing, logs nothing, audits
  nothing (INV-8).
  """
  @spec attachment_write(user_id :: String.t(), entity_type :: String.t(), prefix :: String.t()) ::
          attachment_write_decision()
  def attachment_write(user_id, entity_type, prefix)
      when is_binary(user_id) and is_binary(entity_type) and is_binary(prefix) do
    owner = ManagedTypes.owner_of(entity_type, prefix)
    access = TypeAccess.authorized?(user_id, entity_type, prefix)

    case {access, owner} do
      {{:ok, :allowed}, {:ok, _module_id}} -> :managed
      {{:ok, :allowed}, :unmanaged} -> :open
      _denied_or_failed -> :hidden
    end
  end

  @doc """
  True iff `field_values` is a map with at least one top-level key in `restricted`. A non-map is
  false (the schema and `Records` layers reject it).
  """
  @spec names_restricted?(field_values :: term(), restricted :: MapSet.t(String.t())) ::
          boolean()
  def names_restricted?(field_values, restricted) when is_map(field_values) do
    Enum.any?(Map.keys(field_values), &MapSet.member?(restricted, &1))
  end

  def names_restricted?(_field_values, _restricted), do: false

  @doc """
  The value `Records.create_record/2`, `update_record/2` and `delete_record/2` return for an
  absent type: the one definition of "what absent looks like" to the router.
  """
  @spec hidden_result(entity_type :: String.t()) :: {:error, {:definition_not_found, String.t()}}
  def hidden_result(entity_type), do: {:error, {:definition_not_found, entity_type}}
end
