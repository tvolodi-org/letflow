defmodule Letflow.Modules.Org.People do
  @moduledoc """
  Preparation of the position and employee writers of module `org` (GH #3617 / REQ-661):
  `create_position/3`, `update_position/4`, `retire_position/3`, `create_employee/3`,
  `update_employee/4`, `transfer_employee/5` and `retire_employee/3`, called through
  `Letflow.Modules.Org`.

  Same shape as `Letflow.Modules.Org.Units`: this module only checks arguments and state and builds
  a write plan; every `Records` and audit call stays in `Letflow.Modules.Org.Masters` (one
  transaction, tenant advisory lock, idempotency replay, one audit entry, nothing written on a
  refusal). No function takes a caller identity, a scope set or a tenant id; `prefix` comes from
  the authenticated tenant on the server side.

  Rules: a position and an employee name a live, active unit; an employee's position must be
  active and of the employee's unit; `user_id` must be a user of the tenant (looked up with the
  tenant prefix, so a user of another tenant is `:user_not_found`). A position is never moved
  between units and an employee changes unit only through `transfer_employee/5`. The audit
  entries of an employee omit `full_name` (personal data), see `Masters`.

  Ids are canonical lowercase uuids; an unknown, soft-deleted, other-type or other-tenant id gets
  the same `*_not_found` tuple (INV-5).
  """

  alias Letflow.Identity
  alias Letflow.Modules.Org.Masters
  alias Letflow.Modules.ReadApi

  @unit "org_unit"
  @position "org_position"
  @employee "org_employee"
  @position_keys ~w(code name org_unit_id external_ref_system external_ref_id)
  @position_update_keys ~w(name external_ref_system external_ref_id)
  @employee_keys ~w(code full_name org_unit_id position_id user_id external_ref_system external_ref_id)
  @employee_update_keys ~w(full_name user_id external_ref_system external_ref_id)

  # --- positions ------------------------------------------------------------------------------

  @doc """
  Creates a position. `attrs` (string keys): `code`, `name`, `org_unit_id` required;
  `external_ref_system`, `external_ref_id` optional. Refusals: `{:field_not_allowed, key}`,
  `{:field_invalid, key}`, `:unit_not_found`, `:unit_inactive`, `{:record_payload_invalid, _}`
  (duplicate code or external reference).
  """
  @spec create_position(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_position(prefix, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "create_position/3")

    Masters.run(prefix, attrs, actor, idem, "org_position.created", @position, fn replay? ->
      prepare_create_position(prefix, attrs, replay?)
    end)
  end

  @doc """
  Changes `name`, `external_ref_system`, `external_ref_id`. `code`, `org_unit_id`, `active` and any
  other key is `{:field_not_allowed, key}`. A change that changes nothing writes nothing.
  """
  @spec update_position(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_position(prefix, id, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "update_position/4")

    Masters.run(prefix, attrs, actor, idem, "org_position.updated", @position, fn _replay? ->
      prepare_update(prefix, id, attrs, @position, :position_not_found, @position_update_keys)
    end)
  end

  @doc """
  Retires a position (`active` false). Already retired: `{:ok, map}` with no write. Refused with
  `:position_in_use` while an active employee holds it.
  """
  @spec retire_position(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_position(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "retire_position/3")

    Masters.run(prefix, %{}, actor, idem, "org_position.retired", @position, fn replay? ->
      with {:ok, rec} <- Masters.fetch(prefix, id, @position, :position_not_found) do
        cond do
          rec["active"] == false ->
            {:noop, rec}

          not replay? and
              Masters.named_by_active?(prefix, [@employee], "position_id", rec["record_id"]) ->
            {:error, :position_in_use}

          true ->
            retire_plan(rec)
        end
      end
    end)
  end

  # --- employees ------------------------------------------------------------------------------

  @doc """
  Creates an employee. `attrs` (string keys): `code`, `full_name`, `org_unit_id` required;
  `position_id`, `user_id`, `external_ref_system`, `external_ref_id` optional. Refusals:
  `{:field_not_allowed, key}`, `{:field_invalid, key}`, `:unit_not_found`, `:unit_inactive`,
  `:position_not_found`, `:position_inactive`, `:position_not_in_unit`, `:user_not_found`,
  `{:record_payload_invalid, _}` (duplicate code, user or external reference).
  """
  @spec create_employee(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_employee(prefix, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "create_employee/3")

    Masters.run(prefix, attrs, actor, idem, "org_employee.created", @employee, fn replay? ->
      prepare_create_employee(prefix, attrs, replay?)
    end)
  end

  @doc """
  Changes `full_name`, `user_id` (nil removes the link), `external_ref_system`, `external_ref_id`.
  `code`, `org_unit_id`, `position_id` (use `transfer_employee/5`), `active` and any other key is
  `{:field_not_allowed, key}`. A retired employee may still be updated.
  """
  @spec update_employee(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_employee(prefix, id, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "update_employee/4")

    Masters.run(prefix, attrs, actor, idem, "org_employee.updated", @employee, fn replay? ->
      with {:ok, rec} <- Masters.fetch(prefix, id, @employee, :employee_not_found),
           :ok <- Masters.check_keys(attrs, @employee_update_keys),
           :ok <- Masters.check_optional_required_text(attrs, "full_name"),
           :ok <- Masters.check_ext(attrs),
           {:ok, attrs} <- cast_user_key(prefix, attrs, replay?) do
        plan_update(rec, attrs)
      end
    end)
  end

  @doc """
  Moves an employee to `org_unit_id` and `position_id` (nil: no position) in one record version.
  Refusals: `:employee_not_found`, `:employee_inactive`, `:unit_not_found`, `:unit_inactive`,
  `:position_not_found`, `:position_inactive`, `:position_not_in_unit`. The same unit and position
  write nothing.
  """
  @spec transfer_employee(String.t(), term(), term(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def transfer_employee(prefix, id, org_unit_id, position_id, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "transfer_employee/5")

    Masters.run(prefix, %{}, actor, idem, "org_employee.transferred", @employee, fn replay? ->
      with {:ok, rec} <- Masters.fetch(prefix, id, @employee, :employee_not_found),
           :ok <- check_employee_active(rec, replay?),
           {:ok, unit} <- check_unit(prefix, org_unit_id, replay?),
           {:ok, position} <- check_position(prefix, position_id, unit, replay?) do
        if same_id?(rec["org_unit_id"], unit) and same_id?(rec["position_id"], position) do
          {:noop, rec}
        else
          fv =
            rec
            |> Masters.state()
            |> Map.put("org_unit_id", unit)
            |> put_or_drop("position_id", position)

          {:write, :update, rec["record_id"], Masters.state(rec), fv}
        end
      end
    end)
  end

  @doc """
  Retires an employee (`active` false); the user link and the position stay on the record.
  Already retired: `{:ok, map}` with no write.
  """
  @spec retire_employee(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_employee(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = Masters.opts!(opts, "retire_employee/3")

    Masters.run(prefix, %{}, actor, idem, "org_employee.retired", @employee, fn _replay? ->
      with {:ok, rec} <- Masters.fetch(prefix, id, @employee, :employee_not_found) do
        if rec["active"] == false, do: {:noop, rec}, else: retire_plan(rec)
      end
    end)
  end

  # --- preparation ----------------------------------------------------------------------------

  defp prepare_create_position(prefix, attrs, replay?) do
    with :ok <- Masters.check_keys(attrs, @position_keys),
         :ok <- Masters.check_required_text(attrs, "code"),
         :ok <- Masters.check_required_text(attrs, "name"),
         :ok <- Masters.check_ext(attrs),
         {:ok, unit} <- check_unit(prefix, Map.get(attrs, "org_unit_id"), replay?) do
      fv =
        attrs
        |> Masters.drop_nils()
        |> Map.put("org_unit_id", unit)
        |> Map.put("active", true)

      {:write, :create, nil, nil, fv}
    end
  end

  defp prepare_create_employee(prefix, attrs, replay?) do
    with :ok <- Masters.check_keys(attrs, @employee_keys),
         :ok <- Masters.check_required_text(attrs, "code"),
         :ok <- Masters.check_required_text(attrs, "full_name"),
         :ok <- Masters.check_ext(attrs),
         {:ok, unit} <- check_unit(prefix, Map.get(attrs, "org_unit_id"), replay?),
         {:ok, position} <- check_position(prefix, Map.get(attrs, "position_id"), unit, replay?),
         {:ok, user} <- check_user(prefix, Map.get(attrs, "user_id"), replay?) do
      fv =
        attrs
        |> Masters.drop_nils()
        |> Map.put("org_unit_id", unit)
        |> Map.put("active", true)
        |> put_or_drop("position_id", position)
        |> put_or_drop("user_id", user)

      {:write, :create, nil, nil, fv}
    end
  end

  # Shared by position and (through plan_update/2) employee updates.
  defp prepare_update(prefix, id, attrs, type, not_found, allowed) do
    with {:ok, rec} <- Masters.fetch(prefix, id, type, not_found),
         :ok <- Masters.check_keys(attrs, allowed),
         :ok <- Masters.check_optional_required_text(attrs, "name"),
         :ok <- Masters.check_ext(attrs) do
      plan_update(rec, attrs)
    end
  end

  defp plan_update(rec, attrs) do
    fv = Masters.merged(rec, attrs)

    if fv == Masters.state(rec),
      do: {:noop, rec},
      else: {:write, :update, rec["record_id"], Masters.state(rec), fv}
  end

  defp retire_plan(rec) do
    {:write, :update, rec["record_id"], Masters.state(rec),
     rec |> Masters.state() |> Map.put("active", false)}
  end

  # --- shared checks --------------------------------------------------------------------------

  defp check_unit(prefix, value, replay?) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         {:ok, unit} <- ReadApi.lookup(prefix, uuid, [@unit]) do
      if replay? or unit["active"] == true, do: {:ok, uuid}, else: {:error, :unit_inactive}
    else
      _ -> {:error, :unit_not_found}
    end
  end

  defp check_position(_prefix, nil, _unit, _replay?), do: {:ok, nil}

  defp check_position(prefix, value, unit, replay?) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         {:ok, pos} <- ReadApi.lookup(prefix, uuid, [@position]) do
      cond do
        replay? -> {:ok, uuid}
        pos["active"] != true -> {:error, :position_inactive}
        not same_id?(pos["org_unit_id"], unit) -> {:error, :position_not_in_unit}
        true -> {:ok, uuid}
      end
    else
      _ -> {:error, :position_not_found}
    end
  end

  # The user lookup is prefix-scoped, so a user of another tenant is not found (INV-1, INV-5).
  # The account status is not checked: a disabled user may stay linked (UAT assumption).
  defp check_user(_prefix, nil, _replay?), do: {:ok, nil}

  defp check_user(prefix, value, replay?) do
    with {:ok, uuid} <- Ecto.UUID.cast(value) do
      cond do
        replay? -> {:ok, uuid}
        match?({:ok, _}, Identity.get_user(uuid, prefix: prefix)) -> {:ok, uuid}
        true -> {:error, :user_not_found}
      end
    else
      _ -> {:error, :user_not_found}
    end
  end

  # A `user_id` key present: nil removes the link, otherwise the canonical lowercase uuid.
  defp cast_user_key(prefix, attrs, replay?) do
    if Map.has_key?(attrs, "user_id") do
      with {:ok, user} <- check_user(prefix, attrs["user_id"], replay?),
           do: {:ok, Map.put(attrs, "user_id", user)}
    else
      {:ok, attrs}
    end
  end

  defp check_employee_active(rec, replay?) do
    if replay? or rec["active"] == true, do: :ok, else: {:error, :employee_inactive}
  end

  defp same_id?(stored, canonical) when is_binary(stored),
    do: String.downcase(stored) == canonical

  defp same_id?(nil, nil), do: true
  defp same_id?(_stored, _canonical), do: false

  defp put_or_drop(map, key, nil), do: Map.delete(map, key)
  defp put_or_drop(map, key, value), do: Map.put(map, key, value)
end
