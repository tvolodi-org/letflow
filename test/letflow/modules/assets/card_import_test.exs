Code.require_file("../stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardImportTest do
  @moduledoc """
  GH #3899 / REQ-762: the asset card xlsx import through the full `Letflow.Router` with real OIDC bearer
  tokens on committed tenants (D-098 real HTTP path). The import creates no document, so there is no
  human task to claim: the end check is that an imported card is a normal card of the register routes.

  R1 registration; I1..I5 created/unchanged/updated/dry run/no posting; E1..E9, E11, E12 refusals;
  E13 `asset_currency_unknown` (REQ-826 C4); W1..W5 route guards and tenancy; C1 the 200-row cap;
  U1 direct calls; M1 reason rendering.
  E10 (`asset_kind_locked` end to end through the route) is test L10 of `card_locks_test.exs`; here only the mapping is tested.
  `async: false`, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity.User
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.Import
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ~w(inventory_number name kind org_unit_id acquisition_date currency acquisition_cost
             accumulated_depreciation book_value depreciation_as_of depreciation_method depreciation_rate valid_until
             external_ref_system external_ref_id)
  @path "/api/v1/entities/records/assets_card/import?upsert_by=external_ref"

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = tenant!("ast-ia", ctx.names.a)
    b = tenant!("ast-ib", ctx.names.b)

    ctx =
      Map.merge(ctx, %{
        a: a,
        b: b,
        tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
        tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
      })

    {:ok, Map.merge(ctx, %{unit_a: unit!(ctx.tok_a, "UA"), unit_b: unit!(ctx.tok_b, "UB")})}
  end

  defp tenant!(prefix, realm) do
    t = S.tenant!(prefix, realm, install: false)
    {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
    on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

    for m <- ["org", "catalog_items", "locations", "codes", "stock", "assets"] do
      {:ok, _} =
        Installs.install(m, Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test: REQ-762"
        )
    end

    t
  end

  defp call(conn, token) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp req(method, path, token, body \\ nil) do
    conn =
      if body,
        do: Plug.Test.conn(method, path, Jason.encode!(body)),
        else: Plug.Test.conn(method, path)

    conn |> Plug.Conn.put_req_header("content-type", "application/json") |> call(token)
  end

  defp ok!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp org!(tok, path, body),
    do:
      ok!(
        req(:post, "/api/v1/modules/org" <> path, tok, Map.put(body, "idempotency_key", key())),
        201
      )

  defp key, do: Ecto.UUID.generate()

  # A unit with external id `ext` under system "erp"; returns its record id.
  defp unit!(tok, ext) do
    n = System.unique_integer([:positive])

    le =
      org!(tok, "/legal-entities", %{
        "code" => "L#{n}",
        "name" => "L#{n}",
        "bin" => String.pad_leading("#{n}", 12, "1")
      })["record_id"]

    site =
      org!(tok, "/sites", %{"code" => "S#{n}", "name" => "S#{n}", "legal_entity_id" => le})[
        "record_id"
      ]

    org!(tok, "/units", %{
      "code" => "U#{n}",
      "name" => "U#{n}",
      "legal_entity_id" => le,
      "site_id" => site,
      "external_ref_system" => "erp",
      "external_ref_id" => ext
    })["record_id"]
  end

  # number, ext id, overrides by column name
  defp row(number, ext, over \\ %{}) do
    base = %{
      "inventory_number" => number,
      "name" => "Asset #{number}",
      "kind" => "fixed",
      "org_unit_id" => "UA",
      "acquisition_date" => "2024-01-15",
      "currency" => "KZT",
      "acquisition_cost" => "1000.50",
      "accumulated_depreciation" => "100.25",
      "book_value" => "900.25",
      "depreciation_as_of" => "2025-12-31",
      "depreciation_method" => "straight_line",
      "depreciation_rate" => "20.5",
      "external_ref_system" => "erp",
      "external_ref_id" => ext
    }

    base |> Map.merge(over) |> then(fn m -> Enum.map(@header, &Map.get(m, &1)) end)
  end

  defp import_to(tok, rows, query \\ "") do
    Plug.Test.conn(:post, @path <> query, XlsxFixture.build([[@header | rows]]))
    |> Plug.Conn.put_req_header("content-type", @xlsx)
    |> call(tok)
  end

  defp results(conn), do: Jason.decode!(conn.resp_body)["results"]
  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))

  defp counts(schema) do
    {Repo.aggregate(from(l in Latest, where: l.entity_type == "assets_card"), :count,
       prefix: schema
     ),
     Repo.aggregate(from(a in Entry, where: like(a.action, "assets_card.%")), :count,
       prefix: schema
     )}
  end

  defp card_by_ext(schema, ext) do
    {:ok, c} =
      Letflow.Modules.ReadApi.lookup_by_external_ref(schema, "assets_card", "erp", ext, [
        "assets_card"
      ])

    c
  end

  test "IM-2/IM-3: an unknown method is refused with its header; legacy text re-imports unchanged",
       ctx do
    schema = ctx.a.schema_name
    before = counts(schema)

    conn = import_to(ctx.tok_a, [row("M-1", "EM1", %{"depreciation_method" => "linear"})])
    assert conn.status == 200, conn.resp_body

    assert [%{"reason" => %{"type" => "field_invalid", "header" => "depreciation_method"}}] =
             results(conn)

    assert counts(schema) == before

    assert outcomes(import_to(ctx.tok_a, [row("M-2", "EM2")])) == ["created"]
    c = card_by_ext(schema, "EM2")
    {:ok, %Latest{field_values: fv}} = Latest.get(c["record_id"], "assets_card", schema)

    {:ok, _} =
      Letflow.Entities.Records.update_record(
        %{
          entity_type: "assets_card",
          record_id: c["record_id"],
          field_values: Map.put(fv, "depreciation_method", "straight line"),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        schema,
        Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Assets)
      )

    legacy = row("M-2", "EM2", %{"depreciation_method" => "straight line"})
    before = counts(schema)
    assert outcomes(import_to(ctx.tok_a, [legacy])) == ["unchanged"]
    assert counts(schema) == before
  end

  test "R1: the manifest registers the import function and validates" do
    m = Assets.manifest()
    assert %{entity_type: "assets_card", function: :import_card} in m.import_functions
    assert m.version == "0.24.0"
    assert Catalog.validate(m) == :ok
    assert Catalog.import_function("assets", "assets_card") == :ok
  end

  test "I-dep: changed rate updates, empty method and rate cells clear", ctx do
    assert outcomes(import_to(ctx.tok_a, [row("D-1", "ED1")])) == ["created"]

    assert outcomes(import_to(ctx.tok_a, [row("D-1", "ED1", %{"depreciation_rate" => "25"})])) ==
             ["updated"]

    assert Decimal.equal?(card_by_ext(ctx.a.schema_name, "ED1")["depreciation_rate"], "25")

    cleared = row("D-1", "ED1", %{"depreciation_rate" => nil, "depreciation_method" => nil})
    assert outcomes(import_to(ctx.tok_a, [cleared])) == ["updated"]
    c = card_by_ext(ctx.a.schema_name, "ED1")
    assert c["depreciation_rate"] in [nil, ""]
    assert c["depreciation_method"] in [nil, ""]
  end

  test "I1/I2/I3: created, unchanged, then updated with depreciation", ctx do
    rows = [row("A-1", "E1"), row("A-2", "E2", %{"kind" => "low_value"}), row("A-3", "E3")]
    conn = import_to(ctx.tok_a, rows)
    assert conn.status == 200, conn.resp_body
    assert outcomes(conn) == ["created", "created", "created"]

    c = card_by_ext(ctx.a.schema_name, "E1")
    assert c["org_unit_id"] == ctx.unit_a
    assert Decimal.equal?(c["acquisition_cost"], "1000.50")
    assert Decimal.equal?(c["accumulated_depreciation"], "100.25")
    assert Decimal.equal?(c["book_value"], "900.25")
    assert c["depreciation_as_of"] == "2025-12-31"
    assert c["depreciation_method"] == "straight_line"
    assert Decimal.equal?(c["depreciation_rate"], "20.5")
    assert c["active"] == true

    before = counts(ctx.a.schema_name)
    assert outcomes(import_to(ctx.tok_a, rows)) == ["unchanged", "unchanged", "unchanged"]
    assert counts(ctx.a.schema_name) == before

    changed = [
      row("A-1", "E1"),
      row("A-2", "E2", %{"kind" => "low_value"}),
      row("A-3", "E3", %{"accumulated_depreciation" => "200.00", "book_value" => "800.50"})
    ]

    assert outcomes(import_to(ctx.tok_a, changed)) == ["unchanged", "unchanged", "updated"]
    c3 = card_by_ext(ctx.a.schema_name, "E3")
    assert Decimal.equal?(c3["accumulated_depreciation"], "200.00")
    assert Decimal.equal?(c3["book_value"], "800.50")

    # an imported card is a normal card of the register routes
    patch =
      req(:patch, "/api/v1/modules/assets/cards/#{c3["record_id"]}", ctx.tok_a, %{
        "name" => "Renamed",
        "idempotency_key" => key()
      })

    assert ok!(patch, 200)["name"] == "Renamed"
  end

  test "I4: a dry run answers like the real run and writes nothing", ctx do
    rows = [row("D-1", "D1"), row("D-2", "D2")]
    before = counts(ctx.a.schema_name)
    dry = import_to(ctx.tok_a, rows, "&dry_run=true")
    assert dry.status == 200, dry.resp_body
    assert Jason.decode!(dry.resp_body)["dry_run"] == true
    assert outcomes(dry) == ["created", "created"]
    assert counts(ctx.a.schema_name) == before
    assert outcomes(import_to(ctx.tok_a, rows)) == ["created", "created"]
  end

  test "I5: the import posts nothing and creates no document", ctx do
    assert outcomes(import_to(ctx.tok_a, [row("P-1", "P1")])) == ["created"]

    types =
      Repo.all(from(l in Latest, distinct: true, select: l.entity_type),
        prefix: ctx.a.schema_name
      )

    assert "assets_card" in types
    assert Enum.filter(types, &String.starts_with?(&1, "assets_")) == ["assets_card"]
    refute Enum.any?(types, &String.contains?(&1, "document"))
  end

  test "E1..E9: every refusal is a constant reason, the good row is still created", ctx do
    retired = unit!(ctx.tok_a, "URET")

    ok!(
      req(:post, "/api/v1/modules/org/units/#{retired}/retire", ctx.tok_a, %{
        "idempotency_key" => key()
      }),
      200
    )

    assert outcomes(import_to(ctx.tok_a, [row("T-1", "T1")])) == ["created"]

    rows = [
      row("G-0", "G0"),
      row("G-1", "G1", %{"kind" => "vehicle"}),
      row("G-2", "G2", %{"valid_until" => "2030-01-01"}),
      row("G-3", "G3", %{"acquisition_cost" => "1e3"}),
      row("G-4", "G4", %{"currency" => "USD"}),
      row("G-5", "G5", %{"name" => nil}),
      row("T-1", "G6"),
      row("G-7", "G7", %{"org_unit_id" => "NOPE"}),
      row("G-8", "G8", %{"org_unit_id" => "URET"})
    ]

    conn = import_to(ctx.tok_a, rows)
    assert conn.status == 200, conn.resp_body

    assert outcomes(conn) == [
             "created",
             "asset_kind_invalid",
             "asset_valid_until_not_allowed",
             "csv_invalid_decimal",
             "asset_currency_mismatch",
             "asset_field_required",
             "asset_inventory_number_taken",
             "reference_not_found",
             "reference_inactive"
           ]

    r = results(conn)

    # T-C1b (router level): the column each refusal names, and the sheet line (header = line 1)
    for {index, column} <- [
          {1, "kind"},
          {2, "valid_until"},
          {3, "acquisition_cost"},
          {4, "currency"},
          {5, "name"},
          {6, "inventory_number"}
        ] do
      assert Enum.at(r, index)["reason"]["header"] == column, "row #{index}"
      assert Enum.at(r, index)["line"] == index + 2, "row #{index} line"
    end

    assert Enum.at(r, 7)["reason"]["header"] == "org_unit_id"
    assert Enum.at(r, 8)["reason"]["header"] == "org_unit_id"
    assert {2, _} = counts(ctx.a.schema_name)
  end

  test "T-A1: an atomic card file with a duplicate inventory number writes nothing", ctx do
    assert outcomes(import_to(ctx.tok_a, [row("T-1", "T1")])) == ["created"]
    before = counts(ctx.a.schema_name)
    file = [row("A-1", "A1"), row("T-1", "A2"), row("A-3", "A3")]

    conn = import_to(ctx.tok_a, file, "&atomic=true")
    assert conn.status == 200, conn.resp_body
    assert Jason.decode!(conn.resp_body)["applied"] == false
    assert outcomes(conn) == ["created", "asset_inventory_number_taken", "created"]
    assert %{"header" => "inventory_number"} = Enum.at(results(conn), 1)["reason"]
    assert counts(ctx.a.schema_name) == before

    fixed = [row("A-1", "A1"), row("A-2", "A2"), row("A-3", "A3")]
    ok = import_to(ctx.tok_a, fixed, "&atomic=true")
    assert Jason.decode!(ok.resp_body)["applied"] == true
    assert outcomes(ok) == ["created", "created", "created"]
    assert outcomes(import_to(ctx.tok_a, fixed, "&atomic=true")) == List.duplicate("unchanged", 3)
  end

  test "E11: re-import with optional cells removed clears them", ctx do
    full = row("K-1", "K1", %{"kind" => "intangible", "valid_until" => "2030-01-01"})
    assert outcomes(import_to(ctx.tok_a, [full])) == ["created"]

    bare =
      row("K-1", "K1", %{
        "kind" => "intangible",
        "valid_until" => nil,
        "currency" => nil,
        "acquisition_cost" => nil
      })

    assert outcomes(import_to(ctx.tok_a, [bare])) == ["updated"]
    c = card_by_ext(ctx.a.schema_name, "K1")
    refute Map.has_key?(c, "valid_until")
    refute Map.has_key?(c, "currency")
    refute Map.has_key?(c, "acquisition_cost")
  end

  test "E12: no error entry carries cell text", ctx do
    secret = "ZZsecretcell"

    rows = [
      row("S-1", "S1", %{"kind" => secret}),
      row("S-2", "S2", %{"org_unit_id" => secret}),
      row("S-3", "S3", %{"currency" => secret}),
      row("S-4", "S4", %{"valid_until" => secret})
    ]

    conn = import_to(ctx.tok_a, rows)
    refute conn.resp_body =~ secret
  end

  test "W1: an unknown header refuses the whole file", ctx do
    bytes = XlsxFixture.build([[@header ++ ["bogus"], row("X-1", "X1") ++ ["v"]]])
    before = counts(ctx.a.schema_name)

    conn =
      Plug.Test.conn(:post, @path, bytes)
      |> Plug.Conn.put_req_header("content-type", @xlsx)
      |> call(ctx.tok_a)

    assert conn.status in 400..499
    assert conn.resp_body =~ "not a field of the entity type"
    assert counts(ctx.a.schema_name) == before
  end

  test "W2: a mode other than upsert is refused", ctx do
    before = counts(ctx.a.schema_name)

    conn =
      Plug.Test.conn(
        :post,
        "/api/v1/entities/records/assets_card/import",
        XlsxFixture.build([[@header, row("M-1", "M1")]])
      )
      |> Plug.Conn.put_req_header("content-type", @xlsx)
      |> call(ctx.tok_a)

    assert conn.status == 422, conn.resp_body
    assert counts(ctx.a.schema_name) == before
  end

  test "W3: a scoped TENANT_ADMIN is refused, nothing written", ctx do
    s = tenant!("ast-is", ctx.names.s)
    scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-importer")
    req(:get, "/api/v1/modules/assets/none", scoped)

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
    before = counts(s.schema_name)

    conn = import_to(scoped, [row("W-1", "W1")])
    assert conn.status in 400..499, conn.resp_body
    assert counts(s.schema_name) == before
  end

  test "W4: cross-tenant ids are not found and never touch the other tenant", ctx do
    assert outcomes(import_to(ctx.tok_a, [row("X-1", "XT")])) == ["created"]
    a_before = card_by_ext(ctx.a.schema_name, "XT")

    # B has its own unit "UB"; A's unit external id "UA" is also resolvable only in A
    conn = import_to(ctx.tok_b, [row("X-9", "XB", %{"org_unit_id" => "UA"})])
    assert outcomes(conn) == ["reference_not_found"]

    only_b = import_to(ctx.tok_b, [row("X-2", "XT", %{"org_unit_id" => "UB"})])
    assert outcomes(only_b) == ["created"]
    assert card_by_ext(ctx.a.schema_name, "XT") == a_before
    assert card_by_ext(ctx.b.schema_name, "XT")["org_unit_id"] == ctx.unit_b
  end

  test "T-1866: the unit record id is accepted; an xlsx export loads back", ctx do
    # by record id (the form the export writes)
    conn = import_to(ctx.tok_a, [row("RT-1", "RT1", %{"org_unit_id" => ctx.unit_a})])
    assert outcomes(conn) == ["created"], conn.resp_body
    assert card_by_ext(ctx.a.schema_name, "RT1")["org_unit_id"] == ctx.unit_a

    # another tenant's unit record id is not found
    other = import_to(ctx.tok_a, [row("RT-2", "RT2", %{"org_unit_id" => ctx.unit_b})])
    assert outcomes(other) == ["reference_not_found"]

    # a non-unit record id (the card itself) is not found
    card_id = card_by_ext(ctx.a.schema_name, "RT1")["record_id"]
    wrong = import_to(ctx.tok_a, [row("RT-3", "RT3", %{"org_unit_id" => card_id})])
    assert outcomes(wrong) == ["reference_not_found"]

    # real export, edit one cell, import back
    exp =
      Plug.Test.conn(
        :post,
        "/api/v1/entities/records/assets_card/export?format=xlsx",
        Jason.encode!(%{"entity_type" => "assets_card"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call(ctx.tok_a)

    assert exp.status == 200, exp.resp_body
    {:ok, pkg} = XlsxReader.open(exp.resp_body, source: :binary)
    {:ok, [header | rows]} = XlsxReader.sheet(pkg, "records")
    idx = fn col -> Enum.find_index(header, &(&1 == col)) end
    assert [data] = Enum.filter(rows, &(Enum.at(&1, idx.("external_ref_id")) == "RT1"))
    data = List.replace_at(data, idx.("name"), "Renamed by file")
    # the test fixture writer takes text cells: render the reader's dates and numbers as text
    cell = fn
      %Date{} = d -> Date.to_iso8601(d)
      n when is_number(n) -> to_string(n)
      other -> other
    end

    only = Enum.map(@header, fn col -> cell.(Enum.at(data, idx.(col))) end)

    back = import_to(ctx.tok_a, [only])
    assert outcomes(back) == ["updated"], back.resp_body
    assert card_by_ext(ctx.a.schema_name, "RT1")["name"] == "Renamed by file"
  end

  test "W5: a TASK_WORKER is forbidden, nothing written", ctx do
    before = counts(ctx.a.schema_name)
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-import")
    assert import_to(worker, [row("Z-1", "Z1")]).status == 403
    assert counts(ctx.a.schema_name) == before
  end

  @tag timeout: 540_000
  test "C1: 201 rows are refused whole, 200 rows are accepted", ctx do
    rows = fn n -> for i <- 1..n, do: row("C-#{i}", "C#{i}") end
    before = counts(ctx.a.schema_name)
    assert import_to(ctx.tok_a, rows.(201)).status == 413
    assert counts(ctx.a.schema_name) == before

    conn = import_to(ctx.tok_a, rows.(200))
    assert conn.status == 200, conn.resp_body
    assert Enum.uniq(outcomes(conn)) == ["created"]
    assert length(results(conn)) == 200
  end

  test "U1/E10: direct calls for shapes the core catches first, and the mapping" do
    entry = fn fv ->
      %{
        entity_type: "assets_card",
        external_ref: %Letflow.Entities.ExternalRef{system: "erp", id: "U"},
        field_values: fv
      }
    end

    ctx = %{actor_id: Ecto.UUID.generate(), idempotency_key: "k", dry_run: false}

    assert {:error, {:field_not_allowed, "active"}} =
             Import.import_card("nope", entry.(%{"active" => "true"}), ctx)

    assert {:error, :field_not_allowed} =
             Import.import_card("nope", entry.(%{"bogus" => "x"}), ctx)

    assert {:error, {:asset_field_required, "inventory_number"}} =
             Import.import_card("nope", entry.(%{"inventory_number" => 5}), ctx)

    assert Import.refusal(:kind_locked) == :asset_kind_locked
    assert Import.refusal(:inventory_number_locked) == :asset_inventory_number_locked
    assert Import.refusal(:card_inactive) == :card_inactive
    assert Import.refusal(:org_unit_not_active) == {:reference_inactive, "org_unit_id"}

    assert Import.refusal({:record_payload_invalid, [%{field_path: "/inventory_number"}]}) ==
             :asset_inventory_number_taken

    assert Import.refusal({:record_payload_invalid, [%{field_path: "/book_value"}]}) ==
             {:field_invalid, "book_value"}

    assert Import.refusal({:record_payload_invalid, [%{field_path: "/external_ref_id"}]}) ==
             :asset_row_invalid

    assert Import.refusal(:audit_failed) == :audit_failed
  end

  test "M1: a retired card is refused with card_inactive", ctx do
    assert outcomes(import_to(ctx.tok_a, [row("R-1", "R1")])) == ["created"]
    id = card_by_ext(ctx.a.schema_name, "R1")["record_id"]

    ok!(
      req(:post, "/api/v1/modules/assets/cards/#{id}/retire", ctx.tok_a, %{
        "idempotency_key" => key()
      }),
      200
    )

    assert outcomes(import_to(ctx.tok_a, [row("R-1", "R1", %{"name" => "Other"})])) == [
             "card_inactive"
           ]
  end

  test "E13: currency_unknown refusal — REQ-826 C4: a code not in the platform list is refused with field currency; a lowercase kzt is accepted as KZT; the other rows in the file are still processed",
       ctx do
    rows = [
      row("E13-ok", "E13-0"),
      row("E13-xz", "E13-1", %{"currency" => "XYZ"}),
      row("E13-lc", "E13-2", %{"currency" => "kzt"})
    ]

    conn = import_to(ctx.tok_a, rows)
    assert conn.status == 200, conn.resp_body

    r = results(conn)
    # First row succeeds
    assert Enum.at(r, 0)["outcome"] == "created"
    # XYZ is not an ISO 4217 code
    assert Enum.at(r, 1)["reason"]["type"] == "asset_currency_unknown"
    assert Enum.at(r, 1)["reason"]["header"] == "currency"
    # "kzt" is upper-cased to "KZT" — matches the KZT tenant currency
    assert Enum.at(r, 2)["outcome"] == "created"
    assert card_by_ext(ctx.a.schema_name, "E13-2")["currency"] == "KZT"

    assert Import.refusal(:currency_unknown) == :asset_currency_unknown
  end
end
