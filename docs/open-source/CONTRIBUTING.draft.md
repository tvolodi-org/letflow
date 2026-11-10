# Contributing to Letflow (DRAFT)

> DRAFT for review by a lawyer; not legal advice; not in force. Who may contribute at all is
> pending the owner's answer to Q3 in `docs/uat/ba-decisions/T-1521.md`. It moves to the repository
> root as `CONTRIBUTING.md` at switch-on, and the switch-on waits for the clean-up and history step of T-1599 (see
> `README.md`, section 4).

## A. How to contribute

1. Open an issue first for anything larger than a typo; say what you want to change and why.
2. One pull request per issue, small and focused. Title: `type(GH #N): subject`.
3. Run the checks that cover your change (`mix letflow.check.static`, the tests of the touched
   modules; for `web/` the project's `npm run check` in CI). A bug fix comes with a test that fails
   without the fix.
4. Never include secrets, customer data or real personal data in code, tests, fixtures or issues.
   Security problems go to the private address in `SECURITY.md`, not to a public issue.
5. Follow the security invariants in `docs/agents/instructions/security-invariants.md` (tenant
   isolation first).
6. Each source file you add carries the header `SPDX-License-Identifier: MIT`.

## B. Developer Certificate of Origin (DCO) sign-off

The licence is MIT (owner decision D-116). By contributing you agree to the Developer Certificate
of Origin 1.1 (https://developercertificate.org/): you wrote the change or have the right to submit
it under the project's licence. Show it by signing off every commit:

```
git commit -s -m "fix(GH #123): short subject"
# adds: Signed-off-by: Your Name <your-real-address>
```

A CI check rejects a pull request with an unsigned commit. Your contribution is licensed under the
repository licence (MIT); the project may include it in other builds, including closed ones,
keeping the notices. No CLA and no paperwork beyond the sign-off. (MIT has no patent grant; the
sign-off is the contributor's statement of the right to submit.)

## C. Conduct

A code of conduct (for example Contributor Covenant) is proposed; the contact address is the owner's choice.
