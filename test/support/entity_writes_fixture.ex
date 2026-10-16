defmodule Letflow.EntityWritesFixture do
  @moduledoc """
  GH #2587 / REQ-499 PR B2 (design `gh2587-req499-pr-b-human-task-writes.md` CO-2): the real
  writer of engine-minted `_sys.*` values for tests. It activates a definition whose
  HUMAN_TASK node declares `entity_writes` (through the real activation path, with a real
  activator) and completes the task through the real `Letflow.Engine.complete_task/3`.
  Nothing here hand-writes a `_sys` value, an event or a projection column.

  Real Postgres, no mocks. Every case provisions its own tenant. No helper takes an optional
  argument (anti-patterns ISS-0069); the case map carries everything.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @doc "A unique greppable string."
  @spec unique(String.t()) :: String.t()
  def unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  @doc "A line declaring a `create` of `entity_type` with the given tagged `fields`."
  @spec line(String.t(), map()) :: map()
  def line(entity_type, fields),
    do: %{"op" => "create", "entity_type" => entity_type, "fields" => fields}

  @doc "START -> HUMAN_TASK `ht` (declaring `lines`) -> END."
  @spec graph([map()]) :: map()
  def graph(lines) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "ht",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER", "entity_writes" => lines}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end

  @doc "Provisions a tenant with event types seeded and one active user. Returns the base case."
  @spec tenant_case!(String.t()) :: map()
  def tenant_case!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)
    %{tenant: tenant, schema: schema, user: user!(schema, "completer")}
  end

  @doc """
  Like `tenant_case!/1`, for a module that runs in Sandbox `:auto` mode (real commits, real
  parallel connections): the tenant is NOT torn down by the fixture; the caller registers
  `drop_committed_tenant!/1` in `on_exit`.
  """
  @spec committed_tenant_case!(String.t()) :: map()
  def committed_tenant_case!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix, teardown: false)
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)
    %{tenant: tenant, schema: schema, user: user!(schema, "completer")}
  end

  @doc "Drops a tenant built by `committed_tenant_case!/1`."
  @spec drop_committed_tenant!(String.t()) :: :ok
  def drop_committed_tenant!(tenant_id) do
    case Letflow.TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
      {:error, :invalid_tenant_id} -> :ok
    end

    Repo.delete_all(
      from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
    )

    Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^tenant_id))
    :ok
  end

  @doc "An active internal user in `schema`."
  @spec user!(String.t(), String.t()) :: User.t()
  def user!(schema, label) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "ew-#{label}-#{Ecto.UUID.generate()}",
      display_name: "EW #{label}",
      email: "ew-#{label}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  @doc """
  An ACTIVE, append-only, process-writable entity type `name` with a required string field
  `label` and an optional string field `note`. `extra` is merged into the definition map.
  """
  @spec define_type!(String.t(), String.t(), map()) :: struct()
  def define_type!(schema, name, extra) do
    definition =
      Map.merge(
        %{
          name: name,
          display_name: name,
          fields: [
            %{name: "label", type: :string, required: true},
            %{name: "note", type: :string}
          ],
          writable_by_process: true,
          append_only: true
        },
        extra
      )

    {:ok, row} =
      Letflow.Entities.Definitions.create_definition(
        %{definition: definition, created_by: Ecto.UUID.generate()},
        schema
      )

    {:ok, active} =
      Letflow.Entities.Definitions.activate_definition(
        row.name,
        Ecto.UUID.generate(),
        "go",
        schema
      )

    active
  end

  @doc """
  Creates and activates a process definition with `graph` as `activator_user`
  (`TENANT_ADMIN`, so `:EntitiesRecordsWrite` is held). Returns the activated row.
  """
  @spec activate!(String.t(), User.t(), map()) :: struct()
  def activate!(schema, activator_user, graph) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique("ew-def"),
          version: "1.0.0",
          graph: graph,
          created_by: activator_user.id
        },
        prefix: schema
      )

    activator =
      Activator.from_auth_context(%{user_id: activator_user.id, roles: ["TENANT_ADMIN"]}, false)

    {:ok, %{definition: activated}} =
      Definitions.activate(definition.id, prefix: schema, activator: activator)

    activated
  end

  @doc """
  Inserts `graph` as an ACTIVE row WITHOUT activation validation (the graph may be one the
  validators refuse, e.g. an exclusive gateway with no default route) and records the
  activator the way activation does, so a completion still has a plan.
  """
  @spec legacy_activate!(String.t(), User.t(), map(), [{String.t(), String.t()}]) :: struct()
  def legacy_activate!(schema, activator_user, graph, pairs) do
    alias Letflow.Definitions.ProcessDefinition

    row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: unique("ew-legacy"),
        version: "1.0.0",
        graph: graph,
        created_by: activator_user.id
      })
      |> Repo.insert!(prefix: schema)

    activator =
      Activator.from_auth_context(%{user_id: activator_user.id, roles: ["TENANT_ADMIN"]}, false)

    record = Activator.build_record(activator, pairs, DateTime.utc_now())

    {1, [activated]} =
      from(d in ProcessDefinition, where: d.id == ^row.id, select: d)
      |> Repo.update_all([set: [status: :active, activated_by: record]], prefix: schema)

    activated
  end

  @doc "Starts an instance of `definition` and returns `{instance_id, pending_task}`."
  @spec start!(String.t(), struct()) :: {Ecto.UUID.t(), EngineTask.t()}
  def start!(schema, definition) do
    {:ok, created} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("ew-start")
        },
        prefix: schema
      )

    {created.instance_id, pending_task!(schema, created.instance_id)}
  end

  @doc "The one pending task of an instance."
  @spec pending_task!(String.t(), Ecto.UUID.t()) :: EngineTask.t()
  def pending_task!(schema, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> Repo.one!(prefix: schema)
  end

  @doc """
  The full case: tenant, user, two types (`stock_move`, `stock_note`), an activated definition
  declaring `lines`, a started instance and its pending task.
  """
  @spec case!(String.t(), [map()]) :: map()
  def case!(slug_prefix, lines) do
    base = tenant_case!(slug_prefix)
    define_type!(base.schema, "stock_move", %{})
    define_type!(base.schema, "stock_note", %{})
    attach!(base, lines)
  end

  @doc """
  Like `case!/2`, but the ACTIVATOR and the COMPLETER are different active users: `ctx.user` is
  the completer (what `complete/2` acts as), `ctx.activator` the user recorded in
  `activated_by`.
  """
  @spec distinct_case!(String.t(), [map()]) :: map()
  def distinct_case!(slug_prefix, lines) do
    base = tenant_case!(slug_prefix)
    define_type!(base.schema, "stock_move", %{})
    define_type!(base.schema, "stock_note", %{})
    completer = user!(base.schema, "completer2")
    ctx = attach!(base, lines)
    Map.merge(ctx, %{activator: base.user, user: completer})
  end

  @doc "Activates a definition declaring `lines` in the tenant of `base` and starts it."
  @spec attach!(map(), [map()]) :: map()
  def attach!(base, lines) do
    definition = activate!(base.schema, base.user, graph(lines))
    {instance_id, task} = start!(base.schema, definition)
    Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})
  end

  @doc "Completes the case's pending task as the case's user with `output_variables`."
  @spec complete(map(), map()) :: term()
  def complete(ctx, output_variables) do
    Engine.complete_task(
      ctx.task.id,
      %{
        output_variables: output_variables,
        actor_id: ctx.user.id,
        idempotency_key: unique("ew-complete")
      },
      prefix: ctx.schema
    )
  end

  @doc "Completes with `output_variables`, asserting success; returns the result."
  @spec complete_with_lines!(map(), map()) :: map()
  def complete_with_lines!(ctx, output_variables) do
    {:ok, result} = complete(ctx, output_variables)
    result
  end

  # --- SERVICE_TASK (GH #2587 PR C2) ---------------------------------------------------------
  #
  # The activation fence refuses `entity_writes` on a SERVICE_TASK node until C1, so these cases
  # build the ACTIVE row the way a row from BEFORE B1 exists: `legacy_activate!/4` inserts the
  # graph without activation validation and records the activator (the same document the real
  # activation records), and the instance is started through the real `Engine.create/2`.

  @doc "START -> SERVICE_TASK `svc` (HTTP, declaring `lines`) -> END."
  @spec service_graph([map()]) :: map()
  def service_graph(lines), do: service_graph(lines, %{})

  @doc "`service_graph/1` with extra attributes merged into the service node."
  @spec service_graph([map()], map()) :: map()
  def service_graph(lines, extra_attributes) do
    node_attributes =
      Map.merge(
        %{
          "endpoint" => "https://example.test/svc",
          "method" => "POST",
          "timeout_ms" => 300_000,
          "entity_writes" => lines
        },
        extra_attributes
      )

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "svc", "node_type" => "SERVICE_TASK", "attributes" => node_attributes},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  @doc """
  START -> SERVICE_TASK `svc` (declaring `lines`) -> HUMAN_TASK `ht` -> END: the token is still
  live (waiting at `ht`) after the service apply.
  """
  @spec service_then_human_graph([map()]) :: map()
  def service_then_human_graph(lines) do
    graph = service_graph(lines)

    %{
      "nodes" =>
        List.insert_at(graph["nodes"], 2, %{
          "id" => "ht",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER"}
        }),
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "ht"},
        %{"id" => "e3", "source" => "ht", "target" => "end"}
      ]
    }
  end

  @doc """
  The full SERVICE case: tenant, the activator user, two types (`stock_move`, `stock_note`), an
  ACTIVE definition of `graph` with the activator recorded, a started instance and its one
  PENDING dispatch row marked `"advanced"` (the state `attempt_dispatch/2` leaves, no HTTP).
  """
  @spec service_case!(String.t(), map()) :: map()
  def service_case!(slug_prefix, graph) do
    base = tenant_case!(slug_prefix)
    define_type!(base.schema, "stock_move", %{})
    define_type!(base.schema, "stock_note", %{})
    attach_service!(base, graph)
  end

  @doc """
  Activates `graph` in the tenant of `base` (types `stock_move` and `stock_note` must exist),
  starts an instance and marks its dispatch row `"advanced"`. `service_case!/2` without the
  tenant and type setup, so several cases can share one (committed) tenant.
  """
  @spec attach_service!(map(), map()) :: map()
  def attach_service!(base, graph) do
    definition =
      legacy_activate!(base.schema, base.user, graph, [
        {"stock_move", "create"},
        {"stock_note", "create"}
      ])

    {:ok, created} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{"seed" => "s"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("ew-svc-start")
        },
        prefix: base.schema
      )

    [row] =
      Repo.all(
        from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
          where: d.instance_id == ^created.instance_id
        ),
        prefix: base.schema
      )

    dispatch =
      row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: base.schema)

    Map.merge(base, %{
      definition: definition,
      instance_id: created.instance_id,
      dispatch: dispatch
    })
  end

  @doc "The re-entry the dispatcher performs after a 2xx: apply `body` for the case's dispatch."
  @spec apply_http(map(), map()) :: term()
  def apply_http(ctx, body) do
    Engine.advance_after_service_task_outcome(ctx.dispatch.id, {:advance, body}, Repo, ctx.schema)
  end

  @spec dispatch!(String.t(), Ecto.UUID.t()) :: struct()
  def dispatch!(schema, dispatch_id),
    do:
      Repo.get!(Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch, dispatch_id,
        prefix: schema
      )

  @spec dlq_entries(String.t()) :: [struct()]
  def dlq_entries(schema), do: Repo.all(Letflow.Dlq.Entry, prefix: schema)

  # --- observation helpers -------------------------------------------------------------

  @spec records(String.t(), String.t()) :: [Latest.t()]
  def records(schema, entity_type) do
    Latest
    |> where([l], l.entity_type == ^entity_type)
    |> Repo.all(prefix: schema)
  end

  @doc "Every `ENTITY_RECORD_CREATED` event of the tenant (the per-type synthetic streams)."
  @spec entity_events(String.t()) :: [Event.t()]
  def entity_events(schema) do
    Event
    |> where([e], e.event_type == "ENTITY_RECORD_CREATED")
    |> order_by([e], asc: e.global_seq)
    |> Repo.all(prefix: schema)
  end

  @doc """
  Installs the `fixture_managed` test module through the REAL install route
  (`Letflow.Modules.Installs.install/3`), which stamps `managed_by: "fixture_managed"` on its
  entity types (`fxm_ledger` among them, append-only). The fixture builds no `Owner` and calls
  no module-owner call: the managed-types caller scans cover `test/support`.
  """
  @spec install_managed_fixture!(String.t()) :: :ok
  def install_managed_fixture!(schema) do
    {:ok, tenant_id} = Letflow.TenantProvisioning.tenant_id_for_schema_name(schema)

    # the install writes platform-level rows that reference the tenant (FKs): remove them
    # BEFORE the tenant fixture's own teardown (on_exit callbacks run last-registered first)
    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(
        from(i in Letflow.Definitions.SolutionPackInstall, where: i.tenant_id == ^tenant_id)
      )

      Repo.delete_all(
        from(b in Letflow.Definitions.SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id)
      )

      Repo.delete_all(
        from(cp in Letflow.TenantProvisioning.ColumnPromotion, where: cp.tenant_id == ^tenant_id)
      )
    end)

    {:ok, _result} =
      Letflow.Modules.Installs.install("fixture_managed", Ecto.UUID.generate(),
        prefix: schema,
        rationale: "entity writes fixture"
      )

    :ok
  end

  @spec all_records(String.t()) :: [Latest.t()]
  def all_records(schema), do: Repo.all(Latest, prefix: schema)

  @spec step_idempotency_count(String.t()) :: non_neg_integer()
  def step_idempotency_count(schema) do
    Repo.one(
      from(i in "event_idempotency",
        where: like(i.idempotency_key, "sys:step:%"),
        select: count(i.id)
      ),
      prefix: schema
    )
  end

  @spec audit_rows(String.t(), String.t()) :: [Audit.Entry.t()]
  def audit_rows(schema, action) do
    Audit.Entry
    |> where([a], a.action == ^action)
    |> order_by([a], asc: a.timestamp)
    |> Repo.all(prefix: schema)
  end

  @spec instance_events(String.t(), Ecto.UUID.t(), String.t()) :: [Event.t()]
  def instance_events(schema, instance_id, event_type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^event_type)
    |> order_by([e], asc: e.sequence_number)
    |> Repo.all(prefix: schema)
  end

  @doc "Every event type of the instance, in stream order."
  @spec instance_event_types(String.t(), Ecto.UUID.t()) :: [String.t()]
  def instance_event_types(schema, instance_id) do
    Repo.all(
      from(e in Event,
        where: e.instance_id == ^instance_id,
        order_by: [asc: e.sequence_number],
        select: e.event_type
      ),
      prefix: schema
    )
  end

  @spec all_instance_event_count(String.t(), Ecto.UUID.t()) :: non_neg_integer()
  def all_instance_event_count(schema, instance_id) do
    Repo.aggregate(from(e in Event, where: e.instance_id == ^instance_id), :count, prefix: schema)
  end

  @spec projection!(String.t(), Ecto.UUID.t()) :: InstanceProjection.t()
  def projection!(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  @spec task!(String.t(), Ecto.UUID.t()) :: EngineTask.t()
  def task!(schema, task_id), do: Repo.get!(EngineTask, task_id, prefix: schema)

  @doc """
  `RESET`s the session's `lock_timeout` and `statement_timeout` (CO-4): `SET LOCAL` in a
  SQL-sandbox savepoint survives `RELEASE SAVEPOINT` until the sandbox's outer transaction
  ends, so a test that asserts "no SET LOCAL was issued" must not inherit one from a
  previous completion in the same test.
  """
  @spec reset_local_timeouts!() :: :ok
  def reset_local_timeouts! do
    Repo.query!("RESET lock_timeout")
    Repo.query!("RESET statement_timeout")
    :ok
  end
end
