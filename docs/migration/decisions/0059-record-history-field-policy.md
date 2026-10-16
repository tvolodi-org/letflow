# 0059 -- Record history route with read-time redaction, and one shared FieldPolicy

Status: Accepted: ruled by the advisor session (letflow-ec) and relayed by the supervisor (letflow-supervisor-22) on 2026-10-16 under the user's delegation; written by letflow-2. The decision is made; the design record (REQ-516) works out the detail.

Related: 0051 (scope grants, D6 export scope filter), GH #2697 (restricted-field filter/sort on query and export), REQ-231 (field grants and restriction rows), decision 0054 (managed types), GH #2699 (aggregate join), GH #2700 (type access on join targets).

## Problem
Entity events carry `field_values`. Field restrictions (REQ-231) are applied to query results, records and exports, but there is no governed way to read the history of one record, and every other place that copies event `field_values` (audit entries, webhooks, outbound events, the dead-letter queue, `Response.public_event_payload`, event exports, logs) has its own rule or none. Each fix so far is route by route.

## Decision
1. **A record history route**: `GET /entities/:type/records/:id/history`. It applies `FieldGrants` and restriction rows to every event's `field_values`, and the 0051 scope filter to the record itself (a record outside the caller's scope is a 404 identical to a nonexistent one).
2. **Redaction at read time**, by the caller's CURRENT restrictions. Existing events are not rewritten. Consequence, stated plainly: if a restriction is removed later, history written while it applied becomes visible to a caller who can now read that field. This is accepted: history is a view of the record, not a separate secret store.
3. **One shared module `FieldPolicy`** with two entry points: `check_request` (the allow-list walker over a compiled request, used by #2697) and `redact` (for event payloads, records and exports). Routes do not carry their own field logic.
4. **Every consumer of event `field_values` is listed and covered** by the requirement: audit entries, webhooks, outbound events, the dead-letter queue, `Response.public_event_payload`, event exports, logs. Webhooks and outbound events come first, because they leave the system.
5. **The route is designed first** (REQ-516 is design-first, prio 2): the design record names the redaction point per consumer, whether a consumer is redacted per recipient or stored already-redacted, and the list of consumers found by reading the code, not from this record.

## Not decided here
- Per-consumer storage form (redact on write versus on read) for webhooks and outbound: the design record decides, with SECURITY-REVIEWER.
- The synthetic entity-type instance event leak through the Instances routes: a separate defect issue, filed after its reproducing test exists.

## Not verified
The consumer list above is the advisor's, relayed; it was not re-derived from the code for this record. The design record re-reads each consumer on main.
