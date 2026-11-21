# UAT run BP-MASTER-04

- run id: 20261121T070918Z-dee3f9
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:09:18Z   duration: 129524 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: pass   cleanup: pass
- verdict: **PASS**

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-MASTER-04 | pass | pass | pass | 4787 |  |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-MASTER-04 | health | - | GET /health |  | pass | 360 |  |
| preflight | BP-MASTER-04 | stable | - |  |  | pass | 123205 |  |
| preflight | BP-MASTER-04 | tenant | - | GET / | 200 | pass | 327 |  |
| preflight | BP-MASTER-04 | token:admin | admin |  |  | pass | 410 |  |
| step | BP-MASTER-04 | s1 | admin | POST /api/v1/modules/locations/nodes | 201 | pass | 452 |  |
| step | BP-MASTER-04 | s2 | admin | POST /api/v1/modules/locations/nodes | 201 | pass | 379 |  |
| step | BP-MASTER-04 | s3 | admin | PATCH /api/v1/modules/locations/nodes/5d16b19a-7733-48a7-b97e-ebe36d3f5d71 | 200 | pass | 379 |  |
| step | BP-MASTER-04 | s4 | admin | POST /api/v1/modules/locations/nodes/bab5b0c7-e63b-4562-aa79-bd3f7c0c80fe/retire | 422 | pass | 364 |  |
| step | BP-MASTER-04 | s5 | admin | POST /api/v1/modules/locations/nodes/5d16b19a-7733-48a7-b97e-ebe36d3f5d71/move | 200 | pass | 1049 |  |
| step | BP-MASTER-04 | s6 | admin | POST /api/v1/modules/locations/nodes/5d16b19a-7733-48a7-b97e-ebe36d3f5d71/retire | 200 | pass | 746 |  |
| step | BP-MASTER-04 | s7 | admin | POST /api/v1/modules/locations/nodes/bab5b0c7-e63b-4562-aa79-bd3f7c0c80fe/retire | 200 | pass | 618 |  |
| cleanup | BP-MASTER-04 | c1 | admin | POST /api/v1/modules/locations/nodes/5d16b19a-7733-48a7-b97e-ebe36d3f5d71/retire | 200 | pass | 343 |  |
| cleanup | BP-MASTER-04 | c2 | admin | POST /api/v1/modules/locations/nodes/bab5b0c7-e63b-4562-aa79-bd3f7c0c80fe/retire | 200 | pass | 457 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T070918Z-dee3f9",
  "now_utc": "2026-11-21T07:09:18Z",
  "node_a": "bab5b0c7-e63b-4562-aa79-bd3f7c0c80fe",
  "node_b": "5d16b19a-7733-48a7-b97e-ebe36d3f5d71"
}
```

