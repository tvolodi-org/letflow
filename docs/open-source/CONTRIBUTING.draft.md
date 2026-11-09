# Contributing to Letflow (DRAFT)

> DRAFT for review by a lawyer; not legal advice; not in force. Who may contribute at all is
> pending the owner's answer to Q3 in `docs/uat/ba-decisions/T-1521.md`. It moves to the repository
> root as `CONTRIBUTING.md` at switch-on, keeping **one** of the two sections B1/B2 (the one that
> matches the chosen licence).

## A. How to contribute (both paths)

1. Open an issue first for anything larger than a typo; say what you want to change and why.
2. One pull request per issue, small and focused. Title: `type(GH #N): subject`.
3. Run the checks that cover your change (`mix letflow.check.static`, the tests of the touched
   modules; for `web/` the project's `npm run check` in CI). A bug fix comes with a test that fails
   without the fix.
4. Never include secrets, customer data or real personal data in code, tests, fixtures or issues.
   Security problems go to the private address in `SECURITY.md`, not to a public issue.
5. Follow the security invariants in `docs/agents/instructions/security-invariants.md` (tenant
   isolation first).
6. Each source file you add carries the SPDX header of the chosen licence.

## B1. If the licence is Apache-2.0: Developer Certificate of Origin (DCO)

By contributing you agree to the Developer Certificate of Origin 1.1 (https://developercertificate.org/):
you wrote the change or have the right to submit it under the project's licence. Show it by signing
off every commit:

```
git commit -s -m "fix(GH #123): short subject"
# adds: Signed-off-by: Your Name <your-real-address>
```

A CI check rejects a pull request with an unsigned commit. Under Apache-2.0 section 5 your
contribution is licensed under the same licence (Apache-2.0) unless you state otherwise; the project
may include it in other builds, including closed ones, keeping the notices. No paperwork beyond the sign-off.

## B2. If the licence is AGPL-3.0 (dual licence): Contributor Licence Agreement (CLA)

Contributions come under AGPL-3.0 only if the project may also offer them under a commercial
licence; that needs a CLA signed before the first pull request is merged. The agreement text is for
a lawyer to write; the outline:

- You keep your copyright.
- You grant the project owner a perpetual, worldwide, non-exclusive, irrevocable licence to use,
  modify, sublicense and relicense your contribution, including under proprietary terms.
- You confirm you have the right to grant it (employer permission where needed) and that the work is yours.
- Patent licence for your contribution, as in Apache-2.0 section 3.
- A bot checks the signature on each pull request.
- Adding a CLA later means asking every earlier contributor: do it from day one.

## C. Conduct

A code of conduct (for example Contributor Covenant) is proposed; the contact address is the owner's choice.
