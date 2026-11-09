# CI and the merge queue

## Runner images are pinned

Every job in `.github/workflows/` runs on `ubuntu-24.04`, not `ubuntu-latest` (T-1566).

Why: GitHub moved `ubuntu-latest` to `ubuntu-26.04`. Playwright has no Chromium build for it
(`Playwright does not support chromium on ubuntu26.04-x64`), so `Stock browser e2e (playwright)` failed
in merge groups and each failure ejected the whole group, although CI had passed.

When changing the image, move all workflows together and run the stock e2e job on the new image first.
