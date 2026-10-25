# UAT scope: permanent exclusions

Scenarios that stay in the repository as a record but are not part of a run, with the reason.
Written by the BA for GH #3223 (T-0532). A scenario listed here is reported EXCLUDED, not BLOCKED
and not PASS; a runner does not execute it and does not run its seed steps.

## swiftroute/first-login-administrator-binding.yaml (id swiftroute-first-login-administrator-binding)

- Reason: the scenario needs a company whose administrator grant is still open and an administrator
  account whose e-mail address is not yet verified. The seeded swiftroute company has neither:
  actor-swiftroute-alice already holds TENANT_ADMIN with a verified address (roster
  `test/fixtures/uat/actors.yaml`), and the company cannot be registered again (a registered company
  can only be deactivated). The condition can never become true in swiftroute. It reported BLOCKED in
  runs T-0295 and T-0521.
- Why not move it: a dedicated account for it would be a new roster actor, which the BA does not
  invent. Its two sides are already covered where a freshly registered company and an unverified
  account exist: the foundation group, `platform/foundation-3-administrator-first-sign-in.yaml`
  (verified address binds, once) and `platform/foundation-4b-refusal-unconfirmed-email-does-not-bind.yaml`
  (unverified address does not bind), and `platform/first-login-admin-binding.yaml`.
- Safety: the scenario's cleanup no longer runs the verification seed with "false" for Alice. Running
  that would have left her unverified and broken the other swiftroute scenarios.
- Review: reopen only if the roster gains a dedicated not-yet-bound account in a freshly registered
  company, decided by the process owner.

Decision for UAT only; the process owner configures production.
