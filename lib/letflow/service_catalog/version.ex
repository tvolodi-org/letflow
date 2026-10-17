defmodule Letflow.ServiceCatalog.Version do
  @moduledoc """
  Ecto schema for the `service_catalog_versions` table (REQ-373, design
  `lib/letflow/design/req373-service-catalog-version-lifecycle.md` §4) --
  the append-only archive of every version a `Letflow.ServiceCatalog.publish/3`
  supersedes. See that design doc's §1/§4 for the full schema-decision
  reasoning (`Letflow.ServiceCatalog.Entry`'s moduledoc restates it).

  `version_id` is the primary key -- copied verbatim from the live
  `service_catalog` row's own `version_id` at the moment it's archived,
  never regenerated. No `service_id` foreign key to `service_catalog`,
  deliberately (design §4/§9 OQ-1) -- see `Letflow.ServiceCatalog.publish/3`'s
  own `@doc`.

  Written only by `Letflow.ServiceCatalog.publish/3`, inside the same
  `Repo.transaction/1` that updates the live `service_catalog` row -- never
  updated or deleted once inserted (append-only).
  """

  use Ecto.Schema

  @primary_key {:version_id, Ecto.UUID, autogenerate: false}
  schema "service_catalog_versions" do
    field(:service_id, :string)
    field(:version, :string)
    field(:endpoint_url, :string)
    field(:request_schema, :string)
    field(:response_schema, :string)

    field(:required_auth, Ecto.Enum, values: [:NONE, :API_KEY, :OAUTH2, :MUTUAL_TLS])

    field(:timeout_ms, :integer)
    field(:retry_policy, :string)

    field(:published_at, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @castable_fields [
    :version_id,
    :service_id,
    :version,
    :endpoint_url,
    :request_schema,
    :response_schema,
    :required_auth,
    :timeout_ms,
    :retry_policy,
    :published_at,
    :retired_at
  ]

  # Mirrors Letflow.ServiceCatalog.Entry's own required-field parity for the
  # fields the two schemas share (Entry has no equivalent of `service_id` as
  # a plain field -- it's Entry's primary key -- and no `retired_at`, but
  # both are always present on an archive row; see design §4's column table
  # for the archive table's own not-null list). `request_schema`,
  # `response_schema`, and `retry_policy` are deliberately excluded --
  # legitimately nullable snapshot fields, same as on `Entry`.
  @required_fields [
    :version_id,
    :service_id,
    :version,
    :endpoint_url,
    :required_auth,
    :timeout_ms,
    :published_at,
    :retired_at
  ]

  @doc """
  Changeset for the one insert `Letflow.ServiceCatalog.publish/3` performs
  per call -- a full snapshot of the row being superseded, per design §3.1
  step 3.
  """
  @spec archive_changeset(map()) :: Ecto.Changeset.t()
  def archive_changeset(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, @castable_fields)
    |> Ecto.Changeset.validate_required(@required_fields)
    |> Ecto.Changeset.check_constraint(:endpoint_url,
      name: :chk_service_catalog_versions_endpoint_url_no_reserved_ref,
      message: Letflow.ServiceCatalog.Entry.reserved_constraint_message()
    )
  end
end
