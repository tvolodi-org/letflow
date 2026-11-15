defmodule Letflow.Documents.OfficialFormTemplate do
  @moduledoc """
  Persistence shape of a tenant's `official_form_templates` row (T-1982, decision 0089 D5, S4a).

  This module is a shape, not an API. The only writer is `Letflow.Documents.OfficialFormTemplates`;
  the database trigger `guard_official_form_templates` refuses every other change. Callers pass
  `prefix:` for the tenant schema.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "official_form_templates" do
    field(:tenant_id, :binary_id)
    field(:form_id, :string)
    field(:locale, :string)
    field(:version_no, :integer)
    field(:status, :string)
    field(:content, :binary)
    field(:byte_size, :integer)
    field(:sha256, :string)
    field(:summary, :map)
    field(:rollback_of, :binary_id)
    field(:created_by, :binary_id)
    field(:activated_by, :binary_id)
    field(:activated_at, :utc_datetime_usec)
    field(:retired_at, :utc_datetime_usec)
    field(:reason_code, :string)
    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "Every column except `:content` (what `OfficialFormTemplates.list/2` returns)."
  def metadata_fields, do: __schema__(:fields) -- [:content]
end
