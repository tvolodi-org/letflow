defmodule Letflow.Proof.MesP2.BatchStore do
  @moduledoc """
  MES PROOF P2 (T-1830), REMOVABLE with `git rm -r test/support/mes_p2 test/letflow/proof/mes_p2 docs/design/mes/10-batch-slice-P2.md`.

  A thin batch slice on the P1 copy: recipe version (lines with an item and a unit each), one batch record, `consume` and
  `produce` postings through `Letflow.Proof.MesP1.StockCopy.post/3` (P1 files are reused, not edited). The three proof tables
  are TEST DDL in a throwaway committed tenant schema, not migrations; the tenant drop removes them.

  Lot and batch are uuids in the ledger key / `related_document_id`: they are not real entities (named in doc 10).
  """

  alias Letflow.Proof.MesP1.LotStatus
  alias Letflow.Proof.MesP1.StockCopy
  alias Letflow.Repo

  @schema_re ~r/\Atenant_[0-9a-f]{32}\z/

  @doc "Checks the schema name (the only value that is quoted into SQL) and returns it."
  def schema!(schema) when is_binary(schema) do
    true = Regex.match?(@schema_re, schema)
    schema
  end

  @doc "Creates the proof tables (and the P1 lot status tables) in a TEST tenant schema."
  @spec ensure_tables!(String.t()) :: :ok
  def ensure_tables!(schema) do
    schema = schema!(schema)
    :ok = LotStatus.ensure_table!(schema)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_recipe_version (
      id uuid PRIMARY KEY,
      code text NOT NULL,
      version integer NOT NULL,
      status text NOT NULL CHECK (status IN ('draft', 'approved', 'retired')),
      UNIQUE (code, version)
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_recipe_line (
      id uuid PRIMARY KEY,
      version_id uuid NOT NULL REFERENCES "#{schema}".proof_recipe_version (id),
      role text NOT NULL CHECK (role IN ('input', 'output')),
      sku uuid NOT NULL,
      unit text NOT NULL,
      quantity numeric(30,9) NOT NULL CHECK (quantity > 0)
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{schema}".proof_batch (
      id uuid PRIMARY KEY,
      number text NOT NULL UNIQUE,
      recipe_version_id uuid NOT NULL REFERENCES "#{schema}".proof_recipe_version (id),
      status text NOT NULL CHECK (status IN ('running', 'finished')),
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION "#{schema}".proof_recipe_line_frozen() RETURNS trigger AS $$
    DECLARE v uuid; s text;
    BEGIN
      IF TG_OP = 'INSERT' THEN v := NEW.version_id; ELSE v := OLD.version_id; END IF;
      SELECT status INTO s FROM "#{schema}".proof_recipe_version WHERE id = v;
      IF s IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'recipe version is not a draft: its lines are frozen';
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      ~s|DROP TRIGGER IF EXISTS proof_recipe_line_frozen ON "#{schema}".proof_recipe_line|
    )

    Repo.query!("""
    CREATE TRIGGER proof_recipe_line_frozen BEFORE INSERT OR UPDATE OR DELETE
    ON "#{schema}".proof_recipe_line
    FOR EACH ROW EXECUTE FUNCTION "#{schema}".proof_recipe_line_frozen()
    """)

    :ok
  end

  # ── recipe ───────────────────────────────────────────────────────────────────────────

  @doc "A draft recipe version. `lines` = `[%{role: \"input\"|\"output\", sku:, unit:, quantity:}]`. Returns the version id."
  @spec create_recipe(String.t(), String.t(), integer(), [map()]) :: String.t()
  def create_recipe(schema, code, version, lines) do
    schema = schema!(schema)
    id = Ecto.UUID.generate()

    Repo.transaction(fn ->
      Repo.query!(
        ~s|INSERT INTO "#{schema}".proof_recipe_version (id, code, version, status) VALUES ($1, $2, $3, 'draft')|,
        [Ecto.UUID.dump!(id), code, version]
      )

      for l <- lines, do: insert_line!(schema, id, l)
    end)

    id
  end

  @doc "Inserts one line (refused by the trigger unless the version is a draft)."
  def insert_line!(schema, version_id, l) do
    schema = schema!(schema)

    Repo.query!(
      ~s|INSERT INTO "#{schema}".proof_recipe_line (id, version_id, role, sku, unit, quantity) VALUES ($1, $2, $3, $4, $5, $6)|,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(version_id),
        l.role,
        Ecto.UUID.dump!(l.sku),
        l.unit,
        Decimal.new(l.quantity)
      ]
    )
  end

  def approve(schema, version_id), do: set_version_status(schema, version_id, "approved")
  def retire(schema, version_id), do: set_version_status(schema, version_id, "retired")

  defp set_version_status(schema, version_id, status) do
    schema = schema!(schema)

    Repo.query!(
      ~s|UPDATE "#{schema}".proof_recipe_version SET status = $2 WHERE id = $1|,
      [Ecto.UUID.dump!(version_id), status]
    )

    :ok
  end

  @doc "The lines of a version, sorted: `[%{role, sku, unit, quantity}]` (sku as uuid text, quantity as Decimal)."
  def recipe_lines(schema, version_id) do
    schema = schema!(schema)

    %{rows: rows} =
      Repo.query!(
        ~s|SELECT role, sku, unit, quantity FROM "#{schema}".proof_recipe_line WHERE version_id = $1 ORDER BY role, unit, sku|,
        [Ecto.UUID.dump!(version_id)]
      )

    for [role, sku, unit, q] <- rows,
        do: %{role: role, sku: Ecto.UUID.load!(sku), unit: unit, quantity: q}
  end

  def recipe_line_count(schema) do
    schema = schema!(schema)
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".proof_recipe_line|)
    n
  end

  # ── batch ────────────────────────────────────────────────────────────────────────────

  @spec create_batch(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :version_not_approved}
  def create_batch(schema, number, version_id) do
    schema = schema!(schema)

    %{rows: rows} =
      Repo.query!(~s|SELECT status FROM "#{schema}".proof_recipe_version WHERE id = $1|, [
        Ecto.UUID.dump!(version_id)
      ])

    case rows do
      [["approved"]] ->
        id = Ecto.UUID.generate()

        Repo.query!(
          ~s|INSERT INTO "#{schema}".proof_batch (id, number, recipe_version_id, status) VALUES ($1, $2, $3, 'running')|,
          [Ecto.UUID.dump!(id), number, Ecto.UUID.dump!(version_id)]
        )

        {:ok, id}

      _ ->
        {:error, :version_not_approved}
    end
  end

  def get_batch(schema, batch_id) do
    schema = schema!(schema)

    %{rows: rows} =
      Repo.query!(
        ~s|SELECT number, recipe_version_id, status FROM "#{schema}".proof_batch WHERE id = $1|,
        [Ecto.UUID.dump!(batch_id)]
      )

    case rows do
      [[number, v, status]] ->
        %{number: number, recipe_version_id: Ecto.UUID.load!(v), status: status}

      [] ->
        nil
    end
  end

  def finish(schema, batch_id) do
    schema = schema!(schema)

    Repo.query!(~s|UPDATE "#{schema}".proof_batch SET status = 'finished' WHERE id = $1|, [
      Ecto.UUID.dump!(batch_id)
    ])

    :ok
  end

  # ── consume / produce ────────────────────────────────────────────────────────────────

  @doc """
  Consumes raw lots into the batch, one `consume` entry. Each line: `%{sku, lot, unit, quantity, from: side}`.
  Item and unit must match an `input` line of the batch's recipe version (quantity is not checked).
  """
  @spec consume(String.t(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def consume(schema, batch_id, lines), do: move(schema, batch_id, "consume", "input", lines)

  @doc """
  Produces ONE finished lot (`%{sku, lot, unit, quantity, to: side}`). The lot is set to `quarantine` BEFORE the produce
  posting, so there is no moment when it has no status row (= released, P1 finding 4).
  """
  @spec produce(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def produce(schema, batch_id, line) do
    with :ok <- check_recipe(schema, batch_id, "output", [line]),
         :ok <- LotStatus.set!(schema, line.lot, "quarantine") do
      post(schema, batch_id, "produce", [line])
    end
  end

  defp move(schema, batch_id, cause, role, lines) do
    with :ok <- check_recipe(schema, batch_id, role, lines),
         do: post(schema, batch_id, cause, lines)
  end

  defp check_recipe(schema, batch_id, role, lines) do
    case get_batch(schema, batch_id) do
      nil ->
        {:error, :no_batch}

      %{status: "finished"} ->
        {:error, :batch_finished}

      %{recipe_version_id: v} ->
        allowed = for l <- recipe_lines(schema, v), l.role == role, do: {l.sku, l.unit}

        if Enum.all?(lines, &({&1.sku, &1.unit} in allowed)),
          do: :ok,
          else: {:error, :not_in_recipe}
    end
  end

  defp post(schema, batch_id, cause, lines) do
    cmd = %{
      cause: cause,
      lines:
        for l <- lines do
          l
          |> Map.take([:sku, :lot, :unit, :quantity, :from, :to])
          |> Map.put(:line_id, Ecto.UUID.generate())
        end,
      document_type: "proof",
      document_id: Ecto.UUID.generate(),
      batch_id: batch_id
    }

    StockCopy.post(schema, cmd)
  end

  @doc """
  `%{unit => %{in: Decimal, out: Decimal}}` of the live consume (in) and produce (out) legs of the batch.
  Never summed across units (no density rule: open owner question).
  """
  @spec balance(String.t(), String.t()) :: map()
  def balance(schema, batch_id) do
    schema = schema!(schema)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT l.unit_ref, e.cause, sum(abs(l.quantity))
        FROM "#{schema}".ledger_entry e
        JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
        WHERE e.ledger_id = 'stock' AND e.related_document_id = $1 AND e.cause IN ('consume', 'produce')
          AND NOT EXISTS (SELECT 1 FROM "#{schema}".ledger_entry r WHERE r.ledger_id = 'stock' AND r.reverses_entry_id = e.id)
        GROUP BY l.unit_ref, e.cause
        """,
        [batch_id]
      )

    zero = Decimal.new(0)

    Enum.reduce(rows, %{}, fn [unit, cause, sum], acc ->
      key = if cause == "consume", do: :in, else: :out
      Map.update(acc, unit, Map.put(%{in: zero, out: zero}, key, sum), &Map.put(&1, key, sum))
    end)
  end
end
