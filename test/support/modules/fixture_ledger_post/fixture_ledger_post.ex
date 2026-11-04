defmodule Letflow.Modules.FixtureLedgerPost do
  @moduledoc """
  Test-only entry module (REQ-684 / GH #3698, decision 0073 slice L3a): declares two valid ledger
  registrations, `alpha` (fixed ledger id `fixture_ledger_post`) and `beta`
  (`fixture_ledger_post:beta`), so the later slices can post two ledgers in one transaction. It has
  its own four permission atoms (no role is granted any of them), one error alias on `alpha`, a
  policy in `ledger_policy/`, two posting handlers and a plain `create/3` handler. One pack (REQ-685: only the `fxlp_note` entity type), no
  `on_install`, no router. Registered only in `config/test.exs`, last in the list.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_ledger_post",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/ledger_post.json",
    permissions: [:FxlpPost, :FxlpReverse, :FxlpRead, :FxlpReconcile],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxlp_note"],
    write_handlers: [
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_alpha",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_alpha},
        targets: ["fxlp_note"],
        args: %{
          "note" => %{required: true},
          "posting" => %{required: false},
          "twice" => %{required: false},
          "skip_note" => %{required: false},
          "before" => %{required: false}
        },
        posts_ledger: "alpha"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_beta",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_beta},
        targets: ["fxlp_note"],
        args: %{
          "note" => %{required: true},
          "posting" => %{required: false},
          "twice" => %{required: false},
          "skip_note" => %{required: false},
          "before" => %{required: false}
        },
        posts_ledger: "beta"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "plain",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :plain},
        targets: ["fxlp_note"],
        args: %{"note" => %{required: true}}
      }
    ],
    ledger: %{
      "alpha" => %{
        ledger_ids: {:fixed, ["fixture_ledger_post"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false}
        },
        key_bounds: [%{when_slot_nonempty: "k2", max_on_hand: "1"}],
        permissions: %{
          post: :FxlpPost,
          reverse: :FxlpReverse,
          read: :FxlpRead,
          reconcile: :FxlpReconcile
        },
        scope_slot: nil,
        max_event_lateness_hours: 96,
        error_aliases: %{"insufficient_balance" => "fxlp_short"},
        policy: {Letflow.Modules.FixtureLedgerPost.LedgerPolicy, :declare}
      },
      "beta" => %{
        ledger_ids: {:fixed, ["fixture_ledger_post:beta"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false}
        },
        key_bounds: [%{when_slot_nonempty: "k2", max_on_hand: "1"}],
        permissions: %{
          post: :FxlpPost,
          reverse: :FxlpReverse,
          read: :FxlpRead,
          reconcile: :FxlpReconcile
        },
        scope_slot: nil,
        max_event_lateness_hours: 96,
        policy: {Letflow.Modules.FixtureLedgerPost.LedgerPolicy, :declare}
      }
    }
  )
end
