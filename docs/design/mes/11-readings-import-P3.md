# MES proof P3: readings with a source, and one file import

Task T-1831, 2026-11-13. Plan: `07-roadmap-and-pilot.md` section 4.3 (P3), `02-liquid-streams-options.md` (readings: manual,
files, live), `05-platform-options.md` section 8 point 3. Owner go after P1 (D-123). Limits: D-122. Simple English on purpose.

## 1. Result in one line

**PASS.** In test code only, in a throwaway test tenant: a reading record with a source field was held in a proof table, one
CSV file import loaded readings, refused bad rows with a reason, was safe to repeat, and never touched the stock ledger. 7 200 raw
one-second samples ended as 8 stored aggregates (900 to 1). A mass balance sketch for one tank showed the difference, and posted nothing.
No core change was needed.

Rule used: PASS = import tests I1..I10, raw-outside tests R1..R4 and mass balance tests M1..M4 green, and no change in `lib/`,
`priv/` or `config/`. PARTIAL = a step needed a workaround that changes the plan. FAIL = a ledger write by the import, or raw data stored.
Numbers from the final run: `mix test test/letflow/proof/mes_p3` gave `Result: 20 passed` (3 files, 20 tests; some IDs share a test).

## 2. What was built (all removable)

All names are `MesP3`. Remove everything with:
`git rm -r test/support/mes_p3 test/letflow/proof/mes_p3 docs/design/mes/11-readings-import-P3.md`.

| Part | Where | Verified / guess |
|---|---|---|
| Tables `proof_reading`, `proof_import` (test DDL in a committed test tenant, not a migration) | `test/support/mes_p3/readings.ex` | verified (tests run it) |
| One CSV importer, header `equipment,kind,quantity,unit,measured_at,quality` | `test/support/mes_p3/csv_import.ex` | verified |
| Aggregator (stand-in for the plant export job) | `test/support/mes_p3/aggregate.ex` | verified |
| Mass balance sketch (read only) | `test/support/mes_p3/mass_balance.ex` | verified |
| 20 tests | `test/letflow/proof/mes_p3/` | verified |

A reading holds: equipment code (tank or meter), kind (`level` or `flow_total`), quantity with unit `kg` or `l`, time (UTC),
source (`manual`, `file`, `historian`), quality (`good`, `uncertain`, `bad`), and for an aggregate the number of samples behind it.

## 3. The import (tests I1..I10)

| Claim | Test | Status |
|---|---|---|
| A reading keeps all fields; the table refuses a bad unit, source or quality | I1, I2 | verified |
| A 10-row file loads 10 readings, source `file`, one import id | I3 | verified |
| BOM, CRLF, quoted fields are accepted | I3b | verified |
| Each bad row gets its reason with line and raw text; good rows still load. Reasons: `wrong_column_count`, `empty_equipment`, `bad_kind`, `bad_quantity` (negative, more than 3 decimals, decimal comma), `bad_unit`, `bad_time` (no offset, or more than 24 h in the future), `bad_quality`, `too_dense` | I4 | verified |
| Whole-file refusal writes nothing: `empty_file`, `bad_header`, `unexpected_column` (a `source` column), `not_utf8`, `too_large` (over 1 MB or 10 000 rows) | I5 | verified |
| Same bytes twice: second import is `already_imported`, nothing written | I6 | verified |
| Overlapping file loads only new rows (4 new, 6 duplicates); a re-ordered file loads 0; a duplicate inside one file is a duplicate, not a rejection | I7 | verified |
| The import never writes to the stock ledger: ledger table counts equal before and after, also after a failed (rolled back) import; source of the four support files names no ledger writer | I8, I9 | verified |
| A second tenant sees none of the first tenant's readings | I10 | verified |

Idempotency has two layers: the hash of the file bytes, and a unique key (source plus a hash of the normalised row). The file is
written in one transaction; a forced failure after 3 rows left no partial import (the I8 rollback branch).

## 4. Raw data stays outside the core (tests R1..R4)

The importer cannot tell raw from aggregate by looking at a value, so two controls are used (both are guesses at policy, not a security boundary):

1. **Density cap**: at most 4 readings per equipment, kind and clock hour (so 15-minute aggregates pass, one-second or one-minute samples do not).
   It counts the file and what is already stored. The value 4 is a proof constant (guess); the real value is a plant decision.
2. **Aggregate first**: the plant export job (here `Aggregate.bucket/2`) sends aggregates with min, max, average, last, count.

Numbers (verified): 7 200 simulated 1 Hz level samples (2 hours) became 8 quarter-hour aggregates of 900 samples each (R1, bucket 0 checked
by hand: min 1000, max 1012, last 1001, average 1005.989). Imported as a raw CSV, 7 192 rows were refused at parse and the other 8
by the aggregates already stored for those hours (R3); into an empty tenant the raw file stored 8 rows and refused 7 192 (R2). Stored
after aggregates: 8 rows (900 to 1), `agg_count` sums to 7 200 (R4). The tenant has no table that holds a per-second series
(only `proof_import` and `proof_reading`).

Limit, said plainly: a client can still send 4 noisy rows per hour. The cap keeps volume small; it does not prove the values are meaningful.

## 5. Mass balance sketch for one tank (tests M1..M4)

For tank TK-101 in a window: `in` = change of the inlet meter total, `out` = change of the outlet meter total, `change` = level at end minus
level at start, `expected_change = in - out`, `difference = change - expected_change`. Verified: a balanced window gives difference 0 (in 300,
out 200, change 100); a loss window shows -5.000 kg and states no cause (M1, M2). A meter total that goes down (reset), a litre level
(no density in the proof), an empty window, or fewer than two level readings give no difference and a note or error, never a guess (M3).
Bad-quality readings are dropped, uncertain ones are noted, and for the same time `file` beats `historian` beats `manual` (M3b, a guess at the rule).
The sketch only reads. Ledger counts are equal before and after (M4).

## 6. What would need a core change (design notes only, none built)

D-122 forbids these in this proof. They are notes for phase 1, all guesses until the owner decides:

- A real reading table and equipment link, as a migration with a flag (here tank is a text code).
- An import route with a credential, and a scheduled import; today the file importer is test code.
- The density cap as a setting per tenant and equipment (here a constant of 4).
- `kg` and `l` conversion by item density (here a litre level is refused).
- A mapping table from tank to its meters (here an argument).
- A rule for who may turn a mass balance difference into a ledger posting (here nothing posts; the proof stops at showing it).

## 7. Limits of this proof

- Line numbers in a reject list are record numbers; a quoted field with a line break would shift them (guess: acceptable for plant exports).
- Row cap is 10 000 (the design said 5 000; 7 200 raw samples needed a file the cap could look at, so it was raised). A guess.
- Test-only: no HTTP route, no engine path, no real tenant, no flag. Nothing on QA, production or demo.
- Shared test cluster: any `admin_shutdown` or `TenantSchemaReaper` warning in the log comes from sibling runs, not from this change.
