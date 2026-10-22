defmodule Letflow.Entities.ImportAccess do
  @moduledoc """
  The caller's type access and scope set for one import (GH #2834), replacing the positional
  `{access, scope}` tuple that `Letflow.Routers.Entities` threaded through the import runners.
  `new/2` raises `ArgumentError` for a malformed access or scope set.
  """

  alias Letflow.Entities.Query.Types

  @enforce_keys [:access, :scope]
  defstruct [:access, :scope]

  @type access :: :hidden | {:open, term()}
  @type t :: %__MODULE__{access: access(), scope: Types.scope_set()}

  @spec new(access(), Types.scope_set()) :: t()
  def new(access, scope)
      when access == :hidden or (is_tuple(access) and elem(access, 0) == :open) do
    case Types.cast_scope_set(scope) do
      {:ok, set} -> %__MODULE__{access: access, scope: set}
      :error -> raise ArgumentError, "malformed import scope"
    end
  end

  def new(_access, _scope), do: raise(ArgumentError, "malformed import access")
end
