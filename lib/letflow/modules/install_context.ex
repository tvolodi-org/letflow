defmodule Letflow.Modules.InstallContext do
  @moduledoc """
  The install context handed to a module's `on_install/3` (decision 0052 D3, GH 2531;
  GH 2541 made it a struct).

  `Letflow.Modules.Installs.install/3` is the only caller that builds it. Every required
  field is in `@enforce_keys`, so a missing key fails at construction (`struct!/2`
  raises `ArgumentError`), inside `install/3`, not later inside a module's `on_install/3`.

    * `:actor_id` — the installer's user id.
    * `:rationale` — the installer-supplied, non-blank rationale, verbatim.
    * `:tenant_prefix` — the tenant's schema prefix the install runs in (the same value
      as the `prefix` argument of `on_install/3`).
    * `:pack_entity_definition_ids` — `%{name => id}`, the entity definitions this
      install's own pack inserted (0052 D6: the only ones `on_install/3` may activate);
      `%{}` for a module without a pack.
  """

  @enforce_keys [:actor_id, :rationale, :tenant_prefix, :pack_entity_definition_ids]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          actor_id: Ecto.UUID.t(),
          rationale: String.t(),
          tenant_prefix: String.t(),
          pack_entity_definition_ids: %{String.t() => Ecto.UUID.t()}
        }
end
