defmodule Letflow.Ledger.NegativeBalanceSettings do
  @moduledoc """
  REQ-835 (decision 0090 section 5.1): the row access of the per-tenant negative balance setting, one
  row per registration name in the tenant schema (created by REQ-834). It lives in the ledger
  directory because only that directory may name a ledger table (REQ-620 criterion 12, T-SEC-3);
  `Letflow.LedgerSettings` is the admin context that validates and audits.

  Every query carries the tenant `prefix` (INV-1) and bound parameters (INV-7). Rows are plain maps
  with string uuids; the id and `changed_by` columns are `uuid`.
  """

  import Ecto.Query

  alias Letflow.Repo

  @table "ledger_balance_settings"

  @type row :: %{
          id: Ecto.UUID.t(),
          registration_name: String.t(),
          allow_negative: boolean(),
          changed_by: Ecto.UUID.t(),
          changed_at: DateTime.t(),
          reason: String.t()
        }

  @doc "The rows of `names`, as `%{registration_name => row}`."
  @spec rows(String.t(), [String.t()]) :: %{String.t() => row()}
  def rows(_prefix, []), do: %{}

  def rows(prefix, names) when is_binary(prefix) and is_list(names) do
    from(s in @table,
      where: s.registration_name in ^names,
      select: %{
        id: s.id,
        registration_name: s.registration_name,
        allow_negative: s.allow_negative,
        changed_by: s.changed_by,
        changed_at: s.changed_at,
        reason: s.reason
      }
    )
    |> Repo.all(prefix: prefix)
    |> Map.new(&{&1.registration_name, load(&1)})
  end

  @doc "The row of `name` locked `FOR UPDATE` (call inside a transaction), or nil."
  @spec lock(String.t(), String.t()) :: row() | nil
  def lock(prefix, name) when is_binary(prefix) and is_binary(name) do
    from(s in @table,
      where: s.registration_name == ^name,
      select: %{
        id: s.id,
        registration_name: s.registration_name,
        allow_negative: s.allow_negative,
        changed_by: s.changed_by,
        changed_at: s.changed_at,
        reason: s.reason
      },
      lock: "FOR UPDATE"
    )
    |> Repo.one(prefix: prefix)
    |> case do
      nil -> nil
      row -> load(row)
    end
  end

  @doc "Writes the value of `name`: updates the locked `existing` row or inserts the first one. Returns the new row."
  @spec write!(String.t(), row() | nil, String.t(), boolean(), String.t(), Ecto.UUID.t()) :: row()
  def write!(prefix, existing, name, allow, reason, user_id) do
    now = DateTime.utc_now()

    id =
      case existing do
        nil ->
          id = Ecto.UUID.generate()

          {1, _} =
            Repo.insert_all(
              @table,
              [
                %{
                  id: Ecto.UUID.dump!(id),
                  registration_name: name,
                  allow_negative: allow,
                  changed_by: Ecto.UUID.dump!(user_id),
                  changed_at: now,
                  reason: reason,
                  inserted_at: now,
                  updated_at: now
                }
              ],
              prefix: prefix
            )

          id

        %{id: id} ->
          dumped = Ecto.UUID.dump!(id)

          {1, _} =
            from(s in @table, where: s.id == ^dumped)
            |> Repo.update_all(
              [
                set: [
                  allow_negative: allow,
                  changed_by: Ecto.UUID.dump!(user_id),
                  changed_at: now,
                  reason: reason,
                  updated_at: now
                ]
              ],
              prefix: prefix
            )

          id
      end

    %{
      id: id,
      registration_name: name,
      allow_negative: allow,
      changed_by: user_id,
      changed_at: now,
      reason: reason
    }
  end

  defp load(row), do: %{row | id: load_uuid(row.id), changed_by: load_uuid(row.changed_by)}

  defp load_uuid(raw) when is_binary(raw) and byte_size(raw) == 16, do: Ecto.UUID.load!(raw)
  defp load_uuid(other), do: other
end
