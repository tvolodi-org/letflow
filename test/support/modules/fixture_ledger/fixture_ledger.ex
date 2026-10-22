defmodule Letflow.Modules.FixtureLedger do
  @moduledoc """
  Test-only entry module (GH #2590 / REQ-501 R1, design
  `lib/letflow/design/gh2590-req501-module-write-handlers.md` section 10):
  the registered module that carries `:write_handlers` for the Catalog tests.
  It manages `fxl_ledger` and `fxl_balance` and registers two handlers,
  `post_entry` (both targets) and `post_balance_only` (`fxl_balance`), in
  `Letflow.Modules.FixtureLedger.Handlers`.

  R1 shipped NO pack and NO `on_install`. R2 gives it `module_fixtures/ledger_foundation.json`
  (the two managed entity definitions and process definitions: `fxl_post` plain, and R3 HUMAN_TASK
  variants, two of which declare `module_writes`) so a module install creates STAMPED process
  definition versions. R4a (GH #2590) adds `on_install/3`, which activates and promotes the two
  entity types (so a handler's `HandlerWrites.create/3` has an active managed type to write), and
  makes the handlers write for real; the ENGINE still executes none (R4b). No router, no
  permissions. Registered only in `config/test.exs`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Modules.EntityActivation

  @impl true
  defmanifest(
    id: "fixture_ledger",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/ledger_foundation.json",
    permissions: [],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxl_ledger", "fxl_balance"],
    write_handlers: [
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_entry",
        function: {Letflow.Modules.FixtureLedger.Handlers, :post_entry},
        targets: ["fxl_ledger", "fxl_balance"],
        args: %{"item" => %{required: true}, "quantity" => %{required: true}}
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_balance_only",
        function: {Letflow.Modules.FixtureLedger.Handlers, :post_balance_only},
        targets: ["fxl_balance"],
        args: %{"item" => %{required: true}}
      }
    ]
  )

  @impl true
  def on_install(prefix, _settings, ctx) do
    EntityActivation.activate_and_promote(prefix, ctx, ["fxl_ledger", "fxl_balance"])
  end
end
