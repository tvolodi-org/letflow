# Orphans of the stock area (D-169)

Items of `python3 scripts/uat/bp_inventory.py stock` that no business process uses. Not deleted and not judged here: the owner sees this list.

| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
| Letflow.Modules.Stock.FreezeGuard.hook | lib/letflow/modules/stock/freeze_guard.ex:110 | the test seam of the freeze guard: reads app env `:stock_freeze_test_hook` (nil in production) and, when a test set it, holds the calling process at a named point (`:open_locked`, `:guard_checked`) until the test says go or fail | REQ-765 / GH #3906 (module doc "Test seam" of freeze_guard.ex; `git log -S stock_freeze_test_hook` shows its introduction with the freeze) | lets the lock-order tests of the count freeze force a race deterministically (test/letflow/modules/stock/count_freeze_lock_test.exs) | keep as a platform function |
