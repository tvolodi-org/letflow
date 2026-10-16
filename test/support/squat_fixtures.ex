defmodule Letflow.SquatFixtures do
  @moduledoc """
  Test-only row builders for the GH #2597 squat audit/remediation tests (test specs
  `test/specs/GH-2597.md`). A squat predates GH #2550's namespacing and the HTTP routes can no
  longer produce it, so these helpers write the `events` / `events_archive` /
  `event_idempotency` / `entity_record_latest` rows directly, as the #2550 legacy tests do.

  Test-only (`test/support/`); never referenced from `lib/`.
  """

  import Ecto.Query

  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Repo

  # A fixed instant (no wall clock) that already lands in an events partition in the #2550
  # legacy tests.
  @created_at ~U[2026-11-15 12:00:00.000000Z]

  @spec created_at() :: DateTime.t()
  def created_at, do: @created_at

  @spec platform_actor() :: Ecto.UUID.t()
  def platform_actor, do: EventStore.platform_actor_id()

  @doc """
  Inserts an event plus its `event_idempotency` row under `key`. Options: `:event_type`
  (default `ENTITY_RECORD_CREATED`), `:actor_id` (default random), `:payload`, `:archived`
  (put the event in `events_archive` instead of `events`).
  Returns `%{event_id: _, record_id: _, actor_id: _}`.
  """
  @spec insert_squat!(String.t(), String.t(), keyword()) :: map()
  def insert_squat!(schema, key, opts \\ []) do
    event_id = Ecto.UUID.generate()
    record_id = Ecto.UUID.generate()
    actor_id = Keyword.get_lazy(opts, :actor_id, &Ecto.UUID.generate/0)

    payload =
      Keyword.get(opts, :payload, %{
        "entity_type" => "widget",
        "record_id" => record_id,
        "field_values" => %{}
      })

    attrs = %{
      event_id: event_id,
      created_at: @created_at,
      instance_id: Ecto.UUID.generate(),
      event_type: Keyword.get(opts, :event_type, "ENTITY_RECORD_CREATED"),
      payload: payload,
      actor_id: actor_id,
      sequence_number: System.unique_integer([:positive, :monotonic]),
      idempotency_key: key
    }

    if Keyword.get(opts, :archived, false) do
      %ArchivedEvent{}
      |> ArchivedEvent.insert_changeset(
        Map.merge(attrs, %{
          global_seq: 1_000_000 + System.unique_integer([:positive, :monotonic]),
          archived_at: @created_at
        })
      )
      |> Repo.insert!(prefix: schema)
    else
      %Event{} |> Event.insert_changeset(attrs) |> Repo.insert!(prefix: schema)
    end

    insert_key!(schema, key, event_id)
    %{event_id: event_id, record_id: record_id, actor_id: actor_id}
  end

  @doc "Inserts only an `event_idempotency` row (its event does not exist anywhere)."
  @spec insert_key!(String.t(), String.t(), Ecto.UUID.t()) :: IdempotencyRecord.t()
  def insert_key!(schema, key, event_id \\ Ecto.UUID.generate()) do
    %IdempotencyRecord{}
    |> IdempotencyRecord.insert_changeset(%{
      idempotency_key: key,
      event_id: event_id,
      event_created_at: @created_at
    })
    |> Repo.insert!(prefix: schema)
  end

  @doc "Inserts the `entity_record_latest` row a certificate rule reads (a session's owner)."
  @spec put_session!(String.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Latest.t()
  def put_session!(schema, session_id, user_id) do
    %Latest{}
    |> Latest.insert_changeset(%{
      entity_type: "session",
      record_id: session_id,
      field_values: %{"user_id" => user_id},
      entity_def_version: <<0, 255>>,
      last_event_global_seq: 1
    })
    |> Repo.insert!(prefix: schema)
  end

  @doc "Row counts of the three tables a remediation or audit must (not) change."
  @spec counts(String.t()) :: %{
          events: non_neg_integer(),
          idempotency: non_neg_integer(),
          audit: non_neg_integer()
        }
  def counts(schema) do
    %{
      events: Repo.aggregate(Event, :count, prefix: schema),
      idempotency: Repo.aggregate(IdempotencyRecord, :count, prefix: schema),
      audit: Repo.aggregate(Letflow.Audit.Entry, :count, prefix: schema)
    }
  end

  @spec key_rows(String.t(), String.t()) :: non_neg_integer()
  def key_rows(schema, key) do
    Repo.aggregate(from(i in IdempotencyRecord, where: i.idempotency_key == ^key), :count,
      prefix: schema
    )
  end

  @doc "All `audit_entries` rows for the `idempotency_squat.remediated` action."
  @spec remediation_entries(String.t()) :: [Letflow.Audit.Entry.t()]
  def remediation_entries(schema) do
    Repo.all(
      from(e in Letflow.Audit.Entry, where: e.action == "idempotency_squat.remediated"),
      prefix: schema
    )
  end
end
