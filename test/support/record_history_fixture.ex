defmodule Letflow.Support.RecordHistoryFixture do
  @moduledoc """
  REQ-516 S2 (GH #2701) fixtures for the record history read: a provisioned tenant with an
  active `case_file` type (fields `title` and `secret`), a restriction row on `secret`, users
  with or without a `secret` grant, tokens for them, and record writes that leave history on the
  type's synthetic instance (`Letflow.Entities.EntityTypeInstance`).
  """

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.ScriptTaskFixture, as: F

  @type_name "case_file"

  @doc "The entity type name the fixtures use."
  def type_name, do: @type_name

  @doc """
  A provisioned tenant: event types seeded, `case_file` active with fields `title` and `secret`,
  and a restriction row on `case_file.secret`. The returned map carries `author`, the user who
  wrote the definition and the records.
  """
  def tenant!(slug_prefix) do
    t = F.tenant!(slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(t.schema_name)
    author = user!(t)

    {:ok, _definition} =
      Definitions.create_definition(
        %{definition: document(), created_by: author.id},
        t.schema_name
      )

    {:ok, _activated} =
      Definitions.activate_definition(@type_name, author.id, "test go-live", t.schema_name)

    Repo.insert_all(
      "entity_field_restrictions",
      [restriction_row("secret")],
      prefix: t.schema_name
    )

    Map.put(t, :author, author)
  end

  defp document do
    %{
      name: @type_name,
      display_name: "Case file",
      fields: [
        %{name: "title", type: :string, required: true},
        %{name: "secret", type: :string, required: false}
      ]
    }
  end

  defp restriction_row(field_name) do
    %{
      id: Ecto.UUID.bingenerate(),
      entity_type: @type_name,
      field_name: field_name,
      inserted_at: NaiveDateTime.utc_now(),
      updated_at: NaiveDateTime.utc_now()
    }
  end

  @doc "Removes every restriction row of the tenant (the H3 consequence)."
  def remove_restrictions!(t) do
    Repo.delete_all(from(r in "entity_field_restrictions"), prefix: t.schema_name)
    :ok
  end

  @doc "An active user of the tenant with no grants."
  def user!(t) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req516-#{Ecto.UUID.generate()}",
      display_name: "REQ-516 History Test User",
      email: "req516-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: t.schema_name)
  end

  @doc "Grants `user` the `secret` field of `case_file` (a `user_entity_grants` row)."
  def grant_secret!(t, user) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user.id),
          entity_type: @type_name,
          field_name: "secret",
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema_name
    )

    :ok
  end

  @doc "A bearer token for `user` holding `roles`."
  def token!(t, user, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: t.schema_name)

    plaintext
  end

  @doc "Creates a `case_file` record as the tenant's author; returns its record id."
  def record!(t, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: @type_name,
          field_values: field_values,
          actor_id: t.author.id,
          idempotency_key: Ecto.UUID.generate()
        },
        t.schema_name
      )

    record.record_id
  end

  @doc "Updates a `case_file` record as the tenant's author."
  def update!(t, record_id, field_values) do
    {:ok, _result} =
      Records.update_record(
        %{
          entity_type: @type_name,
          record_id: record_id,
          field_values: field_values,
          actor_id: t.author.id,
          idempotency_key: Ecto.UUID.generate()
        },
        t.schema_name
      )

    :ok
  end

  @doc "Soft-deletes a `case_file` record as the tenant's author."
  def delete!(t, record_id) do
    {:ok, _result} =
      Records.delete_record(
        %{
          entity_type: @type_name,
          record_id: record_id,
          actor_id: t.author.id,
          idempotency_key: Ecto.UUID.generate()
        },
        t.schema_name
      )

    :ok
  end
end
