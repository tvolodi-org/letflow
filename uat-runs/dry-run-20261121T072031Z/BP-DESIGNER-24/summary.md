# UAT run BP-DESIGNER-24

- run id: 20261121T072238Z-b9a5e2
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:22:38Z   duration: 10734 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: pass   cleanup: pass
- verdict: **PASS**

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-DESIGNER-24 | pass | pass | pass | 8885 |  |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-DESIGNER-24 | health | - | GET /health |  | pass | 341 |  |
| preflight | BP-DESIGNER-24 | tenant | - | GET / | 200 | pass | 352 |  |
| preflight | BP-DESIGNER-24 | token:admin | admin |  |  | pass | 386 |  |
| preflight | BP-DESIGNER-24 | token:storekeeper | storekeeper |  |  | pass | 397 |  |
| step | BP-DESIGNER-24 | s1 | storekeeper | POST /api/v1/definitions | 403 | pass | 343 |  |
| step | BP-DESIGNER-24 | s2 | storekeeper | POST /api/v1/entities/definitions | 403 | pass | 5430 |  |
| step | BP-DESIGNER-24 | s3 | storekeeper | POST /api/v1/script-rules/uat-none/versions | 403 | pass | 364 |  |
| step | BP-DESIGNER-24 | s4 | storekeeper | PUT /api/v1/script-policy/kill-switch | 403 | pass | 352 |  |
| step | BP-DESIGNER-24 | s5 | storekeeper | POST /api/v1/webhooks/subscriptions | 403 | pass | 349 |  |
| step | BP-DESIGNER-24 | s6 | storekeeper | POST /api/v1/dlq/00000000-0000-0000-0000-000000000000/retry | 403 | pass | 336 |  |
| step | BP-DESIGNER-24 | s7 | storekeeper | POST /api/v1/promotions | 403 | pass | 345 |  |
| step | BP-DESIGNER-24 | s8 | storekeeper | GET /api/v1/definitions | 403 | pass | 344 |  |
| step | BP-DESIGNER-24 | s9 | storekeeper | GET /api/v1/entities/definitions | 200 | pass | 557 |  |
| step | BP-DESIGNER-24 | s10 | admin | GET /api/v1/definitions | 200 | pass | 465 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T072238Z-b9a5e2",
  "now_utc": "2026-11-21T07:22:38Z"
}
```

