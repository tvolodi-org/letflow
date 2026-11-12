defmodule Letflow.Proof.MesP1.LotStatus do
  @moduledoc """
  MES PROOF P1 (T-1829), REMOVABLE: a lot quality status (`quarantine`, `released`, `rejected`) and a list of customer
  locations, kept in two TEST tables of a throwaway committed tenant schema. The DDL here is proof-only test DDL, not a
  migration: it never runs on a real tenant and the tenant drop removes the tables.

  Status changes take `Letflow.Ledger.hold_exclusive!/2` of the `stock` ledger (the same pairing as `CountSheet.open/3`);
  a posting takes the shared hold, so a posting and a status change cannot interleave.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Ledger
  alias Letflow.Repo

  @statuses ~w(quarantine released rejected)
  @schema_re ~r/\Atenant_[0-9a-f]{32}\z/
  @transitions [
    {"quarantine", "released"},
    {"quarantine", "rejected"},
    {"released", "quarantine"}
  ]

  def statuses, do: @statuses

  @doc "Pure: may a lot go from `from` to `to`? `rejected` is terminal."
  @spec allowed_transition?(String.t(), String.t()) :: boolean()
  def allowed_transition?(from, to), do: {from, to} in @transitions

  @doc "Creates the two proof tables in a TEST tenant schema (the name is checked first, no values are interpolated)."
  @spec ensure_table!(String.t()) :: :ok
  def ensure_table!(schema) when is_binary(schema) do
    true = Regex.match?(@schema_re, schema)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_lot_status (
      lot uuid PRIMARY KEY,
      status text NOT NULL CHECK (status IN ('quarantine', 'released', 'rejected')),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_customer_location (location uuid PRIMARY KEY)
    """)

    :ok
  end

  @doc "The status of `lot` (a uuid text), or nil when the lot has no row (a legacy lot)."
  @spec get(String.t(), String.t()) :: String.t() | nil
  def get(prefix, lot) when is_binary(lot) and lot != "" do
    Repo.one(
      from(s in "proof_lot_status", where: s.lot == type(^lot, :binary_id), select: s.status),
      prefix: prefix
    )
  end

  def get(_prefix, _lot), do: nil

  @doc "True when `location` (a uuid text) is marked as a customer location."
  @spec customer_location?(String.t(), String.t()) :: boolean()
  def customer_location?(prefix, location) when is_binary(location) and location != "" do
    Repo.exists?(
      from(c in "proof_customer_location", where: c.location == type(^location, :binary_id)),
      prefix: prefix
    )
  end

  def customer_location?(_prefix, _location), do: false

  def mark_customer_location!(prefix, location) do
    Repo.insert_all("proof_customer_location", [%{location: Ecto.UUID.dump!(location)}],
      prefix: prefix,
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  Sets the status of `lot`. One transaction: the exclusive hold of the `stock` ledger first, then the current row is
  read and the transition checked, then the row is written. A first status is only `quarantine` or `released`.
  """
  @spec set!(String.t(), String.t(), String.t()) :: :ok | {:error, :transition_not_allowed}
  def set!(prefix, lot, status) when status in @statuses do
    result =
      Repo.transaction(fn ->
        Ledger.hold_exclusive!(prefix, "stock")

        case get(prefix, lot) do
          nil ->
            write!(prefix, lot, status)

          current ->
            if allowed_transition?(current, status),
              do: write!(prefix, lot, status),
              else: Repo.rollback(:transition_not_allowed)
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write!(prefix, lot, status) do
    Repo.insert_all(
      "proof_lot_status",
      [%{lot: Ecto.UUID.dump!(lot), status: status, updated_at: DateTime.utc_now()}],
      prefix: prefix,
      on_conflict: {:replace, [:status, :updated_at]},
      conflict_target: [:lot]
    )

    :ok
  end
end
