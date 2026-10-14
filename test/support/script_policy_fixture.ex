defmodule Letflow.Support.ScriptPolicyFixture do
  @moduledoc """
  GH 2534 PR 7b-2a test helpers (`lib/letflow/design/gh2534-7b2a-script-policy.md` section 12):
  entity definitions (active or never activated), type and field restrictions, readable-master
  flags, a script manifest with `reads`, and audit-entry lookups. Every row is written into
  the fixture tenant's own schema.
  """

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Definitions
  alias Letflow.Repo
  alias Letflow.Scripts.Policy

  @fields ["name", "tier", "ssn"]

  @doc "The field names `active_definition!/2` declares by default."
  @spec default_fields() :: [String.t()]
  def default_fields, do: @fields

  @doc "Creates and activates an entity definition `name` with string `fields`."
  @spec active_definition!(String.t(), String.t(), [String.t()]) :: :ok
  def active_definition!(schema, name, fields \\ @fields) do
    {:ok, definition} = create_definition(schema, name, fields)

    {:ok, _activated} =
      Definitions.activate_definition(definition.name, Ecto.UUID.generate(), "go-live", schema)

    :ok
  end

  @doc "Creates an entity definition that is never activated."
  @spec inactive_definition!(String.t(), String.t()) :: :ok
  def inactive_definition!(schema, name) do
    {:ok, _definition} = create_definition(schema, name, @fields)
    :ok
  end

  defp create_definition(schema, name, fields) do
    Definitions.create_definition(
      %{
        definition: %{
          name: name,
          display_name: String.capitalize(name),
          fields: Enum.map(fields, &%{name: &1, type: :string, queried: true})
        },
        created_by: Ecto.UUID.generate()
      },
      schema
    )
  end

  @doc "Inserts an `entity_type_restrictions` row (REQ-394)."
  @spec restrict_type!(String.t(), String.t()) :: :ok
  def restrict_type!(schema, entity_type) do
    now = NaiveDateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        "entity_type_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: entity_type,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: schema
      )

    :ok
  end

  @doc "Inserts an `entity_field_restrictions` row (REQ-231)."
  @spec restrict_field!(String.t(), String.t(), String.t()) :: :ok
  def restrict_field!(schema, entity_type, field_name) do
    now = NaiveDateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: entity_type,
            field_name: field_name,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: schema
      )

    :ok
  end

  @doc "An interactive (OIDC) tenant actor."
  @spec actor(Ecto.UUID.t()) :: map()
  def actor(user_id \\ Ecto.UUID.generate()),
    do: %{user_id: user_id, credential: :oidc, trace_id: "script-policy-test-trace"}

  @doc "Flags `entity_type` through the context (it must have an active definition)."
  @spec flag!(String.t(), String.t()) :: :ok
  def flag!(schema, entity_type) do
    {:ok, :created, _master} = Policy.set_readable_master(schema, entity_type, "test", actor())
    :ok
  end

  @doc "Inserts a readable-master row directly (bypasses the definition checks)."
  @spec flag_raw!(String.t(), String.t()) :: :ok
  def flag_raw!(schema, entity_type) do
    {1, _} =
      Repo.insert_all(
        "script_readable_masters",
        [
          %{
            entity_type: entity_type,
            set_by: Ecto.UUID.bingenerate(),
            set_at: NaiveDateTime.utc_now(),
            reason: "raw",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: schema
      )

    :ok
  end

  @doc "Turns the tenant latch on or off through the context."
  @spec kill_switch!(String.t(), boolean()) :: :ok
  def kill_switch!(schema, on) do
    {:ok, _policy} = Policy.set_tenant_kill_switch(schema, on, "test", actor())
    :ok
  end

  @doc "A by-id read of `entity_type` delivered under `name`."
  @spec id_read(String.t(), String.t(), [String.t()]) :: map()
  def id_read(name, entity_type, fields \\ ["name"]) do
    %{
      "name" => name,
      "entity_type" => entity_type,
      "match" => %{"id_from" => "cid"},
      "fields" => fields
    }
  end

  @doc "An equality read (`match.field == input[value_from]`)."
  @spec field_read(String.t(), String.t(), String.t(), map()) :: map()
  def field_read(name, entity_type, match_field, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "entity_type" => entity_type,
        "match" => %{"field" => match_field, "value_from" => "tier"},
        "fields" => ["name"],
        "limit" => 5
      },
      extra
    )
  end

  @doc "A manifest whose input carries `cid` (string) and `tier` (string), with `reads`."
  @spec manifest([map()]) :: map()
  def manifest(reads) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"cid" => %{"type" => "string"}, "tier" => %{"type" => "string"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      },
      "fail_codes" => ["missing"],
      "reads" => reads
    }
  end

  @doc "Audit entries of `action` in `schema`'s chain, oldest first."
  @spec entries(String.t(), String.t()) :: [Entry.t()]
  def entries(schema, action) do
    Entry
    |> where([e], e.action == ^action)
    |> order_by([e], asc: e.timestamp)
    |> Repo.all(prefix: schema)
  end

  @doc "Every `script_policy.*` entry in `schema`'s chain."
  @spec policy_entries(String.t()) :: [Entry.t()]
  def policy_entries(schema) do
    Entry
    |> where([e], like(e.action, "script_policy.%"))
    |> Repo.all(prefix: schema)
  end
end
