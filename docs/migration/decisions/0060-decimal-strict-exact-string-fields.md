# 0060 -- Exact decimal strings on entity fields: an opt-in per field (`decimal_strict`)

Status: Accepted: shape ruled by the coordinator (backward compatibility first) and approved by the supervisor on 2026-10-17; written by CODE-DESIGNER for GH #2654. Registered in the docs index by letflow-2 in the usual docs PR.

Date: 2026-10-17

Related: 0057 D4 (exact decimal quantity, a string on the wire; this record amends it), 0056 (decimal strings in versioned documents), 0054 (managed types), 0055 (module upgrade), 0059 (record history). Design: `lib/letflow/design/gh2654-decimal-exact-strings.md`.

## Problem
A `:decimal` entity field takes a JSON number on the wire (`{"type":"number"}`), which is a float after the body decode: values are lossy, `2.50` and `2.5` are the same, `decimal_scale` is not enforced on write, and a decimal string is refused. The WMS ledger (0057 D4, REQ-504) needs exact quantities as strings with enforced scale.

## Decision
1. A new optional boolean key `decimal_strict` (default false) on `:decimal` field definitions. It is carried through every place that carries `decimal_precision` and `decimal_scale`.
2. Fields **with** `decimal_strict: true`: a write accepts a canonical decimal string or a JSON integer and refuses every JSON float; the scale and precision are enforced (422 with the field path, constraints `scale` and `precision`, never rounded); `min`/`max`/`non_negative` are compared exactly with `Decimal`; the stored, event, response and read form is the canonical scale-padded string; filters coerce literals to `Decimal`; aggregates are padded to the field scale. In-process readers get the same string; `Decimals.to_decimal/1` is the shared helper.
3. Fields **without** the flag: unchanged in every respect (JSON numbers accepted and returned, no new scale enforcement, no rounding change).
4. The flag is **immutable once the entity type has any record** (any row in the latest-record table, including soft-deleted): a change of `decimal_strict` on a decimal field, in either direction, is refused at definition activation with HTTP 409; it is allowed on an empty type. Legacy numbers therefore never coexist with a strict flag; WMS declares the flag from its first definition. A module pack that would adopt tenant rows (stamp adoption) must match the row's strictness field by field, otherwise the type is a conflict.
5. A `min`/`max` bound on a strict decimal field may be a JSON number or a decimal string; on a non-strict field it must be a number as today.
6. WMS (REQ-504) declares `decimal_strict: true` on its quantity fields.

## Write-side recheck: the one behaviour change for tenants that do not use the flag
The immutability rule is only sound if every writer re-validates under the type's sequence lock. `command_multi` already did (`:recheck_definition`). `create_record`, `update_record` and `delete_record` (all through `append_command/4`) now do too: after the sequence-lock step and before the projection upsert they re-resolve the active definition and refuse `{:definition_changed, type}` (HTTP 409, "entity definition changed during the write; retry") when it is not the one the write was validated against; nothing is appended and a retry is safe. This is unconditional, so it is also the single narrow change for tenants that never set `decimal_strict`: a record write that overlaps ANY activation of its type returns 409 instead of committing under the old definition (the same outcome `command_multi` already gives a process step). No other behaviour of a non-strict tenant changes in this work.

## Why not always-string

Making every decimal field string-typed would break shipped code that reads decimals as numbers: the exam module's definitions (`priv/modules/exam/entity_definitions`: `passing_score_pct`, `score_pct`, `likert_weight`, `score`/`max_score`) are written as computed floats (`Exam.Session`, e.g. 66.6666) and read by `to_float/1` helpers (`session.ex`, `certificate.ex`, `certificate_public_projection.ex`) that have no binary clause; about 33 test definitions and the SPA's number inputs and `parseFloat` filters assume numbers; existing tenants hold stored numbers and number-typed integrations. Rewriting those is a larger, riskier change than the WMS need.

## Migration path
Non-strict fields stay legacy and are documented as such (lossy floats, no scale enforcement). A later change of the default is a SEPARATE decision and is explicitly not part of this work.

## Managed types
`ManifestHash` does not hash entity-definition content, so a flag change alone does not change a module's manifest hash. A module that flips the flag in its shipped pack must bump its manifest `:version` (hashed) in the same release; that changes the hash, and in-flight handler tasks then refuse per the OQ-R3 pilot limit.

## Obligation on the future module-upgrade planner (0055)
The 0055 upgrade path is not built (module install on main is first-install only). When it is built, its planner MUST refuse a `decimal_strict` change on an entity type that has records at PLAN time, surface the 409-shaped reason in the upgrade journal and run report to the tenant admin (permission `:ModulesManage`), and never start the upgrade. The activation gate (`activate_definition/4`, evaluated before any activation is committed, under the type's sequence lock) stays as a backstop.

## Not decided here
Adding strict-field names to the manifest-hash surface; strict-field input widgets in the SPA and mobile app; per-unit-of-measure scale (the module's handler narrows within the field scale); the record-history route's use of the shared decoder (its own design, REQ-516).
