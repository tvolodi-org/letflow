# UAT run BP-DESIGNER-26

- run id: 20261121T072249Z-b27343
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:22:49Z   duration: 2503 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: pass   cleanup: pass
- verdict: **PASS**

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-DESIGNER-26 | pass | pass | pass | 1048 |  |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-DESIGNER-26 | health | - | GET /health |  | pass | 353 |  |
| preflight | BP-DESIGNER-26 | tenant | - | GET / | 200 | pass | 337 |  |
| preflight | BP-DESIGNER-26 | token:admin | admin |  |  | pass | 411 |  |
| step | BP-DESIGNER-26 | s1 | admin | GET /api/v1/definitions/00000000-0000-0000-0000-000000000000 | 404 | pass | 366 |  |
| step | BP-DESIGNER-26 | s2 | admin | POST /api/v1/definitions/00000000-0000-0000-0000-000000000000/activate | 404 | pass | 340 |  |
| step | BP-DESIGNER-26 | s3 | admin | DELETE /api/v1/definitions/00000000-0000-0000-0000-000000000000 | 404 | pass | 342 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T072249Z-b27343",
  "now_utc": "2026-11-21T07:22:49Z"
}
```

