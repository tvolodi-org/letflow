defmodule Letflow.Proof.MesP2.Trace do
  @moduledoc """
  MES PROOF P2 (T-1830), REMOVABLE: lot trace backward and forward as plain SQL over the real `ledger_entry` and
  `ledger_leg` rows of ONE tenant schema (batch id in `related_document_id`, item in `k1`, lot in `k5`). Only live entries
  count: an entry that has a later reversal is left out. One level only (rework is out of the slice).

  Shipped quantity = negative legs of live `issue` / `hand_over` entries of the (item, lot), plus the legs of a `transfer`
  entry that also has a positive leg at a location in `proof_customer_location` (the P1 marker table).
  """

  alias Letflow.Proof.MesP2.BatchStore
  alias Letflow.Repo

  @live "NOT EXISTS (SELECT 1 FROM \"%S\".ledger_entry r WHERE r.ledger_id = 'stock' AND r.reverses_entry_id = e.id)"

  defp live(schema), do: String.replace(@live, "%S", schema)

  @doc "Which batches made `(sku, lot)`, what they consumed, and the receipts of the consumed lots."
  def backward(schema, sku, lot) do
    schema = BatchStore.schema!(schema)

    batches =
      q(
        schema,
        """
        SELECT DISTINCT e.related_document_id, b.number
        FROM "#{schema}".ledger_entry e
        JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
        JOIN "#{schema}".proof_batch b ON b.id::text = e.related_document_id
        WHERE e.ledger_id = 'stock' AND e.cause = 'produce' AND l.k1 = $1 AND l.k5 = $2 AND #{live(schema)}
        ORDER BY b.number
        """,
        [sku, lot]
      )

    %{
      batches:
        for [batch_id, number] <- batches do
          consumed =
            for [s, lt, unit, qty] <- consumed(schema, batch_id),
                do: %{sku: s, lot: lt, unit: unit, quantity: qty}

          receipts =
            for c <- consumed,
                doc <- receipts(schema, c.sku, c.lot),
                do: %{sku: c.sku, lot: c.lot, document_id: doc}

          %{batch_id: batch_id, number: number, consumed: consumed, receipts: receipts}
        end
    }
  end

  defp consumed(schema, batch_id) do
    q(
      schema,
      """
      SELECT l.k1, l.k5, l.unit_ref, sum(abs(l.quantity))
      FROM "#{schema}".ledger_entry e
      JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
      WHERE e.ledger_id = 'stock' AND e.cause = 'consume' AND e.related_document_id = $1 AND #{live(schema)}
      GROUP BY l.k1, l.k5, l.unit_ref ORDER BY l.k1, l.k5
      """,
      [batch_id]
    )
  end

  defp receipts(schema, sku, lot) do
    for [doc] <-
          q(
            schema,
            """
            SELECT DISTINCT e.document_id
            FROM "#{schema}".ledger_entry e
            JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
            WHERE e.ledger_id = 'stock' AND e.cause = 'receipt' AND l.k1 = $1 AND l.k5 = $2 AND #{live(schema)}
            ORDER BY e.document_id
            """,
            [sku, lot]
          ),
        do: doc
  end

  @doc "Which batches used `(sku, lot)`, what they produced and how much of each finished lot was shipped."
  def forward(schema, sku, lot) do
    schema = BatchStore.schema!(schema)

    batches =
      q(
        schema,
        """
        SELECT DISTINCT e.related_document_id, b.number
        FROM "#{schema}".ledger_entry e
        JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
        JOIN "#{schema}".proof_batch b ON b.id::text = e.related_document_id
        WHERE e.ledger_id = 'stock' AND e.cause = 'consume' AND l.k1 = $1 AND l.k5 = $2 AND #{live(schema)}
        ORDER BY b.number
        """,
        [sku, lot]
      )

    %{
      batches:
        for [batch_id, number] <- batches do
          produced =
            for [s, lt, unit, qty] <- produced(schema, batch_id) do
              {shipped, shipped_unit} = shipped(schema, s, lt, unit)

              %{
                sku: s,
                lot: lt,
                unit: unit,
                quantity: qty,
                shipped: shipped,
                shipped_unit: shipped_unit
              }
            end

          %{batch_id: batch_id, number: number, produced: produced}
        end
    }
  end

  defp produced(schema, batch_id) do
    q(
      schema,
      """
      SELECT l.k1, l.k5, l.unit_ref, sum(l.quantity)
      FROM "#{schema}".ledger_entry e
      JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
      WHERE e.ledger_id = 'stock' AND e.cause = 'produce' AND e.related_document_id = $1 AND #{live(schema)}
      GROUP BY l.k1, l.k5, l.unit_ref ORDER BY l.k1, l.k5
      """,
      [batch_id]
    )
  end

  defp shipped(schema, sku, lot, unit) do
    [[sum]] =
      q(
        schema,
        """
        SELECT coalesce(sum(abs(l.quantity)), 0)
        FROM "#{schema}".ledger_entry e
        JOIN "#{schema}".ledger_leg l ON l.entry_id = e.id AND l.ledger_id = e.ledger_id
        WHERE e.ledger_id = 'stock' AND l.k1 = $1 AND l.k5 = $2 AND l.quantity < 0 AND #{live(schema)}
          AND (e.cause IN ('issue', 'hand_over')
               OR (e.cause = 'transfer' AND EXISTS (
                     SELECT 1 FROM "#{schema}".ledger_leg p
                     JOIN "#{schema}".proof_customer_location c ON c.location::text = p.k2
                     WHERE p.entry_id = e.id AND p.ledger_id = e.ledger_id AND p.quantity > 0)))
        """,
        [sku, lot]
      )

    {sum, unit}
  end

  defp q(_schema, sql, params), do: Repo.query!(sql, params).rows
end
