defmodule Letflow.Proof.MesP3.Readings do
  @moduledoc """
  MES PROOF P3 (T-1831), REMOVABLE with
  `git rm -r test/support/mes_p3 test/letflow/proof/mes_p3 docs/design/mes/11-readings-import-P3.md`.

  A reading (tank or meter code, quantity with unit kg or l, time, source, quality) in two TEST tables of a throwaway
  committed tenant schema. The DDL is proof-only test DDL, not a migration; the tenant drop removes it. Nothing here
  touches the stock ledger. The schema name is checked against a pattern first; no value is interpolated into SQL
  (INV-7), values travel as bound parameters.
  """

  alias Letflow.Repo

  @schema_re ~r/\Atenant_[0-9a-f]{32}\z/

  @doc "Creates `proof_reading` and `proof_import` in a TEST tenant schema."
  @spec ensure_table!(String.t()) :: :ok
  def ensure_table!(schema) when is_binary(schema) do
    true = Regex.match?(@schema_re, schema)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_import (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      file_hash text NOT NULL UNIQUE,
      loaded integer NOT NULL DEFAULT 0,
      rejected integer NOT NULL DEFAULT 0,
      duplicates integer NOT NULL DEFAULT 0,
      imported_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_reading (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      equipment text NOT NULL,
      kind text NOT NULL CHECK (kind IN ('level', 'flow_total')),
      quantity numeric(18,3) NOT NULL CHECK (quantity >= 0),
      unit text NOT NULL CHECK (unit IN ('kg', 'l')),
      measured_at timestamptz NOT NULL,
      source text NOT NULL CHECK (source IN ('manual', 'file', 'historian')),
      quality text NOT NULL CHECK (quality IN ('good', 'uncertain', 'bad')),
      agg_count integer NOT NULL DEFAULT 1 CHECK (agg_count >= 1),
      agg_kind text CHECK (agg_kind IN ('last', 'avg', 'min', 'max')),
      import_id uuid,
      row_key text NOT NULL,
      UNIQUE (source, row_key)
    )
    """)

    :ok
  end

  @doc "The idempotency key of a reading: sha256 of the normalised row (source is a separate unique column)."
  @spec row_key(map()) :: String.t()
  def row_key(%{
        equipment: e,
        kind: k,
        quantity: %Decimal{} = q,
        unit: u,
        measured_at: %DateTime{} = t
      }) do
    {:ok, utc} = DateTime.shift_zone(t, "Etc/UTC")
    qn = q |> Decimal.normalize() |> Decimal.to_string(:normal)
    raw = Enum.join([e, k, qn, u, DateTime.to_iso8601(utc)], "|")
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @doc """
  Inserts one reading. `attrs`: equipment, kind, quantity (Decimal), unit, measured_at (DateTime), source, quality, and
  optional agg_count, agg_kind, import_id (uuid text). A CHECK violation raises (Postgrex.Error). Returns
  `{:ok, :inserted}` or `{:ok, :duplicate}` (same source and row key already stored).
  """
  @spec insert(String.t(), map(), keyword()) :: {:ok, :inserted | :duplicate}
  def insert(schema, attrs, _opts \\ []) do
    true = Regex.match?(@schema_re, schema)

    res =
      Repo.query!(
        """
        INSERT INTO "#{schema}".proof_reading
          (equipment, kind, quantity, unit, measured_at, source, quality, agg_count, agg_kind, import_id, row_key)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::text::uuid, $11)
        ON CONFLICT (source, row_key) DO NOTHING
        """,
        [
          attrs.equipment,
          attrs.kind,
          attrs.quantity,
          attrs.unit,
          attrs.measured_at,
          attrs.source,
          attrs.quality,
          Map.get(attrs, :agg_count, 1),
          Map.get(attrs, :agg_kind),
          Map.get(attrs, :import_id),
          row_key(attrs)
        ]
      )

    if res.num_rows == 1, do: {:ok, :inserted}, else: {:ok, :duplicate}
  end

  @doc "Readings of `schema`, oldest first. Filters: `:equipment`, `:kind`, `:source`."
  @spec list(String.t(), keyword()) :: [map()]
  def list(schema, filters \\ []) do
    true = Regex.match?(@schema_re, schema)

    {where, params} =
      [:equipment, :kind, :source]
      |> Enum.filter(&Keyword.has_key?(filters, &1))
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} -> {"#{f} = $#{i}", Keyword.fetch!(filters, f)} end)
      |> Enum.unzip()

    where_sql = if where == [], do: "", else: "WHERE " <> Enum.join(where, " AND ")

    %{rows: rows, columns: cols} =
      Repo.query!(
        ~s|SELECT equipment, kind, quantity, unit, measured_at, source, quality, agg_count, agg_kind, import_id::text FROM "#{schema}".proof_reading #{where_sql} ORDER BY measured_at, source|,
        params
      )

    Enum.map(rows, fn r ->
      cols |> Enum.zip(r) |> Map.new(fn {c, v} -> {String.to_atom(c), v} end)
    end)
  end

  @spec count(String.t()) :: non_neg_integer()
  def count(schema) do
    true = Regex.match?(@schema_re, schema)
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".proof_reading|)
    n
  end

  @spec import_count(String.t()) :: non_neg_integer()
  def import_count(schema) do
    true = Regex.match?(@schema_re, schema)
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".proof_import|)
    n
  end
end
