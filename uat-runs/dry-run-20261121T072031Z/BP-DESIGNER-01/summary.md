# UAT run BP-DESIGNER-01

- run id: 20261121T072031Z-a36657
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:20:31Z   duration: 127324 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: FAIL   cleanup: pass
- verdict: **FAIL**

> **FIRST FAILING STEP: BP-DESIGNER-01 step s6** - expected 409 got 200

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-DESIGNER-01 | FAIL | FAIL | pass | 2601 | s6: expected 409 got 200 |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-DESIGNER-01 | health | - | GET /health |  | pass | 418 |  |
| preflight | BP-DESIGNER-01 | stable | - |  |  | pass | 123207 |  |
| preflight | BP-DESIGNER-01 | tenant | - | GET / | 200 | pass | 330 |  |
| preflight | BP-DESIGNER-01 | token:admin | admin |  |  | pass | 392 |  |
| step | BP-DESIGNER-01 | s1 | admin | POST /api/v1/definitions | 201 | pass | 343 |  |
| step | BP-DESIGNER-01 | s2 | admin | POST /api/v1/definitions/8d306971-7515-40c9-b86d-ba9cee8d9593/validate | 200 | pass | 358 |  |
| step | BP-DESIGNER-01 | s3 | admin | PUT /api/v1/definitions/8d306971-7515-40c9-b86d-ba9cee8d9593 | 200 | pass | 465 |  |
| step | BP-DESIGNER-01 | s4 | admin | GET /api/v1/definitions/8d306971-7515-40c9-b86d-ba9cee8d9593 | 200 | pass | 341 |  |
| step | BP-DESIGNER-01 | s5 | admin | POST /api/v1/definitions/8d306971-7515-40c9-b86d-ba9cee8d9593/activate | 200 | pass | 363 |  |
**>>** | step | BP-DESIGNER-01 | s6 | admin | POST /api/v1/definitions/8d306971-7515-40c9-b86d-ba9cee8d9593/activate | 200 | **FAIL** | 364 | expected 409 got 200 |
| step | BP-DESIGNER-01 | s7 | admin |  |  | skipped | 0 | an earlier step failed |
| step | BP-DESIGNER-01 | s8 | admin |  |  | skipped | 0 | an earlier step failed |
| cleanup | BP-DESIGNER-01 | c1 | admin | DELETE /api/v1/definitions/8d306971-7515-40c9-b86d-ba9cee8d9593 | 200 | pass | 367 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T072031Z-a36657",
  "now_utc": "2026-11-21T07:20:31Z",
  "version": "1.0.0",
  "def_id": "8d306971-7515-40c9-b86d-ba9cee8d9593",
  "def_name": "uat-designer-20261121T072031Z-a36657"
}
```

