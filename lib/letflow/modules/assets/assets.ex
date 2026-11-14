defmodule Letflow.Modules.Assets do
  @moduledoc """
  Module `assets` (GH #3894 / REQ-748, decisions 0050 D6, 0051 M4, 0076 R1 and R7, owner decision
  D-097; spec `docs/assets/asset-register.md`): the asset register, first slice, a skeleton.

  Module name: Assets (ru: Учёт активов; kk: Активтерді есепке алу). Record type `assets_card`
  (en: Asset card; ru: Карточка актива; kk: Актив карточкасы). The backend has no localized-name key
  in a manifest or a definition, so the names are stated here; the screens carry them in their own
  message files.

  The one record type `assets_card` is shipped by the pack `priv/modules/assets/pack.json`
  (generated from `priv/modules/assets/entity_definitions/` by
  `priv/modules/assets/generate_pack.exs`). It is a managed type: after install the generic write
  routes answer 403 `entity_type_managed`. Cards are written only by `Letflow.Modules.Assets.Cards`
  through the routes of `Letflow.Modules.Assets.Router` (REQ-750, permission `AssetsCardWrite`, no
  role grants).

  **Asset ledger** (REQ-749 / GH #3893, version 0.5.0; `docs/assets/asset-register.md` section 4):
  ledger id `assets`, slots `asset, org_unit, location, material_responsible, actual_user` (all uuid
  text; location and actual user may be empty; the order is append-only), scope slot `org_unit`,
  causes `commission` (positive), `change` and `handover` (zero sum per asset), `writeoff` (negative,
  a reason required), unit `pcs`. The pure policy is `Letflow.Modules.Assets.LedgerPolicy`, the read
  names are `Letflow.Modules.Assets.Views`, and three read routes (`balances`, `movements`,
  `reconcile`) live in `Letflow.Modules.Assets.Router`. The permissions `AssetsPost`, `AssetsReverse`,
  `AssetsRead` and `AssetsReconcile` have no role grants, so only TENANT_ADMIN and PLATFORM_ADMIN hold
  them. The commission document (C10, version 0.6.0, REQ-751 / REQ-752; C11, version 0.7.0, REQ-753, adds the change of responsible or user `assets_change` (ACH), the hand over `assets_handover` (AHO) and the write off `assets_writeoff` (AWO) on the same routes, with their line types and process definitions) is the first poster:
  record types `assets_commission`, `assets_commission_line` and `assets_posting_mark`, write handlers
  `post_document` and `reverse_document`, process definitions `assets_commission` and
  `assets_reversal`, seven `/documents` routes (`Letflow.Modules.Assets.Documents`). The storage is created at
  install by `Letflow.Modules.Installs`. A tenant that installed an earlier version (auto-CD deploys
  main to QA) has no `assets` partitions: the read routes answer empty lists, a posting would be
  refused `:ledger_storage_missing`, and the upgrade plan lists the ledger under `missing_ledger_storage`.

  **Change of kind** (C15 part 1, version 0.8.0, REQ-759 / GH #3902; spec `docs/assets/change-of-kind.md`):
  a fifth document kind `kind_change` (a stock SKU becomes an asset card) on the same `/documents` routes,
  with record types `assets_kind_change` and `assets_kind_change_line` and the document type
  `assets_kind_change` (AKC). It is drafted and issued (the master checks of section 5 run at issue, reading
  the catalog, locations, org and the card register). Because the checks read `catalog_items` and `stock`, the
  module now depends on both.

  **Posting a change of kind** (C15 part 3A, version 0.9.0, REQ-760 / GH #3901): issuing a `kind_change` starts the
  process definition `assets_kind_change`; completing its task runs two write handlers in ONE transaction:
  `post_kind_change` (this module: the mark, one `assets_card` per line, the asset entry with cause `kind_change_in`)
  and `post_kind_change_out` (module `stock`: the mark and the stock entry with cause `kind_change_out`), both with the
  same `correlation_id`. The card ids are derived by the platform (`HandlerWrites.next_record_id/1`). The reversal of the
  pair is part 3B.

  **Asset opening document** (G5 part 1, version 0.10.0, GH #4037, decision 0083, proposed): a sixth document kind
  `opening` (existing cards enter the register at their posting time) on the same `/documents` routes, with record
  types `assets_opening` and `assets_opening_line`, the document type `assets_opening` (AOP), and the route
  `POST /documents/:id/check` (every line's reasons, writes nothing).

  **Posting an opening** (G5 part 2, version 0.18.0, GH #4037, decision 0083 D1, D5, D6): the issue starts the process
  `assets_opening` (the issuer completes `submit`, a second person completes `approve`, which runs `post_document`),
  the ledger cause `opening` (positive, no client event time: the entry's event time is its posting time) puts each
  card into the register once. Money and dates stay on the card; the posting carries only the placement. The
  reversal is the generic `assets_reversal`. No SQL migration.

  **Card locks** (T-1490, version 0.13.0): `GET /cards/:id/lock` (`AssetsRead`) answers whether the card has a posted
  document; the card write path refuses a changed `inventory_number` or `kind` then (`CardLocks`).

  **Card holder** (T-1488 / G1-a, version 0.12.0): the card's `org_unit_id` is optional and no longer typed; the
  routes refuse it, a new card has none, and its holder (org unit, location, responsible, user) is read from the
  register. A card with an empty unit is visible to tenant-wide principals only. Relaxing `required` is a class B
  change, so tenants on 0.9.0 are re-seeded (no in-place upgrade). Setting the column by a posting is G2.

  **Card follows the hand over** (T-1489 / G2, version 0.14.0, decision 0054 R-update, D-111): the write handlers
  `post_document` and `reverse_document` may change `assets_card.org_unit_id` (`updates`, a new field of the handler
  registration, `Letflow.Entities.HandlerWrites.update/3`). A posted hand over moves the card of every `fixed` or
  `intangible` line from the header unit (or an empty unit) to the destination unit in the SAME transaction as the
  ledger entry; its reversal moves the card back when it is still at the destination. One card is one org unit
  (owner decision D-111): a `low_value` card is not moved here (its split by a partial hand over is a follow-up).
  Cards already moved or posted before this version are not touched.

  **Document print** (T-1915, version 0.21.0): `GET /documents/:id/print[?lang=ru|kk|en]` (`AssetsRead`, the guard of
  `GET /documents/:id`) answers the plain A4 act (PDF) of an issued, posted or reversed commission, change, hand over
  or write-off, from the ISSUED version (`DocumentPrint`, `DocumentPrintSource`). Code and route only, no definition or
  pack change (class A). T-1921: the same route with `form=da1&format=pdf|docx&lang=ru|kk` answers the official form
  ДА-1 / ҰМА-1 (annex 16) of an issued commission or hand over (`FormDa1`, `priv/print_forms/da1.json`); code only, no
  version bump. T-1922: `form=da4` answers ДА-4 / ҰМА-4 (annex 19, `FormDa4`) of an issued change or hand over;
  T-1923: `form=da3` answers ДА-3 / ҰМА-3 (annex 18, `FormDa3`) of an issued write-off, the commission block
  printing blank until REQ-777; the other official forms are later slices.

  **Card print** (T-1924, version 0.25.0): `GET /cards/:id/print?form=da2&format=pdf|docx&lang=ru|kk` (`AssetsRead`, the
  guard of `GET /cards/:id/lock`) answers the official form ДА-2 / ҰМА-2 (annex 17) of a card (`CardPrintSource`,
  `FormDa2`, `priv/print_forms/da2.json`); unit and materially responsible person come from the register when the card
  has exactly one row. Code and route only, no definition or pack change (class A).

  **Asset count K1** (T-1927, version 0.22.0, REQ-816 / GH #4375, owner decision D-128, spec
  `docs/assets/asset-count.md`): the count ORDER of fixed assets. Record types `assets_count_order`,
  `assets_count_scope` and `assets_count_member`, document types `assets_count.order` (ACO),
  `assets_count.sheet` (ACS) and `assets_count.result` (ACR) (only the order is issued), permissions
  `AssetsCountOrder` and `AssetsCountRecord` (no role grants, so TENANT_ADMIN and PLATFORM_ADMIN hold
  them), settings `count_enabled` (default off: the six `/counts` routes answer the 404 of a tenant
  without the module), `count_signer_role` (default `accountant`) and `count_freeze_limit_minutes`
  (default 120), read by `Letflow.Modules.Assets.Settings`. See `Letflow.Modules.Assets.Counts`. Existing
  installs take the new types by the in-place upgrade (class A); document types register lazily at the
  first issue.

  **Asset count K2** (T-1928, version 0.23.0, REQ-817 / GH #4374): the count SHEET. Record types
  `assets_count_line`, `assets_count_entry` and `assets_count_signature`, nine optional fields on
  `assets_count_order`, eight routes under `/counts/:id` (open, `PUT lines/:line_no`, `surplus-lines`, close,
  `sheet-signatures`, and the reads `lines`, `entries`, `sheet-document`). No new permission, setting or
  migration (class A). See `Letflow.Modules.Assets.CountSheet`.

  **Asset count K5** (T-1929, version 0.24.0, REQ-820 / GH #4371): the freeze of the counted scope. Four
  optional fields on `assets_count_order` (`freeze_started_at`, `freeze_until`, `freeze_whole_unit`,
  `freeze_location_ids`); opening a freeze order stores them, and issuing an asset document with a side in the
  frozen scope is refused `422 count_in_progress` inside the issue lock. No new permission, route, setting or
  migration (class A). See `Letflow.Modules.Assets.CountFreeze`.

  **Scope declaration** `{:column, "org_unit_id"}`: a scoped reader sees the cards of the org units
  of its grant. The declaration lives only in this compiled manifest; a managed type cannot be
  declared by a tenant (decision 0051 M4), so it cannot be edited later.

  **Shipped report**: install also creates the saved report "Asset list" (`Letflow.Modules.Assets.Reports`,
  spec `docs/assets/government-lists.md` section 3). Installs made before this change do not get it
  (no upgrade runner carries it).

  **Storekeeper grant** (T-1570, version 0.16.0, D-097): the setting `storekeeper_grants` (subset of
  `AssetsRead`, `AssetsPost`) lets a tenant's STOREKEEPER read and post assets. `role_grants` stays empty
  (a manifest line would widen every tenant); the grant is a per-tenant overlay read by
  `Letflow.Api.TenantGrants`. `on_install/3` seeds read and post for a tenant that installs the module now;
  an existing tenant has no key and stays off until a tenant administrator switches it on
  (`PUT /tenant/role-grants`). AssetsReverse, AssetsReconcile and AssetsCardWrite are never grantable.

  **Currency** (D-097, C4 / REQ-826): the tenant currency is read from the currency directory
  (`Letflow.Currencies.tenant_currency_opt/1`) with the legacy module setting `currency` as fallback
  for tenants not yet migrated by the C3 release task. Card writes and the xlsx import refuse a code
  not in the platform list (`:currency_unknown`) and a known code that is not the tenant currency
  (`:currency_mismatch`). See `currency/1`.

  **Import** (C17, REQ-762): `import_card/3` is the managed import function of `assets_card` (xlsx upsert by
  external reference, spec `docs/assets/asset-xlsx.md`); see `Letflow.Modules.Assets.Import`.

  **Expiry reminder** (C12): the module setting `expiry_reminder_lead_days` (1..3650, no default) is the
  lead time of `Letflow.Modules.Assets.Reminders`; absent means no reminder. See `expiry_lead_days/1`.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  alias Letflow.Documents
  alias Letflow.Modules.Assets.Reports
  alias Letflow.Modules.EntityActivation

  # Must stay equal to `manages_entity_types` in the manifest below (defmanifest takes literals).
  @types [
    "assets_card",
    "assets_commission",
    "assets_commission_line",
    "assets_change",
    "assets_change_line",
    "assets_handover",
    "assets_handover_line",
    "assets_writeoff",
    "assets_writeoff_line",
    "assets_posting_mark",
    "assets_kind_change",
    "assets_kind_change_line",
    "assets_opening",
    "assets_opening_line",
    "assets_count_order",
    "assets_count_scope",
    "assets_count_member",
    "assets_count_line",
    "assets_count_entry",
    "assets_count_signature"
  ]

  # GH #3891 / REQ-751: the document type of the commission (prefix ACM, numbering restarts each year).
  @document_types [
    %{
      key: "assets_commission",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "ACM",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_change",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "ACH",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_handover",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "AHO",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_writeoff",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "AWO",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_kind_change",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "AKC",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_opening",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "AOP",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_count.order",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "ACO",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_count.sheet",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "ACS",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    },
    %{
      key: "assets_count.result",
      owner_module: "assets",
      numbering_scope: :year,
      number_prefix: "ACR",
      number_pad: 6,
      legal_entity_required: false,
      declared_fields: %{}
    }
  ]

  @doc "The document types this module registers at install (and lazily at the first save)."
  @spec document_types() :: [map()]
  def document_types, do: @document_types

  @impl true
  defmanifest(
    id: "assets",
    version: "0.25.0",
    # T-1860: step-less window; the plan's class rows still gate unsafe changes. Without it a bump strands every tenant.
    min_upgradable_from: "0.1.0",
    depends_on: ["catalog_items", "locations", "org", "stock"],
    pack: "modules/assets/pack.json",
    permissions: [
      :AssetsCardWrite,
      :AssetsPost,
      :AssetsReverse,
      :AssetsRead,
      :AssetsReconcile,
      :AssetsCountOrder,
      :AssetsCountRecord
    ],
    role_grants: %{},
    required_roles: [],
    settings_schema: %{
      "type" => "object",
      "properties" => %{
        "currency" => %{"type" => "string", "minLength" => 3, "maxLength" => 3},
        "expiry_reminder_lead_days" => %{"type" => "integer", "minimum" => 1, "maximum" => 3650},
        "count_enabled" => %{"type" => "boolean"},
        "count_signer_role" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "count_freeze_limit_minutes" => %{"type" => "integer", "minimum" => 1, "maximum" => 5760},
        "storekeeper_grants" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => ["AssetsRead", "AssetsPost"]},
          "uniqueItems" => true
        }
      },
      "additionalProperties" => false
    },
    route_policies: [
      {"POST", "/cards", :AssetsCardWrite},
      {"PATCH", "/cards/:id", :AssetsCardWrite},
      {"POST", "/cards/:id/retire", :AssetsCardWrite},
      {"GET", "/cards/:id/lock", :AssetsRead},
      {"GET", "/cards/:id/print", :AssetsRead},
      {"GET", "/balances", :AssetsRead},
      {"GET", "/movements", :AssetsRead},
      {"GET", "/reconcile", :AssetsReconcile},
      {"POST", "/documents", :AssetsPost},
      {"PUT", "/documents/:id", :AssetsPost},
      {"DELETE", "/documents/:id", :AssetsPost},
      {"POST", "/documents/:id/issue", :AssetsPost},
      {"POST", "/documents/:id/check", :AssetsPost},
      {"POST", "/documents/:id/reverse", :AssetsReverse},
      {"GET", "/documents", :AssetsRead},
      {"GET", "/documents/:id", :AssetsRead},
      {"GET", "/documents/:id/print", :AssetsRead},
      {"POST", "/counts", :AssetsCountOrder},
      {"PUT", "/counts/:id", :AssetsCountOrder},
      {"POST", "/counts/:id/issue", :AssetsCountOrder},
      {"POST", "/counts/:id/cancel", :AssetsCountOrder},
      {"GET", "/counts", :AssetsRead},
      {"GET", "/counts/:id", :AssetsRead},
      # K2 (REQ-817): the count sheet routes (open, typed input, surplus, close, sheet marks, reads).
      {"POST", "/counts/:id/open", :AssetsCountRecord},
      {"PUT", "/counts/:id/lines/:line_no", :AssetsCountRecord},
      {"POST", "/counts/:id/surplus-lines", :AssetsCountRecord},
      {"POST", "/counts/:id/close", :AssetsCountRecord},
      {"POST", "/counts/:id/sheet-signatures", :AssetsCountRecord},
      {"GET", "/counts/:id/lines", :AssetsRead},
      {"GET", "/counts/:id/entries", :AssetsRead},
      {"GET", "/counts/:id/sheet-document", :AssetsRead}
    ],
    manages_entity_types: [
      "assets_card",
      "assets_commission",
      "assets_commission_line",
      "assets_change",
      "assets_change_line",
      "assets_handover",
      "assets_handover_line",
      "assets_writeoff",
      "assets_writeoff_line",
      "assets_posting_mark",
      "assets_kind_change",
      "assets_kind_change_line",
      "assets_opening",
      "assets_opening_line",
      "assets_count_order",
      "assets_count_scope",
      "assets_count_member",
      "assets_count_line",
      "assets_count_entry",
      "assets_count_signature"
    ],
    scope_declarations: %{
      "assets_card" => {:column, "org_unit_id"},
      "assets_commission" => {:column, "org_unit_id"},
      "assets_commission_line" => {:column, "org_unit_id"},
      "assets_change" => {:column, "org_unit_id"},
      "assets_change_line" => {:column, "org_unit_id"},
      "assets_handover" => {:column, "org_unit_id"},
      "assets_handover_line" => {:column, "org_unit_id"},
      "assets_writeoff" => {:column, "org_unit_id"},
      "assets_writeoff_line" => {:column, "org_unit_id"},
      "assets_posting_mark" => {:column, "org_unit_id"},
      "assets_kind_change" => {:column, "org_unit_id"},
      "assets_kind_change_line" => {:column, "org_unit_id"},
      "assets_opening" => {:column, "org_unit_id"},
      "assets_opening_line" => {:column, "org_unit_id"},
      "assets_count_order" => {:column, "org_unit_id"},
      "assets_count_scope" => {:column, "org_unit_id"},
      "assets_count_member" => {:column, "org_unit_id"},
      "assets_count_line" => {:column, "org_unit_id"},
      "assets_count_entry" => {:column, "org_unit_id"},
      "assets_count_signature" => {:column, "org_unit_id"}
    },
    write_handlers: [
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_document",
        function: {Letflow.Modules.Assets.Handlers, :post_document},
        targets: ["assets_posting_mark", "assets_card"],
        updates: %{"assets_card" => ["org_unit_id"]},
        args: %{
          "document_id" => %{required: true},
          "document_type" => %{required: true},
          "version_no" => %{required: true},
          "org_unit_id" => %{required: true},
          "mark" => %{required: true},
          "posting" => %{required: true}
        },
        posts_ledger: "assets"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "reverse_document",
        function: {Letflow.Modules.Assets.Handlers, :reverse_document},
        targets: ["assets_posting_mark", "assets_card"],
        updates: %{"assets_card" => ["org_unit_id"]},
        args: %{
          "document_id" => %{required: true},
          "document_type" => %{required: true},
          "version_no" => %{required: true},
          "org_unit_id" => %{required: true},
          "mark" => %{required: true},
          "reason_code" => %{required: true},
          "posting" => %{required: true}
        },
        posts_ledger: "assets"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_kind_change",
        function: {Letflow.Modules.Assets.Handlers, :post_kind_change},
        targets: ["assets_posting_mark", "assets_card"],
        args: %{
          "document_id" => %{required: true},
          "document_type" => %{required: true},
          "version_no" => %{required: true},
          "org_unit_id" => %{required: true},
          "mark" => %{required: true},
          "posting" => %{required: true}
        },
        posts_ledger: "assets"
      }
    ],
    ledger: %{
      "assets" => %{
        ledger_ids: {:fixed, ["assets"]},
        slots: [
          %{name: "asset", format: :uuid, required: true},
          %{name: "org_unit", format: :uuid, required: true},
          %{name: "location", format: :uuid, required: false},
          %{name: "material_responsible", format: :uuid, required: true},
          %{name: "actual_user", format: :uuid, required: false}
        ],
        causes: %{
          "commission" => %{sign_rule: :positive, reason_required: false},
          "change" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
          "handover" => %{sign_rule: :zero_sum_by_slot_1, reason_required: false},
          "writeoff" => %{sign_rule: :negative, reason_required: true},
          "kind_change_in" => %{sign_rule: :positive, reason_required: false},
          "opening" => %{sign_rule: :positive, reason_required: false}
        },
        key_bounds: [],
        permissions: %{
          post: :AssetsPost,
          reverse: :AssetsReverse,
          read: :AssetsRead,
          reconcile: :AssetsReconcile
        },
        scope_slot: "org_unit",
        max_event_lateness_hours: 96,
        error_aliases: %{},
        units: ["pcs"],
        policy: {Letflow.Modules.Assets.LedgerPolicy, :declare}
      }
    },
    import_functions: [
      %{entity_type: "assets_card", function: :import_card},
      %{entity_type: "assets_opening_line", function: :import_opening_line}
    ]
  )

  @doc """
  The import function of `assets_card` (GH #3899 / REQ-762, manifest `:import_functions`): one row of
  a file, called by the core import route. See `Letflow.Modules.Assets.Import`; it writes only
  through `Letflow.Modules.Assets.Cards`.
  """
  @spec import_card(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, map()} | {:error, term()}
  def import_card(prefix, entry, ctx),
    do: Letflow.Modules.Assets.Import.import_card(prefix, entry, ctx)

  @doc """
  The import function of `assets_opening_line` (G6, decision 0083 D7, manifest `:import_functions`): one
  row of a file into a DRAFT opening document. See `Letflow.Modules.Assets.Documents.OpeningImport`.
  """
  @spec import_opening_line(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, map()} | {:error, term()}
  def import_opening_line(prefix, entry, ctx),
    do: Letflow.Modules.Assets.Documents.OpeningImport.row(prefix, entry, ctx)

  @impl true
  def router, do: Letflow.Modules.Assets.Router

  @impl true
  def on_install(prefix, _settings, ctx) do
    with :ok <- EntityActivation.activate_and_promote(prefix, ctx, @types),
         :ok <- register_document_types(prefix, ctx),
         :ok <- Letflow.Api.TenantGrants.seed_default(prefix) do
      Reports.ensure_asset_list(prefix, ctx.actor_id)
    end
  end

  defp register_document_types(prefix, ctx) do
    Enum.reduce_while(@document_types, :ok, fn attrs, :ok ->
      case Documents.register_type(prefix, attrs, ctx) do
        {:ok, _type} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  The tenant currency of the tenant schema `prefix`: the `currency` setting of the active `assets`
  install, `"KZT"` when the setting is absent or the module is not installed (D-097). The tenant
  comes only from `prefix` (INV-1). Lives in `Letflow.Modules.Assets.Settings`.
  """
  @spec currency(prefix :: String.t()) :: String.t()
  defdelegate currency(prefix), to: Letflow.Modules.Assets.Settings

  @doc """
  The reminder lead time in days: the `expiry_reminder_lead_days` setting of the active `assets`
  install of `prefix`, `nil` when absent, invalid or the module is not installed (no default).
  """
  @spec expiry_lead_days(prefix :: String.t()) :: pos_integer() | nil
  defdelegate expiry_lead_days(prefix), to: Letflow.Modules.Assets.Settings

  @doc """
  Release entry of the currency migration (REQ-825, slice C3): maps the legacy `currency` setting
  and the stored card texts to the ISO codes of the directory. See
  `Letflow.Modules.Assets.CurrencyMigration`; run through `Letflow.Release.Currencies`.
  """
  @spec currency_migration(opts :: keyword()) ::
          {:ok, Letflow.Modules.Assets.CurrencyMigration.report()}
  defdelegate currency_migration(opts), to: Letflow.Modules.Assets.CurrencyMigration, as: :run
end
