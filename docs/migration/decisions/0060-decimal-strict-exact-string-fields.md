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
4. Changing the flag on an existing field: `false->true` is allowed as a new definition version and rewrites nothing (legacy numbers are rendered as padded strings on read); `true->false` is refused at activation when the type has any record, allowed on an empty type.
5. A decimal-field bound (`min`/`max`) may be a JSON number or a decimal string (definition time only).
6. WMS (REQ-504) declares `decimal_strict: true` on its quantity fields.

## Why not always-string
Making every decimal field string-typed would break shipped code that reads decimals as numbers: the exam module's definitions (`priv/modules/exam/entity_definitions`: `passing_score_pct`, `score_pct`, `likert_weight`, `score`/`max_score`) are written as computed floats (`Exam.Session`, e.g. 66.6666) and read by `to_float/1` helpers (`session.ex`, `certificate.ex`, `certificate_public_projection.ex`) that have no binary clause; about 33 test definitions and the SPA's number inputs and `parseFloat` filters assume numbers; existing tenants hold stored numbers and number-typed integrations. Rewriting those is a larger, riskier change than the WMS need.

## Migration path
Non-strict fields stay legacy and are documented as such (lossy floats, no scale enforcement). A later change of the default is a SEPARATE decision and is explicitly not part of this work.

## Managed types
`ManifestHash` does not hash entity-definition content, so a flag change alone does not change a module's manifest hash. A module that flips the flag in its shipped pack must bump its manifest `:version` (hashed) in the same release; that changes the hash, and in-flight handler tasks then refuse per the OQ-R3 pilot limit.

## Not decided here
Adding strict-field names to the manifest-hash surface; strict-field input widgets in the SPA and mobile app; per-unit-of-measure scale (the module's handler narrows within the field scale); the record-history route's use of the shared decoder (its own design, REQ-516).
