defmodule Letflow.SecurityProbe.Fixtures.RogueAuditWriter do
  @moduledoc """
  The seeded failing case of the G-05 audit-writer probe (NOT compiled, NOT run:
  this file is text under `test/fixtures/`, read by
  `test/letflow/security_probe/g05_audit_writer_matrix_test.exs`).

  It is a deliberately broken audit writer. It breaks the probe's anti-bypass rule in
  three ways at once, so the probe cannot pass on an empty or partial scan:

    * it bulk-writes the tenant's audit chain through the schema alias (`Entry`) --
      the form this codebase already uses for its other tenant tables;
    * it bulk-writes the same table through a module attribute that holds its name;
    * and it writes the same table inside an `Ecto.Multi`, so the row lands with the
      transaction it belongs to.

  It also calls the central writer through an `import`, which the matrix must still
  name: a caller that hides the central call cannot leave the inventory either.

  Every defect here is a defect the probe must catch on the real tree.
  """

  import Letflow.Audit

  alias Letflow.Audit.Entry
  alias Letflow.Repo

  @audit_table "audit_entries"

  @spec rogue_bulk_write([map()], String.t()) :: term()
  def rogue_bulk_write(rows, prefix) do
    Repo.insert_all(Entry, rows, prefix: prefix)
  end

  @spec rogue_attribute_write([map()], String.t()) :: term()
  def rogue_attribute_write(rows, prefix) do
    Repo.insert_all(@audit_table, rows, prefix: prefix)
  end

  @spec rogue_multi_write([map()]) :: term()
  def rogue_multi_write(rows) do
    Ecto.Multi.insert(:audit_entry, Entry, rows)
  end

  @spec rogue_central_call(term(), map(), String.t()) :: term()
  def rogue_central_call(repo, attrs, prefix) do
    insert_entry(repo, attrs, prefix)
  end
end
