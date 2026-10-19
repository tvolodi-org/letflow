# GH #2660 / REQ-504 -- WMS quantity rules (3 of 4): exact decimal strings, scale per unit of measure, rounding rule, conversion at posting, the (base, original, unit) triple, item tolerance

Author: CODE-DESIGNER, 2026-10-19. Revision 1. Branch `docs/GH-2660-wms-quantity-design`, from `origin/main` `a614e9c1`.
Design only: signatures, type shapes, column and constraint lists, step lists, test briefs. No function bodies. Nothing here was run
(docs only; the host is memory-starved and mix is not used). Every claim about existing code carries a `file:line` re-read on `a614e9c1`
(worktree `C:\Users\tvolo\AppData\Local\Temp\wt2660`), a citation to what #2654 DELIVERED (it is done, so "planned" is now "delivered"), or is
marked NOT FOUND or NOT VERIFIED.

Sources: issue #2660 (body, updates of 2026-10-17 and 2026-10-18); decisions 0057 D4, D9, D10 (`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:16,44-48`
and the D10 addendum), 0058 (c), 0060 (items 1-6 and "Not decided here"), 0050 (D1-D3); `lib/letflow/design/gh2654-decimal-exact-strings.md` (cited `gh2654...md`);
the reviewed ledger-core note `gh2657-wms-stock-ledger-core.md` revision 4 (read on the branch `docs/GH-2657-wms-ledger-core-design`, PR #2873, NOT on main;
cited `gh2657...md` section numbers); issues #2657, #2658 (with the alignment comment of 2026-10-19), #2661-#2664; base document `docs/WMS/WMS_Procurement_Requirements_Draft.md`
(MD-01 :60, MD-07 :66, MD-08 :67, stock dimensions :40); mapping `docs/migration/wms-customer-draft-mapping-20261016.md:57`.

## 0. Verdicts in one screen

| # | Question | Verdict |
|---|---|---|
| V1 | Is #2654 still a dependency? | **No, it is met.** Strict writes, reads, filters, sort, cursor, aggregates and ScriptReads are on main (section 1). The interim shape in the issue body (`validator.ex:108` JSON number) is superseded: `validator.ex:134-135`. |
| V2 | Where does the unit-of-measure SCALE live? | Target home: the unit MASTER (`catalog_uom`, #2663, NOT BUILT and explicitly without it). In L1-L4 the trust anchor is a **static `units` table in the ledger registration** (scale 0..9 and a dimension per unit), because `declare/2` is pure and has no master read (`gh2657...md` 3.3, V9). Scale is **increase-only** per unit. |
| V3 | Rounding | One rounding step per leg, at the END of a conversion, to the BASE unit's scale, by a per-item rule from a CLOSED set of five (`half_up` default, `half_even`, `half_down`, `up`, `down`, all on the magnitude so a reversal is exact). A quantity ENTERED with more digits than its unit's scale is REFUSED, never rounded (the #2654 rule). |
| V4 | Conversion | Single hop original -> base, ONE multiplication, no division anywhere, exact INTEGER arithmetic on the Decimal coefficient and exponent (not `Decimal.mult`/`round`, which use the ambient 34-digit process-dictionary context), rounded once. Factors are decimal strings (0057 D4): at most 18 integer and 12 fractional digits. |
| V5 | Trust of factors | A factor that is a **registered universal pair** (kg<->g, m<->cm ...) is VERIFIED by `declare/2`. An **item-specific** factor (1 box = 12 pcs) is client evidence, stored with `conversion_basis = command` and UNVERIFIED until the read facade (slice L7). |
| V6 | The triple | Columns on `ledger_leg`: base = `quantity` + `unit_ref` (already in the ledger note), original = `quantity_original` + `original_unit_ref` (+ `original_scale`), plus `conversion_factor`, `conversion_basis`, `rounding_mode`, and an always-present `quantity_scale`. NULL group when no conversion happened. Section 4.5. |
| V7 | Tolerance | Absolute only, in the item's BASE unit, inclusive boundary; **percent basis NOT supported** in release 1 (additive later). Evaluated in `declare/2` after rounding, re-validated by core (B4) and by a DB CHECK. Outside tolerance: typed refusal (`invalid_posting` reason `out_of_tolerance`) unless the command carries an exception reference, then accepted and stored as `excepted` (MD-07: "out-of-tolerance values require an exception"). |
| V8 | MD-07 measurement evidence | A reserved leg `attrs` key `measurement_ref` (token). The evidence itself (ticket image, scale protocol) is the document slice's (WM-02); truck-scale integration is release 2 (draft :13). Section 4.7. |
| V9 | Wire | A quantity, factor, tolerance and reference are canonical decimal STRINGS or JSON INTEGERS; every JSON float is refused, exactly the #2654 choice (0060 item 2; `decimals.ex:130-148`). A factor or quantity with more fractional digits than its scale is REFUSED. |
| V10 | Effect on #2657 | 13 listed amendments (section 8): the REQ-504 leg columns, digest canonical form, `units`/`conversions`/`rounding` in rule 12, `Policy` helper signatures, the `invalid_posting` reason enum, reversal copy rule, reconcile `conversion_check`, CSV neutralisation exemption, canonicalisation for `payload_hash`. This note does NOT edit that file. |
| V11 | Customer input | None blocking: 0057 D10 says ISO and standard unit scales are the defaults. One plain-language confirmation item (section 12.2). |

## 1. State of the world (all on `a614e9c1` unless stated)

### 1.1 What #2654 delivered (and where)

| # | Fact | Source |
|---|---|---|
| E1 | `decimal_strict` is a per-field opt-in, default false; immutable once the type has any record; WMS declares it from its first definition | 0060 items 1, 4, 6; `lib/letflow/entities/definitions.ex:471-...` (gate), `definition/validator.ex:470-540` (Rule 7), `managed_types/stamp.ex:97,584-607,651` |
| E2 | Write grammar for a strict field: a binary of at most 1100 bytes matching `^-?(0|[1-9][0-9]*)(\.[0-9]+)?$` (no exponent, no sign `+`, no whitespace), or a JSON integer; every JSON float refused with constraint `type` | `entities/record/decimals.ex:41-44, 120-121, 130-148`; 0060 item 2 |
| E3 | Value-based digit rule: trailing zeros are dropped first, then more fractional digits than `decimal_scale` is `scale`, more integer digits than `precision - scale` is `precision`; NEVER rounded; order type -> scale -> precision -> min/max | `decimals.ex:156-166`; `gh2654...md` section 3 |
| E4 | Stored, event, response and read form is the canonical scale-padded string (`"2.5"` -> `"2.50"`, `3` -> `"3.00"`, `-0.00` -> `0.00`) | `decimals.ex:189-209, 392`; `records.ex:1830-1838` (`validate_field_values` returns the normalised map); `record/validator.ex:96-114` |
| E5 | Strict field subschema is `{"type":"string"}`; non-strict stays `{"type":"number"}` | `record/validator.ex:134-135` (the issue body's `:108` has moved) |
| E6 | Bounds: `min`/`max`/`non_negative` compared with `Decimal.compare/2`, INCLUSIVE (`:lt` / `:gt` are the refusals); a strict bound may be a decimal string | `decimals.ex:99-116, 399-405`; `definition/validator.ex:611-616` |
| E7 | Filters (`eq neq gt gte lt lte in not_in`) coerce the literal to an exact Decimal; a float literal is `invalid_decimal_value` (422) | `entities/query/compiler.ex:468-503`; `decimals.ex:336-347` |
| E8 | Sort casts the stored text (`(?->>?)::numeric`); a tampered cursor on ANY decimal field is a cursor error, not a raise | `compiler.ex:642-660`; `query/cursor.ex:353-370` |
| E9 | Aggregates: `sum`/`min`/`max` and a `group_by` key of a strict field are padded to the field scale; `avg` is UNPADDED; non-strict untouched | `compiler.ex:894-925, 1048`; `allowlist.ex:444-454` |
| E10 | HTTP reads (get, create, update, delete, query incl. joins), JSON export and ScriptReads/Lua render strict fields as strings from the DEFINITION's specs | `routers/entities.ex:3136-3156, 3372-3376, 3427-3432`; `entities/script_reads.ex:102, 223-233, 296-308` |
| E11 | In-process helper for arithmetic on a stored strict value: `Decimals.to_decimal/1`; for output `Decimals.render_value/2` (accepts a `%Decimal{}`, a number or a string; never raises; a value with more digits than `scale` is printed unpadded) | `decimals.ex:290-301, 319-328` |
| E12 | Decimal dependency is 3.1.1; its default context is precision 34, rounding `half_up`, and `mult`/`round` apply the context of the CALLING PROCESS (process dictionary); `Decimal.to_string/1` defaults to SCIENTIFIC notation and the `Jason.Encoder` for `Decimal` uses it | `mix.lock:4`; `deps/decimal/lib/decimal/context.ex` (`defstruct precision: 34`, `Context.with/2` does `Process.put`); `decimal.ex:1224-1230` (`mult` ends in `context()`), `:1304-1318` (`round/3` ends in `context(value, [])`), `:1686`; `deps/jason/lib/encoder.ex:227-230` |
| E13 | `HandlerWrites.create/3` writes through `command_multi/3`, so a handler-created record passes the strict pre-pass | `entities/handler_writes.ex:138-149`; `records.ex:1836` |
| E14 | Per-unit-of-measure scale is NOT a core concern: field scale is the maximum and the module narrows through the public parser | 0060 "Not decided here"; `gh2654...md` section 9, D8 |
| E15 | StreamData is a test dependency and property tests exist in the repo | `mix.exs:62`; `test/letflow/api/pagination_test.exs:11` (`use ExUnitProperties`) |

### 1.2 NOT FOUND on `a614e9c1`

| # | Item | Evidence |
|---|---|---|
| N1 | Any unit master: `Letflow.Modules.CatalogItems`, `catalog_uom`, `catalog_item` | `lib/letflow/modules/` has `exam/` only, `priv/modules/` has `exam/` only; #2663 is OPEN and its body says "The unit-of-measure decimal scale and conversion factors are NOT here: #2660 ... No decimal field is introduced"; #2664 `item_uom_valid?` allows ONLY the base unit |
| N2 | `Letflow.Ledger`, any `ledger_*` table, `quantity_original`, `conversion_factor` | the design is on a branch (PR #2873); `lib/letflow/ledger` does not exist |
| N3 | Any rounding or unit-conversion code | no `Decimal.round`, `Decimal.mult`, `Decimal.div` anywhere in `lib/` (searched) |
| N4 | Any item tolerance, rounding rule, alternate unit, item class | no field, no module (grep `toleran` finds only unrelated timeouts) |
| N5 | A read facade for handlers (item/unit lookup) | `gh2590-req501-module-write-handlers.md` OQ-R4; `gh2657...md` V1, 14.6 |
| N6 | Whether a process variable bound to a handler arg can be made un-overridable by the task completer | NOT VERIFIED (`gh2590...md` D-R.4 says args are "resolved values only"; who may set the variable is not read here) |
| N7 | Clause-level text of SAP MM or Dynamics 365 unit-of-measure documentation | NOT VERIFIED: practice cited as 0057 D9 cites it (by product and concept, not by clause) |

### 1.3 Relation to the ledger core

This note supplies what `gh2657...md` 4.5 reserves by reference ("REQ-504 columns", "`declare/2` computes the conversion from arguments already in the
command", "conversion evidence is untrusted metadata", 4.4 pilot risk) and what 14.1 leaves as `optional(atom()) => term()` on `declared_leg`. Everything here
is written against route R-N: the core stays domain-neutral (Rule 7 denylist `stock item location warehouse site lot serial sku material inventory bin pallet`);
the words `quantity`, `unit`, `scale`, `conversion`, `rounding`, `tolerance` are not on the denylist and are used in core. The stock vocabulary (item, cable,
box) stays in the stock module's registration, `declare/2` and read layer.

## 2. Wire choices: what #2654 decided and what this note assumes (AC 2, third clause)

| Input | Choice (cited) | The test asserts |
|---|---|---|
| decimal as a canonical string `"2.50"` | accepted (E2) | stored `quantity_original` 2.5, rendered `"2.5"` at the unit's scale |
| decimal as a JSON integer `3` | accepted, exact bignum (E2: `decimals.ex:140-146`) | `3` == `"3"` |
| decimal as a JSON number with a fraction or exponent `2.5`, `3.0`, `1e3` | **refused**, constraint `type`: the body decoder has already made it a lossy float, so no float can be proven exact (0060 item 2; `gh2654...md` D3) | refused as `invalid_posting` reason `type`, authorised subject |
| a float produced by a process variable or a Lua script | refused for the same reason; the author converts to a string (`gh2654...md` 2.4 item 5, D3) | same |
| string with an exponent, `+`, whitespace, `.5`, `5.`, `1,5`, `NaN`, `Infinity`, empty, leading zero, Unicode digits | refused (`decimals.ex:121`: the regex is ASCII-only) | table test |
| more fractional digits than the scale (quantity, factor, tolerance) | **refused, never rounded** (E3: `decimals.ex:162`; 0060 item 2, `gh2654...md` D5) | `"0.0000000000001"` as a factor (13 digits) refused; 12 digits accepted |
| a conversion RESULT with more digits than the base scale | the one place that **rounds** (section 4.4), by the item's stored rule | the two-rounding-rule test |

The ledger command and every document quantity therefore use ONE grammar. `Letflow.Ledger.Policy.decimal/…` (a `gh2657...md` 14.4 helper, NOT on main)
is amended (section 8, A5) to wrap `Decimals.parse/3` (`decimals.ex:130-166`) AFTER a tighter byte pre-check (64 bytes instead of 1100), so the parser the
ledger uses IS the #2654 parser and cannot drift from it.

## 3. Each rule tied to evidence (AC 1)

| Rule | On main / delivered by #2654 | Not on main (NOT FOUND, designed here) |
|---|---|---|
| R1 exact decimal, string on the wire | E2-E5, E10 (entity quantity fields, reads, export, ScriptReads) | the ledger leg columns and the ledger read maps (N2) |
| R2 scale per unit of measure | E14: core gives a field-level MAXIMUM scale and a public parser; narrowing is the module's job | the unit scale source (N1): registration table (L1-L4), master later (section 4.1) |
| R3 rounding rule per item (half-up default) | nothing (N3); the closest precedent is "refuse, never round" (E3) | the closed mode set, the storage and the algorithm (section 4.3-4.4) |
| R4 conversion at posting, factor as decimal string | E2 parses a factor; E11 renders; no arithmetic exists (N3) | the algorithm, the verified-pair table, the verification (section 4.4) |
| R5 stored triple | none (N2) | columns, CHECKs, digest, reversal (section 4.5) |
| R6 item tolerance | none (N4) | the rule, its place, its refusal (section 4.6) |
| R7 MD-07 evidence | none | `attrs.measurement_ref` (section 4.7) |
| R8 sums and reports exact, no float | E9 (entity aggregates), E11 | ledger-side sums and rendering (section 4.8) |
| R9 DoS limits | E2 byte and integer caps (`decimals.ex:41-44, 150-152`) | tighter ledger caps (section 4.2) |

## 4. Design

### 4.1 The unit-of-measure scale (decision D-Q1)

**Three layers of scale, never confused.**

1. *Storage scale (maximum).* Every WMS quantity is `numeric(30,9)`: 21 integer and 9 fractional digits. Entity quantity FIELDS (document lines, requests, receipts)
   declare `type: decimal, decimal_precision: 30, decimal_scale: 9, decimal_strict: true` (0060 item 6; E1), the same maximum as the ledger (`gh2657...md` OQ-10, closed by this
   note), so a document quantity can always be posted. Factor fields use precision 30, scale 12 (see 4.4). Because `decimal_strict` is immutable once records exist (E1), these
   declarations are in the module's FIRST definition files; a later flip is refused with 409 (0060 item 4).
2. *Unit scale (the per-unit precision, 0..9).* The number of fractional digits a quantity in this unit may have. It is the MD-07 "precision". It is enforced by REFUSAL
   at the entity-write step of the module (using `Decimals.parse/3` with the unit's scale: E14) and again by `declare/2`.
3. *Quantity scale stored on the leg* (`quantity_scale`, section 4.5): the unit scale that was in force when the leg posted. It makes every historic row renderable and checkable
   without consulting a registration that may have changed.

**Where the unit scale comes from.**

| Option | Verdict |
|---|---|
| A. A unit MASTER (`catalog_uom` with a `decimal_scale` integer field, and `catalog_item_uom` rows for item-specific factors) | **Target home.** NOT BUILT (N1) and #2663 excludes it by design. `declare/2` cannot read it in L1-L4 (V9 of the ledger note; the read facade is N5). Needs a follow-up requirement (section 9). |
| B. **Static `units` table in the ledger registration** (module-version-controlled data hashed by `ManifestHash`, validated by rule 12) | **ADOPTED for L1-L4.** Pure, deterministic, reviewable, tenant-independent, matches 0057 D10 ("ISO and standard unit scales as defaults"). Cost: a new unit is a module version change. |
| C. Scale carried by the COMMAND | **Rejected.** The client would choose the digits it is refused on; a wrong scale on a first posting would pin a wrong precision. |
| D. Plain module config | Rejected: not hashed, not validated, not visible to core B4. |

**Registration data (amendment A12 to rule 12).** `units` is a map `unit_ref -> %{scale: 0..9, dimension: token}`. Keys use the ledger's `:token` charset. Rule 12 enforces:
(i) scale is an integer 0..9; (ii) **scale is increase-only against the previously installed registration** (a smaller scale would make existing rows unrepresentable; a larger
one never does, because a quantity with at most `s` digits has at most `s+1`); (iii) the keys are exactly the allowed `unit_ref` set of `gh2657...md` 14.3 (the optional
`units` allowlist becomes this map); (iv) `dimension` is a token (`length`, `mass`, `count`, `volume`, `pack`). Illustrative defaults for the stock module (final list decided at L4,
confirmed in 12.2): `ea` 0, `pcs` 0, `set` 0, `box` 0 (pack), `kg` 3, `g` 0, `t` 3, `m` 3, `cm` 1, `mm` 1, `km` 3, `l` 3, `ml` 0.

**Consequence for trust, said exactly.** In L1-L4 the base unit of a balance key is chosen by the first posting (client-supplied; `gh2657...md` 4.4 pilot risk) but must be a KEY of the
registered table, and its scale is the registered one; the pin on `ledger_balance.unit_ref` then prevents any later change (`unit_mismatch`). Scale is not pinned on the balance row:
the increase-only rule makes the registration the authority. What stays unverified until the read facade exists: that THIS item's base unit is the unit the client named.

### 4.2 Quantity grammar and caps (the DoS section of the wire)

* A quantity, factor, reference or tolerance reaches `declare/2` as a string or JSON integer. Pre-checks run BEFORE the regex and before any `Decimal` call: a binary of more than
  **64 bytes** is refused `type` (the longest legal text is `-` + 21 digits + `.` + 9 digits = 32 for a quantity, 19+1+12 = 32 for a factor); an integer whose
  `:binary.encode_unsigned` is longer than **16 bytes** (10^21 needs 9) is refused `precision`, using the mechanism of `decimals.ex:150-152` with a tighter constant.
* The grammar has no exponent, so `1e1000000` is refused as `type` by the regex without a parse (`decimals.ex:121`); `Decimal.parse/2`'s own 34-digit default (`decimal.ex:167`) is
  overridden in `Decimals` (`decimals.ex:44`) precisely because the size is checked first; `Policy.decimal` keeps that order.
* Digit caps after parse: quantity and reference and tolerance at most 21 integer and 9 fractional digits (further capped by the unit scale); factor at most 18 integer and 12
  fractional digits; factor must be `> 0`; tolerance `>= 0`; reference `> 0`.
* Arithmetic bound: the exact product has at most 30 + 30 = 60 digits; one integer multiplication and at most one integer division by a power of ten `<= 10^21`. Nothing allocates in
  proportion to an attacker-chosen exponent because no exponent can be expressed.

### 4.3 The rounding rule per item (decision D-Q2)

* **Closed set of five modes, applied to the MAGNITUDE (absolute value), then the sign is re-applied:** `half_up` (default; ties away from zero; "commercial" rounding), `half_even`
  (banker's rounding, the IEEE 754 default for decimal), `half_down`, `up` (away from zero), `down` (toward zero). Magnitude-based rounding means `convert(-q) = -convert(q)`, so a
  receipt and its exact reversal can never differ (reversals do not recompute anyway: 10 of the ledger note). `ceiling` and `floor` are excluded: their meaning flips with the sign of
  a leg (receipt versus issue) and inventory practice has no use for them. This matches the semantics of `Decimal.round/3` for the same five names (`context.ex` rounding table), which
  makes `Decimal.round/3` a TEST ORACLE (section 6).
* **Where chosen.** Target: an attribute of the item (or item class: 0057 D10 says scales and tolerances are "configurable per item class") on the item master. NOT BUILT (N1, N4).
  In L1-L4 it is a command argument `rounding_mode` per leg; the registration carries `rounding: %{default: :half_up, allowed: [modes]}` and rule 12 requires `default` in `allowed`. An
  absent mode means the registration default; a mode outside `allowed` is `invalid_posting` reason `rounding_mode`.
* **What is stored.** `rounding_mode` on every leg that went through a conversion (4.5), so the result is reproducible and `reconcile` can recompute it. A leg posted in its base
  unit has no rounding (the quantity was entered at or below the scale or refused).
* **Trust.** In L1-L4 the mode is client evidence; its worst effect is one unit of the base scale per converted leg (the difference between two modes), bounded and visible in the
  stored mode. The registration `allowed` list is the only hard limit. Verification against the master waits for L7.

### 4.4 The conversion rule at posting (decision D-Q3)

**Definitions.** `original` = the quantity as entered, in unit `U_o` with scale `s_o`. `base` = the posted quantity in unit `U_b` with scale `s_b`. `factor` = base units per ONE original
unit, a positive decimal string with at most 12 fractional digits. `mode` as in 4.3.

**Order of operations in `declare/2` for each leg (normative).**

1. Parse `original` with the 4.2 caps and the scale `s_o` of `U_o` (refuse `type` / `scale` / `precision`; `unit_unknown` when `U_o` or `U_b` is not in `units`).
2. If `U_o == U_b`: no conversion. A supplied factor or mode is `invalid_posting` reason `factor_unexpected`. `base = original` (already within `s_b`). The conversion group stays NULL.
3. Else a `factor` is required (`factor_missing`). Classify the pair:
   a. `(U_o, U_b)` is a REGISTERED pair: the supplied factor must be absent or EQUAL to the registered one; otherwise `factor_mismatch`. `conversion_basis = registered`.
   b. Not registered: allowed only when `dimension(U_o) == "pack"` (a packaging unit such as `box`); otherwise `unit_pair` (kg -> m by client factor is nonsense and is refused).
      `conversion_basis = command`; the factor is parsed with 18/12 caps and `> 0`.
4. Exact product `P = original x factor`, computed on the integer coefficients and added exponents. **No `Decimal.mult`, `Decimal.round` or `Decimal.div` is used**: they apply the ambient
   process-dictionary context (E12, precision 34, silent rounding beyond it), and `Decimal.Context.with/2` writes the process dictionary, which the policy purity contract forbids
   (`gh2657...md` T-PL-1: "no process dictionary use"). The precedent for this style is already in main: `Decimals.reduce/1` and `to_canonical/2` avoid Decimal arithmetic for the same reason
   (`decimals.ex:168-209`, comment at :168-169). Decimal structs are only the carrier of sign, coefficient and exponent.
5. **Round once, at the end.** If `P` has at most `s_b` fractional digits it is exact and nothing is rounded. Otherwise round the magnitude to `s_b` fractional digits with `mode`. There is no
   intermediate rounding anywhere (no rounding of `original`, of `factor`, or between hops). **Chains are not allowed**: a conversion is always one hop original -> base, so there is no
   place for a second rounding; an item-specific pallet -> pcs factor is a direct factor, not pallet -> box -> pcs.
6. If the rounded magnitude is zero: `invalid_posting` reason `rounds_to_zero` (a leg of zero is not allowed: `CHECK quantity <> 0`, `gh2657...md` 4.3). If it exceeds 21 integer digits:
   reason `precision`. Re-apply the sign of `original` (factor is positive, so the sign is preserved and the cause sign rule of the ledger sees the right sign).
7. Tolerance (4.6) is evaluated on the rounded `base`.
8. Return the declared leg with `quantity = base`, `unit_ref = U_b`, and the REQ-504 keys of 4.5.

**Core re-validation (B4 of `gh2657...md` 7.1), added.** Core recomputes steps 4-6 from the stored group (`original`, `factor`, `mode`, `s_b`) with the same pure function and refuses any
declared leg whose `quantity` differs (`invalid_posting` reason `conversion_inconsistent`). A buggy module policy therefore cannot post a base quantity that does not follow from the stored
triple. The same function backs `reconcile` (4.9).

**Refusal versus rounding, the whole table.**

| Digits exceed the scale in... | Outcome |
|---|---|
| an ENTERED quantity (base or original unit) | refuse `scale` (never rounded; E3) |
| a factor (more than 12 fractional or 18 integer digits) | refuse `scale` / `precision` |
| a reference or tolerance (more than the base scale) | refuse `scale` |
| the exact PRODUCT of a conversion | **round once** by the item's mode (the only rounding in the system) |
| a sum of legs | cannot happen: all legs of a key share the pinned unit and each has at most that scale |

**Division.** Never performed. Both directions of a universal pair are registered explicitly (kg -> g `1000`, g -> kg `0.001`); rule 12 requires that, when both directions are present,
their product is exactly 1. A unit conversion that needs a non-terminating fraction (1/3) cannot be expressed as a 12-digit decimal factor: that is the recorded D4 limit (OQ-Q6).

**Registered universal pairs (illustrative; exact list at L4).** g<->kg, t<->kg, cm<->m, mm<->m, km<->m, ml<->l, with the exact decimal factors (`0.001`, `1000`, `0.01`, ...). Each endpoint pair
is within one dimension; rule 12 enforces same dimension, no self pair, no duplicate `(from, to)`, positive factor with at most 18/12 digits.

### 4.5 The stored triple (decision D-Q4): columns on `ledger_leg`

These replace the placeholder row "(REQ-504 columns)" of `gh2657...md` 4.3. All are added to the FIRST migration (an append-only table cannot be back-filled).

| Column | Type | Null | Meaning and CHECKs |
|---|---|---|---|
| `quantity` | numeric(30,9) | no | already in the ledger note: SIGNED delta in the BASE unit; `CHECK (quantity <> 0)`; **new:** `CHECK (quantity = round(quantity, quantity_scale))` (Postgres `round(numeric, int)`: the value has at most `quantity_scale` fractional digits) |
| `unit_ref` | text | no | already in the ledger note: the BASE unit, pinned per balance key |
| `quantity_scale` | smallint | no | **new, always present:** the base unit's scale at posting; `CHECK (quantity_scale BETWEEN 0 AND 9)`. Renders `quantity` deterministically forever |
| `quantity_original` | numeric(30,9) | yes | the quantity AS ENTERED in the original unit, same sign as `quantity`; `CHECK (quantity_original <> 0)` and `CHECK (sign(quantity_original) = sign(quantity))` |
| `original_unit_ref` | text | yes | `:token` charset, at most 128 bytes (text hygiene of `gh2657...md` section 4), `CHECK (original_unit_ref <> unit_ref)` |
| `original_scale` | smallint | yes | the original unit's scale at posting; `CHECK (BETWEEN 0 AND 9)`; `CHECK (quantity_original = round(quantity_original, original_scale))` |
| `conversion_factor` | numeric(30,12) | yes | base units per ONE original unit; `CHECK (conversion_factor > 0)` |
| `conversion_basis` | text | yes | `CHECK (conversion_basis IN ('registered','command'))` |
| `rounding_mode` | text | yes | `CHECK (rounding_mode IN ('half_up','half_even','half_down','up','down'))` |
| `reference_quantity` | numeric(30,9) | yes | tolerance group (4.6): the expected magnitude in the base unit; `CHECK (reference_quantity > 0)` |
| `tolerance_abs` | numeric(30,9) | yes | absolute tolerance in the BASE unit; `CHECK (tolerance_abs >= 0)` |
| `tolerance_state` | text | yes | `CHECK (tolerance_state IN ('within','excepted'))` |
| `exception_ref` | text | yes | token, at most 128 bytes, set iff `tolerance_state = 'excepted'` |

**Group CHECKs.** Conversion group: `quantity_original`, `original_unit_ref`, `original_scale`, `conversion_factor`, `conversion_basis`, `rounding_mode` are ALL NULL or ALL NOT NULL.
Tolerance group: `reference_quantity`, `tolerance_abs`, `tolerance_state` ALL NULL or ALL NOT NULL; `exception_ref IS NOT NULL` iff `tolerance_state = 'excepted'`. **Tolerance consistency in the
database:** `CHECK (tolerance_state IS DISTINCT FROM 'within' OR abs(abs(quantity) - reference_quantity) <= tolerance_abs)` and `CHECK (tolerance_state IS DISTINCT FROM 'excepted' OR abs(abs(quantity) -
reference_quantity) > tolerance_abs)`. Free text is not allowed in any of these columns; every text column carries the `octet_length` and control-character CHECKs of `gh2657...md` section 4.

**NULL means "no conversion".** A direct leg has an empty conversion group; readers use `COALESCE(quantity_original, quantity)` and `COALESCE(original_unit_ref, unit_ref)`. (Always filling the group with unit equal and factor 1 was
rejected: it doubles the bytes of the common case and invites a stored factor of 1 that nothing checks; see OQ-Q11.)

**Mapping to the entry digest.** The per-leg canonical form of `gh2657...md` 4.2 gains the new columns: a key-sorted JSON object per leg in `leg_no` order, every numeric as canonical text at its
STORAGE scale (quantities 9, factor 12), `quantity_scale` / `original_scale` as integers, absent columns as JSON `null`. `quantity` keeps "canonical text at scale 9" so digests do not depend on
`quantity_scale`; `quantity_scale` is a digest input itself.

**Reversal (`gh2657...md` 10).** The reversal copies each target leg: `quantity` negated, the conversion group copied with `quantity_original` negated, **the tolerance group set to NULL** (a
reversal is not a measurement; it is not re-evaluated). Because rounding is magnitude-based and the stored base is negated, not recomputed, the reversal needs no rounding and `reconcile`'s
conversion check holds for it.

**Registration change cannot corrupt history.** `quantity_scale` and `original_scale` freeze the scales used; the increase-only unit rule (4.1) keeps current registered scales at or above every
stored one.

### 4.6 The item tolerance rule (decision D-Q5)

* **Meaning.** For a measured good the receiver records the MEASURED quantity (the posting quantity, from the original measure through 4.4). The tolerance compares its magnitude with a
  REFERENCE (nominal or expected) magnitude in the base unit: `deviation = abs(abs(base) - reference)`. **Inside tolerance** iff `deviation <= tolerance_abs` (boundary INCLUSIVE).
* **Basis.** **Absolute, in the item's base unit only.** Percent is NOT supported in release 1: it is ambiguous (percent of the reference? of the order? of the measured?), it is the
  procurement over/under-delivery tolerance of WM-01 and WM-02 (a different concept owned by the discrepancy slice), and adding `tolerance_pct` later is an additive nullable column plus a
  registration key, not a rewrite. A caller that holds a percent converts it to an absolute value at the reference before posting; the absolute value is what is stored.
* **Where evaluated.** In `declare/2` (pure; all inputs are in the command), AFTER rounding. Core B4 re-validates the declared evidence (group shape, `tolerance_state` consistent with the
  numbers, `exception_ref` iff excepted) and the database CHECKs of 4.5 backstop it. Core does not know why a tolerance exists.
* **Outside tolerance.**
  - Without an exception reference: the build refuses `invalid_posting` reason `out_of_tolerance` with `leg_no` (the closed 422 channel: `gh2657...md` 14.4 allows only `invalid_posting` from
    `declare/2`; details are `leg_no` and the closed reason only, so no quantity leaves the step). It is released only to an authorised subject (INV-5 rule of 7.1). Nothing is written.
    BPM routes the refusal to an exception task (kept boundary of 0057: BPM decides route and who; the module decides validity).
  - With `tolerance_exception_ref` (a token, in practice the id of the approved exception task): accepted, stored `tolerance_state = 'excepted'`, `exception_ref` set. In L1-L4 the
    reference is UNVERIFIED client evidence (a post-permission holder can write any token); verification that the task exists, is approved and is bound to this posting needs the read facade
    (slice L7). Stated plainly: until then the tolerance is a consistency control on the command, not an authorization control.
* **Is the tolerance mandatory for an item?** Whether a given item is "measured goods" and which tolerance it has are MASTER facts (N4). In L1-L4 the tolerance group is optional per leg;
  evaluation is mandatory whenever the command carries it. At L7 the master's tolerance must equal the command's, or the leg is refused.
* **Tolerance and the cause rules.** It applies to receipt and issue legs a module chooses; it is irrelevant to `zero_sum` balancing because balancing is on base quantities.

### 4.7 MD-07 measurement evidence (decision D-Q6)

MD-07 asks for "scale/measurement evidence where applicable" and "Recorded physical measure and posted base-unit quantity can be reconciled". Mapping:

| MD-07 element | Where |
|---|---|
| actual measured length/weight | `quantity_original` + `original_unit_ref` (the physical measure as entered) |
| precision | unit `scale` (4.1) |
| tolerance | 4.6 |
| unit conversion | 4.4 |
| posted base-unit quantity | `quantity` + `unit_ref` |
| reconcile measure to posting | the triple plus `reconcile`'s `conversion_check` (4.9) |
| out-of-tolerance requires an exception | `out_of_tolerance` refusal + `exception_ref` |
| scale / measurement evidence | **reserved `attrs` key `measurement_ref`** (a token, at most 128 bytes: a weighing ticket number, a scale or tape id) at receipt and issue; stored in the leg `attrs` (digest-covered, immutable). The evidence ARTIFACT (ticket photo, scale protocol output) is an attachment on the receipt document (WM-02) and truck-scale integration is release 2 (draft :13) |

Out of this slice: instrument registry, calibration status, automatic scale readings. `measurement_ref` is optional in L1-L4; a cause or item class that requires it is registration policy later.

### 4.8 Wire format of quantities, reads and reports (decision D-Q7)

* **Posting command (module level).** A closed leg shape (names are the stock module's; the keys that matter here): `quantity` (string or integer, signed, in `unit`), `unit` (token),
  `base_unit` (token), optional `conversion_factor` (string), `rounding_mode` (enum), `reference_quantity` (string), `tolerance_abs` (string), `tolerance_exception_ref` (token), `measurement_ref`
  (token). Unknown keys, floats, non-canonical decimals, digits beyond scale are `invalid_posting`.
* **Read and report maps (`entries/3`, `balances/5`, exports).** Every quantity is a STRING:
  `quantity` at `quantity_scale`, `quantity_original` at `original_scale`, `reference_quantity` and `tolerance_abs` at the base `quantity_scale`, `conversion_factor` in reduced plain notation
  (trailing zeros dropped, never scientific), balances and sums at the unit's CURRENT registered scale (at or above every leg's scale). Rendering reuses `Decimals.render_value/2`
  (`decimals.ex:290-301`) on the `%Decimal{}` the database returns. **No implicit `Jason` encoding of a `Decimal` is allowed in a read map**: its default is scientific notation (E12), so `1E+3`
  could reach a client.
* **Sums.** The ledger read functions sum in SQL (`sum(quantity)` over `numeric`, exact) and render as above; there is no float step anywhere. Elixir-side sums by module code use
  `Quantity.sum/1` (integer arithmetic on scaled integers, exact for any list length) instead of `Decimal.add`, whose context would round a sum beyond 34 digits (E12). A report never totals
  across different `unit_ref` values (the key's pinned unit differs); it groups by unit.
* **Entity-side aggregates** (document lines, requests) go through the strict path: `sum`/`min`/`max` padded to the field scale (scale 9 for WMS quantity fields), `avg` unpadded (E9). A UI
  shows a quantity at its UNIT's scale, which a module renderer derives; core does not.
* **Export.** JSON export of strict fields is a string (E10). Ledger CSV/XLSX export (L4): the neutralisation rule of `gh2657...md` 16.3 (cells starting `=`, `+`, `-`, `@`) must EXEMPT cells
  that match the canonical decimal grammar (they cannot be formulas, and a leading `-` is a negative quantity); see amendment A11.
* **Round trip.** Entity quantity written as `"2.500"` is stored `"2.500"`, returned by get/query/export/ScriptReads as `"2.500"` (E4, E10); a ledger leg written from `253` cm reads back
  `quantity "2.530"`, `quantity_original "253"`, `original_unit_ref "cm"`.

### 4.9 Interfaces (types and signatures only)

New pure core module `Letflow.Ledger.Quantity` (file under `lib/letflow/ledger/`, covered by Rule 7), reached by module code only through `Letflow.Ledger.Policy` delegates (the policy allowlist of
`gh2657...md` 14.4 permits no other Letflow module).

```
@type rounding_mode :: :half_up | :half_even | :half_down | :up | :down
@type reason :: :type | :scale | :precision | :factor_range | :rounds_to_zero | :conversion_inconsistent
@type quantity_group :: %{quantity_scale: 0..9,
                          quantity_original: Decimal.t() | nil, original_unit_ref: String.t() | nil, original_scale: 0..9 | nil,
                          conversion_factor: Decimal.t() | nil, conversion_basis: :registered | :command | nil, rounding_mode: rounding_mode() | nil,
                          reference_quantity: Decimal.t() | nil, tolerance_abs: Decimal.t() | nil,
                          tolerance_state: :within | :excepted | nil, exception_ref: String.t() | nil}

@spec parse(term(), scale :: 0..12, int_digits :: 1..21) :: {:ok, Decimal.t()} | {:error, :type | :scale | :precision}   # 64-byte pre-check, then Decimals.parse/3
@spec parse_factor(term()) :: {:ok, Decimal.t()} | {:error, :type | :scale | :precision | :factor_range}                 # scale 12, 18 integer digits, > 0
@spec parse_mode(term()) :: {:ok, rounding_mode()} | {:error, :invalid}
@spec convert(original :: Decimal.t(), factor :: Decimal.t(), target_scale :: 0..9, rounding_mode()) :: {:ok, Decimal.t()} | {:error, :rounds_to_zero | :precision}
@spec round_magnitude(Decimal.t(), target_scale :: 0..9, rounding_mode()) :: Decimal.t()          # exact; the only rounding function
@spec deviation(base :: Decimal.t(), reference :: Decimal.t()) :: Decimal.t()                     # abs(abs(base) - reference), exact
@spec within_tolerance?(base :: Decimal.t(), reference :: Decimal.t(), tolerance_abs :: Decimal.t()) :: boolean()   # inclusive
@spec sum([Decimal.t()]) :: Decimal.t()                                                            # exact for any length
@spec to_wire(Decimal.t(), scale :: 0..12) :: String.t()                                           # plain notation, padded, never scientific
@spec verify_leg(declared_leg_quantity_fields :: map()) :: :ok | {:error, reason()}                # core B4 and reconcile
```

`Letflow.Ledger.Policy` gains thin delegates for `parse`, `parse_factor`, `parse_mode`, `convert`, `within_tolerance?`, `sum`, `to_wire` and its existing `decimal/2` signature is widened (A5).
`declared_leg` (`gh2657...md` 14.1) gains the typed optional keys of `quantity_group`. `reconcile`'s result gains `conversion_check :: :ok | {:inconsistent_at, pos_integer()}` (the first `posting_seq` whose
leg fails `verify_leg/1` or the tolerance CHECK relation; chunked like the other checks, `gh2657...md` 11.2).

**`invalid_posting` reasons added to the closed enum** (details stay `{leg_no, reason}` only): `type`, `scale`, `precision`, `unit_unknown`, `unit_pair`, `factor_missing`, `factor_unexpected`, `factor_mismatch`,
`factor_range`, `rounding_mode`, `rounds_to_zero`, `out_of_tolerance`, `tolerance_input`, `conversion_inconsistent`, `evidence_shape`.

## 5. Worked examples (the numbers the tests use)

Test registration units: `m` scale 3 / length, `cm` scale 1 / length, `mm` scale 1 / length, `kg` 3 / mass, `g` 0 / mass, `ea` 0 / count, `box` 0 / pack. Registered pairs: `cm -> m` `0.01`, `mm -> m` `0.001`, `g -> kg` `0.001`.

| Case | Input leg | Result |
|---|---|---|
| E1 cable, nominal | base `m`, `250` cm, reference `2.5`, tolerance `0.05` | `0.01` registered; `quantity "2.500"`, original `250` cm, `tolerance_state within`, deviation 0.000 |
| E2 cable, measured | `253` cm | `quantity "2.530"`, deviation 0.030 <= 0.05, within; original `253` cm kept |
| E3 boundary | `255` cm and `245` cm | deviation exactly 0.050 and 0.050: accepted (inclusive) |
| E4 outside | `256` cm | deviation 0.060: `invalid_posting` reason `out_of_tolerance`; with `tolerance_exception_ref "t-7"`: accepted, `excepted`, `exception_ref t-7` |
| E5 two rounding rules | `2.5` mm to `m` (factor `0.001`), product exactly `0.0025`, scale 3 | `half_up` `0.003`, `half_even` `0.002`, `half_down` `0.002`, `up` `0.003`, `down` `0.002`; the same with `-2.5` gives the negatives (`-0.003` / `-0.002` ...) |
| E6 rounds to zero | `0.4` mm, `half_up` | product `0.0004` -> `0.000`: `rounds_to_zero` |
| E7 packaging | base `ea`, `3` box, factor `12` (command) | `quantity "36"`, `conversion_basis command`; `2.5` box refused `scale` (box scale 0); kg -> `ea` by a command factor refused `unit_pair` |
| E8 factor digits | factor `0.000000000001` (12) vs `0.0000000000001` (13) | accepted vs `invalid_posting` reason `scale` |
| E9 JSON number | `quantity: 2.5` vs `"2.5"` vs `3` | refused `type` vs accepted vs accepted |
| E10 registered mismatch | cm -> m with factor `0.1` | `factor_mismatch` |

## 6. Test plan (ExUnit; property tests with StreamData, E15)

New files, `async: false` where they touch the database. The pure quantity module needs no database and no tenant.

| Id | File | Case |
|---|---|---|
| T-Q1 | `ledger/quantity_grammar_test.exs` | grammar table of section 2 for quantity, factor, tolerance, reference: every refusal reason; JSON `2.5` refused `type`, `"2.5"` accepted, `3` accepted, `3.0` refused; a 10 MB string, `"1e1000000"`, `"1E5"`, `"0x10"`, Arabic-Indic digits, `" 1"`, `"+1"`, `"NaN"` refused WITHOUT reaching `Decimal.parse` (a timing budget of 5 ms and an assertion that a 10 MB input is rejected by length); an integer of 5000 bits refused |
| T-Q2 | same | **factor with more digits than its scale**: 12 fractional accepted, 13 refused `scale`, 19 integer digits refused `precision`, `"0"` and `"-1"` refused `factor_range`; the asserted choice is #2654's (refuse, never round: `decimals.ex:162`), named in the test |
| T-Q3 | `ledger/quantity_round_test.exs` | E5 for all five modes, positive and negative, against the table of section 5 AND against `Decimal.round/3` as oracle; ties, non-ties, exact products (no rounding), rounds-to-zero |
| T-Q4 | `ledger/quantity_property_test.exs` (StreamData) | (P1) `parse(to_wire(d, s), s)` round-trips for random coefficient/exponent within caps; (P2) rounding bounds: for the half modes `abs(round(x) - x) <= 0.5 ulp`, for `up`/`down` `< 1 ulp`; `down <= abs(x) <= up`; exact when representable; (P3) equals `Decimal.round/3` for all five modes on random values of at most 34 digits; (P4) sign symmetry `convert(-q) = -convert(q)`; (P5) **rounding once**: the single-step result of `q x f` is within the P2 bound of the exact product, and for random `f1`, `f2` the exact `(q x f1) x f2 == q x (f1 x f2)` (associativity of the EXACT product), which documents why chains with intermediate rounding are not allowed; (P6) `sum` of N random legs equals the integer sum, order-independent, and 10 x `0.1` sums to `1.0`; (P7) `verify_leg` accepts every output of `convert` and rejects any perturbation of one unit in the last place |
| T-Q5 | `ledger/conversion_policy_test.exs` | `declare/2` of the stock test policy: E1-E10 of section 5, including registered versus command basis, `unit_pair`, `unit_unknown`, `factor_unexpected` for a same-unit leg, `factor_missing`; zero extra queries (telemetry) and no process dictionary write (the Decimal context is untouched: assert `Decimal.Context.get/0` unchanged after the call) |
| T-Q6 | `ledger/quantity_posting_test.exs` | **2.5 m of cable with tolerance 0.05 m posts the base quantity and keeps the original**: through `Ledger.post/1` with the test registration, the stored leg has `quantity 2.500`, `unit_ref m`, `quantity_original 250`, `original_unit_ref cm`, `conversion_factor 0.01`, `conversion_basis registered`, `tolerance_state within`; `entries/3` returns the strings; the balance is `"2.500"`. **The same posting under two rounding rules** (E5) posts `0.003` under `half_up` and `0.002` under `half_even`, both rows stored with their `rounding_mode`, the balances differ accordingly |
| T-Q7 | same | outside tolerance for an authorised subject is the 422 `invalid_posting {leg_no, out_of_tolerance}` with nothing written and the counter unchanged; an UNAUTHORISED subject gets the byte-identical `write_not_permitted` (INV-5, `gh2657...md` 7.1); with an exception reference the leg is `excepted`; boundary inclusive; a tolerance group with `within` but a quantity outside is refused by the DB CHECK (raw SQL in a throwaway tenant) |
| T-Q8 | `ledger/quantity_core_check_test.exs` | core B4 refuses a module policy that returns a base quantity inconsistent with the stored triple (`conversion_inconsistent`); a hand-edited leg row violates each CHECK of 4.5 (raw SQL): scale, sign agreement, group all-or-none, mode set, basis set, factor positive, exception_ref iff excepted |
| T-Q9 | `ledger/quantity_reversal_test.exs` | a reversal of a converted leg negates `quantity` and `quantity_original`, copies factor and mode, has a NULL tolerance group, and `conversion_check` stays `:ok`; reversal equals the exact negation for random values under every mode (property) |
| T-Q10 | `ledger/quantity_transfer_test.exs` | a `zero_sum_by_slot_1` transfer whose two legs are entered in different units and convert to base quantities differing by the rounding residual is refused `posting_not_balanced`; the same transfer entered in one unit balances |
| T-Q11 | `ledger/quantity_sum_test.exs` | sums of many legs exact: 1,000 random legs of scale 3 equal the Decimal integer sum in `balances/5`, in `reconcile/2`, and in the cut-off report; no `E` in any rendered string; a `Decimal` with a positive exponent (`1E+3`) is rendered `"1000"` (E12 hazard) |
| T-Q12 | `entities/quantity_fields_roundtrip_test.exs` | entity document line with `decimal_strict` precision 30 scale 9: write `"2.500"` through `HandlerWrites.create/3`, read via HTTP get, query (`gt "2.4999"`, `in`), JSON export, ScriptReads, in-process `Latest.get/3` plus `Decimals.to_decimal/1`: identical strings; ten `"0.100"` aggregate `sum "1.000000000"`, `avg` unpadded (E9); a float body is 422 `type`; a non-strict twin is unchanged (compatibility) |
| T-Q13 | `ledger/registration_units_test.exs` | rule 12: scale outside 0..9, a decrease against the installed registration, a pair across dimensions, a duplicate pair, both directions whose product is not exactly 1, a default mode outside `allowed`, a unit key outside the token charset are each refused; an increase is accepted |
| T-Q14 | `ledger/export_roundtrip_test.exs` (L4) | ledger export cells for negative quantities keep the leading `-` (neutralisation exempts canonical decimals) while a free-text cell starting with `=` is neutralised |
| T-Q15 | `support/tenant_template_ledger_test.exs` | extends T-TT-2: the new CHECKs and columns exist in a cloned schema |

Exact-input property generators draw coefficient digits and exponents within the caps of 4.2 only; the oracle properties (P3) also bound the digit count to 34 because `Decimal.round/3` itself rounds to its context precision (E12).

## 7. Security (INV map)

* **Untrusted inputs (INV-4/5/7/8).** Everything below arrives from the client in L1-L4 and is treated as hostile: the unit strings (token charset, `units` allowlist), factor (caps, positivity,
  registered-pair equality), rounding mode (closed set, registration `allowed`), reference and tolerance (caps, non-negative), `tolerance_exception_ref` and `measurement_ref` (token, 128 bytes, no
  free text). Nothing from them is interpolated into SQL (INV-7: numerics are bound as `Decimal` parameters; the only literal SQL is the fixed migration text).
* **Decimal DoS.** Section 4.2: length before regex, no exponent in the grammar, integer byte cap, digit caps, 60-digit product bound, one integer multiplication. `Decimal.parse` is called only on a
  string that already passed the grammar, with the limits overridden knowingly (`decimals.ex:44`). The ambient context is never relied on, so an attacker cannot make arithmetic depend on it.
  T-Q1 pins this.
* **Build-time refusals and INV-5.** Every quantity refusal is a build-time `invalid_posting`; per `gh2657...md` 7.1 it is released only after the authority check, so an unauthorised subject cannot
  probe the unit table, the registered factors or the tolerance logic from error bodies. `details` carry `leg_no` and a closed reason; never a value, so no quantity reaches logs or the audit chain
  (T-ERR-3 of the ledger note).
* **INV-2.** Read maps are allowlisted; `exception_ref` and `measurement_ref` are included only for a subject holding the registration's `read` permission; factors and tolerances are not secrets but follow
  the same allowlist.
* **INV-8.** The quantity functions are total on their domain: refusal is by return value; a raise inside `declare/2` is the existing closed build failure; `to_wire` and `render_value` never raise.
* **Integrity.** The conversion triple is covered by `entry_digest` and the chain; core recomputes the conversion at B4 and at `reconcile`; the database CHECKs reject rows that violate the relations even
  for a bug in core. The tripwire nature of the triggers (`gh2657...md` 5.1) is unchanged: an owner can still rewrite, and the residual is the same.
* **Trust statement (also for SECURITY-REVIEWER).** In L1-L4 the stored `conversion_factor` with `conversion_basis = command`, the `rounding_mode`, the tolerance group and `exception_ref` are
  UNVERIFIED client evidence. The base quantity IS authoritative for the balance once posted; its correctness depends on the poster's honesty for item-specific factors until slice L7. That is the same
  trust the ledger note already gives the first unit pin.
* **Process variables.** Whether the factor, tolerance and mode can come from a trusted (script-computed from the master via ScriptReads, `script_reads.ex:102, 296-308`) variable that the task completer
  cannot overwrite is NOT VERIFIED (N6); until it is, the process design must not be assumed to protect them.

## 8. Amendments to the #2657 note (precise; this note does not edit that file)

| # | Where in `gh2657...md` | Change |
|---|---|---|
| A1 | 4.3 table, row "(REQ-504 columns)" | replace by the thirteen rows of section 4.5 of this note (`quantity_scale` NOT NULL; the conversion, tolerance groups; the CHECK list incl. `quantity = round(quantity, quantity_scale)`, sign agreement, group all-or-none, tolerance consistency) |
| A2 | 4.5 bullet "REQ-504 (#2660)" | keep the reserved names `quantity_original`, `original_unit_ref`, `conversion_factor` (type `numeric(30,12)`, no longer bare `numeric`); drop "a tolerance-evidence reference"; add `original_scale`, `conversion_basis`, `rounding_mode`, `quantity_scale`, `reference_quantity`, `tolerance_abs`, `tolerance_state`, `exception_ref`. Reword "the conversion itself is computed by `declare/2`" to add "and re-verified by core B4" |
| A3 | 4.2 `entry_digest`, and 5.1 | the canonical per-leg form includes every new column as in 4.5 of this note (key-sorted JSON, `null` for absent, numerics as canonical text at storage scale, `quantity_scale` and `original_scale` as integers) |
| A4 | 4.4 and 4.1 text on `unit_ref` | `unit_ref` stays pinned per balance key; add: the unit's SCALE is not pinned but comes from the registration `units` table whose scales are increase-only; `quantity_scale` is copied to every leg |
| A5 | 14.4 `Letflow.Ledger.Policy` | `decimal/2` becomes `decimal(term, scale :: 0..12, int_digits :: 1..21)` wrapping `Decimals.parse/3` after a 64-byte pre-check; add `parse_factor/1`, `parse_mode/1`, `convert/4`, `within_tolerance?/3`, `sum/1`, `to_wire/2` (section 4.9); the allowlist scan for policy files is unchanged (Decimal is already permitted, but conversion arithmetic must go through `Policy`) |
| A6 | 14.1 `declared_leg` | replace `optional(atom()) => term()` for the REQ-504 keys by the typed optional keys of `quantity_group` (4.9); `reconciliation` gains `conversion_check` |
| A7 | 7.1 B4 and 12.2 `invalid_posting` | B4 additionally recomputes the conversion and re-checks the tolerance evidence; the closed `reason` enum is extended with the fifteen values of 4.9. Out-of-tolerance is reason `out_of_tolerance` of `invalid_posting` (422), not a new core code |
| A8 | 9.1 posting command, 9.2 | the leg keys of 4.8; `payload_hash` canonicalises every decimal to its REDUCED plain form (`"2.5"` and `"2.50"` are the same command), so a client re-sending a differently padded spelling is a duplicate, not `idempotency_key_reuse` |
| A9 | 10 Reversal | copy rule of 4.5 (negate `quantity_original`, copy factor/mode/basis/scales, tolerance group NULL) |
| A10 | 14.3 rule 12 | add `units %{unit_ref => %{scale, dimension}}` (replaces the optional allowlist), `conversions [%{from, to, factor}]`, `rounding %{default, allowed}` and the checks of 4.1 and 4.4 (increase-only, dimension, no duplicate or self pair, both-direction product 1, positive factor with 18/12 digits, default in allowed); `ManifestHash` covers them (it already covers the whole registration) |
| A11 | 16.3 CSV/XLSX neutralisation | cells that match the canonical decimal grammar are exempt (a negative quantity starts with `-`); only other cells are neutralised |
| A12 | 13 test plan | add T-Q1..T-Q15 by reference; T-PL-1 gains "the Decimal context of the build process is unchanged by `declare/2`" |
| A13 | 17 slicing, 20 OQ-10 | L1 includes the A1 columns and CHECKs and depends on THIS note being accepted; OQ-10 is CLOSED: `numeric(30,9)` confirmed, factor `numeric(30,12)`; add an L1 migration test that a populated ledger plus a later nullable column stay byte-identical (with #2658) |

## 9. Effect on #2658 and on the masters

* **#2658 (dimensions).** No dimension slot is added for quantity. The alternate-unit column that 0057 G3 lists "now" is satisfied by the REQ-504 triple (`original_unit_ref`), so #2658 must NOT add
  an alternate-unit slot. A serial-tracked item has base unit `ea` (scale 0) so its `key_bounds` `max_on_hand: "1"` is an integer in the base unit. Status/available-to-pick reads sum base
  quantities per unit. No change to the slot design or the lock order.
* **#2663 / #2664 (masters, open).** No edit by this note. Proposed FOLLOW-UP requirement (to be filed by the supervisor), after the ledger core and before L7: `catalog_uom.decimal_scale` (integer 0..9, required),
  `catalog_uom.dimension`, a new managed type `catalog_item_uom` (item id, uom id, `factor` decimal strict precision 30 scale 12 with `min "0.000000000001"` because bounds are inclusive (E6) and zero must be
  refused, `active`), `catalog_item.rounding_mode` enum of the five, `catalog_item.tolerance_abs` (decimal strict, 30,9, non-negative, optional), and `item_uom_valid?` extended beyond the base unit
  (#2664 allows only the base unit today). Then L7 replaces the static table by master reads performed in the pre-validation step (never in `declare/2`).
* **0057 D4 / 0060.** D4 is implemented, not amended. 0060 item 6 ("WMS declares `decimal_strict: true`") is the reason section 4.1 gives for every WMS quantity field.

## 10. Implementation slicing and what is out

| Slice | Content | Size | Depends on |
|---|---|---|---|
| Q0 | decision record (proposed number 0063; 0062 is the ledger record proposed in #2657; recheck at write time): the rules R1-R9, D-Q1..D-Q7, practice citations (docs only) | S | this note accepted |
| Q1 | `Letflow.Ledger.Quantity` pure module and T-Q1..T-Q4 (grammar, rounding oracle, properties). **No database, no dependency on the ledger migration**: can start immediately | M | Q0 |
| Q2 | the A1 columns and CHECKs inside the ledger L1 migration, digest change, T-Q8, T-Q15 | M | #2657 note accepted with A1-A4; Q1 |
| Q3 | `Policy` delegates, B4 re-check, rule 12 additions (`units`, `conversions`, `rounding`), `reconcile` conversion check, T-Q9, T-Q13 | M | #2657 L3; Q1, Q2 |
| Q4 | stock module `declare/2` (unit table, pairs, command shape, tolerance), entity quantity field declarations, T-Q5..T-Q7, T-Q10..T-Q12, T-Q14 | L | #2657 L4; Q3 |
| Q5 | masters follow-up (unit scale, item units, rounding, tolerance) and the read-facade verification of factors, tolerances and exception tasks | L | OQ-R4 facade; #2663/#2664; part of L7 |

Explicitly OUT: percent tolerance; chains of conversions; non-multiplicative conversions (temperature offsets); exact fractions (numerator/denominator); per-tenant configurable unit tables in L1-L4;
valuation, price and currency rounding; instrument registry and calibration; truck-scale integration (release 2); automatic measurement capture; any UI input widget for strict decimals (`gh2654...md` 2.10);
backfill of legacy numbers.

## 11. Decisions recorded (for the Q0 record; 0057 D9 practice cited by product and concept, NOT VERIFIED at clause level, N7)

* **D-Q1** unit scale: static registration table in L1-L4, master later; increase-only; scale 0..9.
* **D-Q2** rounding: five magnitude-based modes, `half_up` default, stored per converted leg. Practice: ERP unit-of-measure handling in SAP MM and Dynamics 365 Supply Chain keeps a decimal-places setting per
  unit and a configurable rounding on conversion (nearest, up, down); `half_even` is the IEEE 754 default decimal rounding; commercial rounding is `half_up`.
* **D-Q3** conversion: single hop, one multiplication, exact integer arithmetic, round once at the end; refuse digits that are ENTERED beyond the scale; decimal-string factors per 0057 D4 (practice uses numerator/denominator,
  see OQ-Q6).
* **D-Q4** triple and the column set of 4.5; NULL group means no conversion; `quantity_scale` always present.
* **D-Q5** tolerance: absolute, base unit, inclusive, evaluated after rounding in `declare/2` and re-validated; refuse unless an exception reference (MD-07 acceptance wording).
* **D-Q6** measurement evidence: `attrs.measurement_ref`; artefacts in the document slice.
* **D-Q7** wire: strings (or JSON integers) in and out, floats refused, no implicit Jason encoding of Decimal in a read map.

## 12. Open questions with defaults

### 12.1 For the CODE-DESIGN-VALIDATOR and the supervisor

| Id | Question | Default |
|---|---|---|
| OQ-Q1 | Unit scale source in L1-L4 | registration `units` table (B); master at L7 |
| OQ-Q2 | The rounding set | five modes, `half_up` default |
| OQ-Q3 | Percent tolerance | not supported in release 1 |
| OQ-Q4 | Outside tolerance: refuse or accept with a flag | refuse unless an exception reference (MD-07 wording); not a conflict with the draft |
| OQ-Q5 | Factor digits | 18 integer, 12 fractional |
| OQ-Q6 | Exact fractions (numerator/denominator, as SAP and Dynamics hold them) instead of a decimal factor | keep the decimal string (0057 D4 ruling); a unit needing exactly 1/3 is the stated limit. Raise to the supervisor only if the pilot has such a unit |
| OQ-Q7 | New units need a module version | yes in L1-L4; a tenant-editable table is L7 |
| OQ-Q8 | Trusted channel for factor/tolerance/mode (N6) | not assumed; verify at L7 |
| OQ-Q9 | A distinct wire code for out-of-tolerance (needs a change of the 14.4 allowed-code list) | reason of `invalid_posting` |
| OQ-Q10 | `reference_quantity` required with a tolerance | yes (both or neither) |
| OQ-Q11 | Fill the conversion group even for direct legs | no: NULL means no conversion |
| OQ-Q12 | Reduced-form canonicalisation for `payload_hash` (A8) | yes |
| OQ-Q13 | CSV exemption for canonical decimals (A11) | yes |
| OQ-Q14 | A same-dimension item-specific factor (e.g. a cable sold by the roll where roll is `pack`) fits `pack`; a conversion between two physical dimensions (kg to m for a given cable linear density) is refused as `unit_pair` | refuse in release 1; revisit with the master |

### 12.2 Customer-dependent input, plain language (for the user)

The pilot scales and tolerances were answered on 2026-10-16 (0057 D10): standard unit precisions as the default, adjustable per kind of item, no customer numbers needed. This design follows that.
Two things would be good to confirm when convenient, neither blocks design: (1) whether the pilot warehouse measures anything in units other than pieces, boxes, kilograms, tonnes, metres, centimetres,
millimetres and litres (the starter list); (2) for the cable and metal example in the draft, whether a tape or a scale is read to 1 millimetre / 1 gram, and whether a deviation of 0.05 m on a 2.5 m cable is a
realistic allowance, since that figure is only the example from the requirement and is not set for any real item.

## 13. Acceptance-criteria map

| AC | Where |
|---|---|
| Each rule tied to main (cited, re-read) or to #2654 (cited), else NOT FOUND | sections 1 and 3 (E1-E15, N1-N7) |
| Test: 2.5 m cable, tolerance 0.05 m absolute, posts the base, keeps original+unit | T-Q6, E1-E4 of section 5 |
| Percent basis stated | 4.6 (not supported; why; how added later) |
| Same posting under two rounding rules shows both results | T-Q6, T-Q3, E5 |
| JSON number and a factor with more digits than its scale follow #2654; the note names the assumed choice | section 2, T-Q1, T-Q2 |
| Added point: REQ-504 owns the triple, #2658 does not; #2657 includes it by reference | 4.5, section 8 (A1-A4), section 9 |
| Added point: MD-07 evidence recorded or out of slice | 4.7 |
| CODE-DESIGN-VALIDATOR passes | pending |
| Scale per unit: where it lives, how in L1-L4, trust of client factors | 4.1, 4.4, V5, section 7 |
| Rounding per item: where chosen, what is stored | 4.3, 4.5 |
| Conversion: factor decimal string, exact arithmetic with explicit scale, order, round once, refusal vs rounding | 4.4 |
| Tolerance: absolute, where evaluated, outside tolerance | 4.6 |
| Wire format and exact sums, no float, aggregates through the strict path | 4.8, E9, T-Q11, T-Q12 |
| Security (untrusted inputs, Decimal DoS), INV-2/4/7/8 | section 7 |
| Amendments to the #2657 note; effect on #2658 | sections 8, 9 |
| Slicing, out of scope, open questions with defaults, customer input in plain language | sections 10, 12 |

## 14. Risks for CODE-DESIGN-VALIDATOR to attack first

1. 4.4 step 4: the claim that exact integer arithmetic on `coef` and `exp` is both feasible within the policy allowlist (only `Decimal` and `Policy` helpers) and consistent with the "explicit context" wording of the issue; the alternative (Decimal under `Context.with`) is rejected on the purity contract of T-PL-1, which lives in the unmerged #2657 note.
2. 4.1/V5: that a static registration `units` table plus command-supplied item-specific factors is an acceptable L1-L4 trust model, and that the `pack` dimension rule (4.4 step 3b) is neither too strict (blocks a legitimate kg -> m item) nor too loose.
3. 4.5: the CHECK `quantity = round(quantity, quantity_scale)` and the tolerance consistency CHECKs (do they hold for reversals, whose tolerance group is NULL; do they survive the `LIKE ... INCLUDING ALL` clone of `TenantTemplate`), and the digest change.
4. 4.6: refusal channel for `out_of_tolerance` through `invalid_posting` and `leg_no` only, versus MD-07's "require an exception"; the unverified `exception_ref`.
5. The amendments A1-A13 against a note that is still under review (the amendment text must be applied to revision 4 as it stands on PR #2873, which was not merged when this was written).
6. 4.8: the CSV exemption (A11) as a weakening of an injection control, justified by the canonical grammar.
7. Section 3/R3: practice citations are not verified at clause level (N7); the decision rests on the 0057 D4 ruling and standard decimal rounding semantics, not on vendor text.
