Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.AssetsCountsFixture do
  @moduledoc """
  REQ-816 / GH #4375 (asset count K1): setup of the count order tests. A `.exs` file loaded with
  `Code.require_file/2`; the callers build committed tenants through `Letflow.AssetsRegisterFixture`
  (Sandbox `:auto`, `async: false`).

  The world of one org unit: `%{unit, chair, chair_user, members, a, a1, b, c}`. `a1` is below `a`; `a`,
  `a1` and `b` are linked to the unit, `c` exists but is NOT linked.
  """

  alias Letflow.AssetsDocsFixture, as: AD
  alias Letflow.Entities.Records
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Locations
  alias Letflow.Modules.TenantModule
  alias Letflow.OrgFixture
  alias Letflow.Repo

  defp wopts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  def employee!(schema, unit, user) do
    n = System.unique_integer([:positive])
    extra = %{"org_unit_id" => unit, "active" => true}
    extra = if user, do: Map.put(extra, "user_id", user), else: extra

    OrgFixture.create!(schema, "org_employee", OrgFixture.values("org_employee", "E#{n}", extra)).record_id
  end

  defp node!(schema, kind, parent) do
    n = System.unique_integer([:positive])
    attrs = %{"code" => "L#{n}", "name" => "L", "node_kind" => kind}
    attrs = if parent, do: Map.put(attrs, "parent_id", parent), else: attrs
    {:ok, node} = Locations.create_node(schema, attrs, wopts())
    node["record_id"]
  end

  defp link!(schema, unit, location) do
    {:ok, _} = Locations.link_unit_location(schema, unit, location, wopts())
    :ok
  end

  @doc "The world of a fresh org unit; the chair is linked to `chair_user` (a random uuid by default)."
  def world!(schema, chair_user \\ nil) do
    unit = AD.unit!(schema)
    chair_user = chair_user || Ecto.UUID.generate()
    a = node!(schema, "building", nil)
    a1 = node!(schema, "zone", a)
    b = node!(schema, "building", nil)
    c = node!(schema, "building", nil)
    for l <- [a, a1, b], do: link!(schema, unit, l)

    %{
      unit: unit,
      chair: employee!(schema, unit, chair_user),
      chair_user: chair_user,
      members: [employee!(schema, unit, nil), employee!(schema, unit, nil)],
      a: a,
      a1: a1,
      b: b,
      c: c
    }
  end

  @doc "A valid order body of the world `w`; `extra` overrides keys."
  def input(w, extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => w.unit,
        "kinds" => ["fixed"],
        "planned_start" => "2026-11-20T09:00:00+05:00",
        "planned_end" => "2026-11-21T09:00:00+05:00",
        "chair_employee_id" => w.chair,
        "member_employee_ids" => w.members,
        "location_ids" => [w.a],
        "note" => "year end"
      },
      extra
    )
  end

  def opts(actor \\ nil), do: %{actor_id: actor || Ecto.UUID.generate()}

  defp settings(schema) do
    case Repo.get_by(TenantModule, [module_id: "assets", status: :active], prefix: schema) do
      %TenantModule{settings: %{} = s} -> s
      _ -> %{}
    end
  end

  @doc "Sets the flag `count_enabled` (the settings PUT replaces the map, so the current keys are kept)."
  def enable!(schema, flag \\ true) do
    {:ok, _} =
      Installs.put_settings("assets", Map.put(settings(schema), "count_enabled", flag),
        prefix: schema
      )

    :ok
  end

  @doc "Sets one setting `key` (the other keys are kept)."
  def put_setting!(schema, key, value) do
    {:ok, _} =
      Installs.put_settings("assets", Map.put(settings(schema), key, value), prefix: schema)

    :ok
  end

  @doc "Removes the flag key."
  def disable!(schema) do
    {:ok, _} =
      Installs.put_settings("assets", Map.delete(settings(schema), "count_enabled"),
        prefix: schema
      )

    :ok
  end

  @doc "Writes `status` into the order header (the way a later slice would)."
  def set_status!(schema, id, status) do
    {:ok, header} = Letflow.Modules.ReadApi.lookup(schema, id, ["assets_count_order"])
    fv = header |> Map.drop(["record_id", "entity_type"]) |> Map.put("status", status)

    attrs = %{
      entity_type: "assets_count_order",
      record_id: id,
      field_values: fv,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (test fixture, the owner path of the assets module)
    {:ok, _} =
      Records.update_record(attrs, schema, ManagedTypes.owner_for!(Letflow.Modules.Assets))

    :ok
  end

  @doc "An order window around now: started an hour ago, ends in 20 hours (K2 opens inside it)."
  def window(extra \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
        "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
      },
      extra
    )
  end

  @doc """
  REQ-817 (asset count K2): the people and places of a count over the masters `m` of
  `AssetsDocsFixture` (`ctx.ma`): a chair, one member and one other employee, each linked to a user,
  and a second linked location `loc2` of the unit. `w` is the world map `input/2` takes (root `a` is
  the master location).
  """
  def sheet_world!(schema, m) do
    chair_user = Ecto.UUID.generate()
    member_user = Ecto.UUID.generate()
    other_user = Ecto.UUID.generate()
    chair = employee!(schema, m.unit, chair_user)
    member = employee!(schema, m.unit, member_user)
    other = employee!(schema, m.unit, other_user)

    %{
      m: m,
      chair: chair,
      chair_user: chair_user,
      member: member,
      member_user: member_user,
      other: other,
      other_user: other_user,
      loc2: AD.location!(schema, m.unit),
      w: %{unit: m.unit, chair: chair, members: [member], a: m.location}
    }
  end
end
