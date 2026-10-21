defmodule Letflow.Entities.DefinitionAccess do
  @moduledoc """
  The gate of the two entity-definition WRITE routes (GH #2808, INV-2, INV-5, INV-8; design
  `lib/letflow/design/gh2784-write-routes-typeaccess.md` follow-up R7/OQ-3). Sibling of
  `Letflow.Entities.RecordAccess`: do every read unconditionally, then make ONE decision from a
  closed value that carries nothing the caller could tell apart.

    * `activate/3` -- `POST /entities/definitions/:name/activate`. `:hidden` (denied by
      TypeAccess, or a failed read) is answered as an ABSENT name (404) by the router, after the
      same body validation an absent name gets.
    * `create/3` -- `POST /entities/definitions`. "Denied equals absent" cannot hold (an absent
      name answers 201), so `:denied` is the constant route-level 403 the router sends.

  `Letflow.Entities.Definitions` stays ungated: solution packs, module installs and seeds call it
  with platform authority and no user subject.
  """

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.TypeAccess

  @type activate_decision :: :hidden | :managed | :open
  @type create_decision :: :denied | :open

  @doc """
  Makes BOTH reads, in this order and without branching on the first result:
  `ManagedTypes.check_tenant_write/2`, `TypeAccess.authorized?/3`; then decides with the
  precedence hidden > managed > open. A failed read is `:hidden` (fail closed). Writes nothing,
  logs nothing, audits nothing.
  """
  @spec activate(user_id :: String.t(), name :: String.t(), prefix :: String.t()) ::
          activate_decision()
  def activate(user_id, name, prefix)
      when is_binary(user_id) and is_binary(name) and is_binary(prefix) do
    managed = ManagedTypes.check_tenant_write(name, prefix)
    access = TypeAccess.authorized?(user_id, name, prefix)

    case {access, managed} do
      {{:ok, :allowed}, :ok} -> :open
      {{:ok, :allowed}, {:error, :entity_type_managed}} -> :managed
      _denied_or_failed -> :hidden
    end
  end

  @doc """
  ONE read, `TypeAccess.authorized?/3`; anything but `{:ok, :allowed}` (denied or a failed
  read) is `:denied`. Writes nothing, logs nothing, audits nothing.
  """
  @spec create(user_id :: String.t(), name :: String.t(), prefix :: String.t()) ::
          create_decision()
  def create(user_id, name, prefix)
      when is_binary(user_id) and is_binary(name) and is_binary(prefix) do
    case TypeAccess.authorized?(user_id, name, prefix) do
      {:ok, :allowed} -> :open
      _denied_or_failed -> :denied
    end
  end
end
