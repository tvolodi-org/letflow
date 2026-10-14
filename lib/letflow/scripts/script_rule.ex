defmodule Letflow.Scripts.ScriptRule do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1): one version of a tenant script (tenant schema table
  `script_rules`). Design: `lib/letflow/design/gh2534-7b1-script-registry.md` section 1.

  Rows are never deleted and version numbers are never reused; the status machine
  (`draft -> published | discarded`, `published -> retired | revoked`, `retired -> revoked`)
  and the immutability of non-draft content are enforced by the `script_rules_guard` trigger
  (SQLSTATE `LF001`), not only by `Letflow.Scripts`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "script_rules" do
    field(:key, :string)
    field(:version, :integer)
    field(:hook_kind, :string)
    field(:status, :string)
    field(:source, :string)
    field(:manifest, :map)
    field(:test_cases, {:array, :map})
    field(:sha256, :string)
    field(:contributors, {:array, :binary_id})
    field(:publisher_id, :binary_id)
    field(:published_at, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:discarded_at, :utc_datetime_usec)
    field(:self_published, :boolean, default: false)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
