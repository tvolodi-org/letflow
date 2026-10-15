defmodule Letflow.Modules.FixtureLedger do
  @moduledoc """
  Test-only entry module (GH #2590 / REQ-501 R1, design
  `lib/letflow/design/gh2590-req501-module-write-handlers.md` section 10):
  the registered module that carries `:write_handlers` for the Catalog tests.
  It manages `fxl_ledger` and `fxl_balance` and registers two handlers,
  `post_entry` (both targets) and `post_balance_only` (`fxl_balance`), in
  `Letflow.Modules.FixtureLedger.Handlers`.

  R1 ships NO pack and NO `on_install`: nothing installs or calls it in a
  running flow. A later PR (R4a) extends this fixture with its pack and
  activation. No router, no permissions. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_ledger",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxl_ledger", "fxl_balance"],
    write_handlers: [
      %{
        name: "post_entry",
        function: {Letflow.Modules.FixtureLedger.Handlers, :post_entry},
        targets: ["fxl_ledger", "fxl_balance"],
        args: %{"item" => %{required: true}, "quantity" => %{required: true}}
      },
      %{
        name: "post_balance_only",
        function: {Letflow.Modules.FixtureLedger.Handlers, :post_balance_only},
        targets: ["fxl_balance"],
        args: %{"item" => %{required: true}}
      }
    ]
  )
end
