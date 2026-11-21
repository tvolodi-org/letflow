# UAT run BP-MASTER-13

- run id: 20261121T071146Z-d29e57
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:11:46Z   duration: 6067 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: pass   cleanup: pass
- verdict: **PASS**

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-MASTER-13 | pass | pass | pass | 4653 |  |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-MASTER-13 | health | - | GET /health |  | pass | 323 |  |
| preflight | BP-MASTER-13 | tenant | - | GET / | 200 | pass | 335 |  |
| preflight | BP-MASTER-13 | token:admin | admin |  |  | pass | 405 |  |
| step | BP-MASTER-13 | s1 | admin | POST /api/v1/modules/locations/nodes | 422 | pass | 358 |  |
| step | BP-MASTER-13 | s2 | admin | POST /api/v1/modules/locations/nodes | 422 | pass | 345 |  |
| step | BP-MASTER-13 | s3 | admin | POST /api/v1/modules/locations/nodes | 422 | pass | 351 |  |
| step | BP-MASTER-13 | s4 | admin | PATCH /api/v1/modules/locations/nodes/00000000-0000-0000-0000-000000000000 | 404 | pass | 1366 |  |
| step | BP-MASTER-13 | s5 | admin | POST /api/v1/modules/locations/nodes/00000000-0000-0000-0000-000000000000/move | 422 | pass | 356 |  |
| step | BP-MASTER-13 | s6 | admin | POST /api/v1/modules/org/units/00000000-0000-0000-0000-000000000000/retire | 404 | pass | 357 |  |
| step | BP-MASTER-13 | s7 | admin | POST /api/v1/modules/codes/receive | 422 | pass | 343 |  |
| step | BP-MASTER-13 | s8 | admin | POST /api/v1/modules/locations/nodes | 201 | pass | 388 |  |
| step | BP-MASTER-13 | s9 | admin | POST /api/v1/modules/locations/nodes | 409 | pass | 389 |  |
| cleanup | BP-MASTER-13 | c1 | admin | POST /api/v1/modules/locations/nodes/7bfc988b-d5db-4a55-bed4-bb5a98b33d0f/retire | 200 | pass | 400 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T071146Z-d29e57",
  "now_utc": "2026-11-21T07:11:46Z",
  "node_y": "7bfc988b-d5db-4a55-bed4-bb5a98b33d0f"
}
```

