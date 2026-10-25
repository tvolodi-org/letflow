defmodule Letflow.ScheduledJobs.Job do
  @moduledoc """
  REQ-561 / GH #3194 -- one row of the per-tenant `scheduled_jobs` table, and the validation of
  a job's definition.

  `validate/2` is the one typed-error path (create and update both use it): it returns
  `{:ok, attrs}` with the normalised, known fields, or `{:error, [{field, code}]}`. A refusal names
  the field and a code atom and never echoes the offending value. The codes: `:required`,
  `:invalid`, `:not_utc`, `:too_long`, `:too_large`, `:secret_like`, `:not_accepted` (a
  `tenant_id` in the attrs), and `:taken` (from the unique index on `key`, see
  `Letflow.ScheduledJobs`).
  """

  use Ecto.Schema

  alias Letflow.ScheduledJobs.Schedule

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @outcomes ~w(ok definition_not_found definition_not_active definition_needs_reactivation
               actor_not_allowed start_failed raised)

  @max_key 100
  @max_title 200
  @max_variables_bytes 16_384
  @secret_keys ~w(password token secret apikey)

  schema "scheduled_jobs" do
    field(:tenant_id, :binary_id)
    field(:key, :string)
    field(:title, :string)
    field(:definition_name, :string)
    field(:variables, :map, default: %{})
    field(:scope_node_id, :string)
    field(:interval_minutes, :integer)
    field(:anchor_at, :utc_datetime_usec)
    field(:enabled, :boolean, default: true)
    field(:next_run_at, :utc_datetime_usec)
    field(:last_run_at, :utc_datetime_usec)
    field(:last_outcome, :string)
    field(:last_outcome_details, :map)
    field(:consecutive_failures, :integer, default: 0)
    field(:created_by, :binary_id)

    timestamps()
  end

  @type t :: %__MODULE__{}
  @type validation_error :: {atom(), atom()}

  @create_fields ~w(key title definition_name variables scope_node_id interval_minutes anchor_at)a
  @update_fields ~w(title variables scope_node_id interval_minutes anchor_at)a

  @doc "The closed list of run outcome codes."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  Validates `attrs` for `:create` (every field checked, `variables` defaults to `%{}`) or `:update`
  (only the editable fields that are present). Keys may be atoms or strings.
  """
  @spec validate(map(), :create | :update) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(attrs, mode) when is_map(attrs) and mode in [:create, :update] do
    fields = if mode == :create, do: @create_fields, else: @update_fields

    tenant_errors = if has_key?(attrs, :tenant_id), do: [{:tenant_id, :not_accepted}], else: []

    {values, errors} =
      Enum.reduce(fields, {%{}, tenant_errors}, fn field, {acc, errs} ->
        case fetch(attrs, field) do
          :error when mode == :update ->
            {acc, errs}

          :error ->
            check(field, nil, acc, errs, mode)

          {:ok, value} ->
            check(field, value, acc, errs, mode)
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, values}
      errors -> {:error, errors}
    end
  end

  def validate(_attrs, _mode), do: {:error, [{:attrs, :invalid}]}

  defp check(field, value, acc, errs, mode) do
    case validate_field(field, value, mode) do
      {:ok, normalised} -> {Map.put(acc, field, normalised), errs}
      {:error, code} -> {acc, [{field, code} | errs]}
    end
  end

  defp validate_field(:key, value, _mode), do: text(value, @max_key)
  defp validate_field(:title, value, _mode), do: text(value, @max_title)
  defp validate_field(:definition_name, value, _mode), do: text(value, @max_title)

  defp validate_field(:scope_node_id, nil, _mode), do: {:ok, nil}

  defp validate_field(:scope_node_id, value, _mode) when is_binary(value) do
    if String.trim(value) == "" or String.length(value) > @max_title,
      do: {:error, :invalid},
      else: {:ok, value}
  end

  defp validate_field(:scope_node_id, _value, _mode), do: {:error, :invalid}

  defp validate_field(:interval_minutes, value, _mode)
       when is_integer(value) do
    if value >= Schedule.min_interval() and value <= Schedule.max_interval(),
      do: {:ok, value},
      else: {:error, :invalid}
  end

  defp validate_field(:interval_minutes, nil, _mode), do: {:error, :required}
  defp validate_field(:interval_minutes, _value, _mode), do: {:error, :invalid}

  defp validate_field(:anchor_at, nil, _mode), do: {:error, :required}
  defp validate_field(:anchor_at, "", _mode), do: {:error, :required}

  defp validate_field(:anchor_at, %DateTime{utc_offset: 0, std_offset: 0} = dt, _mode),
    do: {:ok, usec(dt)}

  defp validate_field(:anchor_at, %DateTime{}, _mode), do: {:error, :not_utc}

  defp validate_field(:anchor_at, value, _mode) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> {:ok, usec(dt)}
      {:ok, _dt, _offset} -> {:error, :not_utc}
      {:error, :missing_offset} -> {:error, :not_utc}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp validate_field(:anchor_at, _value, _mode), do: {:error, :invalid}

  defp validate_field(:variables, nil, :create), do: {:ok, %{}}
  defp validate_field(:variables, value, _mode) when is_struct(value), do: {:error, :invalid}

  defp validate_field(:variables, value, _mode) when is_map(value) do
    cond do
      secret_like?(value) -> {:error, :secret_like}
      not encodable?(value) -> {:error, :invalid}
      byte_size(Jason.encode!(value)) > @max_variables_bytes -> {:error, :too_large}
      true -> {:ok, value}
    end
  end

  defp validate_field(:variables, _value, _mode), do: {:error, :invalid}

  defp text(nil, _max), do: {:error, :required}
  defp text(value, _max) when not is_binary(value), do: {:error, :invalid}

  defp text(value, max) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, :required}
      String.length(trimmed) > max -> {:error, :too_long}
      true -> {:ok, trimmed}
    end
  end

  defp encodable?(value) do
    match?({:ok, _json}, Jason.encode(value))
  end

  # A key containing password/token/secret/apikey (a substring heuristic, ignoring case and _ or - separators; any depth, inside lists too) whose
  # value is not empty. Variables are stored in the job row and written into instance events, so
  # a secret never goes through them: keep secrets out of a job and reference them from the process instead.
  defp secret_like?(map) when is_map(map) and not is_struct(map) do
    Enum.any?(map, fn {key, value} ->
      (secret_key?(key) and not empty_value?(value)) or secret_like?(value)
    end)
  end

  defp secret_like?(list) when is_list(list), do: Enum.any?(list, &secret_like?/1)
  defp secret_like?(_other), do: false

  defp secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))

  defp secret_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[[:space:]_-]/, "")
    Enum.any?(@secret_keys, &String.contains?(normalized, &1))
  end

  defp secret_key?(_key), do: false

  defp empty_value?(value), do: value in [nil, "", %{}, []]

  @doc "`dt` with microsecond precision 6, which the `:utc_datetime_usec` columns require."
  @spec usec(DateTime.t()) :: DateTime.t()
  def usec(%DateTime{microsecond: {us, _precision}} = dt), do: %{dt | microsecond: {us, 6}}

  defp has_key?(attrs, field),
    do: Map.has_key?(attrs, field) or Map.has_key?(attrs, to_string(field))

  defp fetch(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, to_string(field))
    end
  end
end
