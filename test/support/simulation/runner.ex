defmodule Letflow.Simulation.Scenario do
  @moduledoc """
  REQ-205 test-support struct (`lib/letflow/design/req205-simulation-harness-foundation.md`
  §3.1). A parsed, in-memory business-scenario shape -- no Ecto schema, no
  persistence. `Letflow.Simulation.Runner.run/1` consumes this struct; REQ-206/207/208
  own actually parsing scenario YAML into it (design §9 OQ-2) -- this requirement
  only needs the struct shape and the execution mechanism, exercised here against a
  hand-built `%Scenario{}` (no scenario corpus exists yet).

  ## `actor` field on `step()` -- an addition over the design's literal table

  The design's §3.1 step() table has `via`/`action`/`params`/`produces` and
  deliberately no actor reference (OQ-2 defers the exact HTTP dispatch mapping).
  Dispatching a real HTTP request through `Letflow.Router.call/2` (AC4) requires a
  caller identity, though, so each step map here carries an additional
  `"actor"` key: the scenario-local actor key (matching `actors`' own keys) to
  authenticate as for that step. When a step omits `"actor"` and `actors` has
  exactly one entry, that sole actor is used; otherwise an unresolvable actor
  reference is `{:error, {:unresolved_actor, step}}`. This is a plumbing addition,
  not a scope decision REQ-206/207/208 need to honor -- their own scenario YAML is
  free to always specify one explicit actor per step.

  `actors`' values are `%{"token" => plaintext_token, "tenant_slug" => slug}` --
  the two pieces of data an API-token-authenticated request needs
  (`Authorization: Bearer <token>` + `x-tenant-slug: <slug>`, per
  `Letflow.Plugs.AuthPipeline`'s API-token branch).
  """

  @enforce_keys [:id, :company_id, :process_id]
  defstruct id: nil,
            company_id: nil,
            process_id: nil,
            actors: %{},
            preconditions: [],
            steps: [],
            expected_outcomes: [],
            unbuilt_feature: nil

  @type precondition :: %{
          required(:check) => :process_definition_active | :no_pending_instances | :custom,
          optional(:args) => map()
        }

  @type step :: %{
          required(:via) => :api | :gui | :skip | :blocked,
          required(:action) => String.t(),
          optional(:params) => map(),
          optional(:produces) => String.t(),
          optional(:actor) => String.t(),
          optional(:severity) => :minor | :major | :blocker | nil,
          optional(:note) => String.t() | nil,
          optional(:blocked_by) => String.t() | nil
        }

  @type expected_outcome :: %{
          required(:verification) => %{
            method:
              :task_assigned
              | :instance_state
              | :audit_event
              | :audit_event_ordering
              | :no_task_of_type,
            args: map()
          }
        }

  @type t :: %__MODULE__{
          id: String.t(),
          company_id: String.t(),
          process_id: String.t(),
          actors: %{optional(String.t()) => map()},
          preconditions: [precondition()],
          steps: [step()],
          expected_outcomes: [expected_outcome()],
          unbuilt_feature: %{reason: String.t()} | nil
        }
end

defmodule Letflow.Simulation.RunReport do
  @moduledoc """
  REQ-205 test-support struct (design §3.2). Plain, in-memory run-result shape --
  no Ecto schema, no persistence.
  """

  defstruct scenario_id: nil,
            precondition_results: [],
            step_results: [],
            outcome_results: [],
            disposition: :executed,
            notes: nil

  @type precondition_result :: %{precondition: term(), outcome: :ok | :error, detail: term()}

  @type step_result :: %{
          step: Letflow.Simulation.Scenario.step(),
          outcome: :ok | :error | :deferred_to_s8 | :skip | :blocked,
          captured: map() | nil,
          detail: term(),
          severity: :minor | :major | :blocker | nil,
          blocked_by: String.t() | nil
        }

  @type outcome_result :: %{
          expected_outcome: Letflow.Simulation.Scenario.expected_outcome(),
          outcome: :pass | :fail,
          observed: term()
        }

  @type t :: %__MODULE__{
          scenario_id: String.t(),
          precondition_results: [precondition_result()],
          step_results: [step_result()],
          outcome_results: [outcome_result()],
          disposition: :executed | :unbuilt_feature,
          notes: String.t() | nil
        }
end

defmodule Letflow.Simulation.Runner do
  @moduledoc """
  REQ-205 test-support module
  (`lib/letflow/design/req205-simulation-harness-foundation.md` §3). Executes
  REQ-206/207/208's business-scenario corpus (a `Letflow.Simulation.Scenario.t()`)
  against a real running Letflow instance -- `via: :api` steps dispatch real HTTP
  through `Letflow.Router.call/2` (this repo's own `Plug.Test` router-test
  convention, see `test/letflow/routers/req078_supporting_routes_test.exs`); `via:
  :gui` steps are recorded `:deferred_to_s8`, never executed and never silently
  dropped -- there is no integrated `web/`-against-Letflow environment yet (S8's
  job), and two of the three GUI-driven scenarios have no Playwright spec at all
  (verified this session by `find` over `web/tests/e2e/pipelines/`).

  This is a **test-execution harness** built by REQ-205, the correctness gate over
  S4/S5/S6's combined output (`docs/migration/stage-7-simulation-uat-parity.md`).

  ## NOT `simulation_test.zig`/`scenario_runner.zig`

  This module is explicitly **not** R-Co's `src/api/routes/simulation_test.zig` /
  `src/simulation/scenario_runner.zig` mechanism. That subsystem is a
  **design-time dry-run tool** validating a candidate process *definition*
  against a schema+event-trace assertion set (`POST /simulation/validate`, `POST
  /simulation/run`, permission-gated `simulation:validate`/`simulation:run`) -- a
  different input shape (a definition, not a business scenario), a different
  caller (a definition author, not a test harness), and a different question
  answered ("is this definition well-formed" vs. "does the running platform
  behave correctly for this business scenario"). `Letflow.Router` reserves a
  route slot for that subsystem (`Letflow.Routers.SimulationTest`, per
  `lib/letflow/router.ex`'s own router-inventory table) -- **this requirement
  does not build that router**, does not fill that slot, and nothing in this
  module's execution path touches it.

  ## Deviations from the design's literal context-function citations (recorded,
  ## not silent)

  - §3.3's `:no_pending_instances` precondition cites
    `Letflow.Engine.count_instances_by_status/1` as "scoped to the scenario's
    `process_id` and tenant prefix." Reading its real body this session
    (`lib/letflow/engine.ex` ~3554-3567) shows it takes only `opts ::
    [prefix: String.t()]` -- there is no `process_id`/definition scoping
    parameter at all; it counts every instance in the tenant's schema by status.
    This module therefore checks the *tenant-wide* pending/running count, not a
    per-process one -- a real, if coarser, precondition than the design
    describes.
  - §6's `instance_state` method cites "`Letflow.Engine`'s instance-lookup
    path." The actual read-side context module is `Letflow.Instances.get_by_id/2`
    (`lib/letflow/instances.ex`), not a function on `Letflow.Engine` itself --
    used here as the real, already-existing equivalent.
  - §6's `task_assigned` method cites "the same context function
    `Letflow.Routers.Tasks` uses to read a task" -- that function is
    `Letflow.Tasks.get_task/2` (`lib/letflow/tasks.ex`), returning `{Task.t(),
    correlation_key, form_version}`. `Task.t()` has no single `assignee` field;
    assignment is `assignee_type`/`assignee_ref` (`lib/letflow/engine/task.ex`).
    This module compares the expected actor's resolved user id against
    `assignee_ref` when `assignee_type == "user"`.
  """

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Instances
  alias Letflow.Simulation.RunReport
  alias Letflow.Simulation.Scenario
  alias Letflow.Tasks

  @router_opts Letflow.Router.init([])

  @doc """
  Runs one scenario end to end: preconditions -> api-via steps (with
  `{{produces.X}}` template substitution) -> gui-via steps (recorded
  `:deferred_to_s8`) -> expected-outcome verification (§3.3, in order).

  `{:error, _}` is reserved for the harness itself malfunctioning (an unknown
  custom precondition, an unresolved template, an unresolvable actor) -- a
  scenario with failing steps or failing outcomes still returns `{:ok, report}`,
  since the report's own contents carry the pass/fail information.
  """
  @spec run(Scenario.t()) :: {:ok, RunReport.t()} | {:error, term()}
  def run(%Scenario{unbuilt_feature: %{reason: reason}} = scenario) do
    {:ok,
     %RunReport{
       scenario_id: scenario.id,
       disposition: :unbuilt_feature,
       notes: reason,
       precondition_results: [],
       step_results: [],
       outcome_results: []
     }}
  end

  def run(%Scenario{} = scenario) do
    with {:ok, precondition_results} <- run_preconditions(scenario) do
      if Enum.any?(precondition_results, &(&1.outcome == :error)) do
        {:ok,
         %RunReport{
           scenario_id: scenario.id,
           precondition_results: precondition_results,
           step_results: [],
           outcome_results: []
         }}
      else
        run_steps_and_outcomes(scenario, precondition_results)
      end
    end
  end

  defp run_steps_and_outcomes(scenario, precondition_results) do
    with {:ok, step_results} <- run_steps(scenario) do
      produces = accumulate_produces(step_results)
      outcome_results = Enum.map(scenario.expected_outcomes, &verify_outcome(&1, produces))

      {:ok,
       %RunReport{
         scenario_id: scenario.id,
         precondition_results: precondition_results,
         step_results: step_results,
         outcome_results: outcome_results
       }}
    end
  end

  # ── Phase 1: preconditions (§3.3 step 1) ──────────────────────────────────

  defp run_preconditions(scenario) do
    prefix = tenant_prefix!(scenario)

    Enum.reduce_while(scenario.preconditions, {:ok, []}, fn precondition, {:ok, acc} ->
      case check_precondition(precondition, scenario, prefix) do
        {:ok, detail} ->
          {:cont, {:ok, acc ++ [%{precondition: precondition, outcome: :ok, detail: detail}]}}

        {:error, detail} ->
          {:halt, {:ok, acc ++ [%{precondition: precondition, outcome: :error, detail: detail}]}}
      end
    end)
  end

  defp check_precondition(%{check: :process_definition_active} = precondition, scenario, prefix) do
    name = Map.get(precondition[:args] || %{}, "name", scenario.process_id)

    case Definitions.get_active_by_name(name, prefix: prefix) do
      {:ok, %{status: :active} = definition} -> {:ok, definition}
      {:ok, definition} -> {:error, {:not_active, definition.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_precondition(%{check: :no_pending_instances}, _scenario, prefix) do
    case Engine.count_instances_by_status(prefix: prefix) do
      {:ok, counts} ->
        pending = Map.get(counts, :active, 0)
        if pending == 0, do: {:ok, counts}, else: {:error, {:pending_instances, pending}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_precondition(%{check: :custom} = precondition, scenario, prefix) do
    name = Map.get(precondition[:args] || %{}, "predicate")

    case custom_predicate(name) do
      nil -> {:error, {:unknown_custom_precondition, name}}
      fun -> fun.(scenario, prefix)
    end
  end

  # Closed registry (§3.3 step 1) -- no arbitrary code execution from YAML
  # content. Named-function-clause dispatch, not a data-driven map (a literal
  # `%{}` module attribute makes Elixir's type checker infer an
  # always-empty-map type and flag every lookup as dead code). "always_true"
  # is the one predicate this requirement itself needs (a placeholder custom
  # precondition a hand-built test scenario can reference); REQ-206/207/208
  # add further named clauses as their own scenarios need them. Any other
  # name falls through to the catch-all and fails loudly (§3.3), never
  # silently passing.
  @type custom_predicate_fun :: (Scenario.t(), String.t() -> {:ok, term()} | {:error, term()})
  @spec custom_predicate(String.t() | nil) :: custom_predicate_fun() | nil
  defp custom_predicate("always_true"), do: fn _scenario, _prefix -> {:ok, :always_true} end
  defp custom_predicate(_other_or_nil), do: nil

  # ── Phase 2/3: steps, interleaved in declared order (§3.3 steps 2-3) ──────

  defp run_steps(scenario) do
    {results, _produces} =
      Enum.reduce(scenario.steps, {[], %{}}, fn step, {acc, produces} ->
        case step.via do
          :gui ->
            result = %{
              step: step,
              outcome: :deferred_to_s8,
              captured: nil,
              severity: nil,
              blocked_by: nil,
              detail:
                "S8 frontend integration not started; see docs/migration/stage-7-simulation-uat-parity.md"
            }

            {acc ++ [result], produces}

          :skip ->
            severity =
              case Map.get(step, :severity) do
                nil ->
                  raise ArgumentError,
                        "step with via: :skip is missing a severity field: #{inspect(step)}"

                s ->
                  s
              end

            result = %{
              step: step,
              outcome: :skip,
              captured: nil,
              severity: severity,
              blocked_by: nil,
              detail: Map.get(step, :note) || "marked SKIP at scenario-authoring time"
            }

            {acc ++ [result], produces}

          # REQ-208 design §2.1 -- distinct from :skip: a genuinely blocking,
          # undocumented gap (no scenario-authored fallback), always :blocker
          # severity (fixed here, never author-supplied), never dispatched over
          # HTTP. `blocked_by` is required and fail-loud when absent, same
          # discipline :skip's missing-severity check already established.
          :blocked ->
            blocked_by =
              case Map.get(step, :blocked_by) do
                nil ->
                  raise ArgumentError,
                        "step with via: :blocked is missing a blocked_by field: #{inspect(step)}"

                b ->
                  b
              end

            result = %{
              step: step,
              outcome: :blocked,
              captured: nil,
              severity: :blocker,
              blocked_by: blocked_by,
              detail: Map.get(step, :note) || "blocked; see " <> blocked_by
            }

            {acc ++ [result], produces}

          :api ->
            {result, new_produces} = run_api_step(step, scenario, produces)
            {acc ++ [result], new_produces}
        end
      end)

    {:ok, results}
  end

  defp run_api_step(step, scenario, produces) do
    with {:ok, resolved_action} <- substitute_templates(step.action, produces),
         {:ok, resolved_params} <- substitute_templates(Map.get(step, :params, %{}), produces),
         {:ok, actor} <- resolve_actor(step, scenario),
         {:ok, final_params} <- resolve_timer_node(resolved_action, resolved_params, scenario) do
      dispatch_api_step(%{step | action: resolved_action}, final_params, actor, produces)
    else
      {:error, reason} ->
        {%{
           step: step,
           outcome: :error,
           captured: nil,
           severity: nil,
           blocked_by: nil,
           detail: reason
         }, produces}
    end
  end

  # ISS-1007 / Q-989: a definition whose human tasks each arm a D-ESC escalation timer has several
  # pending timers at once, so `POST /instances/:id/advance-timer` needs a `timer_id` (the route
  # answers 400 "specify timer_id" otherwise). A scenario step may instead name the node
  # (`params: {timer_node_id: <node>}`, the same input name the narrative UAT scenarios use); the
  # Runner turns it into the pending timer's id. Any other step is untouched.
  #
  # Since REQ-494 a HUMAN_TASK node can carry a reminder and an escalation timer at once, so a node
  # id alone may match two pending timers. The step may then add `timer_type: <type>` (e.g.
  # "reminder" or "escalation") to pick one. There is no default: a node with several pending timers
  # and no (or a non-selecting) `timer_type` is `{:error, {:ambiguous_timer_for_node, node_id,
  # timer_types}}`, never a raise.
  @doc false
  def resolve_timer_node(action, %{"timer_node_id" => node_id} = params, scenario)
      when is_binary(node_id) do
    with [_all, instance_id] <- Regex.run(~r{/instances/([^/]+)/advance-timer$}, action),
         {:ok, timer_id} <-
           pick_pending_timer(
             instance_id,
             node_id,
             params["timer_type"],
             tenant_prefix!(scenario)
           ) do
      {:ok, %{"timer_id" => timer_id}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:no_pending_timer_for_node, node_id}}
    end
  end

  def resolve_timer_node(_action, params, _scenario), do: {:ok, params}

  defp pick_pending_timer(instance_id, node_id, timer_type, prefix) do
    pending =
      Letflow.Repo.all(
        from(t in Letflow.Scheduler.Timer,
          where:
            t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == "pending",
          order_by: t.timer_type
        ),
        prefix: prefix
      )

    candidates =
      if is_binary(timer_type),
        do: Enum.filter(pending, &(&1.timer_type == timer_type)),
        else: pending

    case candidates do
      [%Letflow.Scheduler.Timer{id: timer_id}] -> {:ok, timer_id}
      [] -> {:error, {:no_pending_timer_for_node, node_id}}
      many -> {:error, {:ambiguous_timer_for_node, node_id, Enum.map(many, & &1.timer_type)}}
    end
  end

  defp resolve_actor(%{actor: actor_key}, scenario) when is_binary(actor_key) do
    case Map.fetch(scenario.actors, actor_key) do
      {:ok, actor} -> {:ok, actor}
      :error -> {:error, {:unresolved_actor, actor_key}}
    end
  end

  defp resolve_actor(_step, %Scenario{actors: actors}) when map_size(actors) == 1 do
    {:ok, actors |> Map.values() |> List.first()}
  end

  defp resolve_actor(step, _scenario), do: {:error, {:unresolved_actor, step}}

  defp dispatch_api_step(step, params, actor, produces) do
    {method, path} = parse_action!(step.action)

    # body_params is set directly (not JSON-string-encoded through conn/3) --
    # matches this repo's own router-test convention
    # (test/letflow/routers/req078_supporting_routes_test.exs's build_conn/4),
    # since handlers read conn.body_params directly rather than running a real
    # Plug.Parsers pass under Plug.Test dispatch.
    request_conn =
      conn(method, path)
      |> Map.put(:body_params, params)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> Map.fetch!(actor, "token"))
      |> put_req_header("x-tenant-slug", Map.fetch!(actor, "tenant_slug"))

    response_conn = Letflow.Router.call(request_conn, @router_opts)

    if response_conn.status in 200..299 do
      body = decode_json_body(response_conn)
      captured = if Map.get(step, :produces), do: body, else: nil
      new_produces = maybe_store_produces(produces, Map.get(step, :produces), body)

      {%{
         step: step,
         outcome: :ok,
         captured: captured,
         severity: nil,
         blocked_by: nil,
         detail: body
       }, new_produces}
    else
      body = decode_json_body(response_conn)

      {%{
         step: step,
         outcome: :error,
         captured: nil,
         severity: nil,
         blocked_by: nil,
         detail: %{status: response_conn.status, body: body}
       }, produces}
    end
  end

  defp maybe_store_produces(produces, nil, _body), do: produces
  defp maybe_store_produces(produces, name, body), do: Map.put(produces, name, body)

  defp decode_json_body(%Plug.Conn{resp_body: nil}), do: nil

  defp decode_json_body(%Plug.Conn{resp_body: resp_body}) do
    case Jason.decode(resp_body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp parse_action!(action) do
    [method, path] = String.split(action, " ", parts: 2)
    {String.to_existing_atom(String.downcase(method)), path}
  end

  defp accumulate_produces(step_results) do
    Enum.reduce(step_results, %{}, fn
      %{step: %{produces: name}, captured: captured}, acc
      when is_binary(name) and not is_nil(captured) ->
        Map.put(acc, name, captured)

      _other, acc ->
        acc
    end)
  end

  # ── §5: {{produces.X}} template substitution ──────────────────────────────

  @template_regex ~r/\{\{produces\.([a-zA-Z0-9_.]+)\}\}/

  defp substitute_templates(value, produces) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case substitute_templates(v, produces) do
        {:ok, substituted} -> {:cont, {:ok, Map.put(acc, k, substituted)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp substitute_templates(value, produces) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case substitute_templates(item, produces) do
        {:ok, substituted} -> {:cont, {:ok, acc ++ [substituted]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp substitute_templates(value, produces) when is_binary(value) do
    case Regex.run(@template_regex, value) do
      [^value, dotted_path] ->
        # Entire-string form: replace with the resolved value as-is (may be
        # any JSON type, not just a string).
        resolve_dotted_path(dotted_path, produces)

      _other ->
        substitute_substrings(value, produces)
    end
  end

  defp substitute_templates(value, _produces), do: {:ok, value}

  defp substitute_substrings(value, produces) do
    Regex.scan(@template_regex, value)
    |> Enum.reduce_while({:ok, value}, fn [whole, dotted_path], {:ok, acc} ->
      case resolve_dotted_path(dotted_path, produces) do
        {:ok, resolved} when is_binary(resolved) ->
          {:cont, {:ok, String.replace(acc, whole, resolved)}}

        {:ok, resolved} ->
          {:cont, {:ok, String.replace(acc, whole, to_string(resolved))}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp resolve_dotted_path(dotted_path, produces) do
    [name | rest] = String.split(dotted_path, ".")

    case Map.fetch(produces, name) do
      {:ok, root} -> walk_path(root, rest, dotted_path)
      :error -> {:error, {:unresolved_template, "produces." <> dotted_path}}
    end
  end

  defp walk_path(value, [], _dotted_path), do: {:ok, value}

  defp walk_path(value, [key | rest], dotted_path) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> walk_path(next, rest, dotted_path)
      :error -> {:error, {:unresolved_template, "produces." <> dotted_path}}
    end
  end

  # Numeric string key on a list — supports {{produces.list_name.items.0.id}} style
  defp walk_path(value, [key | rest], dotted_path) when is_list(value) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 ->
        case Enum.at(value, index) do
          nil -> {:error, {:unresolved_template, "produces." <> dotted_path}}
          element -> walk_path(element, rest, dotted_path)
        end

      _ ->
        {:error, {:unresolved_template, "produces." <> dotted_path}}
    end
  end

  defp walk_path(_value, _rest, dotted_path),
    do: {:error, {:unresolved_template, "produces." <> dotted_path}}

  # ── Phase 4: expected outcomes (§6) ────────────────────────────────────────

  defp verify_outcome(%{verification: %{method: :task_assigned, args: args}} = expected, produces) do
    with {:ok, task_ref} <- resolve_ref(args, "task_ref", produces),
         {:ok, prefix} <- fetch_prefix(args),
         {:ok, {task, _correlation_key, _form_version}} <-
           Tasks.get_task(task_ref, prefix: prefix) do
      expected_actor_id = Map.get(args, "expected_assignee_user_id")
      observed = %{assignee_type: task.assignee_type, assignee_ref: task.assignee_ref}

      outcome =
        if task.assignee_type == "user" and task.assignee_ref == expected_actor_id,
          do: :pass,
          else: :fail

      %{expected_outcome: expected, outcome: outcome, observed: observed}
    else
      {:error, reason} ->
        %{expected_outcome: expected, outcome: :fail, observed: {:error, reason}}
    end
  end

  # REQ-208 design §2.2 -- new 5th verification.method. `:task_assigned`
  # requires an already-resolved `task_ref`; there is none for "a task of
  # this type was never created" (EO-002's own negative-assertion point).
  # Queries the instance's real task list across EVERY status (deliberate --
  # absence must hold regardless of status, not merely PENDING), never
  # inferring PASS from an unresolved template or a not-found error.
  defp verify_outcome(
         %{verification: %{method: :no_task_of_type, args: args}} = expected,
         produces
       ) do
    with {:ok, instance_ref} <- resolve_ref(args, "instance_ref", produces),
         {:ok, prefix} <- fetch_prefix(args),
         {:ok, node_id} <- fetch_required(args, "node_id"),
         {:ok, %{items: items}} <-
           Tasks.list_tasks(%{page_size: 100, instance_id: instance_ref}, prefix: prefix) do
      observed = Enum.map(items, fn {task, _form_version} -> {task.node_id, task.status} end)

      outcome =
        if Enum.any?(observed, fn {n, _status} -> n == node_id end), do: :fail, else: :pass

      %{expected_outcome: expected, outcome: outcome, observed: observed}
    else
      {:error, reason} ->
        %{expected_outcome: expected, outcome: :fail, observed: {:error, reason}}
    end
  end

  defp verify_outcome(
         %{verification: %{method: :instance_state, args: args}} = expected,
         produces
       ) do
    with {:ok, instance_ref} <- resolve_ref(args, "instance_ref", produces),
         {:ok, prefix} <- fetch_prefix(args),
         {:ok, projection} <- Instances.get_by_id(instance_ref, prefix: prefix) do
      expected_status = Map.get(args, "status")
      observed = %{status: status_string(projection.status), variables: projection.variables}

      status_matches? = status_string(projection.status) == expected_status
      variables_match? = variables_match?(args, projection.variables)

      outcome = if status_matches? and variables_match?, do: :pass, else: :fail

      %{expected_outcome: expected, outcome: outcome, observed: observed}
    else
      {:error, reason} ->
        %{expected_outcome: expected, outcome: :fail, observed: {:error, reason}}
    end
  end

  defp verify_outcome(%{verification: %{method: :audit_event, args: args}} = expected, produces) do
    case find_audit_entry(args, produces) do
      {:ok, matching} ->
        outcome = if matching, do: :pass, else: :fail
        %{expected_outcome: expected, outcome: outcome, observed: %{matching_entry: matching}}

      {:error, reason} ->
        %{expected_outcome: expected, outcome: :fail, observed: {:error, reason}}
    end
  end

  # REQ-207 design §3.2 -- new 4th verification.method. Resolves "first" and
  # "second" each via the same audit_event lookup logic as the clause above
  # (find_audit_entry/2, shared rather than duplicated), guards both sides
  # resolve to the same tenant prefix (chain order is only meaningful within
  # one tenant's chain), then walks the real queried hash-chain linkage via
  # Audit.chain_precedes?/3 (ISS-0972 -- audit_entries has no
  # sequence_number/global_seq-equivalent column, unlike ISS-0970's `events`
  # precedent, so chain-walking replaces timestamp comparison rather than
  # reusing it). :pass iff both entries were found, both sides share a
  # prefix, AND the chain walk proves first precedes second; :fail
  # otherwise, with `observed` always carrying both real entries -- same
  # "always carry real queried state, never infer PASS from absence of
  # error" discipline the other three methods already follow.
  defp verify_outcome(
         %{verification: %{method: :audit_event_ordering, args: args}} = expected,
         produces
       ) do
    with {:ok, first_args} <- fetch_ordering_side(args, "first"),
         {:ok, second_args} <- fetch_ordering_side(args, "second"),
         {:ok, first_prefix} <- fetch_prefix(first_args),
         {:ok, second_prefix} <- fetch_prefix(second_args),
         :ok <- require_same_prefix(first_prefix, second_prefix),
         {:ok, first_entry} <- find_audit_entry(first_args, produces),
         {:ok, second_entry} <- find_audit_entry(second_args, produces) do
      outcome = ordering_outcome(first_prefix, first_entry, second_entry)

      %{
        expected_outcome: expected,
        outcome: outcome,
        observed: %{first: first_entry, second: second_entry}
      }
    else
      {:error, reason} ->
        %{expected_outcome: expected, outcome: :fail, observed: {:error, reason}}
    end
  end

  @spec require_same_prefix(String.t(), String.t()) ::
          :ok | {:error, {:prefix_mismatch, String.t(), String.t()}}
  defp require_same_prefix(prefix, prefix), do: :ok

  defp require_same_prefix(first_prefix, second_prefix),
    do: {:error, {:prefix_mismatch, first_prefix, second_prefix}}

  @spec ordering_outcome(String.t(), Audit.Entry.t() | nil, Audit.Entry.t() | nil) ::
          :pass | :fail
  defp ordering_outcome(_prefix, nil, _second_entry), do: :fail
  defp ordering_outcome(_prefix, _first_entry, nil), do: :fail

  defp ordering_outcome(prefix, first_entry, second_entry) do
    case Audit.chain_precedes?(prefix, first_entry, second_entry) do
      {:ok, true} -> :pass
      {:ok, false} -> :fail
      {:error, _reason} -> :fail
    end
  end

  defp fetch_ordering_side(args, key) do
    case Map.fetch(args, key) do
      {:ok, side_args} when is_map(side_args) -> {:ok, side_args}
      _other -> {:error, {:missing_arg, key}}
    end
  end

  # Shared audit_event lookup: template-substituted resource_id/resource_type,
  # real Audit.list_entries/1 query, first matching row by action/resource_id/
  # resource_type. Used by both the :audit_event and :audit_event_ordering
  # verify_outcome/2 clauses above.
  defp find_audit_entry(args, produces) do
    with {:ok, prefix} <- fetch_prefix(args),
         {:ok, resource_id} <- resolve_optional_ref(args, "resource_id", produces),
         {:ok, resource_type} <- resolve_optional_ref(args, "resource_type", produces) do
      expected_action = Map.fetch!(args, "event_type")

      query_params = %{
        prefix: prefix,
        page_size: 100,
        resource_id: resource_id,
        resource_type: resource_type
      }

      case Audit.list_entries(query_params) do
        {:ok, %{items: items}} -> {:ok, Enum.find(items, &(&1.action == expected_action))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp variables_match?(args, observed_variables) do
    case Map.get(args, "variables") do
      nil -> true
      expected_variables -> Map.equal?(expected_variables, observed_variables || %{})
    end
  end

  defp resolve_ref(args, key, produces) do
    case Map.fetch(args, key) do
      {:ok, raw} -> substitute_templates(raw, produces)
      :error -> {:error, {:missing_arg, key}}
    end
  end

  # Like resolve_ref/3, but the key is optional (:audit_event's `resource_id`/
  # `resource_type` args) -- a missing key resolves to `nil` rather than
  # `{:error, {:missing_arg, key}}`, since `Audit.list_entries/1` already
  # treats a `nil` resource_id/resource_type as "don't filter on this field."
  defp resolve_optional_ref(args, key, produces) do
    case Map.fetch(args, key) do
      {:ok, raw} -> substitute_templates(raw, produces)
      :error -> {:ok, nil}
    end
  end

  defp fetch_prefix(args) do
    case Map.fetch(args, "prefix") do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, {:missing_arg, "prefix"}}
    end
  end

  # Shared required-arg fetch (REQ-208's :no_task_of_type's "node_id") -- same
  # {:error, {:missing_arg, key}} shape as fetch_prefix/1, generalized to any key.
  defp fetch_required(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_arg, key}}
    end
  end

  defp status_string(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.upcase()

  defp tenant_prefix!(%Scenario{
         expected_outcomes: expected_outcomes,
         preconditions: preconditions
       }) do
    (preconditions ++ expected_outcomes)
    |> Enum.find_value(fn
      %{args: %{"prefix" => prefix}} -> prefix
      %{verification: %{args: %{"prefix" => prefix}}} -> prefix
      _other -> nil
    end) || raise ArgumentError, "no precondition/expected_outcome carries a tenant prefix"
  end
end
