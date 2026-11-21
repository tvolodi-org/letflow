# UAT run BP-MASTER-11

- run id: 20261121T071138Z-c2a137
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:11:38Z   duration: 8175 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: pass   cleanup: pass
- verdict: **PASS**

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-MASTER-11 | pass | pass | pass | 6668 |  |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-MASTER-11 | health | - | GET /health |  | pass | 333 |  |
| preflight | BP-MASTER-11 | tenant | - | GET / | 200 | pass | 341 |  |
| preflight | BP-MASTER-11 | token:storekeeper | storekeeper |  |  | pass | 461 |  |
| step | BP-MASTER-11 | s1 | storekeeper | POST /api/v1/modules/org/legal-entities | 403 | pass | 343 |  |
| step | BP-MASTER-11 | s2 | storekeeper | POST /api/v1/modules/org/sites | 403 | pass | 342 |  |
| step | BP-MASTER-11 | s3 | storekeeper | POST /api/v1/modules/org/units | 403 | pass | 345 |  |
| step | BP-MASTER-11 | s4 | storekeeper | PATCH /api/v1/modules/org/units/00000000-0000-0000-0000-000000000000 | 403 | pass | 359 |  |
| step | BP-MASTER-11 | s5 | storekeeper | POST /api/v1/modules/org/units/00000000-0000-0000-0000-000000000000/retire | 403 | pass | 347 |  |
| step | BP-MASTER-11 | s6 | storekeeper | POST /api/v1/modules/org/positions | 403 | pass | 341 |  |
| step | BP-MASTER-11 | s7 | storekeeper | POST /api/v1/modules/org/employees | 403 | pass | 362 |  |
| step | BP-MASTER-11 | s8 | storekeeper | POST /api/v1/modules/org/employees/00000000-0000-0000-0000-000000000000/transfer | 403 | pass | 362 |  |
| step | BP-MASTER-11 | s9 | storekeeper | POST /api/v1/modules/locations/nodes | 403 | pass | 371 |  |
| step | BP-MASTER-11 | s10 | storekeeper | POST /api/v1/modules/locations/nodes/00000000-0000-0000-0000-000000000000/move | 403 | pass | 344 |  |
| step | BP-MASTER-11 | s11 | storekeeper | POST /api/v1/modules/locations/links | 403 | pass | 351 |  |
| step | BP-MASTER-11 | s12 | storekeeper | POST /api/v1/modules/locations/links/retire | 403 | pass | 338 |  |
| step | BP-MASTER-11 | s13 | storekeeper | POST /api/v1/modules/catalog_items/lots | 403 | pass | 346 |  |
| step | BP-MASTER-11 | s14 | storekeeper | POST /api/v1/modules/catalog_items/lots/00000000-0000-0000-0000-000000000000/retire | 403 | pass | 351 |  |
| step | BP-MASTER-11 | s15 | storekeeper | POST /api/v1/modules/codes/receive | 403 | pass | 353 |  |
| step | BP-MASTER-11 | s16 | storekeeper | POST /api/v1/modules/codes/00000000-0000-0000-0000-000000000000/assign | 403 | pass | 353 |  |
| step | BP-MASTER-11 | s17 | storekeeper | POST /api/v1/modules/codes/00000000-0000-0000-0000-000000000000/value | 403 | pass | 355 |  |
| step | BP-MASTER-11 | s18 | storekeeper | POST /api/v1/modules/codes/resolve | 404 | pass | 357 |  |
| step | BP-MASTER-11 | s19 | storekeeper | POST /api/v1/modules/codes/labels | 422 | pass | 348 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T071138Z-c2a137",
  "now_utc": "2026-11-21T07:11:38Z"
}
```

