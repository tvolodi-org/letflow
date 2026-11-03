Code.require_file("org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Org.PeopleTest do
  @moduledoc """
  GH #3617 / REQ-661: the position and employee writers of module `org` on real provisioned
  tenants (design tests F, E, P, T, A, N, S, D). `async: false`: tenant provisioning switches the
  sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity.User
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture

  @people_path Path.join(File.cwd!(), "lib/letflow/modules/org/people.ex")
  @runbook_path Path.join(File.cwd!(), "docs/runbooks/wms-foundation.md")

  setup do
    ctx = OrgFixture.installed_tenant!("gh3617-org")
    {:ok, Map.put(ctx, :unit, unit!(ctx.schema, "U1"))}
  end

  defp opts(key \\ nil),
    do: %{actor_id: Ecto.UUID.generate(), idempotency_key: key || Ecto.UUID.generate()}

  defp unit!(schema, code), do: OrgFixture.unit_id!(schema, code)

  defp user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh3617-#{Ecto.UUID.generate()}",
      display_name: "GH3617 User",
      email: "gh3617-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
    |> Map.fetch!(:id)
  end

  defp position!(ctx, code, unit \\ nil) do
    {:ok, p} =
      Org.create_position(
        ctx.schema,
        %{"code" => code, "name" => "P #{code}", "org_unit_id" => unit || ctx.unit},
        opts()
      )

    p
  end

  defp employee!(ctx, code, extra \\ %{}) do
    attrs =
      Map.merge(
        %{"code" => code, "full_name" => "Zhanna Secretova", "org_unit_id" => ctx.unit},
        extra
      )

    {:ok, e} = Org.create_employee(ctx.schema, attrs, opts())
    e
  end

  defp count(schema, type),
    do: Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)

  defp audit_rows(schema, like) do
    Repo.all(from(e in Audit.Entry, where: like(e.action, ^like), order_by: e.timestamp),
      prefix: schema
    )
  end

  defp snapshot(schema),
    do:
      {count(schema, "org_position"), count(schema, "org_employee"),
       length(audit_rows(schema, "org_%"))}

  defp assert_refused(ctx, expected, fun) do
    before = snapshot(ctx.schema)
    assert fun.() == expected
    assert snapshot(ctx.schema) == before
  end

  # All events of the tenant: a transfer of one record is exactly one more.
  defp events(schema, _id) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".events", [])
    n
  end

  # --- AC 1 -----------------------------------------------------------------------------------

  test "F1 seven functions create, change and read back", ctx do
    for {f, a} <- [
          create_position: 3,
          update_position: 4,
          retire_position: 3,
          create_employee: 3,
          update_employee: 4,
          transfer_employee: 5,
          retire_employee: 3
        ],
        do: assert(function_exported?(Org, f, a))

    pos = position!(ctx, "P1")
    assert pos["active"] == true and pos["org_unit_id"] == ctx.unit
    {:ok, pos2} = Org.update_position(ctx.schema, pos["record_id"], %{"name" => "New"}, opts())
    assert pos2["name"] == "New"

    emp = employee!(ctx, "E1", %{"position_id" => pos["record_id"]})
    assert emp["position_id"] == pos["record_id"]
    assert {:ok, ^emp} = Org.lookup(ctx.schema, emp["record_id"])
    assert Org.active_employee?(ctx.schema, emp["record_id"])

    {:ok, _} = Org.retire_employee(ctx.schema, emp["record_id"], opts())
    refute Org.active_employee?(ctx.schema, emp["record_id"])
    {:ok, p3} = Org.retire_position(ctx.schema, pos["record_id"], opts())
    assert p3["active"] == false
  end

  # --- AC 2 -----------------------------------------------------------------------------------

  test "E1..E9 create_employee refusals write nothing", ctx do
    {:ok, c} =
      Org.create_legal_entity(
        ctx.schema,
        %{"code" => "C", "name" => "C", "bin" => "123456789012"},
        opts()
      )

    {:ok, st} =
      Org.create_site(
        ctx.schema,
        %{"code" => "S", "name" => "S", "legal_entity_id" => c["record_id"]},
        opts()
      )

    {:ok, ru} =
      Org.create_unit(
        ctx.schema,
        %{
          "code" => "RU",
          "name" => "RU",
          "legal_entity_id" => c["record_id"],
          "site_id" => st["record_id"]
        },
        opts()
      )

    retired_unit = ru["record_id"]
    {:ok, _} = Org.retire_unit(ctx.schema, retired_unit, opts())
    other_unit = unit!(ctx.schema, "U2")
    pos_other = position!(ctx, "PO", other_unit)
    pos_retired = position!(ctx, "PR")
    {:ok, _} = Org.retire_position(ctx.schema, pos_retired["record_id"], opts())
    other = OrgFixture.installed_tenant!("gh3617-other")
    foreign_user = user!(other.schema)
    base = %{"code" => "X", "full_name" => "N", "org_unit_id" => ctx.unit}

    create = fn extra ->
      fn -> Org.create_employee(ctx.schema, Map.merge(base, extra), opts()) end
    end

    assert_refused(
      ctx,
      {:error, :unit_not_found},
      create.(%{"org_unit_id" => Ecto.UUID.generate()})
    )

    assert_refused(ctx, {:error, :unit_not_found}, create.(%{"org_unit_id" => "nope"}))
    assert_refused(ctx, {:error, :unit_inactive}, create.(%{"org_unit_id" => retired_unit}))

    assert_refused(
      ctx,
      {:error, :position_not_found},
      create.(%{"position_id" => Ecto.UUID.generate()})
    )

    assert_refused(
      ctx,
      {:error, :position_inactive},
      create.(%{"position_id" => pos_retired["record_id"]})
    )

    assert_refused(
      ctx,
      {:error, :position_not_in_unit},
      create.(%{"position_id" => pos_other["record_id"]})
    )

    assert_refused(ctx, {:error, :user_not_found}, create.(%{"user_id" => "not-a-uuid"}))
    assert_refused(ctx, {:error, :user_not_found}, create.(%{"user_id" => Ecto.UUID.generate()}))
    # E8: a user of a second tenant
    assert_refused(ctx, {:error, :user_not_found}, create.(%{"user_id" => foreign_user}))

    # E9: the same user linked twice
    u = user!(ctx.schema)
    employee!(ctx, "E-A", %{"user_id" => u})
    before = snapshot(ctx.schema)

    assert {:error, {:record_payload_invalid, _}} =
             Org.create_employee(ctx.schema, Map.merge(base, %{"user_id" => u}), opts())

    assert snapshot(ctx.schema) == before

    # E10: no user, no position accepted; user_id stored canonical lowercase
    e = employee!(ctx, "E-B")
    refute Map.has_key?(e, "position_id") or Map.has_key?(e, "user_id")
    e2 = employee!(ctx, "E-C", %{"user_id" => String.upcase(user!(ctx.schema))})
    assert e2["user_id"] == String.downcase(e2["user_id"])
  end

  test "E11 position refusals and bad keys", ctx do
    assert {:error, {:field_not_allowed, "active"}} =
             Org.create_position(
               ctx.schema,
               %{"code" => "A", "name" => "A", "org_unit_id" => ctx.unit, "active" => false},
               opts()
             )

    assert {:error, :unit_not_found} =
             Org.create_position(ctx.schema, %{"code" => "A", "name" => "A"}, opts())

    assert {:error, {:field_invalid, "name"}} =
             Org.create_position(
               ctx.schema,
               %{"code" => "A", "name" => " ", "org_unit_id" => ctx.unit},
               opts()
             )

    assert {:error, :position_not_found} =
             Org.update_position(ctx.schema, "x", %{"name" => "A"}, opts())

    assert {:error, :employee_not_found} = Org.retire_employee(ctx.schema, "x", opts())
    assert {:error, {:field_invalid, "attrs"}} = Org.create_employee(ctx.schema, nil, opts())
  end

  test "E12 update_employee checks the user and clears the link", ctx do
    u = user!(ctx.schema)
    e = employee!(ctx, "E1")

    assert {:error, :user_not_found} =
             Org.update_employee(ctx.schema, e["record_id"], %{"user_id" => "zz"}, opts())

    assert {:error, {:field_not_allowed, "org_unit_id"}} =
             Org.update_employee(ctx.schema, e["record_id"], %{"org_unit_id" => ctx.unit}, opts())

    {:ok, linked} =
      Org.update_employee(ctx.schema, e["record_id"], %{"user_id" => String.upcase(u)}, opts())

    assert linked["user_id"] == u
    n = events(ctx.schema, e["record_id"])

    # same value in another case: no spurious version
    {:ok, _} =
      Org.update_employee(ctx.schema, e["record_id"], %{"user_id" => String.upcase(u)}, opts())

    assert events(ctx.schema, e["record_id"]) == n
    {:ok, cleared} = Org.update_employee(ctx.schema, e["record_id"], %{"user_id" => nil}, opts())
    refute Map.has_key?(cleared, "user_id")
  end

  # --- AC 3 -----------------------------------------------------------------------------------

  test "P1..P3 a position in use is not retired; its unit is not changed", ctx do
    pos = position!(ctx, "P1")
    emp = employee!(ctx, "E1", %{"position_id" => pos["record_id"]})

    assert_refused(ctx, {:error, :position_in_use}, fn ->
      Org.retire_position(ctx.schema, pos["record_id"], opts())
    end)

    assert {:error, {:field_not_allowed, "org_unit_id"}} =
             Org.update_position(
               ctx.schema,
               pos["record_id"],
               %{"org_unit_id" => unit!(ctx.schema, "U9")},
               opts()
             )

    {:ok, _} = Org.transfer_employee(ctx.schema, emp["record_id"], ctx.unit, nil, opts())
    assert {:ok, %{"active" => false}} = Org.retire_position(ctx.schema, pos["record_id"], opts())
  end

  # --- AC 4 -----------------------------------------------------------------------------------

  test "T1..T4 transfer", ctx do
    u2 = unit!(ctx.schema, "U2")
    u3 = unit!(ctx.schema, "U3")
    p1 = position!(ctx, "P1")
    p2 = position!(ctx, "P2", u2)
    p3 = position!(ctx, "P3", u3)
    emp = employee!(ctx, "E1", %{"position_id" => p1["record_id"]})
    id = emp["record_id"]
    n = events(ctx.schema, id)

    assert_refused(ctx, {:error, :position_not_in_unit}, fn ->
      Org.transfer_employee(ctx.schema, id, u2, p3["record_id"], opts())
    end)

    assert {:ok, moved} = Org.transfer_employee(ctx.schema, id, u2, p2["record_id"], opts())
    assert moved["org_unit_id"] == u2 and moved["position_id"] == p2["record_id"]
    assert events(ctx.schema, id) == n + 1

    # T4: same unit and position writes nothing
    before = snapshot(ctx.schema)
    assert {:ok, ^moved} = Org.transfer_employee(ctx.schema, id, u2, p2["record_id"], opts())
    assert snapshot(ctx.schema) == before
    assert events(ctx.schema, id) == n + 1

    {:ok, gone} = Org.transfer_employee(ctx.schema, id, u3, nil, opts())
    refute Map.has_key?(gone, "position_id")

    {:ok, _} = Org.retire_employee(ctx.schema, id, opts())

    assert_refused(ctx, {:error, :employee_inactive}, fn ->
      Org.transfer_employee(ctx.schema, id, u2, nil, opts())
    end)
  end

  # --- AC 5 -----------------------------------------------------------------------------------

  test "A1..A4 audit entries, no full name, replay", ctx do
    key = Ecto.UUID.generate()
    actor = Ecto.UUID.generate()

    {:ok, e} =
      Org.create_employee(
        ctx.schema,
        %{"code" => "E1", "full_name" => "Zhanna Secretova", "org_unit_id" => ctx.unit},
        %{actor_id: actor, idempotency_key: key}
      )

    [row] = audit_rows(ctx.schema, "org_employee.%")
    assert row.action == "org_employee.created" and row.resource_id == e["record_id"]
    assert to_string(row.actor_id) == actor

    # A3: same key and input writes nothing new
    {:ok, _} =
      Org.create_employee(
        ctx.schema,
        %{"code" => "E1", "full_name" => "Zhanna Secretova", "org_unit_id" => ctx.unit},
        %{actor_id: actor, idempotency_key: key}
      )

    assert length(audit_rows(ctx.schema, "org_employee.%")) == 1
    assert count(ctx.schema, "org_employee") == 1

    {:ok, _} =
      Org.update_employee(ctx.schema, e["record_id"], %{"full_name" => "Other Name"}, opts())

    {:ok, _} = Org.retire_employee(ctx.schema, e["record_id"], opts())
    rows = audit_rows(ctx.schema, "org_employee.%")

    assert Enum.map(rows, & &1.action) ==
             ~w(org_employee.created org_employee.updated org_employee.retired)

    for r <- rows do
      dumped = inspect({r.before_state, r.after_state})
      refute dumped =~ "Zhanna"
      refute dumped =~ "Other Name"
      refute Map.has_key?(r.before_state || %{}, "full_name")
      refute Map.has_key?(r.after_state || %{}, "full_name")
    end

    assert Enum.at(rows, 1).after_state["changed_fields"] == ["full_name"]

    # A4: a refusal writes no audit
    n = length(audit_rows(ctx.schema, "org_%"))
    {:error, :employee_not_found} = Org.retire_employee(ctx.schema, Ecto.UUID.generate(), opts())
    assert length(audit_rows(ctx.schema, "org_%")) == n
  end

  # --- AC 6 -----------------------------------------------------------------------------------

  test "N1 other tenant gets the not-found tuples and nothing changes", ctx do
    pos = position!(ctx, "P1")
    emp = employee!(ctx, "E1")
    other = OrgFixture.installed_tenant!("gh3617-b")
    mine = snapshot(ctx.schema)
    theirs = snapshot(other.schema)

    assert {:error, :position_not_found} =
             Org.update_position(other.schema, pos["record_id"], %{"name" => "x"}, opts())

    assert {:error, :position_not_found} =
             Org.retire_position(other.schema, pos["record_id"], opts())

    assert {:error, :employee_not_found} =
             Org.retire_employee(other.schema, emp["record_id"], opts())

    assert {:error, :employee_not_found} =
             Org.transfer_employee(other.schema, emp["record_id"], ctx.unit, nil, opts())

    assert {:error, :unit_not_found} =
             Org.create_employee(
               other.schema,
               %{"code" => "E", "full_name" => "N", "org_unit_id" => ctx.unit},
               opts()
             )

    assert snapshot(ctx.schema) == mine
    assert snapshot(other.schema) == theirs
  end

  test "N2 people.ex names no tenant id, Records or Audit" do
    src = File.read!(@people_path)
    refute src =~ "tenant_id"
    refute src =~ "opts[:tenant"
    refute src =~ "Records."
    refute src =~ "Audit."
  end

  # --- AC 7 / 8 -------------------------------------------------------------------------------

  test "S1 no function takes a principal and no scope declaration is added" do
    refute function_exported?(Letflow.Modules.Org.People, :scope_declarations, 0)

    for {f, a} <- [create_position: 3, transfer_employee: 5, retire_employee: 3],
        do: assert(function_exported?(Letflow.Modules.Org.People, f, a))
  end

  test "D1 the runbook describes the people write functions" do
    rb = File.read!(@runbook_path)
    assert rb =~ "GH #3617"
    assert rb =~ "transfer_employee/5"
  end
end
