defmodule Letflow.IntegrationMappings do
  @moduledoc """
  REQ-565 slice 1 (GH #3201) -- tenant integration mappings: a declarative, stored payload mapping.

  A mapping is **data, not code**. It is a name, a direction (`"outbound"` | `"inbound"`) and a list
  of at most 100 rules; each rule copies a value from a source path (`from`, optionally
  `required`) or writes a literal (`const`) to a target path (`to`). Nothing here evaluates
  anything: no `Code.eval_*`, no script sandbox (INV-3 does not apply, there is no untrusted
  runtime), no template engine. Strings such as `"\#{1+1}"`, `"{{x}}"` or `"$(x)"` are inert text
  in a `const` and are refused in a `from` path (a path segment is `[A-Za-z0-9_-]+`).

  A `const` is public configuration and is **never a secret** (INV-4): there is no credential
  column, no mapping response or audit event carries a signing key, and secrets stay behind
  `Letflow.Secrets` references. The audit entry names only the id, name and direction.

  ## `apply_mapping/2`

  Pure: reads no config, calls no `Repo`. `payload` is a JSON-shaped map with string keys.
  `from` descends segment by segment: a map by key, a list by a decimal index. A missing path
  leaves the target key out; a missing `required` source returns
  `{:error, {:required_missing, rule_index}}` (0-based, no value in the error). A present `nil`
  is copied. `to` always builds nested **object** keys; a digit segment in a `to` path is an object
  key, not an array index (only `from` paths index into arrays). The output is built only from the
  rules. Conflicting `to` paths cannot occur because `validate_definition/1` refuses them at save.

  ## Storage

  Per-tenant table `integration_mappings`; every `Repo` call passes `prefix:` (INV-1, INV-6) and
  the row `tenant_id` comes from the schema prefix, never from a request. Create, update and
  delete write their audit entry in the same transaction.

  ## Slice 2: webhook link

  A webhook subscription may link one `"outbound"` mapping (`webhook_subscriptions.outbound_mapping_id`,
  set by `PATCH /webhooks/subscriptions/:id`); `Letflow.Webhooks.deliver/3` then applies it to the
  redacted payload before encoding and signing. `delete/3` refuses (`:in_use`) while a subscription
  references the mapping. Rules edited later apply from the next delivery; a linked mapping turned
  `"inbound"` by `update/4` is treated as not found at delivery (fail closed).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.IntegrationMappings.Mapping
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @max_rules 100
  @max_name 100
  @max_path 200
  @max_depth 8
  @rule_keys ~w(to from const required)
  @segment ~r/\A[A-Za-z0-9_-]+\z/

  @type definition :: %{String.t() => term()}
  @type invalid ::
          :name
          | :direction
          | :rules
          | :too_many_rules
          | :unknown_rule_key
          | :rule_shape
          | :path_length
          | :path_depth
          | :path_segment
          | :to_conflict
          | :name_taken

  # -- pure: validation ---------------------------------------------------------------------

  @doc """
  Validates a string-keyed definition. Unknown top-level keys (a `tenant_id`, say) are ignored and
  never read. Returns the normalized `%{"name", "direction", "rules"}` or
  `{:error, {:invalid, code}}`.
  """
  @spec validate_definition(term()) :: {:ok, definition()} | {:error, {:invalid, invalid()}}
  def validate_definition(%{} = attrs) when not is_struct(attrs) do
    name = Map.get(attrs, "name")
    direction = Map.get(attrs, "direction")
    rules = Map.get(attrs, "rules")

    with :ok <- check_name(name),
         :ok <- check_direction(direction),
         :ok <- check_rules_list(rules),
         :ok <- check_each_rule(rules),
         :ok <- check_to_conflicts(rules) do
      {:ok, %{"name" => name, "direction" => direction, "rules" => Enum.map(rules, &normalize/1)}}
    else
      {:error, code} -> {:error, {:invalid, code}}
    end
  end

  def validate_definition(_other), do: {:error, {:invalid, :rules}}

  defp check_name(name) when is_binary(name) do
    if String.valid?(name) and length(String.codepoints(name)) in 1..@max_name,
      do: :ok,
      else: {:error, :name}
  end

  defp check_name(_), do: {:error, :name}

  defp check_direction(d) when d in ["outbound", "inbound"], do: :ok
  defp check_direction(_), do: {:error, :direction}

  defp check_rules_list(rules) when is_list(rules) and length(rules) <= @max_rules, do: :ok
  defp check_rules_list(rules) when is_list(rules), do: {:error, :too_many_rules}
  defp check_rules_list(_), do: {:error, :rules}

  defp check_each_rule(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case check_rule(rule) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_rule(%{} = rule) when not is_struct(rule) do
    cond do
      not Enum.all?(Map.keys(rule), &(&1 in @rule_keys)) ->
        {:error, :unknown_rule_key}

      not Map.has_key?(rule, "to") ->
        {:error, :rule_shape}

      Map.has_key?(rule, "from") == Map.has_key?(rule, "const") ->
        {:error, :rule_shape}

      true ->
        with :ok <- check_required(rule),
             :ok <- check_const(rule),
             {:ok, _} <- parse_path(rule["to"]) do
          if Map.has_key?(rule, "from"), do: ok(parse_path(rule["from"])), else: :ok
        end
    end
  end

  defp check_rule(_), do: {:error, :rule_shape}

  defp ok({:ok, _}), do: :ok
  defp ok({:error, _} = err), do: err

  defp check_required(%{"required" => r} = rule) do
    if is_boolean(r) and Map.has_key?(rule, "from"), do: :ok, else: {:error, :rule_shape}
  end

  defp check_required(_), do: :ok

  defp check_const(%{"const" => c})
       when is_binary(c) or is_number(c) or is_boolean(c) or is_nil(c),
       do: :ok

  defp check_const(%{"const" => _}), do: {:error, :rule_shape}
  defp check_const(_), do: :ok

  defp parse_path(path) when is_binary(path) do
    segments = String.split(path, ".")

    cond do
      length(String.codepoints(path)) > @max_path -> {:error, :path_length}
      length(segments) > @max_depth -> {:error, :path_depth}
      not Enum.all?(segments, &Regex.match?(@segment, &1)) -> {:error, :path_segment}
      true -> {:ok, segments}
    end
  end

  defp parse_path(_), do: {:error, :rule_shape}

  defp check_to_conflicts(rules) do
    paths = Enum.map(rules, &String.split(&1["to"], "."))

    conflict? =
      paths
      |> Enum.with_index()
      |> Enum.any?(fn {p, i} ->
        paths |> Enum.drop(i + 1) |> Enum.any?(&(prefix?(p, &1) or prefix?(&1, p)))
      end)

    if conflict?, do: {:error, :to_conflict}, else: :ok
  end

  defp prefix?(short, long), do: Enum.take(long, length(short)) == short

  defp normalize(rule), do: Map.take(rule, @rule_keys)

  # -- pure: apply ---------------------------------------------------------------------------

  @doc """
  Applies the rules of a stored (validated) mapping to a JSON-shaped payload. See the moduledoc.
  """
  @spec apply_mapping(%{rules: [map()]}, map()) ::
          {:ok, map()} | {:error, {:required_missing, non_neg_integer()}}
  def apply_mapping(%{rules: rules}, payload) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {rule, index}, {:ok, acc} ->
      case apply_rule(rule, payload, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :missing_required -> {:halt, {:error, {:required_missing, index}}}
      end
    end)
  end

  defp apply_rule(%{"const" => value} = rule, _payload, acc) do
    {:ok, put_path(acc, String.split(rule["to"], "."), value)}
  end

  defp apply_rule(%{"from" => from} = rule, payload, acc) do
    case fetch_path(payload, String.split(from, ".")) do
      {:ok, value} -> {:ok, put_path(acc, String.split(rule["to"], "."), value)}
      :error -> if rule["required"] == true, do: :missing_required, else: {:ok, acc}
    end
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(%{} = map, [seg | rest]) when not is_struct(map) do
    case Map.fetch(map, seg) do
      {:ok, v} -> fetch_path(v, rest)
      :error -> :error
    end
  end

  defp fetch_path(list, [seg | rest]) when is_list(list) do
    with {index, ""} when index >= 0 <- Integer.parse(seg),
         true <- index < length(list) do
      fetch_path(Enum.at(list, index), rest)
    else
      _ -> :error
    end
  end

  defp fetch_path(_other, _segments), do: :error

  defp put_path(acc, [key], value), do: Map.put(acc, key, value)

  defp put_path(acc, [key | rest], value),
    do: Map.put(acc, key, put_path(Map.get(acc, key, %{}), rest, value))

  # -- storage -------------------------------------------------------------------------------

  @doc "All mappings of the tenant behind `prefix`, ordered by name."
  @spec list(String.t()) :: [Mapping.t()]
  def list(prefix) do
    Repo.all(from(m in Mapping, order_by: [asc: m.name]), prefix: prefix)
  end

  @doc "One mapping of the tenant behind `prefix`; a malformed id is `:not_found` without a query."
  @spec get(String.t(), String.t()) :: {:ok, Mapping.t()} | {:error, :not_found}
  def get(id, prefix) do
    with {:ok, uuid} <- cast_id(id),
         %Mapping{} = m <- Repo.get(Mapping, uuid, prefix: prefix) do
      {:ok, m}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec create(term(), String.t() | nil, String.t()) ::
          {:ok, Mapping.t()} | {:error, {:invalid, invalid()} | :internal}
  def create(attrs, actor_id, prefix) do
    with {:ok, defn} <- validate_definition(attrs),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      run(fn ->
        changeset =
          %Mapping{tenant_id: tenant_id, updated_by: actor_id}
          |> Ecto.Changeset.change(atomize(defn))
          |> Ecto.Changeset.unique_constraint(:name, name: :integration_mappings_name_index)

        row = write(Repo.insert(changeset, prefix: prefix))
        audit!(prefix, actor_id, "create", row.id, nil, state(row))
        row
      end)
    else
      {:error, {:invalid, _}} = err -> err
      {:error, _} -> {:error, :internal}
    end
  end

  @spec update(String.t(), term(), String.t() | nil, String.t()) ::
          {:ok, Mapping.t()} | {:error, {:invalid, invalid()} | :not_found | :internal}
  def update(id, attrs, actor_id, prefix) do
    with {:ok, row} <- get(id, prefix),
         {:ok, defn} <- validate_definition(attrs) do
      run(fn ->
        changeset =
          row
          |> Ecto.Changeset.change(Map.put(atomize(defn), :updated_by, actor_id))
          |> Ecto.Changeset.unique_constraint(:name, name: :integration_mappings_name_index)

        updated = write(Repo.update(changeset, prefix: prefix))
        audit!(prefix, actor_id, "update", updated.id, state(row), state(updated))
        updated
      end)
    end
  end

  @doc """
  Deletes a mapping unless a webhook subscription of the tenant still links it (`{:error, :in_use}`).
  The row is re-selected `FOR UPDATE` inside the transaction and the reference check runs after
  that lock is held; `Letflow.Webhooks.update/3` links under `FOR SHARE` on the same row, so a
  concurrent link either commits before the check (409) or finds the row gone (422).
  """
  @spec delete(String.t(), String.t() | nil, String.t()) ::
          {:ok, Mapping.t()} | {:error, :not_found | :in_use | :internal}
  def delete(id, actor_id, prefix) do
    with {:ok, row} <- get(id, prefix) do
      run(fn ->
        locked = lock_for_delete(row.id, prefix)
        if referenced?(locked.id, prefix), do: Repo.rollback(:in_use)
        deleted = write(Repo.delete(locked, prefix: prefix))
        audit!(prefix, actor_id, "delete", deleted.id, state(locked), nil)
        deleted
      end)
    end
  end

  # A concurrent delete between get/2 and the lock leaves no row: not found, never a stale delete.
  defp lock_for_delete(id, prefix) do
    query = from(m in Mapping, where: m.id == ^id, lock: "FOR UPDATE")

    case Repo.one(query, prefix: prefix) do
      %Mapping{} = locked -> locked
      nil -> Repo.rollback(:not_found)
    end
  end

  # Schemaless source on purpose: this module does not depend on Letflow.Webhooks.
  defp referenced?(id, prefix) do
    query =
      from(s in "webhook_subscriptions", where: s.outbound_mapping_id == type(^id, :binary_id))

    Repo.exists?(query, prefix: prefix)
  end

  @doc """
  The outbound mapping `id` of the tenant behind `prefix`, for `Letflow.Webhooks.deliver/3`. An
  unknown, malformed or non-outbound (for example inbound) mapping is `{:error, :not_found}`.
  """
  @spec fetch_outbound(term(), String.t()) :: {:ok, Mapping.t()} | {:error, :not_found}
  def fetch_outbound(id, prefix) do
    with {:ok, uuid} <- cast_id(id),
         %Mapping{direction: "outbound"} = m <- Repo.get(Mapping, uuid, prefix: prefix) do
      {:ok, m}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Like `fetch_outbound/2`, but takes `FOR SHARE` on the row. Call it only inside the transaction
  that writes the link, so a concurrent `delete/3` waits for that transaction.
  """
  @spec lock_outbound_for_link(term(), String.t()) :: {:ok, Mapping.t()} | {:error, :not_found}
  def lock_outbound_for_link(id, prefix) do
    with {:ok, uuid} <- cast_id(id),
         query =
           from(m in Mapping,
             where: m.id == ^uuid and m.direction == "outbound",
             lock: "FOR SHARE"
           ),
         %Mapping{} = m <- Repo.one(query, prefix: prefix) do
      {:ok, m}
    else
      _ -> {:error, :not_found}
    end
  end

  defp run(fun) do
    case Repo.transaction(fun) do
      {:ok, row} -> {:ok, row}
      {:error, {:invalid, _} = reason} -> {:error, reason}
      {:error, :in_use} -> {:error, :in_use}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _other} -> {:error, :internal}
    end
  end

  defp write({:ok, row}), do: row

  defp write({:error, %Ecto.Changeset{errors: errors}}) do
    if Keyword.has_key?(errors, :name),
      do: Repo.rollback({:invalid, :name_taken}),
      else: Repo.rollback(:write_failed)
  end

  defp audit!(prefix, actor_id, action, id, before_state, after_state) do
    entry = %{
      actor_id: actor_id,
      action: action,
      resource_type: "integration_mapping",
      resource_id: id,
      before_state: before_state,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # Audit state: identity only, never the rules (a const must not travel into the audit log).
  defp state(%Mapping{} = m), do: %{"id" => m.id, "name" => m.name, "direction" => m.direction}

  defp atomize(%{"name" => n, "direction" => d, "rules" => r}),
    do: %{name: n, direction: d, rules: r}

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_), do: :error
end
