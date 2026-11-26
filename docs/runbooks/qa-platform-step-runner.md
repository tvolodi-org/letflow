# Runbook: the platform step runner on QA (the environment switch)

The platform step runner (T-2703) is the worker that runs a `platform_call` step of a
process definition: the engine arms a durable dispatch row when a token enters the node,
and the runner claims that row, runs the allow-listed function under the authority fence
and hands the declared outputs back to the engine. The catalogue, the registry, the
dispatcher and the state machine of a dispatch are in
[`docs/platform-steps.md`](../platform-steps.md).

## The switch

`LETFLOW_START_PLATFORM_STEP_RUNNER` is the only switch. It is read once at boot by
`config/runtime.exs` and **exactly `true`** turns the runner on; unset, empty or any other
word leaves it off. The default is off in every environment (a new flag defaults off), and
the production install carries the variable in the settings table of
`docs/runbooks/production-readiness.md`.

## The trap: the instance starts and never runs

With the runner off, a definition that reaches a `platform_call` node **STARTS and NEVER
RUNS**. The engine arms the dispatch row (it is `pending`) and no worker claims it, so
the instance waits at the node for ever: no error, no retry, no DLQ entry, and nothing in
the log that says why. No screen fails -- the instance simply never leaves the step, and
it looks like a stuck process rather than a missing setting.

So the variable is part of the DEPLOYMENT. The QA deploy checks it before it rebuilds
the app: a deploy that would leave the runner off never reaches the running QA.

## Where the variable lives on the QA host

TWO host-local files, and BOTH are needed:

| File | Who reads it | Why |
|---|---|---|
| `/opt/apps/letflow-qa/qa.env` | `deploy/redeploy-qa.sh` sources it | the environment of the deploy script itself |
| `/opt/apps/letflow-qa/deploy/.env` | the compose `env_file` of `deploy/docker-compose.qa.yml` | **this is what the app container boots with** |

`qa.env` alone does not reach the container: the app reads its environment from the
compose `env_file`, so a value that is only in `qa.env` leaves the runner off. Both files
carry the line:

```sh
LETFLOW_START_PLATFORM_STEP_RUNNER=true
```

The value must be exactly `true` -- no quotes, no spaces, no other word. That is the same
word `Letflow.Supervisor.Pollers.parse_platform_step_runner/1` turns on, so the deploy
gate and the running container agree: the gate refuses every value the parser would not
turn on.

## The gate

`deploy/redeploy-qa.sh` runs `deploy/lib/check_platform_step_runner.sh` right after it
pulls the code and BEFORE it builds the image and recreates the app container. The gate
reads both files and stops the deploy when either of them does not carry the variable
exactly `true`:

```text
ERROR: LETFLOW_START_PLATFORM_STEP_RUNNER is not set in /opt/apps/letflow-qa/qa.env.
ERROR: LETFLOW_START_PLATFORM_STEP_RUNNER in /opt/apps/letflow-qa/deploy/.env is not exactly 'true'.

ERROR: the QA deploy stops here. LETFLOW_START_PLATFORM_STEP_RUNNER must be exactly 'true' in BOTH
         /opt/apps/letflow-qa/qa.env (sourced by deploy/redeploy-qa.sh) and
         /opt/apps/letflow-qa/deploy/.env (the compose env_file: what the app container boots with).
       qa.env alone does not reach the container.
       With the runner off a platform_call instance STARTS and NEVER RUNS:
       it waits at the node, with no error and no DLQ entry.
```

The gate is fail-closed: a missing file, a missing key and a wrong value each stop the
deploy, and there is no override.

## What was done (24 Nov 2026)

Infra put the line in both files on 24 Nov 2026 (request
`project/infra-requests/2026-11-24-platform-step-runner.md` in the team repository; record
`runs/2026-11-24-qa-platform-step-runner-env-001/`; backups `qa.env.bak-20261124-000624`
and `deploy/.env.bak-20261124-000624`). No QA restart was done: the next QA deploy -- the
one that carries T-2703 -- recreates the app container and picks the variable up.

## The first deploy after this change

The gate is part of `deploy/redeploy-qa.sh`, and a running bash keeps executing the script
text it started with: the CD that merges this change therefore builds WITHOUT the gate,
and the gate is in force from the deploy after it. That is harmless here, because the two
files already carry the variable.

## Turning the runner off again

Remove the line (or set it to any word other than `true`) in BOTH files and redeploy.
The runner is then not started; instances that reach a platform step park at the node,
their dispatch rows stay `pending`, and nothing is lost. The deploy gate refuses that
state, so turning the runner off deliberately means changing `deploy/redeploy-qa.sh` as
well -- a deliberate act, never a silent one.

## Tests

`test/letflow/qa_platform_step_runner_env_test.exs` (T-2707) runs the gate against a
fixture tree and pins: both files are checked; only the exact value `true` passes; the
gate's verdict agrees with `Letflow.Supervisor.Pollers.parse_platform_step_runner/1` for
every value it is given; `deploy/redeploy-qa.sh` runs the gate before it builds and before
it recreates the app container; and the variable name in the deploy script, in
`config/runtime.exs`, in this runbook, in `docs/platform-steps.md` and in the settings
table of `docs/runbooks/production-readiness.md` is one and the same.
