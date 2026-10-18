defmodule Letflow.Entities.EventTypes do
  @moduledoc """
  One-time seed step registering the three entity-record event types
  (REQ-228) through the **existing**
  `Letflow.EventStore.Registry.register_type/2` — no parallel registration
  mechanism. See
  `lib/letflow/design/req228-entity-event-registration-commands.md` §4 for
  the full design this module implements.

  ## The inner/outer validation split (AC7)

  `register_type/2`'s `json_schema` here validates only the **outer** event
  envelope — that `entity_type`/`entity_def_version`/`record_id`/
  `field_values` are present and correctly typed as a JSON object. It never
  inspects `field_values`'s own keys. Per-entity-definition field constraint
  checking is `Letflow.Entities.Record.Validator.validate_record_payload/2`'s
  (REQ-227) job alone, run before this envelope validation, inside
  `Letflow.Entities.Records`'s command functions.

  ## `entity_def_version`'s wire representation — a flagged, documented
  divergence from the design's literal §4.1 envelope table

  The design's own §4.1 table declares `entity_def_version` as JSON
  `"type": "integer"` in the outer envelope schema, while simultaneously
  stating (same section) that `entity_def_version` carries
  `entity_definitions.logical_shape_version`'s ordinal role — a column that
  is actually a `:binary` content-hash digest, never an integer counter
  (confirmed directly against `Letflow.Entities.EntityDefinition`'s schema).
  A raw binary hash cannot be embedded in a JSON payload directly (Jason
  requires valid UTF-8), and it is not an integer either, so the design's
  literal `"type": "integer"` declaration cannot be satisfied by the actual
  data it is meant to describe. The design itself names this exact gap as an
  open question (§8 item 1), explicitly inviting ELIXIR-DEV/REQ-229 to
  resolve it against `EntityDefinition.t()`'s actual field "rather than
  silently picked here."

  Resolution (flagged for REVIEWER, not silently chosen): the envelope's
  `entity_def_version` property is registered here as `"type": "string"`,
  and `Letflow.Entities.Records` hex-encodes `logical_shape_version`
  (`Base.encode16/2`, lowercase) into that field when building an event
  payload, decoding it back (`Base.decode16!/2`) when reconstructing a
  duplicate-submission's record from a replayed event's stored payload. The
  persisted `entity_record_latest.entity_def_version` column stays `:binary`
  (design §6.1's literal column type) and is populated directly from the
  in-memory `definition.logical_shape_version` value on the write path
  (never round-tripped through the JSON envelope), and from
  `Base.decode16!/2` of the envelope's hex string on the duplicate-replay
  path.
  """

  alias Letflow.EventStore.Registry
  alias Letflow.TenantProvisioning

  @created_or_updated_schema %{
    "type" => "object",
    "required" => ["entity_type", "entity_def_version", "record_id", "field_values"],
    "properties" => %{
      "entity_type" => %{"type" => "string"},
      "entity_def_version" => %{"type" => "string"},
      "record_id" => %{"type" => "string"},
      "field_values" => %{"type" => "object"}
    },
    "additionalProperties" => false
  }

  # GH #2659 / REQ-505: v2 of ENTITY_RECORD_CREATED = the same schema plus an OPTIONAL top-level
  # `external_ref` object. Every v1 payload is also a valid v2 payload.
  @created_v2_schema %{
    @created_or_updated_schema
    | "properties" =>
        Map.put(@created_or_updated_schema["properties"], "external_ref", %{
          "type" => "object",
          "required" => ["system", "id"],
          "properties" => %{
            "system" => %{"type" => "string"},
            "id" => %{"type" => "string"}
          },
          "additionalProperties" => false
        })
  }

  @deleted_schema %{
    "type" => "object",
    "required" => ["entity_type", "entity_def_version", "record_id"],
    "properties" => %{
      "entity_type" => %{"type" => "string"},
      "entity_def_version" => %{"type" => "string"},
      "record_id" => %{"type" => "string"}
    },
    "additionalProperties" => false
  }

  @event_type_specs [
    %{
      name: "ENTITY_RECORD_CREATED",
      # v2 (GH #2659 / REQ-505): bumped IN PLACE, like TASK_ENTITY_WRITES_APPLIED v2 (a v1 entry
      # kept beside v2 would fail every replay with :schema_version_not_monotonic for a tenant
      # already at v2). An upgraded tenant registers v2 at its next replay (monotonic); a
      # re-seed of an already-upgraded tenant hits the :duplicate_event_type_version skip.
      schema_version: 2,
      json_schema: @created_v2_schema,
      description:
        "An entity record was created (REQ-228). Version 2 adds the OPTIONAL top-level " <>
          "external_ref {system, id} object (GH #2659); every v1 payload is also a valid v2 payload."
    },
    %{
      name: "ENTITY_RECORD_UPDATED",
      schema_version: 1,
      json_schema: @created_or_updated_schema,
      description:
        "An entity record's field_values were replaced in full (whole-document update, REQ-228)."
    },
    %{
      name: "ENTITY_RECORD_DELETED",
      schema_version: 1,
      json_schema: @deleted_schema,
      description: "An entity record was marked deleted (REQ-228)."
    }
  ]

  @type seed_result :: %{registered: [Registry.EventType.t()], skipped: [String.t()]}

  @doc """
  Registers `ENTITY_RECORD_CREATED`, `ENTITY_RECORD_UPDATED`,
  `ENTITY_RECORD_DELETED` (in that order) via `Registry.register_type/2`,
  scoped to the tenant schema named by `prefix`.

  Idempotent across repeated calls (design §4): a
  `{:error, :duplicate_event_type_version}` for one of the three is treated
  as "already registered, not a failure" and that event type's `name` is
  added to `skipped` rather than aborting the whole seed. Any other error
  return aborts immediately as `{:error, reason}`, leaving `registered`
  whatever this call itself managed to insert before the failure (not
  rolled back — `register_type/2` has no transactional grouping across the
  three calls, matching every other platform event-type seed call site in
  this codebase).
  """
  @spec seed!(prefix :: String.t()) :: {:ok, seed_result()} | {:error, term()}
  def seed!(prefix) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      @event_type_specs
      |> Enum.reduce_while({:ok, %{registered: [], skipped: []}}, fn spec, {:ok, acc} ->
        case Registry.register_type(spec, tenant_id) do
          {:ok, event_type} ->
            {:cont, {:ok, %{acc | registered: [event_type | acc.registered]}}}

          {:error, :duplicate_event_type_version} ->
            {:cont, {:ok, %{acc | skipped: [spec.name | acc.skipped]}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} ->
          {:ok, %{registered: Enum.reverse(acc.registered), skipped: Enum.reverse(acc.skipped)}}

        {:error, _reason} = error ->
          error
      end
    end
  end
end
