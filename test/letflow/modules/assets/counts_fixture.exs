Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.AssetsCountsFixture do
  @moduledoc """
  REQ-816 / GH #4375 (asset count K1): setup of the count order tests. A `.exs` file loaded with
  `Code.require_file/2`; the callers build committed tenants through `Letflow.AssetsRegisterFixture`
  (Sandbox `:auto`, `async: false`).

  The world of one org unit: `%{unit, chair, chair_user, members, a, a1, b, c}`. `a1` is below `a`; `a`,
  `a1` and `b` are linked to the unit, `c` exists but is NOT linked.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: AD
  alias Letflow.Entities.Records
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Modules.Assets.CountSheet
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.Assets.Documents.Posting
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

  # --- REQ-819 (asset count K4): the result -----------------------------------------------------

  @doc "A group holding `user_id` and a role row `name` of `kind` bound to it; returns the group id."
  def role_row!(schema, user_id, name, kind) do
    {:ok, group} =
      Identity.create_group(%{"name" => "g-#{System.unique_integer([:positive])}"},
        prefix: schema
      )

    {:ok, _} = Identity.add_group_member(group.id, user_id, prefix: schema)

    case RoleRegistry.upsert_role(name, kind, group.id, prefix: schema) do
      {:ok, _} ->
        group.id

      # A recognised platform role name is already bound in a provisioned tenant: join that group.
      {:error, :role_already_bound} when kind == :platform_role ->
        row =
          Repo.one!(
            from(t in Letflow.Identity.TenantRole, where: t.name == ^name and t.kind == ^kind),
            prefix: schema
          )

        {:ok, _} = Identity.add_group_member(row.group_id, user_id, prefix: schema)
        row.group_id
    end
  end

  @doc "Makes `user_id` a holder of the routing role `name` (the signer role)."
  def signer!(schema, user_id, name), do: role_row!(schema, user_id, name, :process_routing_role)

  @doc "A role row of kind `platform_role` named `name` (a recognised role name) held by `user_id`."
  def platform_row!(schema, user_id, name), do: role_row!(schema, user_id, name, :platform_role)

  @doc "A tenant-wide `Letflow.Ledger.Authorized` for the assets ledger of `ctx`."
  def authorized!(ctx) do
    fx = %{tenant_id: ctx.a.tenant_id, schema_name: ctx.schema}
    user = Letflow.LedgerFixture.user!(fx, ["TENANT_ADMIN"])
    conn = Letflow.LedgerFixture.conn_for(fx, user, ["TENANT_ADMIN"])
    {:ok, auth} = Letflow.Ledger.authorize(conn, "assets", :read)
    auth
  end

  @doc "A real user of the tenant (a TENANT_ADMIN holder); returns its id."
  def user!(ctx) do
    Letflow.LedgerFixture.user!(%{tenant_id: ctx.a.tenant_id, schema_name: ctx.schema}, [
      "TENANT_ADMIN"
    ]).id
  end

  @doc "An issued order of the sheet world `ctx.sw` over `extra` keys; returns the id."
  def ordered!(ctx, extra \\ %{}) do
    {:ok, %{"id" => id}} = Counts.create(ctx.schema, input(ctx.sw.w, window(extra)), opts())
    {:ok, _} = Counts.issue(ctx.schema, id, opts())
    id
  end

  def chair_opts(ctx), do: %{actor_id: ctx.sw.chair_user}
  def member_opts(ctx), do: %{actor_id: ctx.sw.member_user}

  @doc "The chair opens the order."
  def open!(ctx, id) do
    {:ok, _} =
      CountSheet.open(ctx.schema, id, %{actor_id: ctx.sw.chair_user, authorized: authorized!(ctx)})

    :ok
  end

  @doc "The sheet lines of the order."
  def lines!(ctx, id) do
    {:ok, %{rows: rows}} = CountSheet.lines(ctx.schema, id, %{"limit" => "200"}, chair_opts(ctx))
    rows
  end

  @doc "Records `body` on the book line of `asset` (typed by the member)."
  def record!(ctx, id, asset, body) do
    line = Enum.find(lines!(ctx, id), &(&1["asset_id"] == asset))
    {:ok, _} = CountSheet.record_line(ctx.schema, id, line["line_no"], body, member_opts(ctx))
    :ok
  end

  @doc "Adds a surplus line (typed by the member); returns its line number."
  def surplus!(ctx, id, body) do
    {:ok, line} = CountSheet.add_surplus_line(ctx.schema, id, body, member_opts(ctx))
    line["line_no"]
  end

  @doc "Closes the count and marks the exact set of required signers: the order is `sheet_signed`."
  def finish!(ctx, id) do
    s = ctx.schema
    {:ok, %{"sheet_document_id" => doc}} = CountSheet.close(s, id, chair_opts(ctx))
    lines = Posting.issued(s, doc).content["lines"]

    people =
      Enum.flat_map(
        lines,
        &[&1["book_material_responsible_id"], &1["observed_material_responsible_id"]]
      )

    ids =
      ([ctx.sw.chair, ctx.sw.member] ++ people)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    {:ok, %{"status" => "sheet_signed"}} =
      CountSheet.mark_sheet_signed(s, id, %{"signer_employee_ids" => ids}, chair_opts(ctx))

    :ok
  end

  @doc """
  The world of criterion 1 (seven differences) through the real flow. Fixed cards f1..f7 with f4 booked at a
  linked location `loc3` outside the roots; roots are the master location and `loc2`. Returns the order id and
  the cards.
  """
  def world7!(ctx) do
    s = ctx.schema
    m = ctx.ma
    loc3 = AD.location!(s, m.unit)
    [f1, f2, f3, f4, f5, f6, f7] = for _ <- 1..7, do: AD.card!(s, "fixed", m.unit)

    AD.commission!(
      ctx,
      AD.body(m, %{
        "lines" => for(c <- [f1, f2, f3, f6, f7], do: %{"asset_id" => c, "quantity" => "1"})
      })
    )

    AD.commission!(
      ctx,
      AD.body(m, %{"location_id" => loc3, "lines" => [%{"asset_id" => f4, "quantity" => "1"}]})
    )

    id = ordered!(ctx, %{"location_ids" => [m.location, ctx.sw.loc2]})
    open!(ctx, id)
    record!(ctx, id, f1, %{"found" => false})
    record!(ctx, id, f2, %{"found" => true, "observed_location_id" => ctx.sw.loc2})
    record!(ctx, id, f3, %{"found" => true, "observed_material_responsible_id" => ctx.sw.other})
    record!(ctx, id, f6, %{"found" => true, "condition" => "damaged"})
    record!(ctx, id, f7, %{"found" => true})

    place = %{
      "observed_location_id" => m.location,
      "observed_material_responsible_id" => m.employee
    }

    n4 = surplus!(ctx, id, Map.put(place, "asset_id", f4))
    n5 = surplus!(ctx, id, Map.put(place, "asset_id", f5))
    n_nc = surplus!(ctx, id, %{"description" => "unknown chair", "counted_quantity" => "1"})
    finish!(ctx, id)

    by_asset = Map.new(lines!(ctx, id), &{&1["asset_id"], &1["line_no"]})

    %{
      id: id,
      loc3: loc3,
      cards: %{f1: f1, f2: f2, f3: f3, f4: f4, f5: f5, f6: f6, f7: f7},
      no: %{
        f1: by_asset[f1],
        f2: by_asset[f2],
        f3: by_asset[f3],
        f4: n4,
        f5: n5,
        f6: by_asset[f6],
        f7: by_asset[f7],
        nc: n_nc
      }
    }
  end

  @doc "Forges an issued sheet of `lines` for a fresh order and puts the order in `sheet_signed`; returns the id."
  def forged_sheet!(ctx, lines) do
    s = ctx.schema
    id = ordered!(ctx)
    now = DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second))

    content = %{
      "count_order_id" => id,
      "org_unit_id" => ctx.ma.unit,
      "cut_off_at" => now,
      "cutoff_seq" => 0,
      "lines" => lines
    }

    {:ok, %{document: doc}} =
      Letflow.Documents.create_draft(
        s,
        %{type_key: "assets_count.sheet", issuing_org_unit_id: ctx.ma.unit, content: content},
        Ecto.UUID.generate()
      )

    {:ok, _} = Letflow.Documents.issue(s, %{document_id: doc.id, actor_id: Ecto.UUID.generate()})
    {:ok, header} = Letflow.Modules.ReadApi.lookup(s, id, ["assets_count_order"])

    fv =
      header
      |> Map.drop(["record_id", "entity_type"])
      |> Map.merge(%{
        "status" => "sheet_signed",
        "sheet_document_id" => doc.id,
        "sheet_number" => "ACS-FORGED",
        "cut_off_at" => now,
        "cutoff_seq" => 0
      })

    attrs = %{
      entity_type: "assets_count_order",
      record_id: id,
      field_values: fv,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (test fixture, the owner path of the assets module)
    {:ok, _} =
      Records.update_record(attrs, s, ManagedTypes.owner_for!(Letflow.Modules.Assets))

    id
  end
end
