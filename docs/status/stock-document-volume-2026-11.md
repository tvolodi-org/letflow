# Stock documents at volume: measured times (REQ-774, GH #3988)

Measured on the local test stack (never on QA) with `test/letflow/modules/stock/document_volume_test.exs`
(tag `:stock_document_volume`, excluded by default; run `MIX_TEST_PARTITION=<n> mix test --only stock_document_volume <file>`).
Three runs per size, milliseconds, median / max. Real HTTP path: save a draft, issue it, complete the posting task,
fetch the document, list one page of 50. The test asserts no target; a miss is recorded as measured.

| kind | lines | save | issue | post | fetch | list page of 50 |
|---|---|---|---|---|---|---|
| receipt | 100 | 839 / 865 | 241 / 279 | 207 / 213 | 15 / 18 | 8 / 8 |
| receipt | 500 | 5001 / 5640 | 1459 / 1531 | 816 / 816 | 33 / 39 | 6 / 7 |
| receipt | 1000 | 11741 / 12240 | 2347 / 3152 | 1647 / 1946 | 65 / 84 | 12 / 14 |
| transfer | 100 | 829 / 833 | 249 / 271 | 292 / 342 | 17 / 18 | 7 / 7 |
| transfer | 500 | 5852 / 6074 | 1417 / 1770 | 1736 / 1831 | 50 / 58 | 7 / 11 |
| transfer | 1000 | 11871 / 12817 | 3265 / 3725 | 3296 / 4315 | 107 / 116 | 11 / 12 |

A transfer of 1000 lines posts 2000 legs in one entry (4 INSERTs of at most 500 legs, one transaction).
Save time is the slowest step (one record per line); document writes run with a 120 s transaction bound.
Installed tenants need the tenant migration `20261106200001_raise_ledger_leg_cap` before they post above 200 legs.
