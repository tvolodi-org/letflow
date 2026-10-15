defmodule Letflow.Support.ScriptTaskFixture do
  @moduledoc """
  GH 2534 PR 7c-1 test helpers (design `lib/letflow/design/gh2534-7c-script-handler.md`
  section 15): published script versions written straight into a fixture tenant's
  `script_rules` (through the guard trigger's legal transitions), definitions binding them,
  instances, dispatch rows, events, and a counting runner seam.

  Every row lives in the fixture tenant's own schema. The runner seam is used ONLY for
  call-count assertions (and the AC12 raise); real scripts drive every outcome.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Scripts.ScriptRule
  alias Letflow.TenantFixture

  # ── tenants ─────────────────────────────────────────────────────────────────

  @doc "A provisioned fixture tenant WITH its script HMAC key."
  @spec tenant!(String.t()) :: map()
  def tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    :ok = HmacSecret.ensure(%{id: tenant.tenant_id})
    delete_secrets_on_exit(tenant.tenant_id)
    tenant
  end

  @doc "A provisioned fixture tenant with NO script HMAC key (fixture tenants have none)."
  @spec tenant_without_hmac!(String.t()) :: map()
  def tenant_without_hmac!(slug_prefix),
    do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  # The secrets table is global (public schema): the tenant's rows go with the test.
  defp delete_secrets_on_exit(tenant_id) do
    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(s in Letflow.Secrets.Secret, where: s.tenant_id == ^tenant_id))
    end)
  end

  # ── script versions ─────────────────────────────────────────────────────────

  @doc "A CLOSED manifest: integer `amount` in, integer `total` out."
  @spec closed_manifest() :: map()
  def closed_manifest do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}},
        "required" => ["amount"]
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "integer"}},
        "required" => ["total"],
        "additionalProperties" => false
      },
      "fail_codes" => ["too_big"],
      "limits" => %{"instructions" => 200_000, "timeout_ms" => 1_000}
    }
  end

  @doc "A source doubling `amount` into `total`."
  @spec doubling_source() :: String.t()
  def doubling_source, do: "return { total = ctx.input.amount * 2 }"

  @doc "Inserts a draft (version = max + 1) through the legal INSERT shape and rehashes it."
  @spec draft!(String.t(), String.t(), String.t(), map()) :: ScriptRule.t()
  def draft!(schema, key, source, manifest) do
    version =
      (Repo.one(from(r in ScriptRule, where: r.key == ^key, select: max(r.version)),
         prefix: schema
       ) || 0) + 1

    test_cases = [%{"name" => "c1", "input" => %{}, "expect" => %{"fail" => "x"}}]

    rule =
      %ScriptRule{
        key: key,
        version: version,
        hook_kind: "service_task",
        status: "draft",
        source: source,
        manifest: manifest,
        test_cases: test_cases,
        sha256: "pending",
        contributors: [Ecto.UUID.generate()]
      }
      |> Repo.insert!(prefix: schema)

    reloaded = Repo.get!(ScriptRule, rule.id, prefix: schema)

    sha =
      Hash.compute(
        reloaded.key,
        reloaded.version,
        reloaded.hook_kind,
        reloaded.manifest,
        reloaded.test_cases,
        reloaded.source
      )

    reloaded |> Ecto.Changeset.change(sha256: sha) |> Repo.update!(prefix: schema)
  end

  @doc "A published version (draft -> published, a publisher outside the contributors)."
  @spec published!(String.t(), String.t(), String.t(), map()) :: ScriptRule.t()
  def published!(schema, key, source, manifest) do
    draft = draft!(schema, key, source, manifest)
    publisher = Ecto.UUID.generate()

    draft
    |> Ecto.Changeset.change(
      status: "published",
      publisher_id: publisher,
      published_at: DateTime.utc_now(),
      sod_excluded: draft.contributors ++ [publisher]
    )
    |> Repo.update!(prefix: schema)
  end

  @doc "published -> retired, bypassing the retire block (raw, for run-time tests)."
  @spec retire_raw!(String.t(), ScriptRule.t()) :: ScriptRule.t()
  def retire_raw!(schema, %ScriptRule{} = rule) do
    rule
    |> Ecto.Changeset.change(status: "retired", retired_at: DateTime.utc_now())
    |> Repo.update!(prefix: schema)
  end

  @doc "published/retired -> revoked (raw)."
  @spec revoke_raw!(String.t(), ScriptRule.t()) :: ScriptRule.t()
  def revoke_raw!(schema, %ScriptRule{} = rule) do
    rule
    |> Ecto.Changeset.change(status: "revoked", revoked_at: DateTime.utc_now())
    |> Repo.update!(prefix: schema)
  end

  @doc "`closed_manifest/0` with `limits` replaced."
  @spec manifest_with_limits(map()) :: map()
  def manifest_with_limits(limits), do: Map.put(closed_manifest(), "limits", limits)

  @doc """
  Publishes `source` under a fresh key with `manifest`, activates a START -> svc -> END
  definition binding it and starts an instance with `variables`: returns
  `%{rule, definition, instance_id, row, actor_id}`.
  """
  @spec bound!(map(), String.t(), map(), map()) :: map()
  def bound!(tenant, source, manifest, variables) do
    bound_graph!(tenant, source, manifest, variables, &script_graph/2, [])
  end

  @doc "`bound!/4` with a custom graph builder `fn key, version -> graph end` and schemas."
  @spec bound_graph!(map(), String.t(), map(), map(), (String.t(), pos_integer() -> map()), [
          map()
        ]) ::
          map()
  def bound_graph!(tenant, source, manifest, variables, graph_fun, variable_schemas) do
    schema = tenant.schema_name
    key = "k#{System.unique_integer([:positive])}"
    rule = published!(schema, key, source, manifest)
    definition = definition!(schema, graph_fun.(key, rule.version), variable_schemas)
    actor_id = Ecto.UUID.generate()
    instance_id = start!(schema, definition, variables, actor_id)

    %{
      rule: rule,
      definition: definition,
      instance_id: instance_id,
      actor_id: actor_id,
      row: List.first(rows(schema, instance_id))
    }
  end

  # ── definitions and instances ──────────────────────────────────────────────

  @doc "START -> SERVICE_TASK `svc` (script binding) -> END."
  @spec script_graph(String.t(), pos_integer()) :: map()
  def script_graph(key, version) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => key, "script_version" => version}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  @doc "START -> HUMAN_TASK `review` -> SERVICE_TASK `svc` (script) -> END."
  @spec human_then_script_graph(String.t(), pos_integer()) :: map()
  def human_then_script_graph(key, version) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "review", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => key, "script_version" => version}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "review"},
        %{"id" => "e2", "source" => "review", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  @doc "START -> svc1 (k1@v1) -> svc2 (k2@v2) -> END: two consecutive script tasks, no HTTP task."
  @spec two_script_graph(String.t(), pos_integer(), String.t(), pos_integer()) :: map()
  def two_script_graph(k1, v1, k2, v2) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc1",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => k1, "script_version" => v1}
        },
        %{
          "id" => "svc2",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => k2, "script_version" => v2}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc1"},
        %{"id" => "e2", "source" => "svc1", "target" => "svc2"},
        %{"id" => "e3", "source" => "svc2", "target" => "end"}
      ]
    }
  end

  @doc "A stored (draft) definition of `graph` with the given variable schemas."
  @spec draft_definition!(String.t(), map(), [map()]) :: Definitions.ProcessDefinition.t()
  def draft_definition!(schema, graph, variable_schemas) do
    attrs = %{
      name: "gh2534-7c-#{System.unique_integer([:positive])}",
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    {:ok, definition} =
      Definitions.create_with_variable_schemas(attrs, variable_schemas, prefix: schema)

    definition
  end

  @doc "An ACTIVE definition of `graph` (activated through `Definitions.activate/2`)."
  @spec definition!(String.t(), map(), [map()]) :: Definitions.ProcessDefinition.t()
  def definition!(schema, graph, variable_schemas) do
    draft = draft_definition!(schema, graph, variable_schemas)
    assert {:ok, %{definition: active}} = Definitions.activate(draft.id, prefix: schema)
    active
  end

  @doc "Integer variable-schema entries for `keys`."
  @spec integer_schemas([String.t()]) :: [map()]
  def integer_schemas(keys),
    do: Enum.map(keys, &%{variable_key: &1, json_schema: %{"type" => "integer"}})

  @doc "Starts an instance; returns its id."
  @spec start!(String.t(), Definitions.ProcessDefinition.t(), map(), Ecto.UUID.t()) ::
          Ecto.UUID.t()
  def start!(schema, definition, variables, actor_id) do
    assert {:ok, %{instance_id: instance_id}} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: variables,
                 actor_id: actor_id,
                 idempotency_key: "gh2534-7c-start-#{System.unique_integer([:positive])}"
               },
               prefix: schema
             )

    instance_id
  end

  @doc "The instance's script dispatch rows, oldest first."
  @spec rows(String.t(), Ecto.UUID.t()) :: [ScriptTaskDispatch.t()]
  def rows(schema, instance_id) do
    ScriptTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> order_by([d], asc: d.inserted_at, asc: d.id)
    |> Repo.all(prefix: schema)
  end

  @doc "The one script dispatch row of the instance."
  @spec row!(String.t(), Ecto.UUID.t()) :: ScriptTaskDispatch.t()
  def row!(schema, instance_id) do
    assert [row] = rows(schema, instance_id)
    row
  end

  @doc "Reloads a dispatch row."
  @spec reload(String.t(), ScriptTaskDispatch.t()) :: ScriptTaskDispatch.t()
  def reload(schema, %ScriptTaskDispatch{id: id}),
    do: Repo.get!(ScriptTaskDispatch, id, prefix: schema)

  @doc "The decoded payloads of the instance's events of `type`, in order."
  @spec payloads(String.t(), Ecto.UUID.t(), String.t()) :: [map()]
  def payloads(schema, instance_id, type) do
    {:ok, events} = EventStore.read(instance_id, prefix: schema)

    for %{event_type: ^type, payload: payload} <- events,
        do: if(is_binary(payload), do: Jason.decode!(payload), else: payload)
  end

  @doc "Every event type of the instance, in order."
  @spec event_types(String.t(), Ecto.UUID.t()) :: [String.t()]
  def event_types(schema, instance_id) do
    {:ok, events} = EventStore.read(instance_id, prefix: schema)
    Enum.map(events, & &1.event_type)
  end

  @doc "The instance projection."
  @spec projection(String.t(), Ecto.UUID.t()) :: InstanceProjection.t()
  def projection(schema, instance_id),
    do: Repo.get_by!(InstanceProjection, [instance_id: instance_id], prefix: schema)

  @doc "DLQ entries count."
  @spec dlq_count(String.t()) :: non_neg_integer()
  def dlq_count(schema), do: Letflow.Dlq.count_entries(prefix: schema)

  @doc "Claims the next due row and runs it; fails the test when none is due."
  @spec run_next!(String.t()) ::
          {ScriptTaskDispatch.t(), {:ok, atom()} | {:error, :apply_failed}}
  def run_next!(schema) do
    assert {:ok, row} = ScriptTaskDispatcher.claim_next(schema)
    {row, ScriptTaskDispatcher.run_claimed(row, schema)}
  end

  @doc "The claim map of a claimed row."
  @spec claim(ScriptTaskDispatch.t()) :: ScriptTaskDispatcher.claim()
  def claim(row),
    do: %{
      dispatch_id: row.id,
      instance_id: row.instance_id,
      node_id: row.node_id,
      attempt: row.attempt
    }

  @doc "Back-dates a running row's lease (simulates expiry without sleeping)."
  @spec expire_lease!(String.t(), ScriptTaskDispatch.t()) :: :ok
  def expire_lease!(schema, %ScriptTaskDispatch{id: id}) do
    {1, _} =
      ScriptTaskDispatch
      |> where([d], d.id == ^id and d.status == "running")
      |> Repo.update_all(
        [set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]],
        prefix: schema
      )

    :ok
  end

  @doc "Makes a pending row due now."
  @spec make_due!(String.t(), ScriptTaskDispatch.t()) :: :ok
  def make_due!(schema, %ScriptTaskDispatch{id: id}) do
    {1, _} =
      ScriptTaskDispatch
      |> where([d], d.id == ^id and d.status == "pending")
      |> Repo.update_all([set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)]],
        prefix: schema
      )

    :ok
  end

  # ── runner seam (call counts only) ─────────────────────────────────────────

  defmodule CountingRunner do
    @moduledoc "Delegates to the real ScriptRunner and tells the registered test pid."
    @spec run(String.t(), map(), keyword()) :: term()
    def run(source, input, opts) do
      case Application.get_env(:letflow, :script_task_runner_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:script_runner_called, self(), Letflow.Repo.in_transaction?()})

        _ ->
          :ok
      end

      Letflow.Engine.Lua.ScriptRunner.run(source, input, opts)
    end
  end

  defmodule RaisingRunner do
    @moduledoc "Raises a sentinel-bearing exception (AC12: a caught raise logs the tag only)."
    @spec run(String.t(), map(), keyword()) :: no_return()
    def run(_source, _input, _opts),
      do: raise(RuntimeError, Application.get_env(:letflow, :script_task_raise_message, "boom"))
  end

  defmodule RecordingReadPort do
    @moduledoc """
    GH 2534 PR 7c-2: a `Letflow.Engine.EntityPort` stub for call-count assertions only. It
    tells the registered test pid, then delegates to the real `Letflow.Entities.ScriptReads`.
    """
    @behaviour Letflow.Engine.EntityPort

    @impl Letflow.Engine.EntityPort
    def prefetch(prefix, reads, input_vars) do
      case Application.get_env(:letflow, :entity_port_test_pid) do
        pid when is_pid(pid) -> send(pid, {:script_read_port_called, prefix, reads, input_vars})
        _ -> :ok
      end

      Letflow.Entities.ScriptReads.prefetch(prefix, reads, input_vars)
    end

    @impl Letflow.Engine.EntityPort
    defdelegate prepare(lines, ctx), to: Letflow.Entities.EntityPortImpl

    @impl Letflow.Engine.EntityPort
    defdelegate validate_lines(lines, ctx), to: Letflow.Entities.EntityPortImpl

    @impl Letflow.Engine.EntityPort
    defdelegate multi(multi, lines, ctx), to: Letflow.Entities.EntityPortImpl
  end

  @doc "Selects `RecordingReadPort` as the configured read port for the test (restored on exit)."
  @spec record_read_port_calls!() :: :ok
  def record_read_port_calls! do
    put_env!(:entity_port, RecordingReadPort)
    put_env!(:entity_port_test_pid, self())
    :ok
  end

  @doc "Routes every run through `CountingRunner`, reporting to the calling test (restored on exit)."
  @spec count_runner_calls!() :: :ok
  def count_runner_calls! do
    put_env!(:script_task_runner, CountingRunner)
    put_env!(:script_task_runner_test_pid, self())
    :ok
  end

  @doc "Sets an application env key for the test, restoring the previous value on exit."
  @spec put_env!(atom(), term()) :: :ok
  def put_env!(key, value) do
    previous = Application.fetch_env(:letflow, key)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)

    Application.put_env(:letflow, key, value)
  end

  @doc "Overrides one `:script_task_dispatcher` config key for the test."
  @spec put_dispatcher_config!(atom(), term()) :: :ok
  def put_dispatcher_config!(key, value) do
    current = Application.get_env(:letflow, :script_task_dispatcher, [])
    put_env!(:script_task_dispatcher, Keyword.put(current, key, value))
  end

  # ── admission ───────────────────────────────────────────────────────────────

  @doc """
  Holds EVERY tenant slot of `schema` in the real `ScriptAdmission` from helper processes;
  returns their pids (kill them to release).
  """
  @spec hold_all_slots!(String.t()) :: [pid()]
  def hold_all_slots!(schema) do
    test_pid = self()

    Stream.repeatedly(fn ->
      holder =
        spawn(fn ->
          result =
            Letflow.Admission.try_acquire({:tenant, schema}, Letflow.Engine.Lua.ScriptAdmission)

          send(test_pid, {:slot, self(), result})
          Process.sleep(:infinity)
        end)

      receive do
        {:slot, ^holder, {:ok, _ref}} -> {:held, holder}
        {:slot, ^holder, {:error, :capacity}} -> Process.exit(holder, :kill) && :full
      after
        2_000 -> flunk("admission holder did not answer")
      end
    end)
    |> Enum.take_while(&(&1 != :full))
    |> Enum.map(fn {:held, pid} -> pid end)
    |> tap(fn holders ->
      # never leave a holder behind (and its slot held) when a test fails before killing it
      ExUnit.Callbacks.on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)
    end)
  end

  @doc "Slots of `schema` currently in use in the real `ScriptAdmission`."
  @spec slots_in_use(String.t()) :: non_neg_integer()
  def slots_in_use(schema) do
    state = :sys.get_state(Letflow.Engine.Lua.ScriptAdmission)

    case state.tenants do
      %{^schema => %{in_use: in_use}} -> in_use
      _ -> 0
    end
  end

  @doc "Polls `fun` (20 ms steps) until truthy or `tries` run out."
  @spec eventually((-> boolean()), non_neg_integer()) :: boolean()
  def eventually(fun, tries) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
