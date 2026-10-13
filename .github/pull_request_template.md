## Checklist (fill in; delete lines that do not apply)
- [ ] Overlap check done: open issues + open PRs' changed files + main
- [ ] CI-shaped local run done (files staged, `MIX_TEST_PARTITION` exported)
- [ ] Any CI failure: failure class (flake/defect/infra) + whether it repeated (repeat = defect)
- [ ] INV-10 cross-tenant negative test attached (if a platform-scope route, or a tenant-scope route that takes a tenant identifier, is touched)
- [ ] New env vars / dependencies / feature flags listed (new flags default off)
- [ ] Work item identified by its GH issue number in the title or body: `Closes #N` only if this PR fully resolves it, otherwise `Refs #N` plus a new linked issue for the residual
- [ ] Status-index `entries:` counter bumped (if requirement statuses flipped)
