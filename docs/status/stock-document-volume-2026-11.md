# Stock documents at volume: measured times (REQ-774, GH #3988)

Measured on the local test stack (never on QA) with `test/letflow/modules/stock/document_volume_test.exs`
(tag `:stock_document_volume`, excluded by default; run `MIX_TEST_PARTITION=<n> mix test --only stock_document_volume <file>`).
Five runs per size (each on a fresh document), milliseconds, median / max. Real HTTP path: save a draft, issue it,
complete the posting task, fetch the document, list one page of 50. The test asserts no target; a miss is recorded as measured.

Environment: Intel Core i7-8700 @ 3.20 GHz, 12 logical CPUs; 62 GB memory (`free -g`); PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2,
the letflow-team container); commit 145db2a77 plus the `@runs 5` change of this task. The host is shared with other sessions.

| kind | lines | save | issue | post | fetch | list page of 50 |
|---|---|---|---|---|---|---|
| receipt | 100 | 896 / 959 | 266 / 316 | 206 / 216 | 16 / 24 | 7 / 8 |
| receipt | 500 | 5696 / 6030 | 1295 / 1411 | 858 / 887 | 44 / 49 | 8 / 8 |
| receipt | 1000 | 9626 / 11923 | 2698 / 2966 | 1558 / 2055 | 60 / 89 | 7 / 10 |
| transfer | 100 | 967 / 1003 | 323 / 343 | 365 / 385 | 21 / 22 | 8 / 10 |
| transfer | 500 | 4383 / 5473 | 1080 / 1462 | 1212 / 1437 | 41 / 57 | 6 / 10 |
| transfer | 1000 | 10943 / 12349 | 2640 / 3343 | 3296 / 3834 | 108 / 164 | 11 / 18 |

A transfer of 1000 lines posts 2000 legs in one entry (4 INSERTs of at most 500 legs, one transaction).
Save time is the slowest step (one record per line); document writes run with a 120 s transaction bound.
Installed tenants need the tenant migration `20261106200001_raise_posting_leg_cap` before they post above 200 legs.
