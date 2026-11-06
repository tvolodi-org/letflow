defmodule Letflow.Modules.FixtureXpostOwner do
  @moduledoc """
  Test-only entry module (REQ-758 / GH #3903): the module M of the cross-module posting line tests.
  It depends on `fixture_ledger_post` (the module N), declares one ledger registration `own`
  (fixed ledger id `fixture_xpost_owner`) with a posting handler `post_own`, and its own four
  permission atoms (only TASK_WORKER holds `FxxpPost`, so a test can hold M's post permission without N's). One pack (only the `fxxp_note` entity type),
  no `on_install`, no router. Registered only in `config/test.exs`, after `FixtureLedgerPost`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_xpost_owner",
    version: "0.1.0",
    depends_on: ["fixture_ledger_post"],
    pack: "module_fixtures/xpost_owner.json",
    permissions: [:FxxpPost, :FxxpReverse, :FxxpRead, :FxxpReconcile],
    role_grants: %{TASK_WORKER: [:FxxpPost]},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxxp_note"],
    write_handlers: [
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_own",
        function: {Letflow.Modules.FixtureXpostOwner.Handlers, :post_own},
        targets: ["fxxp_note"],
        args: %{
          "note" => %{required: true},
          "posting" => %{required: false}
        },
        posts_ledger: "own"
      }
    ],
    ledger: %{
      "own" => %{
        ledger_ids: {:fixed, ["fixture_xpost_owner"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false}
        },
        key_bounds: [],
        permissions: %{
          post: :FxxpPost,
          reverse: :FxxpReverse,
          read: :FxxpRead,
          reconcile: :FxxpReconcile
        },
        scope_slot: nil,
        max_event_lateness_hours: 96,
        error_aliases: %{},
        policy: {Letflow.Modules.FixtureXpostOwner.LedgerPolicy, :declare}
      }
    }
  )
end
