defmodule Letflow.Api.Scope.ShadowEvidence.Counter do
  @moduledoc """
  The `Ecto.Schema` of the tenant table `scope_shadow_counters` (REQ-517 PR 2b / GH #2535,
  design `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.7.1): one row per
  UTC `day` and `metric`, where `metric` is `requests` or one of the six
  `Letflow.Api.Scope.deny_reason()` values. Counts only. No tenant column (0006 D2): the
  tenant is the schema, always passed as an explicit `prefix:`.

  Written ONLY by `Letflow.Api.Scope.ShadowEvidence` (the flush and the daily prune).
  """

  use Ecto.Schema

  @primary_key false
  schema "scope_shadow_counters" do
    field(:day, :date, primary_key: true)
    field(:metric, :string, primary_key: true)
    field(:count, :integer)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          day: Date.t() | nil,
          metric: String.t() | nil,
          count: non_neg_integer() | nil,
          updated_at: DateTime.t() | nil
        }
end
