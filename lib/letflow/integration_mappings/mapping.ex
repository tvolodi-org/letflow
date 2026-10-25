defmodule Letflow.IntegrationMappings.Mapping do
  @moduledoc """
  REQ-565 slice 1 (GH #3201) -- one stored integration mapping (`integration_mappings`, a
  per-tenant table; the schema prefix is passed on every `Repo` call, never set here).

  `rules` is the validated list of string-keyed rule maps (`to`, `from` | `const`, `required`);
  see `Letflow.IntegrationMappings`. There is no credential column.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}

  schema "integration_mappings" do
    field(:tenant_id, :binary_id)
    field(:name, :string)
    field(:direction, :string)
    field(:rules, {:array, :map})
    field(:updated_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end
end
