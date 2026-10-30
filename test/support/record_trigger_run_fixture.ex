defmodule Letflow.RecordTriggerRunFixture do
  @moduledoc """
  REQ-628 (GH #3507) test support for the record-trigger run: a tenant with two entity types, a
  published `entity_event` script, a record, a claimed outbox row, and a stub runner that tells the
  calling process what it was given (the run is in-process, so `self()` is the test).
  """

  import Ecto.Query

  alias Letflow.Entities.Records
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Worker
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Repo
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @type_a "r628_item"
  @type_b "r628_other"

  defmodule StubRunner do
    @moduledoc false
    def run(source, input, opts) do
      send(self(), {:stub_run, source, input, opts, Letflow.Repo.in_transaction?()})

      case Application.get_env(:letflow, :record_trigger_stub_reply) do
        fun when is_function(fun, 1) -> fun.(input)
        other -> other
      end
    end
  end

  @doc "The primary type name."
  def type_a, do: @type_a
  @doc "The second type name."
  def type_b, do: @type_b

  @doc "A tenant (with HMAC key), two active types, the stub runner installed. Returns the schema."
  @spec tenant!(String.t()) :: String.t()
  def tenant!(slug) do
    schema = F.tenant!(slug).schema_name
    {:ok, _seeded} = Letflow.Entities.EventTypes.seed!(schema)
    P.active_definition!(schema, @type_a, ["label", "note", "cid"])
    P.active_definition!(schema, @type_b, ["label", "cid"])
    put_env(:record_trigger_script_runner, StubRunner)
    schema
  end

  @doc "Sets an application env key for the test and restores it afterwards."
  def put_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  @doc "The stub runner's reply: a term, or a 1-arity function of the input."
  def reply(value), do: put_env(:record_trigger_stub_reply, value)

  @doc "A successful runner reply with `output`."
  def ok(output), do: {:ok, %{output: output, stats: %{}}}

  @doc "A manifest whose output is `writes`, declaring `lines` (default: update_self note, create label)."
  def manifest(extra \\ %{}, lines \\ nil) do
    lines =
      lines ||
        [
          %{"entity_type" => @type_a, "mode" => "update_self", "fields" => ["note"]},
          %{"entity_type" => @type_b, "mode" => "create", "fields" => ["label"]}
        ]

    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}}
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"writes" => %{"type" => "array"}},
          "additionalProperties" => false
        },
        "fail_codes" => [],
        "limits" => %{"timeout_ms" => 5_000},
        "writes" => lines
      },
      extra
    )
  end

  @doc "Publishes an `entity_event` script with `manifest`."
  def publish!(schema, manifest \\ nil, opts \\ []),
    do: RF.script!(schema, "entity_event", :published, manifest || manifest(), opts)

  @doc "Creates a record of `type`; returns its id."
  def record!(schema, type, fields) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: fields,
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "r628-seed-" <> Ecto.UUID.generate()
        },
        schema,
        :tenant
      )

    record.record_id
  end

  @doc "Inserts a pending outbox row pinned to `rule` for `record_id`, and claims it."
  def claimed_row!(schema, rule, record_id, attrs \\ []) do
    now = DateTime.utc_now()

    base = %OutboxRow{
      id: Ecto.UUID.generate(),
      binding_id: Ecto.UUID.generate(),
      entity_type: @type_a,
      record_id: record_id,
      event: :updated,
      source_seq: 7,
      occurred_at: DateTime.add(now, -60, :second),
      script_key: rule.key,
      script_version: rule.version,
      script_sha256: rule.sha256,
      actor_id: Ecto.UUID.generate(),
      next_attempt_at: DateTime.add(now, -60, :second)
    }

    row = Repo.insert!(struct(base, attrs), prefix: schema)
    {:ok, %OutboxRow{id: id} = claimed} = Worker.claim_next(schema)
    ^id = row.id
    claimed
  end

  @doc "The outbox row as stored now."
  def fetch(schema, id), do: Repo.get!(OutboxRow, id, prefix: schema)

  @doc "The latest field values of a record."
  def fields(schema, type, record_id) do
    Repo.one!(
      from(l in Letflow.Entities.Record.Latest,
        where: l.entity_type == ^type and l.record_id == ^record_id,
        select: l.field_values
      ),
      prefix: schema
    )
  end

  @doc "Every latest row of `type` (any state)."
  def count(schema, type),
    do:
      Repo.aggregate(
        from(l in Letflow.Entities.Record.Latest, where: l.entity_type == ^type),
        :count,
        :id,
        prefix: schema
      )

  @chain ~w(r628_a r628_b r628_c r628_d r628_e)

  @doc "The five chain type names `r628_a`..`r628_e` (loop and depth tests)."
  def chain_types, do: @chain

  @doc "Like `tenant!/1`, with the five chain types (fields `label`, `cid`) and the stub runner."
  @spec chain_tenant!(String.t()) :: String.t()
  def chain_tenant!(slug) do
    schema = F.tenant!(slug).schema_name
    {:ok, _seeded} = Letflow.Entities.EventTypes.seed!(schema)
    Enum.each(@chain, &P.active_definition!(schema, &1, ["label", "cid"]))
    put_env(:record_trigger_script_runner, StubRunner)
    schema
  end

  @doc """
  Publishes one script per chain type and binds each on (type, `created`). The script of type N
  declares exactly one `create` of type N+1 (`label`, `cid`); E has a script that writes nothing.
  The stub reply (see `chain_reply/0`) is a function of the record's `cid`.
  """
  @spec bind_chain!(String.t()) :: [Letflow.RecordTriggers.Binding.t()]
  def bind_chain!(schema) do
    @chain
    |> Enum.with_index()
    |> Enum.map(fn {type, i} ->
      lines =
        case Enum.at(@chain, i + 1) do
          nil -> []
          next -> [%{"entity_type" => next, "mode" => "create", "fields" => ["label", "cid"]}]
        end

      manifest =
        manifest(
          %{
            "input_schema" => %{
              "type" => "object",
              "properties" => %{"label" => %{"type" => "string"}, "cid" => %{"type" => "string"}}
            }
          },
          lines
        )

      RF.bind_script!(schema, type, "created", publish!(schema, manifest))
    end)
  end

  @doc "The chain's stub reply: cid `a` writes `r628_b` with cid `b`, and so on; `e` writes nothing."
  def chain_reply do
    fn input ->
      case input["record"]["cid"] do
        "e" ->
          ok(%{"writes" => []})

        cid ->
          next = <<List.first(String.to_charlist(cid)) + 1>>

          ok(%{
            "writes" => [
              %{
                "entity_type" => "r628_" <> next,
                "mode" => "create",
                "fields" => %{"label" => "x", "cid" => next}
              }
            ]
          })
      end
    end
  end

  @doc "Forwards the telemetry `event` to the calling process as `{:telemetry, event, metadata}`."
  def forward(event) do
    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      event,
      fn e, _m, meta, _ -> send(parent, {:telemetry, e, meta}) end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc "Runs ticks until one claims nothing (at most 12); returns the number of ticks run."
  def drain!(schema) do
    Enum.reduce_while(1..12, 0, fn n, _ ->
      {summary, _} = Worker.run_tick([schema], 0)
      if summary.claimed == 0, do: {:halt, n}, else: {:cont, n}
    end)
  end

  @doc "Every outbox row of `schema`, oldest first by depth then source_seq."
  def rows(schema) do
    schema |> RF.outbox_rows() |> Enum.sort_by(&{&1.depth, &1.source_seq})
  end

  @doc "Appended event count of `schema` (all instances)."
  def event_count(schema), do: Repo.aggregate(Letflow.EventStore.Event, :count, prefix: schema)
end
