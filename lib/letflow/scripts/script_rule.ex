defmodule Letflow.Scripts.ScriptRule do
  @moduledoc """
  GH 2534 PR 7b-1 (decision 0053 D1): one version of a tenant script (tenant schema table
  `script_rules`). Design: `lib/letflow/design/gh2534-7b1-script-registry.md` section 1.

  Rows are never deleted and version numbers are never reused; the status machine
  (`draft -> published | discarded`, `published -> retired | revoked`, `retired -> revoked`)
  and the immutability of non-draft content are enforced by the `script_rules_guard` trigger
  (SQLSTATE `LF001`), not only by `Letflow.Scripts`.

  `status` is an `Ecto.Enum` over the `:string` column (GH 2603): the atoms equal the
  `script_rules_status` CHECK set exactly, the CHECK stays the backstop, and every external
  form (JSON, audit entries) renders the string via `Atom.to_string/1`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "script_rules" do
    field(:key, :string)
    field(:version, :integer)
    field(:hook_kind, :string)
    field(:status, Ecto.Enum, values: [:draft, :discarded, :published, :retired, :revoked])
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
    # GH 2534 PR 7b-2b (design gh2534-7b2b-script-sod.md 3.2): the publish-time SoD set plus
    # the publisher (NULL on drafts, discarded rows and rows published before 7b-2b), and the
    # D6 confirmation of a self-published version.
    field(:sod_excluded, {:array, :binary_id})
    field(:confirmed_by, :binary_id)
    field(:confirmed_at, :utc_datetime_usec)
    field(:confirmed_sha256, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
