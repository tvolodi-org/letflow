defmodule Letflow.Entities.WriteScope do
  @moduledoc """
  A scoped caller's write, as one value (REQ-518 / GH #2834): the caller's allowed node set and
  the declaration of the entity type being written. It replaces the positional
  `{scope, declaration}` tuple of `Letflow.Routers.Entities`, so the two halves cannot be swapped
  and a half-built pair does not compile (`@enforce_keys`).

  `new/2` is the boundary: it raises `ArgumentError` for a malformed set (see
  `Letflow.Entities.Query.Types.cast_scope_set/1`) or a declaration that is not
  `ScopeDeclaration.declaration/0` or `:unscoped`.
  """

  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.ScopeDeclaration

  @enforce_keys [:scope, :declaration]
  defstruct [:scope, :declaration]

  @type t :: %__MODULE__{
          scope: Types.scope_set(),
          declaration: ScopeDeclaration.declaration() | :unscoped
        }

  @spec new(Types.scope_set(), ScopeDeclaration.declaration() | :unscoped) :: t()
  def new(scope, declaration) do
    with {:ok, set} <- Types.cast_scope_set(scope),
         true <- declaration == :unscoped or ScopeDeclaration.valid_declaration?(declaration) do
      %__MODULE__{scope: set, declaration: declaration}
    else
      _ -> raise ArgumentError, "malformed write scope"
    end
  end
end
