Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.OpeningImportTest do
  @moduledoc """
  G6 (T-1493, REQ-784, decision 0083 D7): the xlsx import of opening lines into a draft asset opening
  document, through the real record import route
  (`POST /api/v1/entities/records/assets_opening_line/import?upsert_by=external_ref`) with real OIDC
  bearer tokens on committed tenants. `async: false` (Sandbox `:auto`).

  G6-1 registration; G6-2..G6-4 create, re-import, change; G6-5..G6-8 references and document state;
  G6-9 quantity; G6-10/G6-16 the 100-line cap (a 200-row file, dry and real); G6-11 drafts only;
  G6-12 dry run; G6-13 tenancy; G6-14 caller guards; G6-15 a PUT keeps the pair; G6-17 the function
  inside an outer transaction.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Entities.ManagedImport
  alias Letflow.Identity.User
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.Documents
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @cols ~w(header_id org_unit_id asset_id location_id material_responsible_id actual_user_id
           quantity external_ref_system external_ref_id)
  @sys "erp"
  @moduletag timeout: 540_000

  setup do
    ctx = D.setup!([:a, :b, :s])
    ctx = Map.merge(ctx, D.tenant_b!(ctx))
    im = setup_doc!(ctx, ctx.schema, "H1")
    {:ok, Map.merge(ctx, %{im: im})}
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
  defp ref(id), do: %{"external_ref_system" => @sys, "external_ref_id" => id}

  # Masters with an external id (under @sys) each: unit, two locations, two employees, three cards.
  defp masters!(schema) do
    n = System.unique_integer([:positive])
    unit = unit!(schema, "unit#{n}")

    loc = fn tag ->
      {:ok, node} =
        Locations.create_node(
          schema,
          Map.merge(
            %{"code" => "L#{tag}#{n}", "name" => "L", "node_kind" => "zone"},
            ref("loc#{tag}#{n}")
          ),
          opts()
        )

      {:ok, _} = Locations.link_unit_location(schema, unit.id, node["record_id"], opts())
      node["record_id"]
    end

    emp = fn tag ->
      OrgFixture.create!(
        schema,
        "org_employee",
        OrgFixture.values(
          "org_employee",
          "E#{tag}#{n}",
          Map.merge(%{"org_unit_id" => unit.id}, ref("emp#{tag}#{n}"))
        )
      ).record_id
    end

    card = fn tag, kind, extra ->
      Cards.card!(
        schema,
        "INV#{tag}#{n}",
        Map.merge(
          %{"kind" => kind, "org_unit_id" => unit.id},
          Map.merge(ref("card#{tag}#{n}"), extra)
        )
      ).record_id
    end

    %{
      n: n,
      unit: unit.id,
      unit_ext: "unit#{n}",
      location: loc.("1"),
      location2: loc.("2"),
      employee: emp.("1"),
      employee2: emp.("2"),
      fixed: card.("F", "fixed", %{}),
      low: card.("L", "low_value", %{}),
      intangible: card.("I", "intangible", %{}),
      base: card.("B", "fixed", %{}),
      retired: card.("R", "fixed", %{"active" => false}),
      refs: %{
        "org_unit_id" => nil,
        "asset_id" => "cardF#{n}",
        "location_id" => "loc1#{n}",
        "material_responsible_id" => "emp1#{n}",
        "actual_user_id" => nil
      }
    }
  end

  defp unit!(schema, ext) do
    n = System.unique_integer([:positive])

    {:ok, le} =
      Org.create_legal_entity(
        schema,
        %{"code" => "LE#{n}", "name" => "LE", "bin" => String.pad_leading("#{n}", 12, "5")},
        opts()
      )

    {:ok, site} =
      Org.create_site(
        schema,
        %{"code" => "S#{n}", "name" => "S", "legal_entity_id" => le["record_id"]},
        opts()
      )

    {:ok, unit} =
      Org.create_unit(
        schema,
        Map.merge(
          %{
            "code" => "U#{n}",
            "name" => "U",
            "legal_entity_id" => le["record_id"],
            "site_id" => site["record_id"]
          },
          ref(ext)
        ),
        opts()
      )

    %{id: unit["record_id"]}
  end

  # A draft opening document (header pair `header_ref`) with NO lines yet: the shape needs one line, so
  # it is saved with one hand-typed line (no pair) of the fixed card `m.base`.
  defp setup_doc!(ctx, schema, header_ref) do
    m = masters!(schema)

    body =
      D.opening_body(m, %{
        "external_ref_system" => @sys,
        "external_ref_id" => header_ref,
        "lines" => [
          %{
            "asset_id" => m.base,
            "location_id" => m.location,
            "material_responsible_id" => m.employee,
            "quantity" => "1"
          }
        ]
      })

    %{m: m, doc: D.save!(ctx, body), header_ref: header_ref}
  end

  defp row(im, ref_id, over \\ %{}) do
    cells =
      Map.merge(
        %{
          "header_id" => im.header_ref,
          "quantity" => "1",
          "external_ref_system" => @sys,
          "external_ref_id" => ref_id
        },
        im.m.refs
      )
      |> Map.merge(over)

    Enum.map(@cols, &Map.get(cells, &1))
  end

  defp import_file(rows, token, query \\ "", cols \\ @cols) do
    Plug.Test.conn(
      :post,
      "/api/v1/entities/records/assets_opening_line/import?upsert_by=external_ref" <> query,
      XlsxFixture.build([[cols | rows]])
    )
    |> put_req_header("content-type", @xlsx)
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp results(conn) do
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["results"]
  end

  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))
  defp reasons(conn), do: Enum.map(results(conn), & &1["reason"])

  defp imp(ctx, rows, query \\ ""), do: import_file(rows, ctx.tok_a, query)

  defp doc(ctx), do: D.get!(ctx, ctx.im.doc["id"])

  defp version_no(ctx) do
    Repo.one(
      from(v in DocumentVersion,
        where: v.document_id == ^ctx.im.doc["id"],
        select: max(v.version_no)
      ),
      prefix: ctx.schema
    )
  end

  # The pair-carrying lines (the hand-typed base line has none).
  defp pair_lines(ctx), do: Enum.filter(doc(ctx)["lines"], & &1["external_ref_id"])

  defp placements(im) do
    m = im.m

    [
      row(im, "R1", %{"asset_id" => "cardF#{m.n}", "quantity" => "1"}),
      row(im, "R2", %{
        "asset_id" => "cardL#{m.n}",
        "actual_user_id" => nil,
        "quantity" => "5"
      }),
      row(im, "R3", %{
        "asset_id" => "cardL#{m.n}",
        "actual_user_id" => "emp2#{m.n}",
        "quantity" => "3"
      }),
      row(im, "R4", %{"asset_id" => "cardI#{m.n}", "location_id" => nil, "quantity" => "1"})
    ]
  end

  test "G6-1: the manifest lists both import functions and validates" do
    m = Assets.manifest()

    assert m.import_functions == [
             %{entity_type: "assets_card", function: :import_card},
             %{entity_type: "assets_opening_line", function: :import_opening_line}
           ]

    assert Catalog.validate(m) == :ok
    assert Catalog.import_function("assets", "assets_opening_line") == :ok
  end

  describe "create, re-import, change" do
    test "G6-2: four rows (fixed, low-value split over two placements, intangible) create four lines",
         ctx do
      assert outcomes(imp(ctx, placements(ctx.im))) == List.duplicate("created", 4)

      d = doc(ctx)
      assert length(d["lines"]) == 5
      assert d["state"] == "draft"
      assert Enum.map(pair_lines(ctx), & &1["external_ref_id"]) == ~w(R1 R2 R3 R4)
      assert Enum.map(d["lines"], & &1["line_no"]) == [1, 2, 3, 4, 5]

      assert Enum.find(d["lines"], &(&1["external_ref_id"] == "R2"))["quantity"] == "5.000000000"
      assert Enum.find(d["lines"], &(&1["external_ref_id"] == "R4"))["location_id"] == nil

      content =
        Repo.one(
          from(v in DocumentVersion,
            where: v.document_id == ^d["id"],
            order_by: [desc: v.version_no],
            limit: 1,
            select: v.content
          ),
          prefix: ctx.schema
        )

      assert length(content["lines"]) == 5
      assert content["header"]["external_ref_id"] == "H1"

      check = D.request(:post, "/documents/#{d["id"]}/check", ctx.tok_a) |> D.status!(200)
      assert check["ok"] == true, inspect(check)
    end

    test "G6-3: the same file again is all unchanged and adds no draft version", ctx do
      rows = placements(ctx.im)
      assert outcomes(imp(ctx, rows)) == List.duplicate("created", 4)
      v = version_no(ctx)
      assert outcomes(imp(ctx, rows)) == List.duplicate("unchanged", 4)
      assert version_no(ctx) == v
    end

    test "G6-4: a changed quantity updates that line only and keeps its line_no", ctx do
      im = ctx.im
      assert outcomes(imp(ctx, placements(im))) == List.duplicate("created", 4)
      before = doc(ctx)["lines"]

      changed =
        List.replace_at(
          placements(im),
          1,
          row(im, "R2", %{"asset_id" => "cardL#{im.m.n}", "quantity" => "9"})
        )

      assert outcomes(imp(ctx, changed)) == ~w(unchanged updated unchanged unchanged)
      after_lines = doc(ctx)["lines"]
      old = Enum.find(before, &(&1["external_ref_id"] == "R2"))
      new = Enum.find(after_lines, &(&1["external_ref_id"] == "R2"))
      assert new["line_no"] == old["line_no"] and new["line_id"] == old["line_id"]
      assert new["quantity"] == "9.000000000"
      assert length(after_lines) == 5
    end
  end

  describe "references and document state" do
    test "G6-5: an unknown external id names its field", ctx do
      for field <- ~w(header_id asset_id location_id material_responsible_id actual_user_id) do
        conn = imp(ctx, [row(ctx.im, "U-#{field}", %{field => "nope"})])
        assert reasons(conn) == [%{"type" => "reference_not_found", "header" => field}], field
      end

      # a record id instead of an external id is just as unknown
      conn = imp(ctx, [row(ctx.im, "U-rec", %{"asset_id" => ctx.im.m.fixed})])
      assert outcomes(conn) == ["reference_not_found"]
      assert length(doc(ctx)["lines"]) == 1
    end

    test "G6-6: a retired card and an inactive employee are reference_inactive", ctx do
      m = ctx.im.m
      conn = imp(ctx, [row(ctx.im, "I-1", %{"asset_id" => "cardR#{m.n}"})])
      assert reasons(conn) == [%{"type" => "reference_inactive", "header" => "asset_id"}]

      emp =
        OrgFixture.create!(
          ctx.schema,
          "org_employee",
          OrgFixture.values(
            "org_employee",
            "EX#{m.n}",
            Map.merge(%{"org_unit_id" => m.unit, "active" => false}, ref("empx#{m.n}"))
          )
        )

      assert emp.record_id
      conn = imp(ctx, [row(ctx.im, "I-2", %{"material_responsible_id" => "empx#{m.n}"})])
      assert outcomes(conn) == ["reference_inactive"]
    end

    test "G6-7: an issued document is document_not_draft", ctx do
      D.issue_directly!(ctx, ctx.im.doc["id"])
      conn = imp(ctx, [row(ctx.im, "D-1")])
      assert outcomes(conn) == ["document_not_draft"]
      assert length(doc(ctx)["lines"]) == 1
    end

    test "G6-8: a row org unit other than the header's is org_unit_mismatch", ctx do
      other = unit!(ctx.schema, "other-unit")
      assert other.id
      conn = imp(ctx, [row(ctx.im, "O-1", %{"org_unit_id" => "other-unit"})])
      assert outcomes(conn) == ["org_unit_mismatch"]

      ok = imp(ctx, [row(ctx.im, "O-2", %{"org_unit_id" => ctx.im.m.unit_ext})])
      assert outcomes(ok) == ["created"]
    end
  end

  describe "quantity and the cap" do
    test "G6-9: non-number, zero and negative quantities; an unknown column", ctx do
      conn =
        imp(ctx, [
          row(ctx.im, "Q-1", %{"quantity" => "abc"}),
          row(ctx.im, "Q-2", %{"quantity" => "0"}),
          row(ctx.im, "Q-3", %{"quantity" => "-3"})
        ])

      assert outcomes(conn) == ~w(csv_invalid_decimal quantity_invalid quantity_invalid)
      assert length(doc(ctx)["lines"]) == 1

      bad = import_file([row(ctx.im, "Q-4") ++ ["9"]], ctx.tok_a, "", @cols ++ ["price"])
      assert bad.status in 400..499 and bad.resp_body =~ "not a field of the entity type"
      assert length(doc(ctx)["lines"]) == 1
    end

    test "G6-10/G6-12/G6-16: a 200-row file, dry and real; cap refusals cost no replay", ctx do
      im = ctx.im
      rows = for i <- 1..150, do: row(im, "B#{i}", %{"asset_id" => "cardL#{im.m.n}"})

      dry = imp(ctx, rows, "&dry_run=true")
      assert dry.status == 200, dry.resp_body
      dry_out = outcomes(dry)
      assert length(dry_out) == 150
      # the base line holds slot 1, so 99 imported lines fit
      assert Enum.count(dry_out, &(&1 == "created")) == 99
      assert Enum.count(dry_out, &(&1 == "lines_count")) == 51
      assert length(doc(ctx)["lines"]) == 1

      real = imp(ctx, rows)
      assert outcomes(real) == dry_out
      assert length(doc(ctx)["lines"]) == 100

      # a cap refusal followed by a valid update of an existing pair, in one dry run
      mixed = [
        row(im, "NEW", %{"asset_id" => "cardL#{im.m.n}"}),
        row(im, "B1", %{"asset_id" => "cardL#{im.m.n}", "quantity" => "7"})
      ]

      dry2 = imp(ctx, mixed, "&dry_run=true")
      assert outcomes(dry2) == ~w(lines_count updated)
      assert length(doc(ctx)["lines"]) == 100

      assert Enum.find(doc(ctx)["lines"], &(&1["external_ref_id"] == "B1"))["quantity"] ==
               "1.000000000"
    end
  end

  describe "drafts only, dry run, tenancy, guards" do
    test "G6-11: nothing is posted; a duplicate asset imports and the check reports it", ctx do
      im = ctx.im

      conn =
        imp(ctx, [
          row(im, "P-1", %{"asset_id" => "cardF#{im.m.n}"}),
          row(im, "P-2", %{"asset_id" => "cardF#{im.m.n}"})
        ])

      assert outcomes(conn) == ~w(created created)
      id = im.doc["id"]
      assert D.counts(ctx, id) == %{entries: %{}, marks: 0}
      assert doc(ctx)["state"] == "draft" and doc(ctx)["number"] == nil

      check = D.request(:post, "/documents/#{id}/check", ctx.tok_a) |> D.status!(200)
      assert check["ok"] == false
      reasons = check["lines"] |> Enum.flat_map(& &1["reasons"])
      assert "duplicate_asset" in reasons
    end

    test "G6-12: a dry run answers like the real import, writes nothing, a refused row does not stop the next",
         ctx do
      im = ctx.im

      rows = [
        row(im, "T-1"),
        row(im, "T-2", %{"asset_id" => "nope"}),
        row(im, "T-3", %{"asset_id" => "cardL#{im.m.n}"})
      ]

      before = D.written(ctx.schema)
      dry = imp(ctx, rows, "&dry_run=true")
      assert outcomes(dry) == ~w(created reference_not_found created)
      assert D.written(ctx.schema) == before
      assert length(doc(ctx)["lines"]) == 1

      assert outcomes(imp(ctx, rows)) == ~w(created reference_not_found created)
      assert length(doc(ctx)["lines"]) == 3
    end

    test "G6-13: another tenant naming this tenant's header or card gets reference_not_found",
         ctx do
      b_im = setup_b_masters(ctx)
      before = doc(ctx)

      conn = import_file([row(b_im, "X-1", %{"header_id" => "H1"})], ctx.tok_b)
      assert outcomes(conn) == ["reference_not_found"]

      # tenant B's own masters, but tenant A's card external id
      stolen = row(b_im, "X-2", %{"header_id" => "H1", "asset_id" => ctx.im.m.refs["asset_id"]})
      assert outcomes(import_file([stolen], ctx.tok_b)) == ["reference_not_found"]
      assert doc(ctx) == before
    end

    test "G6-14: a TASK_WORKER, a STOREKEEPER and a scoped admin are refused", ctx do
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-import")
      assert import_file([row(ctx.im, "W-1")], worker).status == 403
      keeper = S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-import")
      assert import_file([row(ctx.im, "W-2")], keeper).status == 403

      s = S.tenant!("ast-ds", ctx.names.s)
      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-importer")
      D.request(:get, "/documents", scoped)

      user =
        Repo.one!(from(u in User, where: u.username == "scoped-importer"), prefix: s.schema_name)

      _ =
        RSG.raw_delete_rows!(
          s.schema_name,
          RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      :ok = RSG.raw_user_row!(s.schema_name, user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))
      :ok = On.store_mode!(%{tenant_id: s.tenant_id, schema_name: s.schema_name}, :on)

      conn = import_file([row(ctx.im, "W-3")], scoped)
      assert conn.status in 400..499, conn.resp_body
      assert length(doc(ctx)["lines"]) == 1
    end

    test "G6-15: a PUT with the loaded pairs keeps them, so a re-import adds no line", ctx do
      assert outcomes(imp(ctx, placements(ctx.im))) == List.duplicate("created", 4)
      d = doc(ctx)

      keep =
        ~w(asset_id location_id material_responsible_id actual_user_id quantity external_ref_system external_ref_id)

      body =
        d
        |> Map.take(~w(org_unit_id note external_ref_system external_ref_id))
        |> Map.put(
          "lines",
          Enum.map(d["lines"], &(&1 |> Map.take(keep) |> Map.reject(fn {_, v} -> is_nil(v) end)))
        )

      put = D.request(:put, "/documents/#{d["id"]}", ctx.tok_a, body) |> D.status!(200)
      assert Enum.map(put["lines"], & &1["external_ref_id"]) == [nil | ~w(R1 R2 R3 R4)]
      assert put["external_ref_id"] == "H1"

      assert outcomes(imp(ctx, placements(ctx.im))) == List.duplicate("unchanged", 4)
      assert length(doc(ctx)["lines"]) == 5
    end

    test "G6-17: the function inside an outer transaction leaves it usable", ctx do
      id = ctx.im.doc["id"]

      line = %{
        "asset_id" => ctx.im.m.low,
        "material_responsible_id" => ctx.im.m.employee,
        "quantity" => "1.000000000",
        "external_ref_system" => @sys,
        "external_ref_id" => "U-1"
      }

      Repo.transaction(fn ->
        assert Documents.upsert_opening_line(
                 ctx.schema,
                 Ecto.UUID.generate(),
                 line,
                 Ecto.UUID.generate()
               ) ==
                 {:error, :not_found}

        assert {:ok, {_line_id, :created}} =
                 Documents.upsert_opening_line(ctx.schema, id, line, Ecto.UUID.generate())

        refute ManagedImport.poisoned?()
        Repo.rollback(:done)
      end)

      assert length(doc(ctx)["lines"]) == 1
      D.issue_directly!(ctx, id)

      Repo.transaction(fn ->
        assert Documents.upsert_opening_line(ctx.schema, id, line, Ecto.UUID.generate()) ==
                 {:error, :document_not_draft}

        assert Repo.query!("SELECT 1").rows == [[1]]
        refute ManagedImport.poisoned?()
      end)
    end
  end

  # Tenant B needs its own header "H1" lookalike-free masters; the rows only need B's refs.
  defp setup_b_masters(ctx) do
    m = masters!(ctx.b.schema_name)
    %{m: m, header_ref: "HB"}
  end
end
