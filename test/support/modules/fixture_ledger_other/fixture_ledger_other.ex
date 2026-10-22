defmodule Letflow.Modules.FixtureLedgerOther do
  @moduledoc """
  Test-only entry module (GH #2590 / REQ-501 R1): a SECOND module with its own
  managed type `fxo_other` and one handler, used for the cross-module refusal
  tests (a handler of one module cannot be resolved as another module's, and
  its target is not another module's). No pack, no `on_install`, no router,
  no permissions. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_ledger_other",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxo_other"],
    write_handlers: [
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_other",
        function: {Letflow.Modules.FixtureLedgerOther.Handlers, :post_other},
        targets: ["fxo_other"],
        args: %{}
      }
    ]
  )
end

defmodule Letflow.Modules.FixtureLedgerOther.Handlers do
  @moduledoc "Inert handler of `Letflow.Modules.FixtureLedgerOther` (GH #2590 R1)."

  @spec post_other(Ecto.Multi.t(), term(), map()) :: {:ok, Ecto.Multi.t()}
  def post_other(multi, _ctx, _args), do: {:ok, multi}
end
