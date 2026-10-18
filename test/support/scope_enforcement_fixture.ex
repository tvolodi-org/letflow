defmodule Letflow.Support.ScopeEnforcementFixture do
  @moduledoc """
  Test support for REQ-517 PR 2b (design section 4.2): sets the stored scope-enforcement mode
  of a tenant by a direct SQL `UPDATE` of the public `tenants` row. It exists because no route
  or context function may set `on` (`Letflow.ScopeEnforcement.parse_mode/1` and `flip/4` reject
  it until REQ-519). Lives under `test/support`, never under `lib/`; REQ-518 reuses it.
  The value is bound as a parameter; the next request reads the new value without a restart.
  """

  alias Letflow.Repo

  @doc "Sets `tenants.scope_enforcement` of `tenant_id` to `mode`; raises when no row matches."
  @spec set_stored_mode!(tenant_id :: Ecto.UUID.t(), mode :: :off | :shadow | :on) :: :ok
  def set_stored_mode!(tenant_id, mode) when mode in [:off, :shadow, :on] do
    {:ok, id} = Ecto.UUID.dump(tenant_id)

    %{num_rows: 1} =
      Repo.query!("UPDATE tenants SET scope_enforcement = $1 WHERE id = $2", [
        Atom.to_string(mode),
        id
      ])

    :ok
  end
end
