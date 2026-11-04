Code.require_file("../locations/locations_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.CountsFixture do
  @moduledoc """
  REQ-700 / GH #3737: shared setup of the count order tests. A tenant with `org`, `locations` and
  `stock` installed through the real install router, an org unit with a chair (an employee linked to
  a user), members, and a small location tree linked to the unit:

      a, a1, a11, b: all linked to the unit

      a                     b
      +- a1                 
         +- a11
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.LocationsFixture, as: L
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.TenantProvisioning.ColumnPromotion

  @doc "A sandboxed tenant (DataCase) with org, locations and stock installed."
  def tenant! do
    t = L.installed_tenant!("req700")
    L.install_module!(t.tenant_id, "stock")
    t
  end

  @doc "An org unit that the document service also finds: org import puts units in the core scope tree."
  def unit!(schema) do
    unit = L.org_unit!(schema)
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    unit
  end

  @doc "Installs org, locations and stock in a tenant built by another fixture."
  def install_all!(tenant_id) do
    for m <- ["org", "locations", "stock"], do: L.install_module!(tenant_id, m)
    :ok
  end

  def employee!(schema, unit, opts \\ []) do
    code = "E-#{System.unique_integer([:positive])}"
    user = Keyword.get(opts, :user, Ecto.UUID.generate())
    extra = %{"org_unit_id" => unit, "active" => Keyword.get(opts, :active, true)}
    extra = if user, do: Map.put(extra, "user_id", user), else: extra

    OrgFixture.create!(schema, "org_employee", OrgFixture.values("org_employee", code, extra)).record_id
  end

  @doc """
  The world of a unit: `%{unit, chair, chair_user, members, a, a1, a11, b}` (location record ids).
  """
  def world!(schema) do
    unit = unit!(schema)
    chair_user = Ecto.UUID.generate()
    chair = employee!(schema, unit, user: chair_user)
    m1 = employee!(schema, unit, user: nil)
    m2 = employee!(schema, unit, user: nil)

    a = L.node!(schema, "A#{System.unique_integer([:positive])}", "building").record_id

    a1 =
      L.node!(schema, "A1#{System.unique_integer([:positive])}", "zone", %{"parent_id" => a}).record_id

    a11 =
      L.node!(schema, "A11#{System.unique_integer([:positive])}", "rack", %{"parent_id" => a1}).record_id

    b = L.node!(schema, "B#{System.unique_integer([:positive])}", "building").record_id
    L.link!(schema, unit, a)
    L.link!(schema, unit, a1)
    L.link!(schema, unit, a11)
    L.link!(schema, unit, b)

    %{
      unit: unit,
      chair: chair,
      chair_user: chair_user,
      members: [m1, m2],
      a: a,
      a1: a1,
      a11: a11,
      b: b
    }
  end

  def input(w, extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => w.unit,
        "kind" => "selective",
        "planned_start" => "2026-11-10T09:00:00+05:00",
        "planned_end" => "2026-11-11T09:00:00+05:00",
        "chair_employee_id" => w.chair,
        "member_employee_ids" => w.members,
        "location_ids" => [w.a],
        "note" => "year end"
      },
      extra
    )
  end

  def opts(actor \\ nil, scope \\ :all),
    do: %{actor_id: actor || Ecto.UUID.generate(), scope: scope}
end
