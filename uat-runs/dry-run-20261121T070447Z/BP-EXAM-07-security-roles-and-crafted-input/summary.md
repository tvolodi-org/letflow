# UAT run BP-EXAM-07

- run id: 20261121T070447Z-98cd51
- tenant: bilimbaga   base url: https://bilimbaga.letflow.qa.bizdala.com
- started: 2026-11-21T07:04:47Z   duration: 124963 ms
- build sha at start: 97eb7527c5c5cd5e4cfda8b86885b4d23ab17bcc   at end: None
- steps: FAIL   cleanup: pass
- verdict: **FAIL**

> **FIRST FAILING STEP: BP-EXAM-07 preflight token:candidate** - no token for actor 'candidate' (exit 1) no access token for candidate-user (wrong password or realm?)

## Processes

| process | verdict | steps | cleanup | duration ms | first failing step |
|---|---|---|---|---|---|

## Steps

| phase | process | step | actor | request | status | verdict | ms | note |
|---|---|---|---|---|---|---|---|---|
| preflight | BP-EXAM-07 | health | - | GET /health |  | pass | 430 |  |
| preflight | BP-EXAM-07 | stable | - |  |  | pass | 123253 |  |
| preflight | BP-EXAM-07 | tenant | - | GET / | 200 | pass | 450 |  |
| preflight | BP-EXAM-07 | token:admin | admin |  |  | pass | 443 |  |
**>>** | preflight | BP-EXAM-07 | token:candidate | candidate |  |  | **FAIL** | 384 | no token for actor 'candidate' (exit 1) no access token for candidate-user (wrong password or realm?) |

## Outputs

```json
{}
```


## Context at the end

```json
{
  "tenant": "bilimbaga",
  "TENANT": "bilimbaga",
  "run_id": "20261121T070447Z-98cd51",
  "now_utc": "2026-11-21T07:04:47Z"
}
```

