defmodule Letflow.Entities.Views do
  @moduledoc """
  Saved view definitions (REQ-555, GH #3157, decision 0066 D1..D7; pivot kind REQ-598, GH #3367).

  A `pivot` view stores a filter, `group_by` and `aggregates` instead of columns and sort.
  A view is a named, tenant-shared definition over ONE entity type: ordered `columns`, a `filter` and
  a `sort` in the wire shape of `POST /entities/query`. It stores no record value and no function
  here reads a record: a list screen replays a stored view through the ordinary query route, which
  applies type access and field grants to the caller of the query (D3).

  A plain transactional context (no process): `Ecto.Multi` writes the row and its audit entry in one
  transaction. The tenant comes only from `prefix` (INV-1) and the actor only from `user_id`.

  **Visibility (INV-5, D6).** A view whose entity type `Letflow.Entities.TypeAccess` denies the
  caller is dropped from `list/3` and is `{:error, :not_found}` for `get/3`, `update/4` and
  `delete/3`, exactly like an absent, malformed or other-tenant id (the row is simply not in this
  schema). Create answers the same `:not_found` for an unknown or denied type.

  Order on write: shape (`Clauses.parse_body/2`), then visibility, then the query-route clause rules
  (`Clauses.check/3`), then the write. A refusal returns before the `Multi`, so it writes no audit
  entry. A duplicate `(entity_type, name)` is `{:error, :name_taken}`, detected by the unique index.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Entities.TypeAccess
  alias Letflow.Entities.Views.Clauses
  alias Letflow.Entities.Views.View
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @unique_index :entity_views_entity_type_name_index

  @type error :: :not_found | :name_taken | {:unprocessable, String.t()} | term()

  @doc "Lists the views the caller may see, optionally of one entity type, by type then name."
  @spec list(String.t(), String.t(), String.t() | nil) :: {:ok, [View.t()]} | {:error, term()}
  def list(prefix, user_id, entity_type \\ nil) do
    query = from(v in View, order_by: [asc: v.entity_type, asc: v.name])

    query =
      if is_binary(entity_type), do: where(query, [v], v.entity_type == ^entity_type), else: query

    views = Repo.all(query, prefix: prefix)

    with {:ok, denied} <-
           TypeAccess.denied_types(user_id, Enum.map(views, & &1.entity_type), prefix) do
      {:ok, Enum.reject(views, &MapSet.member?(denied, &1.entity_type))}
    end
  end

  @doc "One view, or `{:error, :not_found}` for an absent, malformed, other-tenant or denied id."
  @spec get(String.t(), String.t(), term()) :: {:ok, View.t()} | {:error, :not_found | term()}
  def get(prefix, user_id, id) do
    with {:ok, uuid} <- cast_id(id),
         %View{} = view <- Repo.get(View, uuid, prefix: prefix),
         :ok <- visible(prefix, user_id, view.entity_type) do
      {:ok, view}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Creates a view from a request body (string keys)."
  @spec create(String.t(), String.t(), map()) :: {:ok, View.t()} | {:error, error()}
  def create(prefix, user_id, body) do
    with {:ok, shaped} <- Clauses.parse_body(body, :create),
         :ok <- visible(prefix, user_id, shaped.entity_type),
         :ok <- Clauses.check(prefix, shaped.entity_type, shaped),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      attrs =
        shaped
        |> Map.merge(%{tenant_id: tenant_id, created_by: user_id, updated_by: user_id})
        |> Map.put(:id, Ecto.UUID.generate())

      view = struct!(View, attrs)

      Multi.new()
      |> Multi.insert(:view, view |> Ecto.Changeset.change() |> unique_name(), prefix: prefix)
      |> audit("entity_view.create", user_id, prefix, nil)
      |> run(:view)
    end
  end

  @doc """
  Replaces the name and clauses of a view (columns, filter, sort; group_by and aggregates for a
  pivot); the entity type and the kind cannot change.
  """
  @spec update(String.t(), String.t(), term(), map()) :: {:ok, View.t()} | {:error, error()}
  def update(prefix, user_id, id, body) do
    with {:ok, view} <- get(prefix, user_id, id),
         {:ok, shaped} <- Clauses.parse_body(body, :update, view.kind),
         :ok <- same_type(shaped, view),
         :ok <- Clauses.check(prefix, view.entity_type, shaped) do
      # updated_at is forced so a PUT that changes nothing still moves it and updated_by, matching its audit entry.
      changes =
        shaped
        |> Map.take([:name, :columns, :filter, :sort, :group_by, :aggregates])
        |> Map.merge(%{updated_by: user_id, updated_at: DateTime.utc_now()})

      Multi.new()
      |> Multi.update(:view, view |> Ecto.Changeset.change(changes) |> unique_name(),
        prefix: prefix
      )
      |> audit("entity_view.update", user_id, prefix, view)
      |> run(:view)
    end
  end

  @doc "Deletes a view."
  @spec delete(String.t(), String.t(), term()) :: {:ok, View.t()} | {:error, error()}
  def delete(prefix, user_id, id) do
    with {:ok, view} <- get(prefix, user_id, id) do
      Multi.new()
      |> Multi.delete(:view, Ecto.Changeset.change(view), prefix: prefix)
      |> audit("entity_view.delete", user_id, prefix, view)
      |> run(:view)
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp visible(prefix, user_id, entity_type) do
    case TypeAccess.authorized?(user_id, entity_type, prefix) do
      {:ok, :allowed} -> :ok
      {:ok, :denied} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp same_type(%{entity_type: type}, %View{entity_type: stored}) when type != stored,
    do: {:error, {:unprocessable, "entity_type_immutable"}}

  defp same_type(_shaped, _view), do: :ok

  # Lets the unique index report a duplicate name as a changeset error instead of raising.
  defp unique_name(changeset),
    do: Ecto.Changeset.unique_constraint(changeset, :name, name: @unique_index)

  defp audit(multi, action, user_id, prefix, before_view) do
    Multi.run(multi, :audit, fn _repo, %{view: view} ->
      Audit.insert_entry(
        Repo,
        %{
          actor_id: user_id,
          action: action,
          resource_type: "entity_view",
          resource_id: view.id,
          before_state: before_view && Audit.struct_state(before_view),
          after_state: if(action == "entity_view.delete", do: nil, else: Audit.struct_state(view))
        },
        prefix
      )
    end)
  end

  defp run(multi, key) do
    case Repo.transaction(multi) do
      {:ok, changes} -> {:ok, Map.fetch!(changes, key)}
      {:error, :view, %Ecto.Changeset{errors: errors}, _} -> name_taken_or_invalid(errors)
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp name_taken_or_invalid(errors) do
    if Keyword.has_key?(errors, :name), do: {:error, :name_taken}, else: {:error, :invalid}
  end
end
