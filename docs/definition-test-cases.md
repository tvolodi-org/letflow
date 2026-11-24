# The declared test cases of a definition

A **declared test case** is a case the definition's AUTHOR writes next to the
graph: what the process starts with, what the steps are expected to do, and
what the run must end with. Before a version may be switched on, its declared
cases RUN -- and a case that fails REFUSES the activation.

This is the guardrail the "Register a tenant" pilot (owner decision D-176:
"nobody reviews scripts, so safety must be mechanical") needed before business
users change processes on their own; it is the third of the three D-176
guardrails (G14 the channel allow-list, G15 the actor in the definition audit,
G16 this one) and it is listed in D-179 (c) as part of the authority rule.
Before it, activation ran static validation only: a graph could be perfect and
still do the wrong thing.

It is the sibling of the script rule's own guardrail: a published script runs
its declared cases and is refused on failure
(`Letflow.Scripts.publish/7`); a definition version now does the same for its
own graph.

## The four parts

| Part | Module | What it is |
|---|---|---|
| The declaration | `Letflow.Definitions.TestCases` (`parse/1`) | ONE parse of the declared cases: the name, the start variables, the completions, the faked step outputs and the expectation -- with the bounds (at most 20 cases, 50 variables each). |
| The runner | `Letflow.Definitions.TestCases` (`run/2`) | The walk of the graph on the engine's own transition kernel, in memory: no instance, no row, no queue, no clock, no side effect. |
| The fence | `Letflow.Definitions.check_test_cases/1` | The activation fence. It runs on all four activation paths: activate, reactivate, version rollback and promotion apply. |
| The surface | `Letflow.Definitions.ProcessDefinition` (`test_cases`), `Letflow.Routers.Definitions` | The column the cases live in, the write path that declares them (`POST`, `PUT`, `PATCH`) and the typed 422 a refusal answers. |

## The declaration

```json
"test_cases": [
  {
    "name": "the applicant is approved",
    "start_variables": {"applicant": "Acme"},
    "complete_tasks": [{"node_id": "review", "outputs": {"approved": true}}],
    "step_outputs": {"notify": {"sent": true}},
    "expect": {
      "status": "completed",
      "variables": {"approved": true},
      "visited_nodes": ["start", "review", "end"]
    }
  }
]
```

* `name` -- required, a short label. It is echoed back in the refusal.
* `start_variables` -- the variables the run starts with (scalars only).
* `complete_tasks` -- the human tasks the runner completes by itself, with the
  outputs each completion writes.
* `step_outputs` -- the FAKED result of a step (a platform call, a
  notification, a script, an HTTP call), keyed by node id. A declared case
  never performs a real side effect: it has no connection, no dispatcher and
  no mail adapter.
* `expect` -- required. `status` is `completed` (the default) or `waiting`
  (the run stopped at a human task or a timer); `variables` names the
  variables whose value must hold at the end; `visited_nodes` names the nodes
  the run must have reached.

## What the runner does, and what it does not

The walk runs on `Letflow.Engine.Transition` -- the engine's own kernel -- so
a gateway is evaluated by the engine's own condition evaluator, a human task
is completed by the engine's own completion transition, and a service task is
moved on by the engine's own `advance_off_completed_node/4`, the function the
live dispatcher calls after a successful call.

Two things it deliberately does NOT do:

* it does not start an instance and it does not write a row: a declared case
  is a dry run of the graph, so it is safe to call inside the activation
  transaction;
* it does not run a sub-process: a declared case runs the graph, never a child
  instance. A graph with a sub-process is refused with
  `sub_process_not_supported` rather than silently skipped.

## The refusal

A version whose declared case fails is NOT activated. The refusal is typed and
carries no value: the case's name, a closed reason code
(`status_mismatch`, `variable_mismatch`, `variable_missing`,
`node_not_visited`, `no_matching_edge`, `hop_limit_exceeded`,
`sub_process_not_supported`, `node_type_not_supported`, `transition_failed`,
`reserved_variable_key`, `unknown_node_id`, `no_start_node`) and, when the reason is about a variable or a
node, its NAME. Never a variable's value, never a stack trace, never a secret
the case carried (INV-4).

    HTTP 422
    {"error": "definition_test_cases_failed",
     "failures": [{"name": "the applicant is approved",
                   "reason": "variable_mismatch",
                   "key": "approved"}]}

A promoted definition CARRIES its declared cases: the promotion copies them with
the graph, and the fence runs them in the target tenant before the copy is
activated (a failure answers the same typed 422 on the promotion route, on
version rollback and on solution-pack override activation). The export document
(`bpm/definition/v1`) does not carry them; a re-imported definition declares its
own cases.

A malformed declaration is refused earlier, by the write that carries it, with
the stable code `definition_test_cases_invalid`.

## The boundary

* A version that declares NO case is activated exactly as it was before this
  guardrail existed. The guardrail is opt-in by declaration, not by a flag.
* The cases are the AUTHOR's own data: they live in the tenant's own schema,
  beside the graph, and are read back through the definition's own route.
* Owner decision D-180 (standard definitions are locked; a tenant may later
  fork a copy) is not built here. The column is nullable and open, and the
  later fork/binding slice adds its `custom` marker and its
  `based_on: <standard key>@<version>` reference beside it, as further
  nullable columns.
