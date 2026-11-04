defmodule Letflow.Modules.Stock do
  @moduledoc """
  REQ-687 / GH #3707 (slice L4 of the stock ledger, decision 0073, assets phase B): module `stock`.
  It registers one ledger, `stock`, with the core ledger (`Letflow.Ledger`), declares the pure posting
  policy `Letflow.Modules.Stock.LedgerPolicy`, renders the stock views (`Letflow.Modules.Stock.Views`)
  and serves three read routes (`Letflow.Modules.Stock.Router`). It has no table, record type, pack,
  write handler or master check (those are REQ-679 and slice L7); no tenant gets it installed by
  this change (pilot gate of decision 0073: not enabled for a customer tenant until L6 and L7).

  ## Slots and their order (append-only, rule 12)

  `sku, location, org_unit, responsible, lot`, all uuid text. `sku` is slot 1 because the sign rule
  `zero_sum_by_slot_1` sums per distinct slot-1 value, so a two-leg cause conserves the quantity per
  sku, and the key indexes serve sku and location reads; `org_unit` is the scope slot (decision 0076
  R7). `responsible` and `lot` may be empty. The unit of measure is the leg's `unit_ref`, not a slot.

  ## Causes

  `receipt` (positive), `issue` and `write_off` (negative; write_off needs a reason), `transfer`,
  `hand_over` and `return` (zero sum per sku). Assumption, owner may change at GATE B: the six
  causes, the 96-hour lateness, the slot order.

  ## Permissions

  `StockPost`, `StockReverse`, `StockRead`, `StockReconcile`; no role grants, so only TENANT_ADMIN and
  PLATFORM_ADMIN hold them (OQ-11 of decision 0073 stays open for the owner).
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "stock",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [:StockPost, :StockReverse, :StockRead, :StockReconcile],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"GET", "/balances", :StockRead},
      {"GET", "/movements", :StockRead},
      {"GET", "/reconcile", :StockReconcile}
    ],
    manages_entity_types: [],
    scope_declarations: %{},
    ledger: %{
      "stock" => %{
        ledger_ids: {:fixed, ["stock"]},
        slots: [
          %{name: "sku", format: :uuid, required: true},
          %{name: "location", format: :uuid, required: true},
          %{name: "org_unit", format: :uuid, required: true},
          %{name: "responsible", format: :uuid, required: false},
          %{name: "lot", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false},
          "write_off" => %{sign_rule: :negative, reason_required: true},
          "transfer" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
          "hand_over" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
          "return" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false}
        },
        key_bounds: [],
        permissions: %{
          post: :StockPost,
          reverse: :StockReverse,
          read: :StockRead,
          reconcile: :StockReconcile
        },
        scope_slot: "org_unit",
        max_event_lateness_hours: 96,
        error_aliases: %{"insufficient_balance" => "insufficient_stock"},
        policy: {Letflow.Modules.Stock.LedgerPolicy, :declare}
      }
    }
  )

  @impl true
  def router, do: Letflow.Modules.Stock.Router
end
