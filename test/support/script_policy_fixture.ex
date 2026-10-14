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

  # ── query probe (test-only; no production seam) ─────────────────────────────

  @probe_key {__MODULE__, :probe}

  @doc """
  Attaches a `[:letflow, :repo, :query]` handler for the calling test (detached `on_exit`).
  Ecto emits the event in the process that ran the query, AFTER the query returned (so a lock
  it took is held). In a process armed with `arm_probe/2`, the first query whose SQL satisfies
  the armed predicate sends `{:probe_hit, pid}` to the test and blocks that process (inside its
  transaction, if any) until it receives `:probe_continue`.
  """
  @spec attach_probe!() :: :ok
  def attach_probe! do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler_id, [:letflow, :repo, :query], &__MODULE__.handle_probe/4, nil)

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc "Arms the probe in the CALLING process (the one whose query must be caught)."
  @spec arm_probe(pid(), (String.t() -> boolean())) :: :ok
  def arm_probe(test_pid, predicate) when is_function(predicate, 1) do
    Process.put(@probe_key, {test_pid, predicate})
    :ok
  end

  @doc false
  def handle_probe(_event, _measurements, metadata, _config) do
    with {test_pid, predicate} <- Process.get(@probe_key),
         query when is_binary(query) <- Map.get(metadata, :query),
         true <- predicate.(query) do
      Process.delete(@probe_key)
      send(test_pid, {:probe_hit, self()})

      receive do
        :probe_continue -> :ok
      after
        15_000 -> :ok
      end
    end

    :ok
  end

  # ── 7b-2b: tenant-wide admins through the real GH #2547 paths ───────────────

  @doc "Seeds the platform role groups (TENANT_ADMIN's group among them) into `schema`."
  @spec seed_roles!(String.t()) :: :ok
  def seed_roles!(schema) do
    {:ok, _roles} =
      Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(prefix: schema)

    :ok
  end

  @doc "An active internal user of `schema` (no role)."
  @spec user!(String.t()) :: Ecto.UUID.t()
  def user!(schema) do
    n = System.unique_integer([:positive])

    %Letflow.Identity.User{}
    |> Ecto.Changeset.change(%{
      username: "gh2534-sod-#{n}",
      display_name: "SoD #{n}",
      email: "gh2534-sod-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
    |> Map.fetch!(:id)
  end

  @doc "Makes `user_id` a TENANT_ADMIN group member via `Identity.add_group_member/3` (audited, locked)."
  @spec make_admin!(String.t(), Ecto.UUID.t()) :: Ecto.UUID.t()
  def make_admin!(schema, user_id) do
    group_id =
      Repo.one!(
        from(t in Letflow.Identity.TenantRole,
          where: t.name == "TENANT_ADMIN" and t.kind == :platform_role,
          select: t.group_id
        ),
        prefix: schema
      )

    {:ok, %{created: true}} =
      Letflow.Identity.add_group_member(group_id, user_id, prefix: schema)

    user_id
  end

  @doc "A fresh active user made a tenant-wide admin through the group path."
  @spec admin!(String.t()) :: Ecto.UUID.t()
  def admin!(schema), do: make_admin!(schema, user!(schema))

  @doc "A fresh active user owning a TENANT_ADMIN API token (`Identity.create_token/3`)."
  @spec token_admin!(String.t()) :: {Ecto.UUID.t(), Ecto.UUID.t()}
  def token_admin!(schema) do
    user_id = user!(schema)

    {:ok, %{token: token}} =
      Letflow.Identity.create_token(user_id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: schema
      )

    {user_id, token.id}
  end

  @doc "An operator map whose platform chain is `platform_schema`."
  @spec operator(String.t()) :: map()
  def operator(platform_schema),
    do: %{
      user_id: Ecto.UUID.generate(),
      credential: :oidc,
      trace_id: "operator-trace",
      platform_prefix: platform_schema
    }

  @doc "The platform allows solo_audited for the tenant (context call)."
  @spec allow_solo!(String.t(), Ecto.UUID.t(), String.t()) :: :ok
  def allow_solo!(schema, tenant_id, platform_schema \\ nil) do
    {:ok, _policy} =
      Policy.set_platform_solo_audited(
        schema,
        tenant_id,
        true,
        "allow",
        operator(platform_schema || schema)
      )

    :ok
  end

  @doc "Allows solo mode and declares it, as `admin_id` (who must be the sole admin)."
  @spec solo!(String.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def solo!(schema, tenant_id, admin_id) do
    allow_solo!(schema, tenant_id)
    {:ok, _policy} = Policy.set_sod(schema, "solo_audited", "sole admin", actor(admin_id))
    :ok
  end

  @doc "Every `script_policy.*` entry in `schema`'s chain."
  @spec policy_entries(String.t()) :: [Entry.t()]
  def policy_entries(schema) do
    Entry
    |> where([e], like(e.action, "script_policy.%"))
    |> Repo.all(prefix: schema)
  end
end
