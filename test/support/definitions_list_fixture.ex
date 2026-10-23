defmodule Letflow.TestSupport.DefinitionsListFixture do
  @moduledoc """
  Deterministic fixture for the GH #2739 tests (`GET /entities/definitions` and
  `Definitions.list_definitions/3` honouring `TypeAccess`).

  Every fixture row has a FIXED uuid and a FIXED, pairwise-distinct `inserted_at`
  (no wall clock), so two tenants ("worlds") seeded from the same row table list
  identically and keyset ordering never depends on insertion timing.

  Row table, oldest to newest (`x_ent` is the type the tests restrict):

      n  key  name   status
      1  x0   x_ent  inactive
      2  a1   a_ent  inactive
      3  x1   x_ent  inactive
      4  a2   a_ent  inactive
      5  x2   x_ent  active
      6  a3   a_ent  active
      7  b1   b_ent  active
      8  x3   x_ent  inactive

  Listing is newest first, so the raw order is `x3 b1 a3 x2 a2 x1 a1 x0`: a denied
  row leads the list (x3), denied rows are interleaved (x2, x1) and a denied row
  ends the list (x0, the "trailing denied tail"). The visible order for a caller
  denied `x_ent` is `b1 a3 a2 a1`.

  `world: :with_x` seeds every row; `world: :without_x` seeds the same rows minus
  the `x_ent` versions (same ids, same timestamps for the rest).

  Test-only; compiled under `elixirc_paths(:test)`, never referenced from `lib/`.
  """

  alias Letflow.Entities.EntityDefinition
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Repository

  @base ~U[2026-03-01 00:00:00.000000Z]

  @denied_name "x_ent"

  # {key, name, n, status}
  @rows [
    {:x0, "x_ent", 1, :inactive},
    {:a1, "a_ent", 2, :inactive},
    {:x1, "x_ent", 3, :inactive},
    {:a2, "a_ent", 4, :inactive},
    {:x2, "x_ent", 5, :active},
    {:a3, "a_ent", 6, :active},
    {:b1, "b_ent", 7, :active},
    {:x3, "x_ent", 8, :inactive}
  ]

  @doc "The type name the tests restrict."
  @spec denied_name() :: String.t()
  def denied_name, do: @denied_name

  @doc "The fixed uuid of a fixture row key (`:x0` .. `:x3`, `:a1` .. `:a3`, `:b1`)."
  @spec id(atom()) :: String.t()
  def id(key) do
    {_key, _name, n, _status} = row!(key)
    id_for(n)
  end

  @doc "The fixed `inserted_at` of a fixture row key."
  @spec inserted_at(atom()) :: DateTime.t()
  def inserted_at(key) do
    {_key, _name, n, _status} = row!(key)
    timestamp_for(n)
  end

  @doc "Row keys of a world, newest first (the raw list order)."
  @spec keys(:with_x | :without_x) :: [atom()]
  def keys(world),
    do: world |> rows_of() |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.map(&elem(&1, 0))

  @doc "Row ids of a world, newest first."
  @spec ids(:with_x | :without_x) :: [String.t()]
  def ids(world), do: Enum.map(keys(world), &id/1)

  @doc "Names of a world's rows, newest first."
  @spec names(:with_x | :without_x) :: [String.t()]
  def names(world),
    do: world |> rows_of() |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.map(&elem(&1, 1))

  @doc """
  Inserts the world's rows into the tenant schema. Rows are inserted directly
  (fixed id and `inserted_at`); one real `artifact_versions` row is created
  first because `entity_definitions.artifact_version_id` is a foreign key.
  """
  @spec seed!(schema_name :: String.t(), tenant_id :: String.t(), :with_x | :without_x) ::
          artifact_version_id :: String.t()
  def seed!(schema_name, tenant_id, world) do
    {:ok, %Repository.ArtifactVersion{version_id: artifact_version_id}} =
      Repository.create(
        %{
          artifact_kind: :entity,
          artifact_name: "gh2739_fixture_#{System.unique_integer([:positive])}",
          content_type: "application/json",
          content: "{}",
          created_by: Ecto.UUID.generate()
        },
        schema_name
      )

    for {key, name, n, status} <- rows_of(world) do
      hash = :crypto.hash(:sha256, "gh2739-#{key}")

      Repo.insert!(
        %EntityDefinition{
          id: id_for(n),
          tenant_id: tenant_id,
          name: name,
          display_name: "Display " <> name,
          definition_json: %{"name" => name, "fixture_key" => Atom.to_string(key)},
          content_hash: hash,
          logical_shape_version: hash,
          artifact_version_id: artifact_version_id,
          status: status,
          # GH #2618: every fixture name is `ordinary` (not a backfill-refused name).
          write_class: "ordinary",
          inserted_at: timestamp_for(n)
        },
        prefix: schema_name
      )
    end

    artifact_version_id
  end

  @doc """
  The expected JSON object `GET /entities/definitions` renders for a fixture row,
  WITHOUT `artifact_version_id` (it is a fresh uuid per tenant, so the caller
  compares it separately or masks it). Derived from the fixture row table, not
  captured from the running system.
  """
  @spec golden_item(atom()) :: map()
  def golden_item(key) do
    {^key, name, n, status} = row!(key)
    hash = Base.encode16(:crypto.hash(:sha256, "gh2739-#{key}"), case: :lower)

    %{
      "id" => id_for(n),
      "name" => name,
      "display_name" => "Display " <> name,
      "definition" => %{"name" => name, "fixture_key" => Atom.to_string(key)},
      "content_hash" => hash,
      "logical_shape_version" => hash,
      "status" => Atom.to_string(status),
      "inserted_at" => DateTime.to_iso8601(timestamp_for(n))
    }
  end

  @doc """
  The decoded POSITION of a list cursor: `{id, inserted_at_us}` of the last row it
  names, or `nil` for a nil cursor. A minted cursor embeds the mint time, so two
  non-null cursors are never byte-equal across calls; tests compare this position
  and null-ness instead (design section 10).
  """
  @spec cursor_position(String.t() | nil) :: {String.t(), integer()} | nil
  def cursor_position(nil), do: nil

  def cursor_position(cursor) when is_binary(cursor) do
    {:ok, raw} = Base.url_decode64(cursor, padding: false)
    "ED:" <> rest = raw
    [_mint_time_us, id, inserted_at_us] = String.split(rest, ":", parts: 3)
    {id, String.to_integer(inserted_at_us)}
  end

  @doc "Builds a well-formed `ED:` list cursor naming the position `(id, inserted_at)`."
  @spec craft_cursor(id :: String.t(), inserted_at :: DateTime.t()) :: String.t()
  def craft_cursor(id, %DateTime{} = inserted_at) do
    "ED:"
    |> Letflow.Api.Pagination.build_raw_cursor_timestamp_key(
      System.system_time(:microsecond),
      id,
      DateTime.to_unix(inserted_at, :microsecond)
    )
    |> Letflow.Api.Pagination.encode_cursor()
  end

  @doc "Inserts an `entity_type_restrictions` row for `entity_type`."
  @spec restrict!(schema_name :: String.t(), entity_type :: String.t()) :: :ok
  def restrict!(schema_name, entity_type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema_name
    )

    :ok
  end

  @doc "Inserts a `user_entity_type_grants` row for `(user_id, entity_type)`."
  @spec grant!(schema_name :: String.t(), user_id :: String.t(), entity_type :: String.t()) :: :ok
  def grant!(schema_name, user_id, entity_type) do
    Repo.insert_all(
      "user_entity_type_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema_name
    )

    :ok
  end

  @doc "Inserts a real user in the tenant schema (grants and tokens need one)."
  @spec insert_user!(schema_name :: String.t()) :: User.t()
  def insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2739-#{Ecto.UUID.generate()}",
      display_name: "GH2739 Test User",
      email: "gh2739-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp rows_of(:with_x), do: @rows

  defp rows_of(:without_x),
    do: Enum.reject(@rows, fn {_k, name, _n, _s} -> name == @denied_name end)

  defp row!(key), do: List.keyfind!(@rows, key, 0)

  defp id_for(n),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp timestamp_for(n), do: DateTime.add(@base, n * 60, :second)
end
