defmodule Letflow.Modules.Step do
  @moduledoc """
  One ordered migration step a module manifest declares under `:migrations` (GH #3578 / REQ-640,
  decision 0055 D1/D3): `id`, `from` and `to` (strict semver strings, `to` higher than `from`),
  `kind` (`:declarative` or `:code`), `up`, `down` (a spec, or `:irreversible` for `down`) and
  `lossy` (boolean).

  This slice stores and shape-checks only: `Letflow.Modules.Catalog.validate/2` (rule 17) checks
  the shape and `Letflow.Modules.Catalog.upgrade_path/3` orders steps into a chain. `up` and `down`
  are only required to be non-nil; their declarative variants, the code-step fence and the
  execution belong to later slices (0055 D3, D12 step 2c). Not part of the manifest hash.
  """

  @keys [:id, :from, :to, :kind, :up, :down, :lossy]
  @enforce_keys @keys
  defstruct @keys

  @type t :: %__MODULE__{
          id: term(),
          from: String.t(),
          to: String.t(),
          kind: :declarative | :code,
          up: term(),
          down: term() | :irreversible,
          lossy: boolean()
        }
end
