# UAT run BP-MASTER-09

- run id: 20261121T071127Z-d214af
- tenant: qoimeks-qa2   base url: https://qoimeks-qa2.letflow.qa.bizdala.com
- started: 2026-11-21T07:11:27Z   duration: 11109 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc
- steps: pass   cleanup: pass
- verdict: **PASS**

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|
| BP-MASTER-09 | pass | pass | pass | 4133 |  |

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-MASTER-09 | health | - | GET /health |  | pass | 343 |  |
| preflight | BP-MASTER-09 | tenant | - | GET / | 200 | pass | 5447 |  |
| preflight | BP-MASTER-09 | token:admin | admin |  |  | pass | 406 |  |
| preflight | BP-MASTER-09 | token:storekeeper | storekeeper |  |  | pass | 419 |  |
| step | BP-MASTER-09 | s1 | admin | POST /api/v1/modules/locations/nodes | 201 | pass | 397 |  |
| step | BP-MASTER-09 | s2 | admin | POST /api/v1/modules/codes/receive | 201 | pass | 424 |  |
| step | BP-MASTER-09 | s3 | admin | POST /api/v1/modules/codes/884b8b1a-6c06-4dee-ad59-afcddd4cbcc6/assign | 200 | pass | 387 |  |
| step | BP-MASTER-09 | s4 | storekeeper | POST /api/v1/modules/codes/resolve | 200 | pass | 342 |  |
| step | BP-MASTER-09 | s5 | admin | POST /api/v1/modules/codes/884b8b1a-6c06-4dee-ad59-afcddd4cbcc6/release | 200 | pass | 391 |  |
| step | BP-MASTER-09 | s6 | admin | POST /api/v1/modules/codes/884b8b1a-6c06-4dee-ad59-afcddd4cbcc6/value | 200 | pass | 374 |  |
| step | BP-MASTER-09 | s7 | admin | POST /api/v1/modules/codes/884b8b1a-6c06-4dee-ad59-afcddd4cbcc6/retire | 200 | pass | 367 |  |
| step | BP-MASTER-09 | s8 | storekeeper | POST /api/v1/modules/codes/resolve | 200 | pass | 351 |  |
| step | BP-MASTER-09 | s9 | admin | POST /api/v1/modules/locations/nodes/f0fe5285-9875-45bd-82a9-7d95ac80cbe8/retire | 200 | pass | 377 |  |
| cleanup | BP-MASTER-09 | c1 | admin | POST /api/v1/modules/codes/884b8b1a-6c06-4dee-ad59-afcddd4cbcc6/retire | 200 | pass | 367 |  |
| cleanup | BP-MASTER-09 | c2 | admin | POST /api/v1/modules/locations/nodes/f0fe5285-9875-45bd-82a9-7d95ac80cbe8/retire | 200 | pass | 356 |  |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "qoimeks-qa2",
  "TENANT": "qoimeks-qa2",
  "run_id": "20261121T071127Z-d214af",
  "now_utc": "2026-11-21T07:11:27Z",
  "node": "f0fe5285-9875-45bd-82a9-7d95ac80cbe8",
  "code_id": "884b8b1a-6c06-4dee-ad59-afcddd4cbcc6"
}
```

