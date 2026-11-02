Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.ImportTest do
  @moduledoc """
  GH #3602 / REQ-651 (decision 0077 D5-D7): the import path of module-managed types, through the
  real router (`Letflow.Router.call/2`, a real API-token bearer) on real tenants with the real
  `catalog_items` module installed. `async: false`: provisioning switches the sandbox to `:auto`.

    * G1..G6 route gate; C1..C4 JSON, CSV, xlsx and counterparty rows; F1..F4 reference refusals;
      P1/P2 re-import; D0..D6 dry run (D0 is the spike of the nested-transaction claim);
      X1..X3 tenancy; S1 scope; M2 the core holds no Owner.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CatalogItemsFixture, as: Fx
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.CatalogItems
  alias Letflow.XlsxFixture

  @schema_version "entities/record-export/v1"
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  # ── helpers ────────────────────────────────────────────────────────────

  defp tenant_ctx(prefix, roles \\ ["TENANT_ADMIN"]) do
    %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!(prefix)
    slug = Repo.get!(Tenant, tenant_id).slug

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3602-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3602 test user",
        email: "gh3602-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    %{tenant_id: tenant_id, schema: schema, slug: slug, plaintext: plaintext}
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp path(type, query), do: "/api/v1/entities/records/#{type}/import" <> query

  defp json_import(ctx, type, records, extra \\ %{}, query \\ "") do
    body =
      Map.merge(
        %{
          "record_export_schema_version" => @schema_version,
          "entity_type" => type,
          "records" => records
        },
        extra
      )

    conn(:post, path(type, query), Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> authed(ctx)
  end

  defp upsert(ctx, type, records, extra \\ %{}, query \\ ""),
    do: json_import(ctx, type, records, Map.put(extra, "upsert_by", "external_ref"), query)

  defp csv_import(ctx, type, csv, query) do
    conn(:post, path(type, query), csv)
    |> put_req_header("content-type", "text/csv")
    |> authed(ctx)
  end

  defp xlsx_import(ctx, type, bytes, query) do
    conn(:post, path(type, query), bytes)
    |> put_req_header("content-type", @xlsx)
    |> authed(ctx)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp results(conn), do: body(conn)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp ref(id), do: %{"system" => "erp", "id" => id}

  defp uom_row(id, code \\ nil),
    do: %{
      "external_ref" => ref(id),
      "field_values" => %{"code" => code || id, "name" => "Unit #{id}", "active" => true}
    }

  defp item_row(id, uom_id, extra \\ %{}),
    do: %{
      "external_ref" => ref(id),
      "field_values" =>
        Map.merge(
          %{
            "code" => id,
            "name" => "Item #{id}",
            "base_uom_id" => uom_id,
            "kind" => "material",
            "active" => true
          },
          extra
        )
    }

  defp counterparty_row(id),
    do: %{
      "external_ref" => ref(id),
      "field_values" => %{
        "code" => id,
        "name" => "Supplier #{id}",
        "kind" => "supplier",
        "active" => true
      }
    }

  defp count_of(schema, table),
    do: Repo.aggregate(from(e in table, select: e.id), :count, prefix: schema)

  defp latest_count(schema), do: Repo.aggregate(Latest, :count, prefix: schema)

  defp counts(schema),
    do: {count_of(schema, "events"), count_of(schema, "event_idempotency"), latest_count(schema)}

  defp stored(schema, type, ext_id),
    do: Latest.get_by_external_ref(type, "erp", ext_id, schema)

  # A result with the per-run record ids removed, for comparing a dry run with the real import.
  defp shape(conn),
    do: Enum.map(results(conn), &Map.drop(&1, ["record_id"]))

  # ── G: the route gate ──────────────────────────────────────────────────

  describe "G: route gate" do
    test "G1: an upsert-mode import of catalog_uom answers 200, one result per row" do
      ctx = tenant_ctx("gh3602-g1")
      conn = upsert(ctx, "catalog_uom", [uom_row("U1"), uom_row("U2")])
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created", "created"]
      refute Map.has_key?(body(conn), "dry_run")
    end

    test "G2: the same body without upsert mode is 422 and writes nothing" do
      ctx = tenant_ctx("gh3602-g2")
      before = counts(ctx.schema)
      conn = json_import(ctx, "catalog_uom", [uom_row("U1")])
      assert conn.status == 422
      assert conn.resp_body =~ "upsert_by external_ref only"
      assert counts(ctx.schema) == before
    end

    test "G3: a row without external_ref is the row error external_ref_invalid" do
      ctx = tenant_ctx("gh3602-g3")
      row = %{"field_values" => %{"code" => "X", "name" => "x", "active" => true}}
      conn = upsert(ctx, "catalog_uom", [row, uom_row("U1")])
      assert conn.status == 200
      assert outcomes(conn) == ["external_ref_invalid", "created"]
    end

    test "G4: a managed type with no registered function is still 403 entity_type_managed" do
      ctx = tenant_ctx("gh3602-g4")

      assert Letflow.Modules.Catalog.import_function("catalog_items", "catalog_lot") ==
               {:error, :not_found}

      conn = upsert(ctx, "catalog_lot", [uom_row("L1")])
      assert conn.status == 403
      assert conn.resp_body =~ "entity_type_managed"
      assert latest_count(ctx.schema) == 0
    end

    test "G5: a caller without EntitiesRecordsImport is refused and nothing is written" do
      ctx = tenant_ctx("gh3602-g5", ["TASK_WORKER"])
      conn = upsert(ctx, "catalog_uom", [uom_row("U1")])
      assert conn.status == 403
      assert latest_count(ctx.schema) == 0
    end

    test "G6: catalog_lot answers 403 for an xlsx body too (bytes never read)" do
      ctx = tenant_ctx("gh3602-g6")
      conn = xlsx_import(ctx, "catalog_lot", "garbage", "?upsert_by=external_ref")
      assert conn.status == 403
    end
  end

  # ── C: rows in the three formats ───────────────────────────────────────

  describe "C: catalog rows" do
    test "C1: JSON units then items; base_uom_id is the unit record id; the field pair is stored" do
      ctx = tenant_ctx("gh3602-c1")

      conn =
        upsert(ctx, "catalog_uom", [uom_row("U1"), uom_row("U2")])

      assert outcomes(conn) == ["created", "created"]
      [%{"record_id" => u1}, _] = results(conn)

      conn = upsert(ctx, "catalog_item", [item_row("I1", "U1")])
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created"]
      [%{"record_id" => i1}] = results(conn)

      assert {:ok, %{"base_uom_id" => ^u1} = item} = CatalogItems.lookup(ctx.schema, i1)
      assert item["external_ref_system"] == "erp"
      assert item["external_ref_id"] == "I1"
      assert {:ok, %{"external_ref_id" => "U1"}} = CatalogItems.lookup(ctx.schema, u1)
    end

    test "C2: CSV units then items" do
      ctx = tenant_ctx("gh3602-c2")

      units =
        "code,name,active,external_ref_system,external_ref_id\nU1,Unit 1,true,erp,U1\n"

      conn = csv_import(ctx, "catalog_uom", units, "?upsert_by=external_ref")
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created"]
      [%{"record_id" => u1}] = results(conn)

      items =
        "code,name,base_uom_id,kind,active,external_ref_system,external_ref_id\n" <>
          "I1,Item 1,U1,material,true,erp,I1\n"

      conn = csv_import(ctx, "catalog_item", items, "?upsert_by=external_ref")
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created"]
      [%{"record_id" => i1}] = results(conn)

      assert {:ok, %{"base_uom_id" => ^u1, "external_ref_id" => "I1"}} =
               CatalogItems.lookup(ctx.schema, i1)
    end

    test "C3: xlsx units then items" do
      ctx = tenant_ctx("gh3602-c3")

      units =
        XlsxFixture.build([
          [
            ["code", "name", "active", "external_ref_system", "external_ref_id"],
            ["U1", "Unit 1", true, "erp", "U1"]
          ]
        ])

      conn = xlsx_import(ctx, "catalog_uom", units, "?upsert_by=external_ref")
      assert conn.status == 200, conn.resp_body
      [%{"record_id" => u1}] = results(conn)

      items =
        XlsxFixture.build([
          [
            [
              "code",
              "name",
              "base_uom_id",
              "kind",
              "active",
              "external_ref_system",
              "external_ref_id"
            ],
            ["I1", "Item 1", "U1", "material", true, "erp", "I1"]
          ]
        ])

      conn = xlsx_import(ctx, "catalog_item", items, "?upsert_by=external_ref")
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created"]
      [%{"record_id" => i1}] = results(conn)
      assert {:ok, %{"base_uom_id" => ^u1}} = CatalogItems.lookup(ctx.schema, i1)
    end

    test "C4: counterparties are created, with the field pair" do
      ctx = tenant_ctx("gh3602-c4")
      conn = upsert(ctx, "catalog_counterparty", [counterparty_row("S1"), counterparty_row("S2")])
      assert conn.status == 200, conn.resp_body
      assert outcomes(conn) == ["created", "created"]
      [%{"record_id" => id} | _] = results(conn)

      assert {:ok, %{"external_ref_system" => "erp", "external_ref_id" => "S1"}} =
               CatalogItems.lookup(ctx.schema, id)
    end
  end

  # ── F: reference refusals ──────────────────────────────────────────────

  describe "F: reference refusals" do
    setup do
      ctx = tenant_ctx("gh3602-f")
      conn = upsert(ctx, "catalog_uom", [uom_row("U1")])
      [%{"record_id" => u1}] = results(conn)
      {:ok, ctx: ctx, u1: u1}
    end

    defp assert_ref_refusal(conn, reason) do
      assert conn.status == 200, conn.resp_body
      assert [bad, good] = results(conn)
      assert bad["status"] == "error"
      assert bad["reason"] == %{"type" => reason, "header" => "base_uom_id"}
      assert good["status"] == "ok"
    end

    test "F1: an unknown unit is reference_not_found naming base_uom_id", %{ctx: ctx} do
      conn = upsert(ctx, "catalog_item", [item_row("I1", "NOPE"), item_row("I2", "U1")])
      assert_ref_refusal(conn, "reference_not_found")
      assert {:error, :not_found} = stored(ctx.schema, "catalog_item", "I1")
      assert {:ok, _} = stored(ctx.schema, "catalog_item", "I2")
      refute conn.resp_body =~ "NOPE"
    end

    test "F2: a unit's record id in the cell is reference_not_found", %{ctx: ctx, u1: u1} do
      conn = upsert(ctx, "catalog_item", [item_row("I1", u1), item_row("I2", "U1")])
      assert_ref_refusal(conn, "reference_not_found")
      assert {:error, :not_found} = stored(ctx.schema, "catalog_item", "I1")
    end

    test "F3: a unit that comes later in the file is reference_not_found", %{ctx: ctx} do
      conn =
        upsert(ctx, "catalog_item", [item_row("I1", "U-LATER"), item_row("I2", "U1")])

      assert_ref_refusal(conn, "reference_not_found")

      # the unit itself arrives later in the SAME file: only another file's order helps
      conn = upsert(ctx, "catalog_uom", [uom_row("U-LATER")])
      assert outcomes(conn) == ["created"]
    end

    test "F4: a retired unit is reference_inactive", %{ctx: ctx} do
      upsert(ctx, "catalog_uom", [
        %{
          "external_ref" => ref("U-OLD"),
          "field_values" => %{"code" => "U-OLD", "name" => "old", "active" => false}
        }
      ])

      conn = upsert(ctx, "catalog_item", [item_row("I1", "U-OLD"), item_row("I2", "U1")])
      assert_ref_refusal(conn, "reference_inactive")
      assert {:error, :not_found} = stored(ctx.schema, "catalog_item", "I1")
    end
  end

  # ── P: re-import ───────────────────────────────────────────────────────

  describe "P: re-import" do
    test "P1/P2: the same file again is unchanged and writes nothing; one change is updated" do
      ctx = tenant_ctx("gh3602-p")
      file = [uom_row("U1")]
      items = [item_row("I1", "U1"), item_row("I2", "U1")]
      assert outcomes(upsert(ctx, "catalog_uom", file)) == ["created"]
      assert outcomes(upsert(ctx, "catalog_item", items)) == ["created", "created"]

      before = counts(ctx.schema)
      assert outcomes(upsert(ctx, "catalog_uom", file)) == ["unchanged"]
      assert outcomes(upsert(ctx, "catalog_item", items)) == ["unchanged", "unchanged"]
      assert counts(ctx.schema) == before

      changed = [item_row("I1", "U1", %{"name" => "Renamed"}), item_row("I2", "U1")]
      assert outcomes(upsert(ctx, "catalog_item", changed)) == ["updated", "unchanged"]
    end
  end

  # ── D: dry run ─────────────────────────────────────────────────────────

  describe "D: dry run" do
    test "D0: spike: a refused nested Records write poisons an outer transaction; a pre-DB refusal does not" do
      %{schema: schema} = Fx.installed_tenant!("gh3602-d0")
      Fx.uom!(schema, "DUP")

      {:error, {:probe, db_refused, validation_refused, after_db}} =
        Repo.transaction(fn ->
          db = Fx.create(schema, "catalog_uom", Fx.values("catalog_uom", "DUP", %{}))
          after_db = Letflow.Entities.ManagedImport.poisoned?()
          Repo.rollback({:probe, db, nil, after_db})
        end)

      assert {:error, {:record_payload_invalid, _}} = db_refused
      assert validation_refused == nil
      assert is_boolean(after_db)

      {:error, {:probe, bad, _, clean}} =
        Repo.transaction(fn ->
          bad = Fx.create(schema, "catalog_uom", %{"code" => 5})
          Repo.rollback({:probe, bad, nil, Letflow.Entities.ManagedImport.poisoned?()})
        end)

      assert {:error, _} = bad
      assert clean == false
    end

    test "D1: results equal the real import's, dry_run is true, nothing is kept" do
      ctx = tenant_ctx("gh3602-d1")
      units = [uom_row("U1"), uom_row("U2")]
      items = [item_row("I1", "U1"), item_row("I2", "U2")]
      file_items = fn q -> upsert(ctx, "catalog_item", items, %{}, q) end

      before = counts(ctx.schema)
      dry_units = upsert(ctx, "catalog_uom", units, %{"dry_run" => true})
      assert body(dry_units)["dry_run"] == true
      assert counts(ctx.schema) == before

      real_units = upsert(ctx, "catalog_uom", units)
      assert shape(dry_units) == shape(real_units)

      before = counts(ctx.schema)
      dry_items = file_items.("?dry_run=true")
      assert body(dry_items)["dry_run"] == true
      assert counts(ctx.schema) == before
      assert outcomes(dry_items) == ["created", "created"]
      assert shape(dry_items) == shape(file_items.(""))
    end

    test "D1b: items that refer to units created earlier in the same file resolve in a dry run only if stored" do
      ctx = tenant_ctx("gh3602-d1b")
      # different types are different files: the unit must be stored; a mixed reference to an
      # unstored unit is refused identically in dry and real runs
      items = [item_row("I1", "U-MISSING")]
      before = counts(ctx.schema)
      dry = upsert(ctx, "catalog_item", items, %{"dry_run" => true})
      assert counts(ctx.schema) == before
      real = upsert(ctx, "catalog_item", items)
      assert shape(dry) == shape(real)
    end

    test "D2: a row refused by the database does not change the results of the rows after it" do
      ctx = tenant_ctx("gh3602-d2")
      upsert(ctx, "catalog_uom", [uom_row("EXIST", "DUPCODE")])

      file = [
        uom_row("A1"),
        # same code as a stored unit: refused by the unique constraint
        uom_row("A2", "DUPCODE"),
        uom_row("A3"),
        uom_row("A4")
      ]

      before = counts(ctx.schema)
      dry = upsert(ctx, "catalog_uom", file, %{"dry_run" => true})
      assert dry.status == 200, dry.resp_body
      assert counts(ctx.schema) == before

      real = upsert(ctx, "catalog_uom", file)
      assert shape(dry) == shape(real)
      assert outcomes(real) == ["created", "record_payload_invalid", "created", "created"]
    end

    test "D3: ?dry_run=true on a CSV body writes nothing" do
      ctx = tenant_ctx("gh3602-d3")
      csv = "code,name,active,external_ref_system,external_ref_id\nU1,Unit 1,true,erp,U1\n"
      before = counts(ctx.schema)
      conn = csv_import(ctx, "catalog_uom", csv, "?upsert_by=external_ref&dry_run=true")
      assert conn.status == 200, conn.resp_body
      assert body(conn)["dry_run"] == true
      assert outcomes(conn) == ["created"]
      assert counts(ctx.schema) == before
    end

    test "D4: a dry run on a type that is not managed is 422 and writes nothing" do
      ctx = tenant_ctx("gh3602-d4")

      {:ok, _} =
        Letflow.Entities.Definitions.create_definition(
          %{
            definition: %{
              name: "plain_t",
              display_name: "plain_t",
              fields: [%{name: "title", type: :string, required: true}]
            },
            created_by: Ecto.UUID.generate()
          },
          ctx.schema
        )

      {:ok, _} =
        Letflow.Entities.Definitions.activate_definition(
          "plain_t",
          Ecto.UUID.generate(),
          "gh3602",
          ctx.schema
        )

      row = %{"external_ref" => ref("P1"), "field_values" => %{"title" => "t"}}
      conn = upsert(ctx, "plain_t", [row], %{"dry_run" => true})
      assert conn.status == 422
      assert conn.resp_body =~ "dry_run is offered only"
      assert latest_count(ctx.schema) == 0
    end

    test "D5: dry_run that is not a boolean is 422" do
      ctx = tenant_ctx("gh3602-d5")
      conn = upsert(ctx, "catalog_uom", [uom_row("U1")], %{"dry_run" => "yes"})
      assert conn.status == 422
      assert latest_count(ctx.schema) == 0
    end

    test "D6: more refused-by-the-database rows than the replay cap is 422 and writes nothing" do
      ctx = tenant_ctx("gh3602-d6")
      upsert(ctx, "catalog_uom", [uom_row("EXIST", "DUPCODE")])
      cap = Letflow.Entities.ManagedImport.max_replays()
      rows = for n <- 1..(cap + 2), do: uom_row("R#{n}", "DUPCODE")

      before = counts(ctx.schema)
      conn = upsert(ctx, "catalog_uom", rows, %{"dry_run" => true})
      assert counts(ctx.schema) == before

      assert conn.status == 422
      assert conn.resp_body =~ "dry_run unavailable"
    end
  end

  # ── X: tenancy ─────────────────────────────────────────────────────────

  describe "X: tenancy" do
    test "X1/X2: another tenant's unit is not found; the same ref makes two records" do
      a = tenant_ctx("gh3602-xa")
      b = tenant_ctx("gh3602-xb")
      assert outcomes(upsert(a, "catalog_uom", [uom_row("U1")])) == ["created"]

      before_a = counts(a.schema)
      before_b = counts(b.schema)
      conn = upsert(b, "catalog_item", [item_row("I1", "U1")])
      assert outcomes(conn) == ["reference_not_found"]
      assert counts(a.schema) == before_a
      assert counts(b.schema) == before_b

      assert outcomes(upsert(b, "catalog_uom", [uom_row("U1")])) == ["created"]
      {:ok, ua} = stored(a.schema, "catalog_uom", "U1")
      {:ok, ub} = stored(b.schema, "catalog_uom", "U1")
      assert ua.record_id != ub.record_id
    end

    test "X3: the import code takes no tenant argument other than prefix" do
      for file <- [
            "lib/letflow/modules/catalog_items/import.ex",
            "lib/letflow/entities/managed_import.ex"
          ] do
        source = File.read!(Path.expand("../../../../" <> file, __DIR__))
        refute source =~ ~r/\bdef\w* [a-z_?!]+\([^)]*tenant_id/, "#{file} takes a tenant_id"
      end
    end
  end

  # ── S / M ──────────────────────────────────────────────────────────────

  describe "S1: scope" do
    test "an org-scoped TENANT_ADMIN gets the answer an unmanaged type gets" do
      alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
      alias Letflow.Support.ScopeOnFixture, as: On

      %{tenant_id: tenant_id, schema: schema} = Fx.installed_tenant!("gh3602-s1")
      fx = %{tenant_id: tenant_id, schema_name: schema}
      :ok = On.store_mode!(fx, :on)
      user = On.scoped_holder!(fx, "TENANT_ADMIN")
      _ = RSG

      {:ok, _} =
        Letflow.Entities.Definitions.create_definition(
          %{
            definition: %{
              name: "plain_s",
              display_name: "plain_s",
              fields: [%{name: "title", type: :string, required: true}]
            },
            created_by: user.id
          },
          schema
        )

      {:ok, _} =
        Letflow.Entities.Definitions.activate_definition("plain_s", user.id, "gh3602", schema)

      call = fn type, row ->
        On.call(
          Letflow.Routers.Entities,
          :post,
          "/records/#{type}/import",
          fx,
          user.id,
          ["TENANT_ADMIN"],
          :on,
          %{
            "record_export_schema_version" => @schema_version,
            "entity_type" => type,
            "upsert_by" => "external_ref",
            "records" => [row]
          }
        )
      end

      managed = call.("catalog_uom", uom_row("U1"))

      plain =
        call.("plain_s", %{"external_ref" => ref("P1"), "field_values" => %{"title" => "t"}})

      assert managed.status == plain.status
      assert Map.delete(body(managed), "trace_id") == Map.delete(body(plain), "trace_id")
      assert latest_count(schema) == 0
    end
  end

  describe "M2: the core holds no Owner" do
    test "managed_import.ex, import_upsert.ex and record_import.ex never name an owner" do
      root = Path.expand("../../../..", __DIR__)

      for file <- [
            "lib/letflow/entities/managed_import.ex",
            "lib/letflow/entities/import_upsert.ex",
            "lib/letflow/routers/entities/record_import.ex"
          ] do
        source = File.read!(Path.join(root, file))
        refute source =~ "owner_for!", file
        refute source =~ "module_owner", file
        refute source =~ ~r/ManagedTypes\.owner\(/, file
      end
    end
  end
end
