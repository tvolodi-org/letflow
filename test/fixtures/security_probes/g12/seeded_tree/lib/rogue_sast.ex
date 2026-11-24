defmodule SeededTree.RogueSast do
  @moduledoc """
  The seeded failing case of the G-12 SAST half: one file with one violation of every rule, plus the aliased SQL form the
  scan applies. It is TEXT under test/fixtures/ -- never compiled, never run. The probe drives
  the scan over it and proves that every rule fires, so a scan that finds nothing cannot pass.
  """

  def unsafe_atom(value), do: String.to_atom(value)

  def unsafe_shell(value), do: System.cmd("sh", ["-c", "echo #{value}"])

  def unsafe_sql(value), do: Repo.query!("SELECT * FROM widgets WHERE name = #{value}")

  # The `alias Ecto.Adapters.SQL` form this repository uses at 22 sites: the call node is `SQL`.
  alias Ecto.Adapters.SQL

  def unsafe_aliased_sql(value), do: SQL.query!(Repo, "SELECT * FROM t WHERE n = #{value}", [])

  def unsafe_term(binary), do: :erlang.binary_to_term(binary)

  def weak_digest(value), do: :crypto.hash(:md5, value)
end
