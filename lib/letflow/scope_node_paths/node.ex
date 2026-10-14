defmodule Letflow.ScopeNodePaths.Node do
  @moduledoc """
  `Ecto.Schema` for one `scope_node_paths` row (REQ-496, design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §5-§6.1).

  READ MODEL ONLY. The one writer of the table is `Letflow.ScopeNodePaths.write/2`;
  no other code inserts, updates or deletes through this schema, and module code
  must not name it at all (`mix letflow.check_scope_node_paths_writers`).
  """

  use Ecto.Schema

  @primary_key {:node_id, :string, autogenerate: false}
  schema "scope_node_paths" do
    field(:path, :string)
    field(:depth, :integer)
    field(:retired_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
