# GH #2660 / REQ-504 -- WMS quantity rules (3 of 4): exact decimal strings, scale per unit of measure, rounding rule, conversion at posting, the (base, original, unit) triple, item tolerance

Author: CODE-DESIGNER, 2026-10-19. Revision 3, final (on top of revision 2 `1331249e` and revision 1 `1ca191e5`; section 15 maps every CDV and SECURITY finding of all rounds). Branch `docs/GH-2660-wms-quantity-design`,
from `origin/main` `a614e9c1`. Design only: signatures, type shapes, column and constraint lists, step lists, test briefs. No function bodies. Nothing here was run
(docs only; the host is memory-starved and mix is not used). Every claim about existing code carries a `file:line` re-read on `a614e9c1`
(worktree `C:\Users\tvolo\AppData\Local\Temp\wt2660`), a citation to what #2654 DELIVERED (it is done), or is marked NOT FOUND or NOT VERIFIED.
Path shorthand: `decimals.ex` = `lib/letflow/entities/record/decimals.ex`; `validator.ex` (record) = `lib/letflow/entities/record/validator.ex`.

Sources: issue #2660 (body, updates of 2026-10-17 and 2026-10-18); decisions 0057 D4, D9, D10 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:16,44-48`
and the D10 addendum), 0058 (c), 0060 (items 1-6 and "Not decided here"), 0050; `lib/letflow/design/gh2654-decimal-exact-strings.md` (cited `gh2654...md`);
the ledger-core note **revision 5, `04a0dae9`, PR #2873, NOT on main** (cited `gh2657...md` with ITS section numbers; read in `C:\Users\tvolo\AppData\Local\Temp\wt2657`);
issues #2657, #2658 (with the alignment comment of 2026-10-19), #2661-#2664; base document `docs/WMS/WMS_Procurement_Requirements_Draft.md`
(MD-01 :60, MD-07 :66, MD-08 :67, stock dimensions :40); mapping `docs/migration/wms-customer-draft-mapping-20261016.md:57`.

## 0. Verdicts in one screen

| # | Question | Verdict |
|---|---|---|
| V1 | Is #2654 still a dependency? | **No, it is met.** Strict writes, reads, filters, sort, cursor, aggregates and ScriptReads are on main (section 1). The interim shape in the issue body (`validator.ex:108` JSON number) is superseded: `validator.ex:134-135`. |
| V2 | Where does the unit SCALE live? | Target home: the unit master (no unit master with a `decimal_scale` exists, N1). In L1-L4 the trust anchor is a **static `units` table in the ledger registration** (scale 0..9, dimension, optional tolerance), because `declare/2` is pure and has no master read (`gh2657...md` 3.3, V9). The unit SET only grows; scale is increase-only; dimension and registered factors are immutable. The starter table of 4.1 is NORMATIVE. |
| V3 | Rounding | One rounding step per converted leg, at the END, to the BASE unit's scale. Closed set of five magnitude-based modes. **The mode comes from the REGISTRATION** (production: `half_up` only until L7); a command may name a mode only when the registration allows more than one. A quantity ENTERED with more digits than its scale is REFUSED, never rounded. |
| V4 | Conversion | Single hop original -> base, ONE multiplication, no division, and EVERY `Quantity` function uses coefficient/exponent INTEGER arithmetic plus `Decimal.compare/2` only (all other `Decimal` arithmetic and `abs`/`negate`/`normalize` call the ambient 34-digit process-dictionary context). Factors are decimal strings (0057 D4), at most 18 integer and 12 fractional digits. |
| V5 | Trust of factors | Registered universal pairs: VERIFIED. Item-specific (pack) factors: client evidence, but bounded by a registered `factor_min`/`factor_max` per pack unit, flagged `conversion_basis = command`, permission-gated by a REQUIRED `convert_command`, restricted to registered `pack_targets`, and reported by a reconcile drift check. Full verification waits for L7, which GATES THE PILOT (`gh2657...md` 17). |
| V6 | The triple | `ledger_leg` columns (4.5): base `quantity`+`unit_ref`, original `quantity_original`+`original_unit_ref`+`original_scale`, `conversion_factor`, `conversion_basis`, `rounding_mode`, always-present `quantity_scale`. NULL conversion group when no conversion happened. |
| V7 | Tolerance | Absolute, in the BASE unit, inclusive; percent NOT supported. **The tolerance VALUE comes from the registration and is mandatory for the causes the registration names** (not from the command). Outside tolerance: `invalid_posting` reason `out_of_tolerance`; an exception leg needs a distinct registered permission checked in core's authority step BEFORE any refusal is released; excepted legs are counted in the `ledger.posted` audit entry. |
| V8 | MD-07 evidence | Reserved leg `attrs` key `measurement_ref` (token); artefacts belong to the document slice; truck scales are release 2. |
| V9 | Wire | Canonical decimal strings or JSON integers; every JSON float refused (#2654, `decimals.ex:130-148`); digits beyond scale refused. ONE parser, `Policy.decimal/3`, with ONE error shape. |
| V10 | Effect on #2657 | 33 amendments A1-A33 (section 8): A1-A13 are the quantity columns/digest/helpers/reasons; A14-A25 the SECURITY-driven registration, authority, audit, scan and reconcile changes; A26-A33 the revision-3 items (header `registration_hash`, audit-mode rule, reversal mode, `pack_targets`, `convert_command` required, evaluation-point role exclusion, counts, tenant-scope classification). This note does NOT edit that file. |
| V11 | Customer input | None blocking: 0057 D10 says ISO and standard unit scales are the defaults; one plain-language confirmation item (12.2). |

## 1. State of the world (all on `a614e9c1` unless stated)

### 1.1 What #2654 delivered (and where)

| # | Fact | Source |
|---|---|---|
| E1 | `decimal_strict` is a per-field opt-in, default false; immutable once the type has any record; WMS declares it from its first definition | 0060 items 1, 4, 6; `lib/letflow/entities/definitions.ex:471-...` (gate), `lib/letflow/entities/definition/validator.ex:470-540` (Rule 7), `lib/letflow/entities/managed_types/stamp.ex:97,584-607,651` |
| E2 | Write grammar for a strict field: a binary of at most 1100 bytes matching `^-?(0|[1-9][0-9]*)(\.[0-9]+)?$` (no exponent, no `+`, no whitespace), or a JSON integer; every JSON float refused with constraint `type` | `decimals.ex:41-44, 120-121, 130-148`; 0060 item 2 |
| E3 | Value-based digit rule: trailing zeros dropped first, then more fractional digits than `decimal_scale` is `scale`, more integer digits than `precision - scale` is `precision`; NEVER rounded; order type -> scale -> precision -> min/max | `decimals.ex:156-166`; `gh2654...md` section 3 |
| E4 | Stored, event, response and read form is the canonical scale-padded string (`"2.5"` -> `"2.50"`, `3` -> `"3.00"`, `-0.00` -> `0.00`) | `decimals.ex:189-209, 392`; `lib/letflow/entities/records.ex:1830-1838`; `validator.ex:96-114` |
| E5 | Strict field subschema is `{"type":"string"}`; non-strict stays `{"type":"number"}` | `validator.ex:134-135` |
| E6 | Bounds `min`/`max`/`non_negative` use `Decimal.compare/2`, INCLUSIVE; a strict bound may be a string | `decimals.ex:99-116, 399-405`; `definition/validator.ex:611-616` |
| E7 | Filters coerce the literal to an exact Decimal; a float literal is `invalid_decimal_value` (422) | `lib/letflow/entities/query/compiler.ex:468-503`; `decimals.ex:336-347` |
| E8 | Sort casts the stored text; a tampered cursor on ANY decimal field is a cursor error | `compiler.ex:642-660`; `lib/letflow/entities/query/cursor.ex:353-370` |
| E9 | Aggregates: `sum`/`min`/`max` and a `group_by` key of a strict field padded to the field scale; `avg` UNPADDED | `compiler.ex:894-925, 1048`; `lib/letflow/entities/query/allowlist.ex:444-454` |
| E10 | HTTP reads, JSON export and ScriptReads render strict fields as strings from the DEFINITION's specs | `lib/letflow/routers/entities.ex:3136-3156, 3372-3376, 3427-3432`; `lib/letflow/entities/script_reads.ex:102, 223-233, 296-308` |
| E11 | `Decimals.to_decimal/1` and `render_value/2` (accepts `%Decimal{}`, number or string; never raises; with more digits than `scale` it prints plain notation UNPADDED via `Decimal.to_string(_, :normal)`) | `decimals.ex:290-309, 319-328` |
| E12 | Decimal is 3.1.1; its default context is precision 34, `half_up`; `mult`, `add`, `sub`, `abs`, `negate`, `round` and `normalize` end in `context()` and so read the CALLING PROCESS's context (process dictionary) and round at its precision; `Decimal.compare/2` is context-free (it compares adjusted exponents and padded coefficients); `Context.with/2` does `Process.put`; `Decimal.to_string/1` defaults to SCIENTIFIC and `Jason.Encoder` for `Decimal` uses it | `mix.lock:4`; `deps/decimal/lib/decimal/context.ex` (`defstruct precision: 34`; `with/2`); `deps/decimal/lib/decimal.ex:324` (`abs`), `:363-390` (`add`), `:1145-1147` (`negate`), `:1224-1230` (`mult`), `:1272-1290` (`normalize`), `:1304-1318` (`round/3`), `:506-535` (`compare/2`), `:1686` (`to_string`); `deps/jason/lib/encoder.ex:227-230` |
| E13 | `HandlerWrites.create/3` writes through `command_multi/3`, so a handler-created record passes the strict pre-pass | `lib/letflow/entities/handler_writes.ex:138-149`; `records.ex:1836` |
| E14 | Per-unit-of-measure scale is NOT a core concern; field scale is the maximum, the module narrows through the public parser | 0060 "Not decided here"; `gh2654...md` section 9, D8 |
| E15 | StreamData is a test dependency; property tests exist | `mix.exs:62`; `test/letflow/api/pagination_test.exs:11` |
| E16 | `Decimals.reduce/1` is `defp` (private) and `Decimals.parse/3` returns the REDUCED value (may have a positive exponent) | `decimals.ex:170-177, 164` |

### 1.2 NOT FOUND on `a614e9c1`

| # | Item | Evidence |
|---|---|---|
| N1 | A unit master with a decimal scale: no module `Letflow.Modules.CatalogItems`, no `catalog_uom` definition with `decimal_scale`. `lib/letflow/modules/` holds the registry files (`catalog.ex`, `installs.ex`, ...) and `exam/`; `priv/modules/` holds `exam/`. The names `catalog_uom`/`catalog_item` exist only as name-only fixtures (`priv/module_fixtures/managed_foundation.json:105`; `lib/letflow/design/req496-managed-by-and-scope-node-paths.md:274`). #2663 is OPEN and says the unit scale and conversion factors "are NOT here: #2660"; #2664 `item_uom_valid?` allows only the base unit | `ls lib/letflow/modules priv/modules`; the issue bodies |
| N2 | `Letflow.Ledger`, any `ledger_*` table, `quantity_original`, `conversion_factor` | design only (PR #2873) |
| N3 | Any rounding or unit-conversion code | no `Decimal.round`, `Decimal.mult`, `Decimal.div` in `lib/` (searched) |
| N4 | Any item tolerance, rounding rule, alternate unit, item class | no field or module |
| N5 | A read facade for handlers | `gh2590-req501-module-write-handlers.md` OQ-R4; `gh2657...md` V1, 14.6 |
| N6 | Whether a process variable bound to a handler arg can be made un-overridable by the task completer | NOT VERIFIED |
| N7 | Clause-level text of SAP MM or Dynamics 365 unit-of-measure documentation | NOT VERIFIED: practice cited as 0057 D9 cites it (by product and concept) |

### 1.3 Relation to the ledger core (revision 5)

This note supplies what `gh2657...md` 4.5 reserves by reference (REQ-504 bullet), what 4.4 calls untrusted conversion evidence, and what 14.1 leaves as `optional(atom()) => term()` on
`declared_leg`. Written against route R-N: the core stays domain-neutral (Rule 7 denylist `stock item location warehouse site lot serial sku material inventory bin pallet`, `gh2657...md` 3.5).
`quantity`, `unit`, `scale`, `conversion`, `rounding`, `tolerance` are not on the denylist. Item, cable, box live in the stock module's registration, `declare/2` and read layer. The
pilot gate of revision 5 (the stock module is not enabled for a customer tenant until L6 AND L7, `gh2657...md` 17) means the unverified-evidence window of this note exists only before the pilot.

## 2. Wire choices: what #2654 decided and what this note assumes

| Input | Choice (cited) | The test asserts |
|---|---|---|
| canonical string `"2.50"` | accepted (E2) | stored 2.5, rendered at the unit's scale |
| JSON integer `3` | accepted, exact bignum (`decimals.ex:140-146`) | `3` == `"3"` |
| JSON number with fraction or exponent `2.5`, `3.0`, `1e3` | **refused**, `type`: the body decoder has already made it a lossy float (0060 item 2; `gh2654...md` D3) | `invalid_posting` reason `type` for an authorised subject |
| float from a process variable or Lua | refused for the same reason; the author converts to a string (`gh2654...md` 2.4 item 5, D3) | same |
| exponent, `+`, whitespace, `.5`, `5.`, `1,5`, `NaN`, `Infinity`, empty, leading zero, Unicode digits | refused (`decimals.ex:121`: ASCII-only) | table test |
| more fractional digits than the scale (quantity, factor, reference) | **refused, never rounded** (`decimals.ex:162`; `gh2654...md` D5) | 13-digit factor refused, 12 accepted |
| a conversion RESULT with more digits than the base scale | the one place that **rounds** (4.4), by the registered mode | the two-rounding-rule test |

**One parser.** `Letflow.Ledger.Policy.decimal/3` is the ONLY entry point policy code uses to turn a client value into a `Decimal`. It wraps `Decimals.parse/3` (`decimals.ex:130-166`), whose argument
order is `(value, precision, scale)`; `Policy.decimal` takes `(term, scale, int_digits)` and calls it with `precision = int_digits + scale`. Its single error shape is `{:error, :type | :scale | :precision}`
(amendment A5 replaces revision 5's `{:error, :invalid}` for this function; `uuid/1` and `token/2` keep `:invalid`). The parser the ledger uses IS the #2654 parser.

## 3. Each rule tied to evidence (AC 1)

| Rule | On main / delivered by #2654 | Not on main (NOT FOUND, designed here) |
|---|---|---|
| R1 exact decimal, string on the wire | E2-E5, E10 (entity quantity fields) | ledger leg columns and read maps (N2) |
| R2 scale per unit | E14: field maximum and a public parser | unit scale source (N1): registration table (L1-L4), master later (4.1) |
| R3 rounding rule per item (half-up default) | nothing (N3); precedent "refuse, never round" (E3) | mode set, storage, algorithm, registration source (4.3-4.4) |
| R4 conversion at posting, factor as decimal string | E2 parses a factor; E11 renders; no arithmetic exists (N3) | algorithm, verified pairs, verification (4.4) |
| R5 stored triple | none (N2) | columns, CHECKs, digest, reversal (4.5) |
| R6 item tolerance | none (N4) | rule, place, refusal, permission (4.6) |
| R7 MD-07 evidence | none | `attrs.measurement_ref` (4.7) |
| R8 sums and reports exact, no float | E9 (entity aggregates), E11 | ledger-side sums and rendering (4.8) |
| R9 DoS limits | E2 caps (`decimals.ex:41-44, 150-152`) | tighter ledger caps and shape pre-check (4.2) |

## 4. Design

### 4.1 The unit-of-measure scale (decision D-Q1)

**Three layers.**

1. *Storage scale (maximum).* Every WMS quantity is `numeric(30,9)` (21 integer, 9 fractional). Entity quantity FIELDS declare `type: decimal, decimal_precision: 30, decimal_scale: 9, decimal_strict: true`
   (0060 item 6; E1), the same maximum as the ledger (OQ-10 of `gh2657...md` is closed here), so a document quantity can always be posted. Factor fields use precision 30, scale 12. The flag is immutable once
   records exist (E1), so these declarations are in the module's FIRST definition files.
2. *Unit scale (0..9).* The fractional digits a quantity in this unit may have; the MD-07 "precision". **In L1-L4 it is enforced at POSTING only** (by `declare/2` and again by core B4). Entity document fields
   enforce only the maximum 9. No module entity-write hook is specified or tested for per-unit narrowing; `Quantity` exposes `within_scale?/2` for a module that wants an earlier check, but that is not part of this
   design's guarantees (revision 1 wrongly implied an "entity-write step" enforcement).
3. *Stored scale* (`quantity_scale`, `original_scale`, 4.5): the unit scale in force at posting, so history renders and checks without a registration that may have changed.

**Source.** (A) a unit MASTER is the target home (NOT BUILT, N1; needs a follow-up requirement, section 9); (B) **a static `units` table in the ledger registration, ADOPTED for L1-L4** (pure, hashed by
`ManifestHash`, validated by rule 12, matches 0057 D10); (C) scale carried by the command REJECTED (the client would choose the digits it is refused on); (D) plain module config rejected (not hashed, invisible to core B4).

**Registration data** (additions to rule 12, `gh2657...md` 14.3; section 8 A10, A14-A19):

```
units: %{unit_ref => %{scale: 0..9, dimension: String.t(),
                       rounding_mode: rounding_mode() | nil,                 # optional override for this BASE unit; else rounding.default
                       factor_min: String.t() | nil, factor_max: String.t() | nil,   # REQUIRED when dimension == "pack"; canonical decimals, 18/12 digits, factor_min > 0
                       pack_targets: [String.t()] | nil,                     # REQUIRED when dimension == "pack": the dimensions of the BASE units a command factor may convert to (e.g. ["count"])
                       tolerance: %{abs: String.t(), required_for_causes: [String.t()]} | nil}}
conversions: [%{from: unit_ref, to: unit_ref, factor: String.t()}]             # registered (verified) pairs; both directions listed explicitly
rounding: %{default: rounding_mode(), allowed: [rounding_mode()]}               # allowed has ONE entry in production
permissions: (existing four) + %{tolerance_exception: atom(), convert_command: atom() | nil}   # convert_command is REQUIRED (non-nil) whenever any unit has dimension "pack"
```

Rule 12 checks (all against the previously installed registration where known): every `scale` an integer 0..9 and **increase-only**; **the unit SET only grows** (no unit may be removed); **`dimension` and every
registered conversion factor are immutable** (a changed or removed registered pair is refused; a new pair is allowed); keys are `:token`s; each pair has both endpoints in `units`, the same dimension, no self pair,
no duplicate `(from, to)`, a positive factor of at most 18/12 digits, and when both directions are present their product is exactly 1; `rounding.default` is in `allowed`, **`allowed` has exactly one entry unless the
config flag `:ledger_allow_multiple_rounding_modes` is true (set only in dev/test config, not `Mix.env`)**; a unit with `dimension == "pack"` carries `factor_min`/`factor_max` with `0 < factor_min <= factor_max`;
`tolerance.abs` is a canonical decimal with at most the unit's scale digits; `required_for_causes` names registered causes; `units[*].rounding_mode`, when present, must be IN `rounding.allowed`;
a pack unit carries a non-empty `pack_targets` list of dimension names that occur in `units`; **`convert_command` must be a non-nil manifest permission whenever any unit has `dimension == "pack"`**;
`tolerance_exception` and `convert_command` are manifest permissions distinct from each other and from `post` and `reverse`, and the role grants of `post`, `reverse`, `tolerance_exception` AND `convert_command`
may not include `TENANT_AUDITOR` or `CANDIDATE`. **No widening without a version bump:** a `tolerance.abs` that is LARGER than the previously installed value, a `factor_max` that is larger or a `factor_min`
that is smaller, a `rounding.allowed` that gains a mode, or a `pack_targets` that gains a dimension is refused unless the manifest `version` differs from the installed one (the registration is hashed by
`ManifestHash`, so any change already needs a bump for in-flight tasks; this makes the widening explicit in review). Narrowing is always allowed. The registration in force at each posting is identified on the row
(`ledger_entry.registration_hash`, 4.5), so the tolerance, mode and bounds that applied to a historical leg are recoverable.

**Normative starter table for L1-L4 (F10; the stock module's registration MUST contain at least these; the customer may confirm or extend it, 12.2).**

| unit | scale | dimension | notes |
|---|---|---|---|
| `ea`, `pcs`, `set` | 0 | count | |
| `box`, `pack` | 0 | pack | `factor_min "1"`, `factor_max "1000"`, `pack_targets ["count"]` |
| `kg` | 3 | mass | |
| `g` | 0 | mass | |
| `t` | 3 | mass | |
| `m` | 3 | length | |
| `cm`, `mm` | 1 | length | |
| `km` | 3 | length | |
| `l` | 3 | volume | |
| `ml` | 0 | volume | |

Registered pairs (explicit in both directions): `g -> kg 0.001`, `kg -> g 1000`, `t -> kg 1000`, `kg -> t 0.001`, `cm -> m 0.01`, `m -> cm 100`, `mm -> m 0.001`, `m -> mm 1000`, `km -> m 1000`,
`m -> km 0.001`, `ml -> l 0.001`, `l -> ml 1000`. The starter table declares NO `tolerance` entry (a per-unit tolerance is only meaningful where the stock module sets one, with customer confirmation); the test
registration (section 6) declares `m` with `tolerance abs "0.05"` required for the cause `receipt`.

**Trust, said exactly.** The base unit of a balance key is chosen by the first posting (client-supplied, `gh2657...md` 4.4) but must be a KEY of the registered table with its registered scale; the pin on
`ledger_balance.unit_ref` prevents a later change (`unit_mismatch`). What stays unverified until L7: that THIS item's base unit is the unit the client named.

### 4.2 Quantity grammar, caps and the shape pre-check (the DoS section of the wire)

* **Order inside `Quantity`, strictly:** (1) for a binary: refuse `type` if longer than **64 bytes** BEFORE the regex or any `Decimal` call (the longest legal text is 32 bytes); (2) for an integer: **compare
  `abs(v)` with `10^int_digits` FIRST** (refuse `precision`), and only then, as a redundant assertion on an already bounded value, check the 16-byte `:binary.encode_unsigned` size; nothing calls
  `:binary.encode_unsigned` on an unbounded bignum (revision 1 did, `decimals.ex:150-152` style, whose own cap is 425 bytes); (3) only then delegate to `Decimals.parse/3` (whose caps are 1100 bytes and 425 bytes,
  `decimals.ex:41-42`). `Quantity.decimal/3` therefore rejects every oversized input before `Decimals.parse/3` is reached.
* The grammar has no exponent, so `1e1000000` is `type` by the regex without a parse (`decimals.ex:121`).
* Digit caps: quantity, reference, tolerance at most 21 integer and 9 fractional digits (further capped by the unit scale); factor at most 18 integer and 12 fractional; factor `> 0`; tolerance `>= 0`; reference `> 0`.
* **Carrier form.** `Decimals.parse/3` returns the REDUCED value, which may have a positive exponent (E16). `Quantity` converts every value to its **carrier form**: `sign` is 1 or -1, `0 <= coef < 10^30`,
  `-12 <= exp <= 0`. **Exact accepted domain for a positive exponent (CDV 4):** a received `Decimal` with `exp > 0` is accepted ONLY when `digits(coef) + exp <= 21` (the integer-digit cap); it is then
  EXPANDED to `exp = 0` (coefficient multiplied by `10^exp`) BEFORE the other bounds are applied, so `1E+3` (coef 1, exp 3) becomes coef 1000, exp 0. Any other positive exponent (for example
  `exp: 1_000_000_000`) is `decimal_shape` without computing the power; `exp < -12`, a non-integer or non-finite coefficient, `coef >= 10^30` (after expansion) and a `sign` outside `{1,-1}` are `decimal_shape`. **Every `Quantity` function that receives a `Decimal` first runs the
  SHAPE pre-check** (`is_integer(coef)`, the bounds above, `sign` in `{1,-1}`): this covers values returned by a module's `declare/2` (B4), values read from the database (`reconcile`) and values passed between
  `Quantity` functions. A failing value is `decimal_shape` BEFORE any arithmetic, so a hostile `Decimal` with exponent 10^9 or a 10 MB coefficient never reaches a multiplication.
* Arithmetic bound after the shape check: the exact product has at most 60 digits; one integer multiplication and at most one integer division by a power of ten `<= 10^30`.

### 4.3 The rounding rule (decision D-Q2)

* **Closed set of five modes on the MAGNITUDE, then the sign is re-applied:** `half_up` (default; ties away from zero), `half_even`, `half_down`, `up` (away from zero), `down` (toward zero). Magnitude-based rounding means
  `convert(-q) = -convert(q)`. `ceiling`/`floor` are excluded (sign-dependent meaning). The semantics equal `Decimal.round/3` for the same five names (`context.ex` table), which makes `Decimal.round/3` a TEST ORACLE only.
* **Where chosen (SEC 2).** The mode is a REGISTRATION fact: `units[base].rounding_mode` if present, else `rounding.default`. A command leg may carry a `rounding_mode` ONLY when `rounding.allowed` has more than one entry
  and the mode is in it (else `rounding_mode`). Production: `allowed = [half_up]`, so a client cannot choose `up` on receipts and `down` on issues to skim stock. Per-item and per-class modes (0057 D10) arrive with the master at L7.
* **Stored** in `rounding_mode` on every converted leg (4.5), so the result is reproducible and `reconcile` recomputes it.

### 4.4 The conversion rule at posting (decision D-Q3)

**Definitions.** `original` in unit `U_o`, scale `s_o`; `base` in `U_b`, scale `s_b`; `factor` = base units per ONE original unit.

**Arithmetic contract (F4).** EVERY `Quantity` function (`convert`, `round_magnitude`, `deviation`, `within_tolerance?`, `sum`, `negate`, `abs`, `reduce`, `to_wire`) is implemented on the integer `sign`, `coef` and `exp`
of the carrier form (4.2) plus `Decimal.compare/2` for ordering (E12: context-free). It does NOT call `Decimal.mult/add/sub/div/abs/negate/normalize/round` (they apply the ambient process-dictionary context, E12) and
does not use `Decimal.Context.with/2` (a process-dictionary write, forbidden by the policy purity contract, `gh2657...md` T-PL-1). `Quantity` has its OWN `reduce`/`expand` (the main one is private, E16); the main code's
precedent for this style is `decimals.ex:168-209` (comment at :168-169). `to_wire` is total: it pads when the digits fit the scale and otherwise prints the plain unpadded form exactly like the fallback in
`render_value/2` (`decimals.ex:303-309`), so it can never raise (unlike `to_canonical/2`, which raises when digits exceed the scale, `decimals.ex:194`).

**Order of operations in `declare/2` for each leg (normative).**

1. Parse `original` with `Policy.decimal/3` and the scale `s_o` of `U_o` (`type`/`scale`/`precision`); `unit_unknown` when `U_o` or `U_b` is not in `units`. A zero quantity is `quantity_zero`.
2. If `U_o == U_b`: no conversion. A supplied factor or mode is `factor_unexpected`. `base = original`. The conversion group stays NULL.
3. Else a factor is required (`factor_missing`). Classify the pair: (a) REGISTERED: a supplied factor must be absent or EQUAL to the registered one (`factor_mismatch`); `conversion_basis = registered`. (b) Not
   registered: allowed only when `dimension(U_o) == "pack"` AND `dimension(U_b)` is in `units[U_o].pack_targets` (else `unit_pair`; a box -> kg conversion by client factor is refused); the factor is parsed with 18/12 caps and `> 0` (`factor_range`) and must lie in `[factor_min, factor_max]` of `U_o` (`factor_range`);
   `conversion_basis = command`.
4. Exact product `P = original x factor` on integer coefficients and added exponents.
5. **Round once, at the end.** If `P` has at most `s_b` fractional digits it is exact. Otherwise round the magnitude to `s_b` with the registered mode (4.3). No intermediate rounding; **chains are not allowed**
   (always one hop original -> base).
6. A rounded magnitude of zero is `rounds_to_zero`; more than 21 integer digits is `precision`. Re-apply the sign of `original`.
7. Tolerance (4.6) on the rounded `base`.
8. Return the declared leg: `quantity = base`, `unit_ref = U_b`, the REQ-504 keys of 4.5.

**Core re-validation at B4 and in `reconcile` (F1; `Quantity.verify_leg(leg, registration, mode)`, `mode` is `:post` at B4 and `:audit` in `reconcile`).** A buggy or malicious policy must not be able to post an
inconsistent quantity, so at posting core checks EVERY relation against the REGISTRATION, not against what the policy declared. Each check has its reason atom. **The column "Modes" says where a check runs.**
`:post` = B4 of a normal posting against the registration in force NOW. `:audit` = `reconcile` and the verification of REVERSAL legs: it tests only the row's OWN stored values plus the relations that can
never change (scales may only increase, registered factors are immutable, the unit set only grows). It does NOT re-test anything the registration may legitimately change later (`tolerance.abs`,
`rounding.allowed`, `factor_min`/`factor_max`, `required_for_causes`, `pack_targets`, a new registered pair), because that would report a false `inconsistent_at` for a leg that was correct when posted
(CDV 1). What was in force is recoverable from `ledger_entry.registration_hash` (4.5).

| # | Check | Modes | Reason |
|---|---|---|---|
| C1 | shape pre-check of every Decimal in the leg (4.2) | post, audit | `decimal_shape` |
| C2 | `unit_ref` is a key of `units`; `original_unit_ref` (if present) is a key of `units` | post, audit | `unit_unknown` |
| C3 | `quantity_scale == units[unit_ref].scale` | post only; audit: `<=` (scales only increase) | `scale_mismatch` |
| C4 | `quantity` has at most `quantity_scale` fractional digits and is non-zero | post, audit | `scale` / `quantity_zero` |
| C5 | conversion group all-present or all-absent; `original_unit_ref != unit_ref` | post, audit | `conversion_inconsistent` |
| C6 | `original_scale == units[original_unit_ref].scale`; `quantity_original` within `original_scale` digits | post only for the equality; audit: `<=`; the digit rule in both | `scale_mismatch` / `scale` |
| C7 | `conversion_basis = registered` => `(original, unit)` is in `conversions` AND `conversion_factor` EQUALS the registered factor | post only (a registered pair that no longer exists cannot occur because pairs are immutable, but a leg stored as `command` may later have a registered pair, so the basis is not re-derived in audit) | `factor_mismatch` |
| C8 | `conversion_basis = command` => `(original, unit)` NOT registered, `dimension(original_unit_ref) == "pack"`, `dimension(unit_ref)` in `units[original].pack_targets` and `factor_min <= conversion_factor <= factor_max` | post only | `unit_pair` / `factor_range` |
| C9 | `conversion_factor > 0`, at most 18/12 digits | post, audit | `factor_range` |
| C10 | `rounding_mode` is in `rounding.allowed` | post only (audit: only that it is one of the five closed modes, enforced by the DB CHECK) | `rounding_mode` |
| C11 | recompute `convert(quantity_original, conversion_factor, quantity_scale, rounding_mode)` from the ROW'S OWN values and compare to `quantity`; signs agree | post, audit | `conversion_inconsistent` |
| C12 | tolerance group (4.6): all-or-none; `tolerance_state` consistent with the row's OWN `reference_quantity`, `tolerance_abs` and `quantity`; `exception_ref` iff `excepted` (all post and audit). In `:post` only: `tolerance_abs` EQUALS `units[unit_ref].tolerance.abs`, and the group is present when the cause is in `required_for_causes` | as stated | `tolerance_inconsistent` / `tolerance_input` |

In `:audit` the remaining independent tripwire is the DB CHECK of 4.5, which `reconcile` also evaluates per leg. The `:post` equalities C3/C6 make the DB CHECK `quantity = round(quantity, quantity_scale)` meaningful:
the scale it is relative to is the REGISTERED one at posting time. Registered factors are immutable (rule 12), so C7's equality is stable, but audit does not depend on it.

**Refusal versus rounding, the whole table.**

| Digits exceed the scale in... | Outcome |
|---|---|
| an ENTERED quantity (base or original unit) | refuse `scale` (never rounded; E3) |
| a factor (more than 12 fractional or 18 integer digits) | refuse `scale` / `precision` |
| a reference (more than the base scale) | refuse `scale` |
| the exact PRODUCT of a conversion | **round once** by the registered mode (the only rounding in the system) |
| a sum of legs | cannot happen: legs of a key share the pinned unit and each has at most that scale |

**Division.** Never performed. A conversion needing a non-terminating fraction (1/3) cannot be a 12-digit decimal factor: the recorded D4 limit (OQ-Q6).

### 4.5 The stored triple (decision D-Q4): columns on `ledger_leg`

These replace the placeholder row "(REQ-504 columns)" of `gh2657...md` 4.3. All are in the FIRST migration.

| Column | Type | Null | Meaning and CHECKs |
|---|---|---|---|
| `quantity` | numeric(30,9) | no | existing: SIGNED base delta; `CHECK (quantity <> 0)`; **new** `CHECK (quantity = round(quantity, quantity_scale))` |
| `unit_ref` | text | no | existing: the BASE unit, pinned per balance key |
| `quantity_scale` | smallint | no | the base unit's scale at posting; `CHECK (quantity_scale BETWEEN 0 AND 9)`; equals the registered scale (C3) |
| `quantity_original` | numeric(30,9) | yes | the quantity AS ENTERED, same sign as `quantity`; `CHECK (quantity_original <> 0)`, `CHECK (sign(quantity_original) = sign(quantity))` |
| `original_unit_ref` | text | yes | `:token`, at most 128 bytes, `CHECK (original_unit_ref <> unit_ref)` |
| `original_scale` | smallint | yes | `CHECK (BETWEEN 0 AND 9)`; `CHECK (quantity_original = round(quantity_original, original_scale))` |
| `conversion_factor` | numeric(30,12) | yes | base units per ONE original unit; `CHECK (conversion_factor > 0)` |
| `conversion_basis` | text | yes | `CHECK (IN ('registered','command'))` |
| `rounding_mode` | text | yes | `CHECK (IN ('half_up','half_even','half_down','up','down'))` |
| `reference_quantity` | numeric(30,9) | yes | tolerance group: the expected magnitude in the base unit; `CHECK (reference_quantity > 0)` |
| `tolerance_abs` | numeric(30,9) | yes | the REGISTERED absolute tolerance in the base unit; `CHECK (tolerance_abs >= 0)` |
| `tolerance_state` | text | yes | `CHECK (IN ('within','excepted'))` |
| `exception_ref` | text | yes | token, at most 128 bytes, set iff `excepted` |

**Group CHECKs.** Conversion group (`quantity_original`, `original_unit_ref`, `original_scale`, `conversion_factor`, `conversion_basis`, `rounding_mode`) ALL NULL or ALL NOT NULL. Tolerance group
(`reference_quantity`, `tolerance_abs`, `tolerance_state`) ALL NULL or ALL NOT NULL; `exception_ref IS NOT NULL` iff `tolerance_state = 'excepted'`. Tolerance consistency in the database:
`CHECK (tolerance_state IS DISTINCT FROM 'within' OR abs(abs(quantity) - reference_quantity) <= tolerance_abs)` and the mirror `> tolerance_abs` for `'excepted'`.
**Mode-independent base-quantity tripwire (F9, SEC 7):** `CHECK (quantity_original IS NULL OR abs(abs(quantity_original) * conversion_factor - abs(quantity)) * power(10::numeric, quantity_scale::numeric) < 1)`
(**CDV 3: the scale factor is written as `power(10::numeric, quantity_scale::numeric)`, a NUMERIC positive power, and the inequality is `... * 10^scale < 1` instead of `... < 10^-scale`; the form `10 ^ (-quantity_scale)` with integer operands resolves to the double-precision `^` operator in Postgres and is NOT used**; Postgres `numeric` multiplication is exact; for every one of the five modes the rounded magnitude is within one unit in the last place of the exact product; it holds for reversals because both sides are negated).
Every text column carries the `octet_length` and control-character CHECKs of `gh2657...md` section 4. The CHECKs are a TRIPWIRE relative to the scales the row declares; the REGISTERED scales are enforced by C3/C6.

**NULL means "no conversion"**; readers use `COALESCE(quantity_original, quantity)` and `COALESCE(original_unit_ref, unit_ref)`.

**Entry digest.** The per-leg canonical form of `gh2657...md` 4.2 gains the new columns: a key-sorted JSON object per leg in `leg_no` order, every numeric as canonical text at its STORAGE scale (9 or 12), scales as integers,
absent as `null`. **The text is produced by the fixed plain-notation algorithm of `Quantity.to_wire`, never by `Jason` or `Decimal.to_string/1`** (E12: scientific by default), and a golden-vector test pins it.

**Registration in force (CDV 1, SEC 2).** `ledger_entry` gains `registration_hash text NOT NULL` (`CHECK (registration_hash ~ '^[0-9a-f]{64}$')`, the `ManifestHash` of the module at posting, copied by core from the registration; it is a digest input of `gh2657...md` 4.2). It identifies the registration (tolerance, rounding allowed, factor bounds, pack targets, required causes) that applied to every leg of the entry, so audit never has to guess.

**Reversal.** Copies each target leg: `quantity` negated, conversion group copied with `quantity_original` negated, **tolerance group NULL** (not a measurement, not re-evaluated). It does not recompute, so no rounding
runs; C11 and the tripwire hold because both sides are negated. **Reversal legs are verified in `:audit` mode (CDV 2):** a reversal copies the target's stored `quantity_scale` and `original_scale`, and scales may have
increased since, so the equality checks C3/C6 would wrongly refuse it; `:audit` keeps C1, C2, C4, C5, C9, C11 and the DB tripwire and exempts the registration-equality checks. The reversal's own `registration_hash` is that of
the reversal posting, the legs are copied from the target and not re-derived.

### 4.6 The item tolerance rule (decision D-Q5)

* **Meaning.** For a measured good the posting `quantity` IS the measurement. The tolerance compares its magnitude with a REFERENCE magnitude in the base unit: `deviation = abs(abs(base) - reference)`. Inside iff
  `deviation <= tolerance_abs` (inclusive), evaluated exactly on the carrier form.
* **Basis.** Absolute, in the base unit only. **Percent is NOT supported** in release 1 (ambiguous base; it is the procurement over/under-delivery tolerance of WM-01/WM-02, a different concept); `tolerance_pct` later is
  an additive nullable column plus a registration key.
* **Source of the value (SEC 1).** `tolerance_abs` comes from the REGISTRATION (`units[base].tolerance.abs`), never from the command, so a poster cannot enlarge it; the command carries only `reference_quantity` and an
  optional `tolerance_exception_ref`. A per-ITEM tolerance needs the master (L7); in L1-L4 it is per base unit. The group is **mandatory** for legs whose cause is in `required_for_causes` (a leg without a
  `reference_quantity` is `tolerance_input`); for other causes it is evaluated when a reference is sent.
* **Where evaluated.** In `declare/2` after rounding; re-validated by core B4 (C12) and the DB CHECKs.
* **Undefined cases, all specified (F5):** a `reference_quantity` for a unit with no registered tolerance: `tolerance_input` (never silently dropped); a missing reference where required: `tolerance_input`; a
  `tolerance_abs` key in the command: unknown key, refused by the closed shape; a `tolerance_exception_ref` on a leg that is WITHIN tolerance: `tolerance_input` (so the DB rule "`exception_ref` iff `excepted`" is
  never reached as a raw constraint failure); an exception reference on a leg with no tolerance group: `tolerance_input`.
* **Outside tolerance.** Without an exception reference: `invalid_posting` reason `out_of_tolerance` with `leg_no` only (the closed channel; `gh2657...md` 14.4 allows only `invalid_posting` from `declare/2`), released
  only to an authorised subject. BPM routes to an exception task (0057 kept boundary). With `tolerance_exception_ref`: the leg is `excepted`.
* **Exception legs need a distinct permission (SEC 1).** **Core DERIVES the counts `excepted_leg_count`, `tolerance_leg_count` (legs with a tolerance group) and `command_leg_count` (legs with `conversion_basis = command`) from the validated legs' own `tolerance_state` and `conversion_basis`, never from a number supplied by a policy (SEC 4a, CDV 8)** and stores them in the capability. **Core's authority step (step 2 of `gh2657...md` 7.1) additionally requires the registered
  `tolerance_exception` permission whenever the count is above zero; its absence is the uniform `write_not_permitted`, decided BEFORE any deferred refusal is released** (INV-5). Excepted and tolerance-checked legs are counted
  (numbers, no ids or values) in the `ledger.posted` audit entry (`excepted_leg_count` and `tolerance_leg_count`, A17), so an auditor sees how often the exception path is used against how often tolerance applied. The reference is still a token whose task is not verified in L1-L4 (verification needs the read facade, L7); the
  distinct permission, the audit count and the registration-supplied tolerance are the L1-L4 controls. Until L7 this is therefore a PARTIAL control, not full MD-07 enforcement (F12), and L7 gates the pilot (`gh2657...md` 17, confirmed: nothing here relaxes that gate). **Stated plainly (SEC 3): `reference_quantity` is SELF-ATTESTED by the poster in L1-L4.** A poster can send a reference equal to the measured quantity and pass the tolerance. The controls (registration-supplied tolerance, mandatory evaluation for named causes, the exception permission, the audit counts) therefore detect ERROR, not malice; they become a real control only when L7 reads the reference quantity from the document line (the purchase or request line) SERVER-SIDE, so that the poster no longer supplies it.
* **Permission classification and role exclusion (SEC 4b, 4c).** `tolerance_exception` and `convert_command` are TENANT-scope permissions (INV-10: not platform authority) declared in the module manifest, so
  adding them changes the permission-matrix golden (`priv/permission_matrix/effective.golden`) and the golden `modules` assertion in the same PR. The `TENANT_AUDITOR`/`CANDIDATE` exclusion of rule 12 is a REGISTRATION-time
  check only, and tenant role-grant edits (REQ-517/518, org-scoped role grants) could add such a grant later. It is therefore ALSO enforced at the EVALUATION point: core's authority step (7.1 step 2) never lets the effective
  roles `TENANT_AUDITOR` or `CANDIDATE` satisfy `post`, `reverse`, `tolerance_exception` or `convert_command`, whatever the grants say (A31).
* **Tolerance and cause rules.** Irrelevant to `zero_sum` balancing (base quantities).

### 4.7 MD-07 measurement evidence (decision D-Q6)

| MD-07 element | Where |
|---|---|
| actual measured length/weight | `quantity_original` + `original_unit_ref` |
| precision | unit `scale` (4.1) |
| tolerance | 4.6 |
| unit conversion | 4.4 |
| posted base-unit quantity | `quantity` + `unit_ref` |
| reconcile measure to posting | the triple plus `reconcile`'s `conversion_check` (4.9) |
| out-of-tolerance requires an exception | `out_of_tolerance` + `exception_ref` + the exception permission |
| scale / measurement evidence | reserved `attrs` key `measurement_ref` (token, at most 128 bytes: weighing ticket, scale or tape id) at receipt and issue; the artefact is an attachment on the receipt document (WM-02); truck scales are release 2 (draft :13) |

Out of this slice: instrument registry, calibration, automatic scale readings.

### 4.8 Wire format of quantities, reads and reports (decision D-Q7)

* **Posting command.** `gh2657...md` 9.1 describes the core-level leg (`k`, `quantity`, `unit_ref`, `attrs`, `document_line_id`) and `posting_command` is MODULE-level and opaque to core
  (14.1: `%{required(:client_op_id) => String.t(), optional(atom()) => term()}`). Choice (F3): **the quantity keys of the command are the stock module's names and core never sees them**; core validates only
  `declare/2`'s OUTPUT (the declared leg with `unit_ref` = the base unit and the REQ-504 keys). The module's leg keys: `quantity` (string or integer, signed, in `unit`), `unit`, `base_unit`, `conversion_factor`
  (optional), `rounding_mode` (optional, only if the registration allows), `reference_quantity`, `tolerance_exception_ref`, `measurement_ref`.
* **`payload_hash` (F3).** The reduced-form canonicalisation of revision 1 is DROPPED: core cannot know which command fields are decimals. `payload_hash` stays the hash of the canonical key-sorted JSON of the
  validated command as the ledger defines it (`gh2657...md` 9.2), strings as sent. A client that re-sends a differently padded spelling (`"2.5"` vs `"2.50"`) gets `idempotency_key_reuse`, a safe failure;
  retries resend the stored command bytes.
* **Read and report maps.** Every quantity is a STRING: `quantity` at `quantity_scale`, `quantity_original` at `original_scale`, `reference_quantity`/`tolerance_abs` at `quantity_scale`, `conversion_factor` in
  reduced plain notation (never scientific), balances and sums at the unit's CURRENT registered scale. Rendering is `Quantity.to_wire` (total, 4.4), consistent with `Decimals.render_value/2`.
  **No implicit `Jason` encoding of a `Decimal` in a read map** (E12). **No `%Decimal{}` and no quantity value appears in error `details`, telemetry, logs or audit payloads** (SEC 9): they carry ids, counts and
  closed reason atoms only.
* **Sums.** Ledger reads sum in SQL (`numeric`, exact). Elixir-side sums use `Quantity.sum/1` (integer arithmetic on carrier forms). A report never totals across `unit_ref`s; it groups by unit.
* **Entity-side aggregates** go through the strict path: `sum`/`min`/`max` padded to the field scale (9), `avg` unpadded (E9).
* **Export (SEC 8).** JSON export of strict fields is a string (E10). In ledger CSV/XLSX export the neutralisation exemption (A11) is by **column TYPE**: only typed numeric columns the exporter itself renders from
  `Quantity.to_wire` are exempt (a leading `-` is a negative quantity); the exporter never decides by sniffing cell content. Any content-based test uses a full-string, ASCII-only match with `\A...\z` (not `$`,
  which matches before a trailing newline). `exception_ref`, `measurement_ref` and every unit-ref column are ALWAYS neutralised.
* **Round trip.** Entity quantity `"2.500"` is stored, returned by get/query/export/ScriptReads as `"2.500"` (E4, E10); a ledger leg from `253` cm reads back `quantity "2.530"`, `quantity_original "253"`,
  `original_unit_ref "cm"`; a DIRECT leg reads back the coalesced pair (original = base).

### 4.9 Interfaces (types and signatures only)

New pure core module `Letflow.Ledger.Quantity` (under `lib/letflow/ledger/`, covered by Rule 7), reached by module code only through `Letflow.Ledger.Policy` delegates.

```
@type rounding_mode :: :half_up | :half_even | :half_down | :up | :down
@type parse_error :: :type | :scale | :precision                      # the ONE parser error shape
@type reason :: :type | :scale | :precision | :decimal_shape | :unit_unknown | :unit_pair | :scale_mismatch
              | :factor_missing | :factor_unexpected | :factor_mismatch | :factor_range | :rounding_mode
              | :rounds_to_zero | :quantity_zero | :out_of_tolerance | :tolerance_input
              | :tolerance_inconsistent | :conversion_inconsistent
@type quantity_group :: %{quantity_scale: 0..9,
                          quantity_original: Decimal.t() | nil, original_unit_ref: String.t() | nil, original_scale: 0..9 | nil,
                          conversion_factor: Decimal.t() | nil, conversion_basis: :registered | :command | nil, rounding_mode: rounding_mode() | nil,
                          reference_quantity: Decimal.t() | nil, tolerance_abs: Decimal.t() | nil,
                          tolerance_state: :within | :excepted | nil, exception_ref: String.t() | nil}

# Letflow.Ledger.Policy (policy-file facing; replaces/extends gh2657 14.4)
@spec decimal(term(), scale :: 0..12, int_digits :: 1..21) :: {:ok, Decimal.t()} | {:error, parse_error()}     # THE parser; 64-byte / bignum-compare pre-checks, then Decimals.parse/3 with precision = int_digits + scale
@spec rounding_mode(requested :: term() | nil, rounding :: map(), unit_entry :: map()) :: {:ok, rounding_mode()} | {:error, :rounding_mode}
@spec convert(original :: Decimal.t(), factor :: Decimal.t(), target_scale :: 0..9, rounding_mode()) :: {:ok, Decimal.t()} | {:error, :decimal_shape | :factor_range | :rounds_to_zero | :precision}
@spec within_tolerance?(base :: Decimal.t(), reference :: Decimal.t(), tolerance_abs :: Decimal.t()) :: boolean()   # inclusive; shape-checked
@spec sum([Decimal.t()]) :: Decimal.t()
@spec to_wire(Decimal.t(), scale :: 0..12 | :reduced) :: String.t()                                              # total, never scientific, never raises
@spec leg(%{k: [String.t()], quantity: Decimal.t(), unit_ref: String.t(), optional(atom()) => term()}) :: declared_leg()   # constructor; KEPT keys = the declared_leg keys UNION the quantity_group keys; all other keys dropped

# Letflow.Ledger.Quantity (core only)
@spec verify_leg(declared_leg(), registration :: map(), mode :: :post | :audit) :: :ok | {:error, reason()}       # checks C1-C12 of 4.4
@spec within_scale?(Decimal.t(), scale :: 0..9) :: boolean()
```

**Mapping of every `Quantity`/`Policy` error to the `invalid_posting` reason** (the details stay `{leg_no, reason}` only; the reason enum of `gh2657...md` 12.2 is "closed" but not enumerated there, so this note
enumerates the REQ-504 part; if the ledger's own enum already uses `type`/`scale`/`precision` the same atoms are reused, A7):

| Source | Error | Reason |
|---|---|---|
| `Policy.decimal` | `:type` / `:scale` / `:precision` | same atom |
| any `Quantity` function given a bad Decimal | `:decimal_shape` | `decimal_shape` |
| `Policy.rounding_mode` | `:rounding_mode` | `rounding_mode` |
| `Policy.convert` | `:factor_range` / `:rounds_to_zero` / `:precision` | same atom |
| `declare/2` step 1 | zero entered | `quantity_zero` (NOT `rounds_to_zero`, which exists only after a conversion) |
| `declare/2` step 2 | factor or mode supplied on a same-unit leg | `factor_unexpected` |
| `declare/2` step 3 | factor absent / unregistered pair / registered mismatch / out of `[min,max]` | `factor_missing` / `unit_pair` / `factor_mismatch` / `factor_range` |
| `declare/2`, tolerance | reference/exception cases of 4.6 | `tolerance_input`; outside tolerance `out_of_tolerance` |
| `verify_leg` | C1-C12 | `decimal_shape`, `unit_unknown`, `scale_mismatch`, `scale`, `quantity_zero`, `conversion_inconsistent`, `factor_mismatch`, `unit_pair`, `factor_range`, `rounding_mode`, `tolerance_inconsistent`, `tolerance_input` |

`declared_leg` (`gh2657...md` 14.1) gains the typed optional keys of `quantity_group`. The capability carries `excepted_leg_count`, `tolerance_leg_count` and `command_leg_count :: non_neg_integer()`, all DERIVED BY CORE from the validated legs' own `tolerance_state`, tolerance group and `conversion_basis`, never supplied by a policy. `reconcile` gains two results:
`conversion_check :: :ok | {:inconsistent_at, pos_integer()}` (the first `posting_seq` whose leg fails `verify_leg(_, _, :audit)` or the tripwire relation) and
`factor_drift :: [%{key: [String.t()], original_unit_ref: String.t(), factors: [String.t()]}]` (balance keys with MORE THAN ONE distinct `command` factor for the same original and base unit; informational, not a
failure; chunked like the other checks, `gh2657...md` 11.2).

## 5. Worked examples (the numbers the tests use)

Test registration: units `m` scale 3 / length with `tolerance abs "0.05"` required for the cause `receipt`; `cm` 1, `mm` 1 / length; `kg` 3, `g` 0 / mass; `ea` 0 / count; `box` 0 / pack (`factor_min "1"`,
`factor_max "1000"`). Registered `cm -> m 0.01`, `mm -> m 0.001`, `g -> kg 0.001`. `rounding.allowed` has all five modes (config flag, test only).

| Case | Input leg | Result |
|---|---|---|
| E0 **literal AC: entered in the BASE unit** | base `m`, unit `m`, `2.5`, reference `2.5` | direct leg: `quantity "2.500"`, conversion group NULL, `tolerance_abs "0.050"`, `within`; read-back coalesces `quantity_original "2.500"`, `original_unit_ref "m"` |
| E1 cable, nominal | base `m`, `250` cm, reference `2.5` | `0.01` registered; `quantity "2.500"`, original `250` cm, `within` |
| E2 measured | `253` cm | `quantity "2.530"`, deviation 0.030 <= 0.05, `within` |
| E3 boundary | `255` cm and `245` cm | deviation exactly 0.050: accepted |
| E4 outside | `256` cm | deviation 0.060: `out_of_tolerance`; with `tolerance_exception_ref "t-7"` and the exception permission: `excepted`; WITHOUT the permission: `write_not_permitted` |
| E5 two rounding rules | `2.5` mm to `m`, product exactly `0.0025`, scale 3 | `half_up` `0.003`, `half_even` `0.002`, `half_down` `0.002`, `up` `0.003`, `down` `0.002`; `-2.5` gives the negatives |
| E6 rounds to zero | `0.4` mm, `half_up` | product `0.0004` -> `0.000`: `rounds_to_zero` |
| E7 packaging | base `ea`, `3` box, factor `12` | `quantity "36"`, basis `command`; factor `0` or `5000` -> `factor_range`; `2.5` box -> `scale`; kg -> `ea` by command factor -> `unit_pair` |
| E8 factor digits | on a pack unit with `factor_min "1"`: `1.000000000001` (12 fractional) vs `1.0000000000001` (13) | accepted vs `scale` (the value `0.000000000001` would be `factor_range`, below `factor_min`) |
| E9 JSON number | `quantity: 2.5` vs `"2.5"` vs `3` | refused `type` vs accepted vs accepted |
| E10 registered mismatch | cm -> m with factor `0.1` | `factor_mismatch` |
| E11 exception on a within leg | `253` cm with `tolerance_exception_ref` | `tolerance_input` |

## 6. Test plan (ExUnit; StreamData properties, E15)

The pure quantity module needs no database. New files; `async: false` where they touch the database.

| Id | File | Case |
|---|---|---|
| T-Q1 | `ledger/quantity_grammar_test.exs` | grammar table of section 2 for quantity, factor, reference; JSON `2.5` refused `type`, `"2.5"` and `3` accepted, `3.0` refused; `"1e1000000"`, `"1E5"`, `"0x10"`, Arabic-Indic digits, `" 1"`, `"+1"`, `"NaN"` refused; **a 10 MB binary and a 5000-bit integer are rejected with a bounded REDUCTIONS count** (`:erlang.process_info(self(), :reductions)` delta below a fixed constant) and the 64-byte / bignum-compare pre-checks are shown to fire BEFORE `Decimals.parse/3` (the harness calls `Quantity.decimal/3` with a parse-spy: a module attribute-free check that the result is `{:error, ...}` and that a process trace on `Decimals.parse/3` records no call); no wall-clock budget |
| T-Q2 | same | **factor with more digits than its scale**: on a pack unit with `factor_min "1"`: `1.000000000001` (12 fractional) accepted, `1.0000000000001` (13) refused `scale`, 19 integer digits refused `precision`, `0.5` refused `factor_range` (below `factor_min`), `1001` refused `factor_range` (above `factor_max`), and on the PARSER alone (no unit) `0.000000000001` accepted, `"0"` and `"-1"` refused `factor_range`; the asserted choice is #2654's (refuse, never round: `decimals.ex:162`) |
| T-Q2b | same | shape pre-check: a hand-built `%Decimal{}` with `exp: 1_000_000_000`, a 10 MB coefficient, `coef: :NaN`, `:inf`, a negative `exp` below -12, `exp: 22` with a one-digit coefficient is `decimal_shape`, while `1E+3` (coef 1, exp 3) is ACCEPTED and expanded (`digits(coef) + exp <= 21`), all `decimal_shape` rejections from `convert/4`, `within_tolerance?/3`, `verify_leg/3` and `to_wire/2`, with a reductions bound and no multiplication reached |
| T-Q3 | `ledger/quantity_round_test.exs` | E5 for all five modes, positive and negative, against section 5 AND against `Decimal.round/3` as oracle (**the oracle value is computed OUTSIDE the reduced context; only the `Quantity` call runs inside it**, CDV 6); ties, non-ties, exact products, rounds-to-zero |
| T-Q4 | `ledger/quantity_property_test.exs` | (P1) `to_wire`/`decimal` round trip within caps; (P2) rounding bounds: half modes `abs(round(x) - x) <= 0.5 ulp`, `up`/`down` `< 1 ulp`, `down <= abs(x) <= up`; (P3) equals `Decimal.round/3` for all five modes on values of at most 34 digits; (P4) sign symmetry; (P5) rounding once: single-step within the P2 bound, and the EXACT product is associative `(q x f1) x f2 == q x (f1 x f2)` (why chains with intermediate rounding are not allowed); (P6) `sum` of N random legs equals the integer sum, order-independent, 10 x `0.1` is `1.0`; (P7) `verify_leg` accepts every output of `convert` and rejects a one-ulp perturbation. **Every property of T-Q3 and T-Q4 runs a second time with ONLY the `Quantity` call inside `Decimal.Context.with(%Decimal.Context{precision: 5, rounding: :down}, fn -> ... end)`; the `Decimal.round/3` oracle and the expected values are computed outside it; the results must be IDENTICAL** (this detects ANY dependence on the ambient context, which a "context unchanged" assertion cannot) |
| T-Q5 | `ledger/conversion_policy_test.exs` | `declare/2` of the stock test policy: E0-E11; zero queries (telemetry); the same outputs under the reduced context of T-Q4 |
| T-Q6 | `ledger/quantity_posting_test.exs` | **E0 and E1 through `Ledger.post/1`** with the test registration: E0 stores `quantity 2.500`, `unit_ref m`, NULL conversion group, `reference_quantity 2.5`, `tolerance_abs 0.05`, `tolerance_state within`, and `entries/3` returns `quantity_original "2.500"` (coalesced) and `reference_quantity`/`tolerance_abs` strings; E1 stores the full triple (`250` cm, `0.01`, `registered`) and the balance is `"2.500"`. **The same posting under two rounding rules** (E5): `half_up` posts `0.003`, `half_even` `0.002`, both rows with their `rounding_mode`, the balances differ; run through ONE test registration with `allowed` = both modes (config flag) AND, separately, two registrations each with a single allowed mode |
| T-Q7 | same | outside tolerance for an authorised subject is 422 `invalid_posting {leg_no, out_of_tolerance}` with nothing written and the counter unchanged; boundary inclusive; E11 `tolerance_input`; a within leg with a DB-level violation (raw SQL in a throwaway tenant) fails the CHECK |
| T-Q7b | `ledger/tolerance_authority_test.exs` | a subject WITHOUT the `tolerance_exception` permission posting an excepted leg gets the byte-identical `write_not_permitted` (and the same database round-trip count) as for a subject without `post`; the same subject posting a valid non-excepted leg succeeds; with the permission the leg posts and `ledger.posted` carries `excepted_leg_count`; an UNAUTHORISED subject sending any new `invalid_posting` reason (`out_of_tolerance`, `factor_range`, ...) gets the same uniform body; the permission is checked BEFORE the deferred refusal is released; `tolerance_required_for_causes`: a `receipt` leg without a reference is `tolerance_input` |
| T-Q8 | `ledger/quantity_core_check_test.exs` | for EACH check C1-C12 a hand-built declared leg that violates only that check is refused with the listed reason by `verify_leg(_, registration, :post)`: wrong `quantity_scale` for the unit, wrong `original_scale`, unknown `original_unit_ref`, `registered` with a wrong factor, `command` on a non-pack unit, factor out of `[min,max]`, mode not in `allowed`, `tolerance_abs` different from the registered one, `within` claimed outside tolerance, `excepted` without `exception_ref`, tolerance group missing for a required cause; `:audit` mode accepts a scale lower than the current registered one; **audit-mode cases (CDV 1): post a converted leg, then change EACH of `tolerance.abs`, `rounding.allowed`, `factor_min`/`factor_max`, `required_for_causes`, `pack_targets` and add a new registered pair that covers a past `command` pair, install the new registration, run `reconcile`: `conversion_check` stays `:ok` every time**; a leg whose own stored values disagree (C5, C9, C11, the tripwire) is still reported; AND a raw-SQL row violating each DB CHECK of 4.5 (scale, sign agreement, group all-or-none, mode set, basis set, factor positive, exception iff excepted, the tripwire) in a throwaway tenant |
| T-Q9 | `ledger/quantity_reversal_test.exs` | a reversal of a converted leg negates `quantity` and `quantity_original`, copies factor/mode/basis/scales, NULL tolerance group; `conversion_check` stays `:ok`; equals the exact negation under every mode (property); **reverse a converted leg AFTER a scale increase of its unit** (the stored `quantity_scale` is below the registered one): the reversal posts (verified in `:audit` mode, CDV 2) and `conversion_check` stays `:ok` |
| T-Q10 | `ledger/quantity_transfer_test.exs` | a `zero_sum_by_slot_1` transfer whose legs are entered in different units and convert to base quantities differing by the rounding residual is refused `posting_not_balanced`; the same transfer in one unit balances |
| T-Q11 | `ledger/quantity_sum_test.exs` | 1,000 random legs of scale 3: `balances/5`, `reconcile/2` and the cut-off report equal the integer sum; no `E` in any rendered string; a `Decimal` with a positive exponent (`1E+3`) is rendered `"1000"` |
| T-Q12 | `entities/quantity_fields_roundtrip_test.exs` | entity line with `decimal_strict` 30/9: `"2.500"` through `HandlerWrites.create/3`, HTTP get, query (`gt "2.4999"`, `in`), JSON export, ScriptReads, `Latest.get/3` + `Decimals.to_decimal/1`: identical strings; ten `"0.100"` aggregate `sum "1.000000000"`, `avg` unpadded; a float body is 422 `type`; a non-strict twin unchanged. **Only the field-level scale 9 is asserted; per-unit scale is a posting-time rule (4.1) and is tested in T-Q5/T-Q8** |
| T-Q13 | `ledger/registration_units_test.exs` | rule 12: scale outside 0..9; a scale decrease; a REMOVED unit; a changed dimension; a changed or removed registered factor; a pair across dimensions; a duplicate pair; both directions whose product is not 1; a default mode outside `allowed`; `allowed` with two modes without the config flag; a pack unit without `factor_min`/`factor_max` or without `pack_targets`; **a registration with a pack unit and `convert_command` nil, or equal to `post`/`reverse`/`tolerance_exception`, or granted to `TENANT_AUDITOR`/`CANDIDATE`**; `units[*].rounding_mode` not in `rounding.allowed`; **a widening (larger `tolerance.abs`, larger `factor_max`, smaller `factor_min`, an added allowed mode or pack target) without a `version` bump is refused and accepted with one**; a narrowing accepted; `tolerance.abs` with more digits than the unit scale; `tolerance_exception` equal to `post` or granted to `TENANT_AUDITOR`/`CANDIDATE`; a unit key outside the token charset: each refused; a unit addition, a scale increase and a new pair accepted |
| T-Q14 | `ledger/export_neutralisation_test.exs` (L4) | typed numeric columns keep a leading `-`; vectors `-1+1`, `-1\n`, `-1\n+1`, `-1e3`, `- 1` in a TEXT column (`exception_ref`, `measurement_ref`, a unit ref) are neutralised; the exemption is decided by column type (a text column holding `-1` is neutralised); the exporter's full-string check uses `\A...\z` |
| T-Q15 | `support/tenant_template_ledger_test.exs` | in a CLONED tenant schema (`LIKE ... INCLUDING ALL`) INSERT a violating row for each CHECK of 4.5 (including the tripwire) and assert the constraint error: the CHECKs survive the clone; **the tripwire is also exercised at `quantity_scale` 9 (`quantity_original 1.000000001`, factor `1`, `quantity 1.000000001` passes; a magnitude one unit in the 9th place off fails) with an exactness assertion that no double-precision operator is involved (the expression text contains `power(10::numeric` and no `^`)** (CDV 3) |
| T-Q16 | `entities/ledger_policy_scan_test.exs` | the policy-file scan (A15) flags `Decimal.new/1`, `Decimal.parse`, `Decimal.cast`, `Decimal.mult`, `Decimal.div`, `Decimal.add`, `Decimal.sub`, `Decimal.round`, `Decimal.to_integer`, `Decimal.to_string`, `Decimal.from_float`, `Decimal.negate`, `Decimal.abs`, `Decimal.normalize` in a synthetic policy file and passes `Decimal.t()` type references, `Decimal.compare/2` and `is_decimal` guards; extends T-PL-1 |
| T-Q17 | `ledger/command_factor_drift_test.exs` | two `command` postings with different factors for one (original, base, key) appear in `factor_drift`; a stock registration always declares `convert_command` (rule 12 requires it for pack units) and refuses a `command` leg for a subject without that permission with the uniform body; **a box -> kg command factor is refused `unit_pair` (`pack_targets` is `["count"]`), box -> `ea` accepted**; `command_leg_count` in the capability equals the number of `command` legs, derived by core even when a hostile policy returns a different number |
| T-Q18 | `ledger/digest_golden_test.exs` | a golden vector for the per-leg canonical text with every new column (and `null`s) fixes the digest algorithm independent of `Jason`/`Decimal.to_string` |

Generators draw coefficients and exponents within the caps of 4.2 only; the oracle properties bound the digit count to 34 because `Decimal.round/3` itself rounds to its context (E12).

## 7. Security (INV map)

* **Untrusted inputs (INV-4/5/7/8).** Unit strings (token, `units` allowlist), factor (caps, positivity, registered equality or `[factor_min, factor_max]`), rounding mode (registration only), reference, `exception_ref` and
  `measurement_ref` (token, 128 bytes) are hostile. The tolerance VALUE and the rounding MODE are no longer client inputs (SEC 1, 2). Nothing is interpolated into SQL (INV-7): numerics are bound `Decimal` parameters.
* **Decimal DoS.** 4.2: byte length before regex; bignum compare before any size computation; no exponent in the grammar; `Quantity.decimal/3` rejects before `Decimals.parse/3`; carrier shape pre-check on every
  Decimal from a module or the database; 60-digit product bound; the policy scan bans raw `Decimal` construction and arithmetic in policy files (A15), so a policy cannot feed `1e1000000` to `Decimal.new/1` or
  `Decimal.parse/2`, skipping the pre-checks.
* **Authority (INV-5).** Every REQ-504 refusal is a build-time `invalid_posting`, released only after the authority check (`gh2657...md` 7.1). **Excepted legs additionally require the `tolerance_exception`
  permission in the same authority step**; a `command`-basis leg requires `convert_command`, which rule 12 makes mandatory for any registration with a pack unit. An unauthorised subject gets the byte-identical `write_not_permitted` and cannot probe the
  unit table, registered factors, `factor_min`/`factor_max` or tolerance from error bodies; T-Q7b compares bodies and DB round-trip counts.
* **INV-2.** Read maps are allowlisted; `exception_ref`, `measurement_ref`, `conversion_basis` and `factor_drift` are included only for a subject holding the registration's `read` (or `reconcile`) permission.
* **INV-8.** Quantity functions are total; refusal by return value; a raise inside `declare/2` is the existing closed build failure.
* **Integrity.** The triple is covered by `entry_digest`; core recomputes it at B4 and `reconcile`; DB CHECKs and the mode-independent tripwire reject violating rows even after a core bug.
* **Audit/telemetry (SEC 9).** `ledger.posted` carries `excepted_leg_count` and `tolerance_leg_count` (numbers); no `%Decimal{}` or quantity in `details`, telemetry, logs or audit (T-ERR-3 of the ledger note extended).
* **Trust statement.** In L1-L4 the stored `command` factor, `exception_ref` and the reference quantity remain client evidence: bounded (`factor_min/max`), gated (permissions), counted (audit) and reported
  (`factor_drift`), not verified. The base quantity is authoritative for the balance once posted. L7 (which gates the pilot) replaces this with master reads. Whether the factor can come from a variable the completer
  cannot overwrite (`script_reads.ex:102, 296-308`) is NOT VERIFIED (N6).

## 8. Amendments to the #2657 note, revision 5 (complete list; this note does not edit that file)

| # | Where in `gh2657...md` | Change |
|---|---|---|
| A1 | 4.3 table, row "(REQ-504 columns)" | replace by the 13 rows of 4.5 of this note and the CHECK list (incl. `round(quantity, quantity_scale)`, sign agreement, group all-or-none, tolerance consistency, the mode-independent tripwire) |
| A2 | 4.5 bullet "REQ-504 (#2660)" | keep `quantity_original`, `original_unit_ref`, `conversion_factor` (now `numeric(30,12)`); drop "a tolerance-evidence reference"; add `original_scale`, `conversion_basis`, `rounding_mode`, `quantity_scale`, `reference_quantity`, `tolerance_abs`, `tolerance_state`, `exception_ref`; the conversion is computed by `declare/2` AND re-verified by core B4 against the REGISTRATION |
| A3 | 4.2 `entry_digest`, 5.1 | per-leg canonical form includes every new column (key-sorted JSON, `null` absent, storage-scale canonical text built by the fixed `Quantity.to_wire` algorithm, never `Jason`/`Decimal.to_string/1`); golden vector test |
| A4 | 4.4, 4.1 `unit_ref` | `unit_ref` stays pinned per balance key; the unit's SCALE comes from the registration `units` table (increase-only) and is copied to each leg as `quantity_scale` |
| A5 | 14.4 `Letflow.Ledger.Policy` | `decimal/2` (`{:error, :invalid}`) is REPLACED by `decimal(term, scale 0..12, int_digits 1..21)` returning `{:error, :type \| :scale \| :precision}`, the only parser; add `rounding_mode/3`, `convert/4`, `within_tolerance?/3`, `sum/1`, `to_wire/2`; `leg/1` KEEPS the declared_leg keys and the `quantity_group` keys, dropping all others (`uuid/1`, `token/2` unchanged) |
| A6 | 14.1 `declared_leg`, `reconciliation` | typed optional keys of `quantity_group` instead of `optional(atom()) => term()`; `reconciliation` gains `conversion_check` and `factor_drift` |
| A7 | 7.1 B4, 12.2 `invalid_posting` | B4 runs `Quantity.verify_leg(leg, registration, :post)` (checks C1-C12 of this note's 4.4) after the shape pre-check; the closed `reason` enum gains the REQ-504 atoms listed in 4.9 (reuse `type`/`scale`/`precision` if the ledger enum already has them); out-of-tolerance is a reason of `invalid_posting`, not a new core code |
| A8 | 9.1, 9.2 | the core leg of 9.1 is the declared leg; the module-level command keys are the module's (4.8); **`payload_hash` canonicalisation is NOT extended with decimal reduction** (a differently padded re-send is `idempotency_key_reuse`) |
| A9 | 10 Reversal | copy rule of 4.5 (negate `quantity_original`, copy factor/mode/basis/scales, tolerance group NULL) |
| A10 | 14.3 rule 12 | `units` map (replaces the optional allowlist) with `scale`, `dimension`, optional `rounding_mode`, `factor_min`/`factor_max`, `tolerance`; `conversions`; `rounding %{default, allowed}`; all checks of 4.1 |
| A11 | 16.3 CSV/XLSX neutralisation | exemption by column TYPE for exporter-rendered numeric columns only, full-string `\A...\z` ASCII match if content is ever tested; `exception_ref`, `measurement_ref`, unit-ref columns always neutralised |
| A12 | 13 test plan | add T-Q1..T-Q18 by reference; T-PL-1 gains "`declare/2` output identical under a reduced `Decimal.Context`" |
| A13 | 17 slicing, 20 OQ-10 | L1 includes the A1 columns/CHECKs and depends on this note being accepted; OQ-10 CLOSED (`numeric(30,9)`, factor `numeric(30,12)`); the stock module's starter unit table of 4.1 is normative for L4 |
| A14 14.3 permissions | registration `permissions` gains `tolerance_exception :: atom()` (required, distinct from `post`/`reverse`/`convert_command`, not grantable to `TENANT_AUDITOR`/`CANDIDATE`) and `convert_command :: atom()` (non-nil whenever any unit has dimension `pack`) |
| A15 | 14.4 policy allowlist | `Decimal` is NARROWED: policy files may reference only `Decimal.t()` types, `Decimal.compare/2` and the `is_decimal` guard; banned: `Decimal.new`, `parse`, `cast`, `mult`, `div`, `add`, `sub`, `round`, `to_integer`, `to_string`, `from_float`, `negate`, `abs`, `normalize`; negative scan test T-Q16; T-PL-1 extended |
| A16 | 7.1 step 2 (authority) | when the capability's `excepted_leg_count > 0` the subject must hold `tolerance_exception`; when `command_leg_count > 0` the subject must hold `convert_command` (required by rule 12 for any registration with a pack unit); the counts are DERIVED by core from the legs, never supplied by a policy; either failure is the uniform `write_not_permitted` before any deferred refusal |
| A17 | 7.7 audit entry | `ledger.posted` carries `excepted_leg_count` and `tolerance_leg_count` (numbers only) |
| A18 | 14.3 rule 12 | `rounding.allowed` has exactly one entry unless config flag `:ledger_allow_multiple_rounding_modes` (dev/test only); `units`: unit set only grows, `dimension` and registered factors immutable, scale increase-only; pack units need `factor_min`/`factor_max`, `pack_targets` and a non-nil `convert_command`; `units[*].rounding_mode` in `rounding.allowed`; both-direction product 1; no widening of tolerance, factor bounds, allowed modes or pack targets without a manifest `version` bump |
| A19 | 14.3 causes / 14.1 types | `units[u].tolerance.required_for_causes` names registered causes; capability type gains `excepted_leg_count`, `tolerance_leg_count`, `command_leg_count` (core-derived) |
| A20 | 11.2 `reconcile/3`, result type | `conversion_check` runs `verify_leg(_, _, :audit)` and the tripwire relation per leg; `factor_drift` reports keys with more than one distinct `command` factor |
| A21 | 14.4 / 12.3 / 16.3 | no `%Decimal{}` or quantity value in error `details`, telemetry, logs or audit payloads; `details` stay ids, counts and closed reason atoms |
| A22 | 16.2 / 16.5 | checklist Q1-Q4 of section 10 appended to the per-slice SECURITY checklist |
| A23 | 4.2 text hygiene | `exception_ref`/`original_unit_ref` use the `:token` CHECKs; no free text in any REQ-504 column |
| A24 | 3.5 Rule 7 | new core words (`quantity`, `unit`, `scale`, `conversion`, `rounding`, `tolerance`, `dimension`, `pack`) are NOT denylisted; the registration values `"pack"`/`"count"` are data, not core vocabulary; the denylist is unchanged |
| A25 | T-ERR-1..5 / T-SEC-1 | the new `invalid_posting` reasons and the exception/command-factor permission denials are included in the byte-identity matrix for unauthorised subjects |
| A26 | 4.2 `ledger_entry` columns, digest | add `registration_hash text NOT NULL` (`CHECK ~ '^[0-9a-f]{64}$'`, the `ManifestHash` in force, copied by core) as an immutable header column and a digest input |
| A27 | 7.1 B4 / 11.2 | `verify_leg` has two modes: `:post` (B4, against the registration in force) and `:audit` (`reconcile` and reversal legs: the row's own values plus scale `<=`; no re-test of tolerance, allowed modes, factor bounds, required causes, pack targets, basis derivation); table in 4.4 |
| A28 | 10 Reversal, 7.1 step 4 | reversal legs are verified in `:audit` mode (they copy the stored scales, which may be below the registered ones after an increase) |
| A29 | 14.3 rule 12 | `pack_targets` on pack units; C8 and `declare/2` check the base unit's dimension against it |
| A30 | 14.3 rule 12 | `convert_command` is REQUIRED (non-nil, distinct from `post`, `reverse`, `tolerance_exception`) whenever any unit has dimension `pack`; the `TENANT_AUDITOR`/`CANDIDATE` grant exclusion extends to it; no widening without a version bump |
| A31 | 7.1 step 2 / 16.2 | core's authority step never lets the effective roles `TENANT_AUDITOR` or `CANDIDATE` satisfy `post`, `reverse`, `tolerance_exception` or `convert_command` at evaluation time, in addition to the registration-time exclusion (tenant role-grant edits, REQ-517/518, cannot bypass it) |
| A32 | 14.3 permissions, permission matrix | `tolerance_exception` and `convert_command` are TENANT-scope (INV-10) manifest permissions; the permission-matrix golden (`priv/permission_matrix/effective.golden`) and the golden `modules` assertion are updated in the same PR; SECURITY-REVIEWER trigger |
| A33 | 4.5 Postgres CHECK text | the base-quantity tripwire uses `power(10::numeric, quantity_scale::numeric)` and `... * power(...) < 1`; never the `^` operator on integer operands |

## 9. Effect on #2658 and on the masters

* **#2658.** No dimension slot for quantity; the alternate-unit column of 0057 G3 is satisfied by the triple (`original_unit_ref`), so #2658 must NOT add an alternate-unit slot. A serial-tracked item has base unit
  `ea` (scale 0) so `key_bounds` `max_on_hand: "1"` is an integer in the base unit. Serial-tracked goods stay out of the pilot anyway (`gh2657...md` 17).
* **#2663 / #2664.** No edit by this note. Proposed FOLLOW-UP requirement (supervisor to file): `catalog_uom.decimal_scale` (integer 0..9), `catalog_uom.dimension`, a managed type `catalog_item_uom` (`factor` decimal
  strict 30/12 with `min "0.000000000001"` because bounds are inclusive, E6, `active`), `catalog_item.rounding_mode`, `catalog_item.tolerance_abs` (strict 30/9, non-negative), `item_uom_valid?` beyond the base unit
  (#2664 allows only the base unit). L7 then replaces the static table by master reads in the pre-validation step (never in `declare/2`).
* **0057 D4 / 0060.** D4 is implemented, not amended.

## 10. Implementation slicing, per-slice SECURITY checklist, and what is out

| Slice | Content | Size | Depends on |
|---|---|---|---|
| Q0 | decision record (proposed 0063; 0062 is the ledger record proposed in #2657; recheck at write time) with R1-R9, D-Q1..D-Q8 and practice citations (docs only) | S | this note accepted |
| Q1 | `Letflow.Ledger.Quantity` pure module and T-Q1..T-Q4, T-Q2b, T-Q16. **No database; can start immediately** | M | Q0 |
| Q2 | the A1 columns/CHECKs inside the ledger L1 migration, digest change, T-Q8 (DB part), T-Q15, T-Q18 | M | #2657 accepted with A1-A4; Q1 |
| Q3 | `Policy` delegates, B4 `verify_leg`, rule 12 additions, authority-step permissions, `ledger.posted` field, `reconcile` checks, T-Q7b, T-Q8, T-Q9, T-Q13, T-Q17 | M | #2657 L3; Q1, Q2 |
| Q4 | stock module `declare/2` (starter table, pairs, command shape, tolerance), entity quantity field declarations, T-Q5..T-Q7, T-Q10..T-Q12, T-Q14 | L | #2657 L4; Q3 |
| Q5 | masters follow-up and read-facade verification of factors, tolerances, exception tasks | L | OQ-R4 facade; #2663/#2664; part of L7 |

**Per-slice SECURITY checklist additions (appended to `gh2657...md` 16.5, A22).**
Q1: limits enforced inside `Quantity` before any `Decimal` call; the scan bans raw `Decimal` parse/arithmetic in policy files; `verify_leg` and `convert` shape-check first; the harness reaches the 64-byte and bignum rejections without `Decimals.parse/3`.
Q2: each CHECK verified by raw SQL in a throwaway schema; the base-quantity tripwire is present; a template clone keeps the CHECKs (T-Q15); the digest golden vector covers the new columns.
Q3: rule 12 refuses a production registration whose `rounding.allowed` has more than one mode, a pack unit without `convert_command`/`pack_targets`, and an unversioned widening; `verify_leg` `:audit` does not re-test registration-mutable values; the effective-role exclusion of `TENANT_AUDITOR`/`CANDIDATE` is checked at evaluation; the permission-matrix golden is updated; `factor_min`/`factor_max` validated; the exception permission is checked in core's authority step; the uniform `write_not_permitted` is byte-identical (and database round trips equal) for out-of-tolerance, exception and every new `invalid_posting` reason for an unauthorised subject (INV-5).
Q4: `tolerance.required_for_causes` set for measured units; `command`-factor legs flagged for reporting (`factor_drift`) and gated by `convert_command` where declared; CSV exemption type-based with the T-Q14 vectors; `exception_ref`/`measurement_ref` only in allowlisted read maps for subjects with the registration's read permission (INV-2); telemetry, audit and logs carry ids and reason codes only.

Explicitly OUT: percent tolerance; chains of conversions; non-multiplicative conversions; exact fractions (numerator/denominator); per-tenant configurable unit tables in L1-L4; per-item tolerance and per-item rounding
(L7); valuation and currency rounding; instrument registry and calibration; truck scales (release 2); automatic measurement capture; UI input widgets for strict decimals (`gh2654...md` 2.10); backfill of legacy numbers.

## 11. Decisions recorded (for the Q0 record; 0057 D9 practice cited by product and concept, NOT VERIFIED at clause level, N7)

* **D-Q1** unit scale: static registration table in L1-L4 (unit set only grows, scale increase-only, dimension and registered factors immutable, starter table normative), master later.
* **D-Q2** rounding: five magnitude-based modes; the mode is a REGISTRATION fact (production `half_up` only); stored per converted leg. Practice: ERP unit-of-measure handling (SAP MM, Dynamics 365 Supply Chain) keeps decimal places per unit and a configurable rounding on conversion; `half_even` is the IEEE 754 decimal default; commercial rounding is `half_up`.
* **D-Q3** conversion: single hop, one multiplication, integer arithmetic on carrier forms, round once at the end; entered digits beyond scale refused; decimal-string factors (0057 D4).
* **D-Q4** the triple, the 13 columns, NULL group = no conversion, `quantity_scale` always present, core verifies against the REGISTRATION, DB tripwire.
* **D-Q5** tolerance: absolute, base unit, inclusive, value from the registration, mandatory for named causes, refusal unless an exception leg, exception leg needs a distinct permission, counted in audit.
* **D-Q6** measurement evidence: `attrs.measurement_ref`.
* **D-Q7** wire: strings or JSON integers, floats refused, no implicit Jason encoding, no values in details/telemetry/audit, `payload_hash` stays raw.
* **D-Q8** command-basis factors: pack units only, bounded by registered `factor_min`/`factor_max`, REQUIRED `convert_command` permission (with registered `pack_targets`), `factor_drift` report, verified at L7.

## 12. Open questions with defaults

### 12.1 For the CODE-DESIGN-VALIDATOR and the supervisor

| Id | Question | Default |
|---|---|---|
| OQ-Q1 | Unit scale source in L1-L4 | registration `units` table; master at L7 |
| OQ-Q2 | Rounding set and source | five modes; registration-sourced; production `half_up` only |
| OQ-Q3 | Percent tolerance | not supported in release 1 |
| OQ-Q4 | Outside tolerance: refuse or accept with a flag | refuse unless an exception leg with the distinct permission (MD-07 wording) |
| OQ-Q5 | Factor digits | 18 integer, 12 fractional |
| OQ-Q6 | Exact fractions instead of a decimal factor | keep the decimal string (0057 D4); raise to the supervisor only if the pilot has a unit needing exactly 1/3 |
| OQ-Q7 | New units need a module version | yes in L1-L4 |
| OQ-Q8 | Trusted channel for factor/mode (N6) | not assumed; L7 |
| OQ-Q9 | A distinct wire code for out-of-tolerance | reason of `invalid_posting` |
| OQ-Q10 | `reference_quantity` required with the tolerance group | yes |
| OQ-Q11 | Fill the conversion group for direct legs | no: NULL means no conversion |
| OQ-Q12 | (withdrawn) reduced-form `payload_hash` | dropped, F3 |
| OQ-Q13 | CSV exemption by column type | yes |
| OQ-Q14 | Item-specific factors only for `pack` units; kg -> m by client factor refused | yes in release 1 |
| OQ-Q15 | `convert_command` permission | REQUIRED by rule 12 whenever any unit has dimension `pack` (withdrawn: "optional") |
| OQ-Q16 | Per-unit `tolerance` in the starter table | none; the stock module adds entries only with customer confirmation |
| OQ-Q17 | **Confirm with the supervisor:** tolerance and rounding are PER BASE UNIT (registration) in L1-L4, not per ITEM as 0057 D4 and the issue say ("a rounding rule per item", "a tolerance rule on the item"); per-item values arrive with the master at L7, which gates the pilot | yes, per unit in L1-L4 |
| OQ-Q18 | Does the `reference_quantity` come from the document line server-side at L7 (making the tolerance a real control) | yes, required for L7; until then self-attested (4.6) |

### 12.2 Customer-dependent input, plain language (for the user)

The pilot scales and tolerances were answered on 2026-10-16 (0057 D10): standard unit precisions as default, no customer numbers needed. The starter list in 4.1 is what the design uses. Two things would be good
to confirm when convenient, neither blocks design: (1) whether the pilot warehouse measures anything in units other than pieces, boxes, kilograms, grams, tonnes, metres, centimetres, millimetres, kilometres and
litres; (2) for the cable and metal example in the draft, to what precision a tape or scale is read (1 millimetre, 1 gram) and whether 0.05 m on a 2.5 m cable is a realistic allowance, since that figure is only the
example from the requirement.

## 13. Acceptance-criteria map

| AC | Where |
|---|---|
| Each rule tied to main (cited, re-read) or to #2654, else NOT FOUND | sections 1 and 3 (E1-E16, N1-N7) |
| Test: 2.5 m cable, tolerance 0.05 m absolute, posts the base, keeps original+unit; percent basis stated | T-Q6 (E0 in the base unit, E1 via cm), 4.6 |
| Same posting under two rounding rules shows both results | T-Q6, T-Q3, E5 |
| JSON number and a factor with more digits than its scale follow #2654; assumed choice named | section 2, T-Q1, T-Q2 |
| REQ-504 owns the triple; #2658 does not; #2657 includes by reference | 4.5, section 8, section 9 |
| MD-07 evidence recorded or out of slice | 4.7 |
| Scale per unit: where, how in L1-L4, trust | 4.1, 4.4, 7 |
| Rounding: where chosen, what stored | 4.3, 4.5 |
| Conversion: decimal-string factor, exact arithmetic, order, round once, refusal vs rounding | 4.4 |
| Tolerance: absolute, where evaluated, outside tolerance | 4.6 |
| Wire, exact sums, no float, strict aggregates | 4.8, T-Q11, T-Q12 |
| Security, INV-2/4/5/7/8 | section 7 |
| Amendments to #2657, effect on #2658 | sections 8, 9 |
| Slicing, out of scope, OQs, customer input | sections 10, 12 |
| CODE-DESIGN-VALIDATOR passes | pending |

## 14. Risks for CODE-DESIGN-VALIDATOR to attack first

1. 4.4: the arithmetic contract (integer carrier forms plus `Decimal.compare/2` only) and that the policy allowlist (A15) can still express `declare/2` through `Policy` delegates alone.
2. 4.4 table C1-C12: completeness of the registration-relative core checks (is any relation still trusted from the policy?), especially `:audit` mode versus scale increases.
3. 4.5: the tripwire CHECK `abs(abs(quantity_original) * conversion_factor - abs(quantity)) < 10 ^ (-quantity_scale)` for all five modes and for reversals; behaviour of `10 ^ (-n)` as Postgres numeric.
4. 4.6: tolerance value from the registration only (per base unit, not per item), the exception permission in the authority step, and the partial-control wording until L7.
5. 4.1/4.4: the `pack` dimension rule with `factor_min/max` as the bound on unverified factors.
6. Amendments A1-A33 against a note (revision 5) that is still under review on PR #2873.
7. Practice citations are not verified at clause level (N7).

## 15. Revision map: every CDV and SECURITY finding

### 15.1 Revision 3 (reviews of `1331249e`)

| Finding | Status | How / where |
|---|---|---|
| CDV 1 MAJOR audit mode re-tests registration-mutable values | done | `:audit` tests only the row's own values, scale `<=` and immutable relations; `registration_hash` on the entry; no widening without a version bump; T-Q8/T-Q13 change each field and run `reconcile`: 4.1, 4.4, 4.5, A26, A27 |
| CDV 2 MAJOR reversal fails C3/C6 after a scale increase | done | reversal legs verified in `:audit` mode; T-Q9 reverses after a scale increase: 4.5, A28 |
| CDV 3 MAJOR tripwire CHECK in double precision | done | `power(10::numeric, quantity_scale::numeric)` form; T-Q15 at scale 9 with an expression-text assertion: 4.5, A33 |
| CDV 4 MINOR positive-exponent domain | done | accepted only when `digits(coef) + exp <= 21`, expanded first; `exp: 1_000_000_000` stays `decimal_shape`; `1E+3` renders `"1000"`: 4.2, T-Q2b, T-Q11 |
| CDV 5 MINOR `units[*].rounding_mode` in `allowed` | done | rule 12 check and T-Q13 case: 4.1 |
| CDV 6 MINOR oracle inside reduced context | done | oracle and expectations outside, only the `Quantity` call inside: T-Q3, T-Q4 |
| CDV 7 MINOR E8/T-Q2 versus `factor_min` | done | `1.000000000001` accepted, `1.0000000000001` scale, `0.5`/`1001` factor_range: 5, T-Q2 |
| CDV 8 MINOR counts derived by core | done | `excepted_leg_count`, `tolerance_leg_count`, `command_leg_count` derived from the legs: 4.6, 4.9, A16, A19 |
| CDV 9 MINOR per-unit versus per-item | done | OQ-Q17 (confirm with the supervisor): 12.1 |
| SEC 1 MAJOR `convert_command` optional | done | required whenever a pack unit exists; distinct; auditor/candidate exclusion; T-Q13, T-Q17; OQ-Q15 withdrawn: 4.1, A30 |
| SEC 2 (via CDV 1) record the values in force | done | `registration_hash`, stored `tolerance_abs` and `rounding_mode`, widening needs a version bump: 4.1, 4.5 |
| SEC 3 MINOR self-attested reference | done | stated plainly; detects error not malice until L7 reads the reference server-side; `tolerance_leg_count` in the audit entry; L7 stays a pilot gate: 4.6, A17, OQ-Q18 |
| SEC 4 MINOR (a) counts, (b) role exclusion, (c) classification | done | (a) as CDV 8; (b) enforced at the EVALUATION point as well: A31; (c) tenant-scope INV-10, permission-matrix golden update: 4.6, A32 |
| SEC 5 MINOR pack target dimension unconstrained | done | registered `pack_targets`; C8 and `declare/2` step 3b; box -> kg refused, tested in T-Q17: 4.1, 4.4, A29 |

### 15.2 Revision 2 (reviews of `1ca191e5`)

| Finding | Status | How / where |
|---|---|---|
| CDV F1 B4 re-validation incomplete | done | `verify_leg(leg, registration, mode)` with 12 named checks and reason atoms against the REGISTRATION; T-Q8 per check; A7: 4.4, 4.9 |
| CDV F2 Policy signatures, reasons | done | ONE parser `Policy.decimal(term, scale, int_digits)` with ONE error shape, arity/order stated against `Decimals.parse/3`; `leg/1` keeps the group keys; reason atoms mapped by a table, unreachable reasons removed (`evidence_shape`), `quantity_zero` vs `rounds_to_zero`, `factor_unexpected` for mode on same-unit: 2, 4.9, A5, A7 |
| CDV F3 command keys vs core 9.1, payload_hash | done | module-level keys are the module's; core validates the declared leg; reduced-form canonicalisation DROPPED (re-send with other padding is `idempotency_key_reuse`): 4.8, A8 |
| CDV F4 arithmetic contract | done | every `Quantity` function uses integer carrier arithmetic plus `Decimal.compare/2`; own `reduce`/`expand`; `to_wire` total with the `render_value` fallback; T-Q4/T-Q5 under a reduced `Decimal.Context`: 4.4, 4.9, T-Q4, E12, E16 |
| CDV F5 tolerance undefined cases, AC test | done | every case specified (`tolerance_input`); E0 (base-unit entry) and coalesced read-back, stored `reference_quantity`/`tolerance_abs` asserted in T-Q6: 4.6, 5, 6 |
| CDV F6 rule 12 immutability | done | unit set only grows; dimension and registered factors immutable: 4.1, A10, A18, T-Q13 |
| CDV F7 CSV regex | done | `\A...\z` ASCII, exempt by column type; vectors in T-Q14: 4.8, A11 |
| CDV F8 per-unit scale hook | done | enforced at posting only in L1-L4; no hook claimed; T-Q12 scoped: 4.1, 6 |
| CDV F9 T-Q15 and tripwire | done | violating INSERTs in a cloned schema; the exact tripwire CHECK: 4.5, T-Q15 |
| CDV F10 starter list deferral | done | the starter table and pairs are NORMATIVE: 4.1, A13 |
| CDV F11 timing budget | done | reductions bound and length-guard assertion, no wall-clock: T-Q1 |
| CDV F12 citation hygiene | done | header says Revision 2 and ledger revision 5; `entities/` prefixes in E1; N1 reworded; partial-control statement in 4.6 |
| SEC 1 BLOCKER tolerance opt-in / exception | done | registration supplies `tolerance_abs`, `required_for_causes` mandatory; distinct `tolerance_exception` permission in core's authority step before any refusal; `excepted_leg_count` in audit; T-Q7b: 4.1, 4.6, A14, A16, A17, A19 |
| SEC 2 client rounding_mode skimming | done | mode from the registration; production `half_up` only; test via flag; T-Q6 two registrations: 4.3, A18 |
| SEC 3 unbounded command factor | done | `factor_min`/`factor_max` on pack units (`factor_range`), `convert_command` permission, `factor_drift` reconcile check, T-Q17: 4.1, 4.4, 4.9, A20 |
| SEC 4 policy allowlist narrowing | done | Decimal limited to types, `compare/2`, `is_decimal`; ban list; T-Q16; A15 |
| SEC 5 shape pre-check | done | carrier form and pre-check in B4, `verify_leg`, `convert`, every function; T-Q2b: 4.2 |
| SEC 6 pre-check order | done | bignum compare before `encode_unsigned`; `Quantity.decimal/3` rejects before `Decimals.parse/3`: 4.2 |
| SEC 7 DB CHECK and digest text | done | mode-independent tripwire; fixed-algorithm digest text and golden vector T-Q18: 4.5, A3 |
| SEC 8 CSV | done | as F7, plus text columns always neutralised: 4.8, A11 |
| SEC 9 wire rendering and details | done | `to_wire` only; no `%Decimal{}`/quantity in details, telemetry, audit: 4.8, A21 |
| SEC checklist Q1-Q4 | done | section 10, A22 |
