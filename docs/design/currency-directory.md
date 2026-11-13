# Currency directory (common data) — design and build slices

Task T-1870, written by the business analyst on 2026-11-13. Requirements: REQ-823 to REQ-828 in
`docs/requirements.yaml` (added by the same task). No code. Every statement is marked **[V]** (verified by
reading the file named, on origin/main c7950f342) or **[G]** (a guess or an assumption the build slice must
check). Decisions taken here are marked **Decision**.

## 0. Sources (quoted, because the portfolio file is outside this repository)

`ai-dala-portfolio/DECISIONS.md`, read 2026-11-13:

> **D-097 (2026-11-05)** ... 3. inventory_number is unique per tenant; one currency per tenant (KZT default,
> field kept); old assets arrive by the xlsx import (C17/C18). ...

> **D-134 (2026-11-13) Owner gate C walk, first findings on the asset card.** Owner (walking gate C on QA
> gate-b6): (1) a currency directory is needed as COMMON data (shared by all modules), and the asset card's
> Currency field must be a dropdown from it; (2) Depreciation method must be a selection from a list; (3) Asset
> documents screen shows no documents and has no way to add a new one. Passed to the operator as tasks
> (currency directory in core/common data, dropdowns, asset documents list and creation path); no new
> questions to the owner.

> **D-129 (2026-11-13)** Owner principle: access is checked against PERMISSIONS, never against role names. ...

The task text (operator, T-1870) adds: ISO 4217 codes, names in ru, kk and en, "a tenant switches currencies
on or off", KZT default, every other free-text currency field uses the directory, existing values migrated
without loss, QA only.

Repository sources opened: `docs/assets/asset-register.md` sections 3, 6 and 8; `docs/assets/asset-xlsx.md`
rows 6 and rule 6; `docs/assets/stock-workflow-documents.md` section 4; `docs/assets/kz-forms-mapping.md`
row D3; `docs/assets/government-lists.md` open question 4; requirement entries REQ-748 (C7), REQ-750 (C9),
REQ-551 (label overrides); the code files cited below.

## 1. Where the directory lives — Decision: core, beside the label overrides

**Decision.** The currency directory is **core common data**, not a module: a platform list compiled from a
JSON file shipped in the repository, plus one small tenant table for the tenant's switches. It follows the
tenant label overrides of REQ-551 exactly (platform defaults in a priv JSON file, tenant rows in the tenant
schema, a role-agnostic read, one manage permission).

Reasons:

1. **Every module can read it.** `mix letflow.check_boundaries` rule 4 lets a file in
   `lib/letflow/modules/a/` reference module `b` only when `b` is in `a`'s `depends_on`, and rule 5 forbids a
   core file to reference a module directory **[V]** (`lib/mix/tasks/letflow.check_boundaries.ex`, moduledoc).
   A module may always call core. A directory inside `catalog_items` (the `catalog_uom` pattern) would be
   readable by `stock` and `assets` (both list `catalog_items` in `depends_on` **[V]**,
   `lib/letflow/modules/stock/stock.ex` and `lib/letflow/modules/assets/assets.ex`), but not by a core route or
   by a module that does not depend on `catalog_items` (procurement, exam). "Common data shared by all modules"
   (D-134) is therefore core.
2. **The platform list cannot be seeded into existing tenants through the module machinery.**
   `catalog_uom` is a tenant entity type that each tenant fills itself **[V]**
   (`priv/modules/catalog_items/entity_definitions/catalog_uom.json`; `Letflow.Modules.CatalogItems` ships no
   uom writer except the import). A seeded record list would need `on_install/3` for new tenants and an upgrade
   step for existing ones, and the upgrade apply says "`on_install/3` seeds are not re-run (a new seed is a
   step)" while a step outside `set_default | backfill_from_constant | copy_field` is refused as
   `upgrade_needs_runner` **[V]** (`lib/letflow/module_upgrade/apply.ex` moduledoc,
   `lib/letflow/modules/step_spec.ex` `@executable`). A compiled list has no such problem: every tenant sees
   the same list the moment the build is deployed.
3. **The ISO list is not tenant data.** It is the same for every tenant, so INV-1 does not apply to it; only
   the switches are tenant data and they live in the tenant schema (INV-1, decision 0006 placement as the
   `label_overrides` migration states it: per-tenant via `prefix()`, `tenant_id` kept in the row **[V]**,
   `priv/repo/migrations/20261025300001_create_label_overrides.exs`).
4. **Precedent.** `Letflow.Labels.Defaults` compiles `priv/labels/entities_defaults.json` **[V]**
   (`lib/letflow/labels/defaults.ex`, `@path`), and `Letflow.Routers.Labels` reads with the role-agnostic
   `:MyAccessRead` and writes with `:LabelsManage` **[V]** (`lib/letflow/routers/labels.ex`).

Rejected: a new module `currencies` (needs a `depends_on` edge in every module that reads it and a seed path
that does not exist); `catalog_currency` in `catalog_items` (reason 1 and 2).

## 2. Record shape

Platform list (planned file `priv/currencies/iso4217.json`, compiled by the planned module
`Letflow.Currencies.Catalog`): one entry per currency of ISO 4217 list one that has a numeric minor unit.

| field | type | rule |
|---|---|---|
| `code` | string | ISO 4217 alphabetic code, exactly three letters A-Z, unique |
| `numeric_code` | string | ISO 4217 numeric code, exactly three digits (KZT is `398` **[G]**, checked against the file by the build) |
| `minor_units` | integer | ISO 4217 minor unit, 0..4 (KZT 2 **[G]**) |
| `names` | map | `ru`, `kk`, `en`, each a non-empty string |

Excluded: codes whose ISO minor unit is "N.A." (precious metals, SDR, test and no-currency codes) **[G]**: they
are not money of a document. Source of names: `en` from the ISO 4217 list; `ru` and `kk` from the Kazakhstan
national currency classifier that adopts ISO 4217 **[G]**: the build slice names the exact edition it used in
the JSON file's header field `source` and does not invent a name; an entry without a sourced name in a language
is left out of the file rather than guessed.

Tenant table (planned migration, table `tenant_currencies`, tenant-scoped like `label_overrides`): `id`,
`tenant_id`, `code` (text, CHECK three uppercase letters, unique), `active` (boolean), `tenant_currency`
(boolean; a partial unique index allows at most one true row), `updated_by`, `inserted_at`, `updated_at`.
The table starts empty in every schema; no existing row of any table is altered.

**Reading the switches (one rule).** A code is *active* when its row says `active = true`, or, without a row,
when the code is `KZT`. The *tenant currency* is the code of the row with `tenant_currency = true`, or `KZT`
without one. So an untouched tenant reads exactly what it reads today: KZT, the D-097 default.

## 3. What "switch on" means under D-097 — Decision

D-097 says one currency per tenant, and D-134 does not revoke it. A money field of a card or a document
therefore still carries **only the tenant currency**; the product never converts (asset-register.md section 6
**[V]**). **Decision:**

- A switched-on (active) currency is a currency the tenant may choose **as its tenant currency**, and the set
  every currency picker is built from.
- The tenant currency is always active: switching it off is refused (`currency_is_tenant_currency`).
- Choosing a new tenant currency switches it on in the same write.
- Switching on a second currency does **not** let a card or a document carry it. The asset card check
  `currency_mismatch` (REQ-750; `Letflow.Modules.Assets.Cards`, private `check_rules/2` **[V]**) stays.
- If the owner later lifts the one-currency rule, only that equality check and the picker filter change; the
  directory itself does not.

Changing the tenant currency later is allowed, as the assets setting allows it today (no guard exists
**[V]**, `Letflow.Modules.Installs.put_settings/3` validates only the schema). UAT assumption, to be confirmed
by the process owner: no new guard against changing it while cards hold the old code.

## 4. Who edits it

- The platform list is edited only by a code change to the JSON file (a pull request). No route writes it.
- A tenant writes only its switches, through `PUT /api/v1/currencies/:code` (body `active`, optional
  `tenant_currency: true`), permission **`CurrenciesManage`** (new, tenant scope, no role grants). By the
  computed clauses of `Letflow.Api.Authorization` it is held by PLATFORM_ADMIN and TENANT_ADMIN only, as
  `LabelsManage` is today **[V]** (`priv/permission_matrix/effective.golden`: `LabelsManage` true only for
  PLATFORM_ADMIN and TENANT_ADMIN). No role name appears in any new check (D-129).
- Every authenticated tenant user reads the directory through `GET /api/v1/currencies` with the role-agnostic
  `:MyAccessRead` and scope class `:self_service`, as `GET /labels` does **[V]** (`lib/letflow/routers/labels.ex`;
  `Letflow.Api.Authorization.endpoint_policy_key("GET", "/labels")`). The list is public reference data and the
  switches are not secret, so a user who fills a card or a document line can load the picker without a new
  grant (D-131 O3: a module update never grants new permissions to existing roles; a role-agnostic core read
  avoids that).
- Each accepted switch writes one audit entry through `Letflow.Audit.append_multi/4` in the same transaction,
  action `currencies.switched`, as `Letflow.Labels` does for `labels.override_set` **[V]**
  (`lib/letflow/labels.ex`).

## 5. Inventory of currency fields and currency text (grep on origin/main c7950f342)

Command: `grep -rnwiE 'currency|currency_code|currencies' lib priv/modules web/src` (concurrency and
recurrence hits removed) and `grep -rnE 'KZT|тенге|теңге|₸' lib priv/modules priv/print_forms web/src apps/mobile/lib`.

| # | Where | What it is | Decision |
|---|---|---|---|
| 1 | `priv/modules/assets/entity_definitions/assets_card.json:11`, `priv/modules/assets/pack.json:460` | card field `currency`, string, optional | keeps type string (no definition change, so no class B upgrade); values become ISO codes (slice C3) and writes refuse an unknown code (C4) |
| 2 | `lib/letflow/modules/assets/assets.ex:195` | assets setting `currency` (3 characters) | kept in the schema as a legacy key, read only as a fallback and by the migration (C3, C4); removing it would refuse a settings PUT that sends it back |
| 3 | `lib/letflow/modules/assets/settings.ex:13-21` | `currency/1`, default `KZT` | reads the core tenant currency, legacy fallback (C4) |
| 4 | `lib/letflow/modules/assets/cards.ex:62`, `:272` | `@allowed` key, `currency_mismatch` check on the merged document | check moves to the value sent in the body, adds `currency_unknown` (C4) |
| 5 | `lib/letflow/modules/assets/import.ex:38`, `:148` | xlsx column `currency`, refusal `asset_currency_mismatch` | adds `asset_currency_unknown` (C4) |
| 6 | `lib/letflow/routers/entities/record_import.ex:823`, `:969` | refusal-to-field map of the import | gains `asset_currency_unknown: "currency"` (C4) |
| 7 | `web/src/modules/assets/AssetCardForm.tsx:156-157` | free text input, `maxLength 3`, upper-cased | becomes a dropdown (C6) |
| 8 | `web/src/modules/assets/AssetCardFacts.tsx:21` | shows the stored text | shows code and name in the UI language (C6) |
| 9 | `web/src/modules/assets/assetsModel.ts:43,58,71,177`; `assetsMessages.ts:74,75,106,172,270`; `web/src/i18n/importMessages.ts:233` | form model, labels, error texts | C6 adds the texts of the new reasons |
| 10 | `priv/modules/stock/entity_definitions/stock_receipt_line.json:13-14`, `stock_opening_line.json:16-17` | `unit_price`, `line_value` decimals, **no currency field** | no field is added (stock-workflow-documents.md section 4 default "one tenant currency, shown by the screen, not stored on the line" **[V]**); the screen shows the tenant currency code from the directory (C6) |
| 11 | `web/src/modules/stock/documents/lineColumns.ts:30-31` (labels `stock.doc.field.unitPrice`, `lineValue`) | price and value column headers without a currency | the header carries the tenant currency code (C6) |
| 12 | `web/src/components/ui/lines/linesMessages.ts:28,29,74,75,114,115,160,161,200,201,246,247` | ids `c.price`, `c.value`, `f.price`, `f.value` with a hard-coded `₸` | the `₸` is replaced by a `{cur}` placeholder (C6); `grep -rn "c\.price" web/src` finds no screen that renders these ids today, only the catalog file **[V]** |
| 13 | `priv/print_forms/messages.json:26,27,28,32,50,64,91,102,140,145` | "в теңге" / "теңгемен" in the official form headers (Z-2, Z-3, Z-5, Inv-10, Inv-18) | **unchanged**: it is the official wording of the government form (kz-forms-mapping.md row D3 **[V]**), not a currency field |
| 14 | `lib/letflow/modules/assets/reports.ex:42` (report "asset list") | money columns, no currency column | unchanged (one tenant currency) |
| 15 | catalog items, counterparties, lots; stock issue, transfer, hand over, return, write off; asset documents | no money or currency field **[V]** (field scan of every `priv/modules/*/entity_definitions/*.json`) | nothing to change |
| 16 | `web/src/components/forms/widgets/maskedInput.tsx:17` (`currency-usd` mask) | an input mask of the generic forms, not a currency field | out of scope |
| 17 | `apps/mobile/lib/i18n/catalogue.dart:110` (`localizedCurrencyFormat`) | a formatter helper, no caller found | out of scope |
| 18 | procurement `estimated_cost_eur` (REQ text line 37978) | **not found** in `lib/` or `priv/` (`grep -rnE 'estimated_cost' lib priv web/src` prints nothing) | nothing to change |

## 6. Migration of existing values (slice C3)

Mapping table (one pure function `Letflow.Currencies.normalize/1`, planned): trim, then (a) a three-letter
text that equals an ISO code of the list in any letter case maps to that code; (b) the aliases `тенге`,
`теңге`, `тг`, `₸`, `tenge` (any letter case) map to `KZT`; (c) anything else is **unknown** and maps to
nothing. Aliases other than these are not invented; a new alias is a code change.

Release task (planned `Letflow.Release.Currencies.normalize(dry_run: true | false)`, the pattern of
`Letflow.Release.ExamParentId` **[V]**: thin delegate, reaches the module through `Letflow.Modules.Catalog`):

1. For each tenant schema with an active `assets` install: if no `tenant_currencies` row is the tenant currency
   and the assets setting `currency` maps to a code, that code becomes the tenant currency (and active). An
   unknown setting value is reported and nothing is written for it.
2. For each `assets_card` whose `currency` is not empty and not already an ISO code of the list: a mapped
   value is rewritten to the code through the module's record update (`Letflow.Entities.Records.update_record/3`
   with the assets owner, the path `Letflow.Modules.Assets.Cards` uses **[V]**), one record event and one audit
   entry per card, so the old value stays in the history (no loss). An unknown value is **kept as stored** and
   reported (schema, record id, the value's length, never the value in logs: INV-4 spirit, the text is tenant
   data).
3. The report counts `settings_set`, `cards_rewritten`, `cards_unknown`, `already_ok`, `failed` per tenant.
   A second run changes nothing (idempotent). `dry_run: true` writes nothing and reports the same counts.

Run scope: **QA only**. The operator runs it on QA after the deploy; any run on a real tenant (demo,
production) is announced to the portfolio manager first. Nothing runs at boot.

## 7. Web

- **Currencies screen** (C5): `/admin/currencies`, shown and routed with `RequirePermission` on
  `CurrenciesManage` (the pattern of `/admin/print-templates` in `web/src/router.tsx` and
  `web/src/components/layout/AppShell.tsx` **[V]**). A table: code, name in the UI language, minor units, a
  switch, a "tenant currency" mark and a "make tenant currency" action; a search box over code and names; the
  tenant currency's switch is disabled with a hint. Texts in en, ru, kk.
- **Asset card dropdown** (C6): the `currency` field becomes the shared `Select` (`web/src/components/ui/Select`,
  already used by the form **[V]**). Under D-097 its options are the empty choice ("tenant currency") and the
  tenant currency, shown as `code — name`. A stored value that is not the tenant currency (a legacy unknown
  value) is shown as an extra disabled option with its text, so it is visible and replaceable.
- **Stock lines** (C6): the receipt and opening price and value headers show the tenant currency code.

## 8. Import and export

- Asset xlsx import, column `currency` (asset-xlsx.md row 6 **[V]**): empty = tenant currency (unchanged);
  otherwise trimmed and upper-cased; not an ISO code of the list → row refused `asset_currency_unknown` with
  field `currency`; a code other than the tenant currency → `asset_currency_mismatch` (unchanged). Aliases are
  not accepted by the import (only the migration maps them).
- Export: the generic record export writes the stored value; after the migration it is the ISO code. No change.

## 9. Flags, manifest hash and upgrades

- **No feature flag.** The core directory is additive and an untouched tenant reads KZT as today (section 2);
  the assets reader keeps the legacy setting as fallback (C4). A flag would guard nothing. New flags default off;
  none is added.
- **Core slices (C1, C2):** no module version changes. The new tenant migration is registered in
  `Letflow.TenantProvisioning`'s manifest, as `20261025300001_create_label_overrides.exs` is **[V]**.
- **Assets (C3, C4):** code-only changes; `assets_card` and the pack stay byte-identical, so the manifest hash
  (`Letflow.Modules.ManifestHash`: id, version, managed types, scope declarations, ledger, handlers **[V]**)
  changes only by the version. Each slice moves the assets version one minor step above origin/main at
  implement time. U1/U2: the module must keep a `min_upgradable_from` so a tenant at the previous version gets
  `upgrade_path_available` true. Today `assets` declares none **[V]** (`lib/letflow/modules/assets/assets.ex`
  manifest); task T-1860 (pending, in CI on 2026-11-13) adds it and the CI guard. Both assets slices therefore
  start only after T-1860 has merged.
- **catalog_items, stock, locations, org:** unchanged.

## 10. Build slices, in order

| Slice | REQ | Owner | Size | Depends on |
|---|---|---|---|---|
| C1 platform list and tenant switches (core, no route) | REQ-823 | backend | 1 sitting: JSON file, two modules, one migration | none |
| C2 routes and `CurrenciesManage` | REQ-824 | backend | 1 sitting; pin-heavy (golden, route counts) | REQ-823 |
| C3 migration of existing values (release task) | REQ-825 | backend | 1 sitting | REQ-823, T-1860 |
| C4 assets use the directory | REQ-826 | backend | 1 sitting | REQ-823, T-1860 |
| C5 Currencies admin screen | REQ-827 | web | 1 sitting + shots | REQ-824 |
| C6 asset card dropdown, stock line headers | REQ-828 | web | 1 sitting + shots | REQ-824, REQ-826 |

Ordering notes: C2 touches `lib/letflow/api/authorization.ex`, the permission golden and `docs/roles.md`,
which the roles stage 0 slices (T-1855, T-1856, T-1857) also change one at a time: C2 runs after them. C3 and C4
both bump the assets version: run them one after the other, not in parallel.

Tests per slice are the acceptance criteria of each entry.

## 11. Not decided here / out of scope

- Exchange rates, conversion, several currencies on one document: not in scope (D-097).
- The currency switches in the tenant configuration bundle (`Letflow.TenantConfigBundle`): not part of these
  slices.
- Mobile: no currency field exists in `apps/mobile/lib` **[V]**; nothing to change.
