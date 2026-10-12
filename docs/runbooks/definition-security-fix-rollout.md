# Rolling out a security-fix definition version

Scope: a process definition version that fixes a separation-of-duties or other security gap
(for example `meridian_loan_origination` v1.14 to v1.15, Q-1048 / REQ-467). This is a runbook
rule, not a requirement. It was set by letflow-9a's advisory decision on Q-1050 (ISS-1050), recorded
by the meridian BA on 2026-10-12.

## The standing rule

1. **Deprecate the old version** when the fixed version is activated. In QA, activating the new
   version deprecates the old one.
2. **List the in-flight instances** that are at or before the affected nodes on the old version.
3. **The operator cancels or restarts those instances on the new version by a dated cutoff.**
   Instances are not migrated to a new graph in place. Rewiring a live case is itself a
   separation-of-duties risk, and REQ-373's version pinning covers catalog entries only.
4. **Production:** no definition version with a known separation-of-duties gap is activated there.
   The first production version of a loan process is the fixed one, so there is nothing to drain.
5. **QA:** cancel the test instances on the old version, or let them end, before the cutoff.

## Not covered by this runbook

A real graph migration of live instances is a new engine requirement with a decision record. The
SECURITY-REVIEWER and REVIEWER see it before design, not after.

## Related

- Decision: ISS-1050 / Q-1050 / GH #2394 (closed as decided).
- Worked example: REQ-467 / Q-1048 / GH #2390, `meridian_loan_origination` v1.14 to v1.15.
- Pending follow-up that will need this runbook: ISS-1051 / Q-1051 / GH #2395.
