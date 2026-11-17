Code.require_file("opening_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.QoimeksFilesTest do
  @moduledoc """
  T-1616 (B4#11): the files written by `scripts/pilot/qoimeks_convert.py` go through the REAL import routes
  (`POST /api/v1/entities/records/<type>/import?upsert_by=external_ref`) and the real `POST /documents` route of a
  committed tenant with the `stock` module installed. This is the answer to "does stock accept the same files":
  locations, uoms and items are core masters, the lines file is the stock opening import.

  ST-1 whole procedure incl. the header bootstrap (also 100 and 101 lines); ST-2 repeatable (headers reused);
  ST-3 masters import into a tenant without stock; ST-G3 loads the usual place; ST-G12 loads and resolves item and
  place codes; ST-5 colon-bearing keys stay distinct; ST-4 another tenant's token writes nothing. `async: false` (Sandbox `:auto`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Entities.Record.Latest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Codes
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @script "scripts/pilot/qoimeks_convert.py"
  @fixture "test/fixtures/qoimeks_rehearsal"
  @sys "qoimeks-rehearsal"

  setup do
    ctx = P.setup!([:a, :b])
    dir = Path.join(System.tmp_dir!(), "qft_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = ctx |> Map.put(:dir, dir) |> Map.merge(tenant_masters!(ctx.schema))
    Map.put(ctx, :base, snapshot(ctx.schema))
  end

  # The tenant of the shared stock fixture already holds some masters: the converter's counts are compared as
  # increments over this baseline (the real rehearsal tenant is empty, and qoimeks_compare.sh compares absolutes).
  defp snapshot(schema) do
    types = ~w(location_node catalog_uom catalog_item code_tag code_assignment stock_opening_line)

    Map.new(types, &{&1, count(schema, &1)})
    |> Map.put("items_with_default_location", with_place(schema))
    |> Map.put(
      "documents",
      Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: schema)
    )
  end

  defp with_place(schema),
    do:
      Repo.aggregate(
        from(r in Latest,
          where:
            r.entity_type == "catalog_item" and not r.deleted and
              fragment("coalesce(?->>'default_location_id', '') <> ''", r.field_values)
        ),
        :count,
        prefix: schema
      )

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # The org unit "U1" and the responsible employee "E1" the converter is told about (step 4 of the plan creates
  # them in the real tenant); both with an external id under the run's system.
  defp tenant_masters!(schema) do
    n = System.unique_integer([:positive])
    ref = fn id -> %{"external_ref_system" => @sys, "external_ref_id" => id} end

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
          ref.("U1")
        ),
        opts()
      )

    emp =
      OrgFixture.create!(
        schema,
        "org_employee",
        OrgFixture.values(
          "org_employee",
          "E#{n}",
          Map.merge(%{"org_unit_id" => unit["record_id"]}, ref.("E1"))
        )
      )

    %{unit_id: unit["record_id"], employee_id: emp.record_id}
  end

  defp py(args) do
    {out, code} = System.cmd("python3", ["-I", @script | args], stderr_to_stdout: true)
    assert code in [0, 3], out
    out
  end

  defp convert!(ctx, indir, name) do
    out = Path.join(ctx.dir, name)

    py(
      ["convert", "--in", indir, "--out", out, "--system", @sys, "--org-unit-ext", "U1"] ++
        ["--responsible-ext", "E1", "--received-on", O.back(100), "--allow-drops"]
    )

    out
  end

  defp manifest(out), do: out |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp upload(ctx, type, path, query \\ "?atomic=true", token \\ nil) do
    Plug.Test.conn(
      :post,
      "/api/v1/entities/records/#{type}/import?upsert_by=external_ref" <>
        String.replace_prefix(query, "?", "&"),
      File.read!(path)
    )
    |> put_req_header("content-type", @xlsx)
    |> put_req_header("authorization", "Bearer " <> (token || ctx.tok_a))
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp upload_ok!(ctx, type, path, out_dir) do
    conn = upload(ctx, type, path)
    assert conn.status == 200, conn.resp_body
    # the saved response, as the runbook tells the operator to keep it
    File.write!(Path.join(out_dir, Path.rootname(Path.basename(path)) <> ".json"), conn.resp_body)
    Jason.decode!(conn.resp_body)["results"]
  end

  defp count(schema, type),
    do:
      Repo.aggregate(from(r in Latest, where: r.entity_type == ^type and not r.deleted), :count,
        prefix: schema
      )

  # Runs steps 1-4 of the runbook's upload procedure; returns the outcomes of the lines files in order.
  defp rehearse!(ctx, out, on_upload \\ fn _, _ -> :ok end) do
    resp = Path.join(ctx.dir, "resp_" <> Path.basename(out))
    File.mkdir_p!(resp)
    m = manifest(out)

    for %{"file" => f, "entity_type" => t} <- m["files"], t != "stock_opening_line" do
      results = upload_ok!(ctx, t, Path.join(out, f), resp)

      assert Enum.all?(results, &(&1["outcome"] in ["created", "unchanged", "updated"])),
             inspect(results)

      on_upload.(f, results)
    end

    py([
      "headers",
      "--out",
      out,
      "--responses",
      resp,
      "--org-unit-id",
      ctx.unit_id,
      "--responsible-id",
      ctx.employee_id
    ])

    for %{"id" => hid} <- m["headers"] do
      body = out |> Path.join("headers/#{hid}.json") |> File.read!() |> Jason.decode!()
      assert length(body["lines"]) == 1
      O.save!(ctx, body)
    end

    for %{"file" => f} <- m["files"], String.starts_with?(f, "04-") do
      dry = upload(ctx, "stock_opening_line", Path.join(out, f), "?dry_run=true")
      assert dry.status == 200, dry.resp_body
      Enum.map(upload_ok!(ctx, "stock_opening_line", Path.join(out, f), resp), & &1["outcome"])
    end
  end

  defp expected(out) do
    out
    |> Path.join("expected_counts.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn l ->
      [k, v] = String.split(l, " ")
      {k, String.to_integer(v)}
    end)
  end

  defp assert_counts(ctx, out) do
    now = snapshot(ctx.schema)

    for {key, n} <- expected(out) do
      type = String.replace_prefix(key, "records.", "")

      assert now[type] - ctx.base[type] == n,
             "#{type}: expected +#{n}, got +#{now[type] - ctx.base[type]}"
    end
  end

  defp big_input(ctx, name, balances) do
    dir = Path.join(ctx.dir, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "locations.csv"), "loc_code,loc_name,loc_parent\nL1,Sample L1,\n")

    File.write!(
      Path.join(dir, "items.csv"),
      "sku,sku_name,unit\n" <> Enum.map_join(1..balances, "", &"S#{&1},Sample #{&1},pcs\n")
    )

    File.write!(
      Path.join(dir, "balances.csv"),
      "sku,loc,qty\n" <> Enum.map_join(1..balances, "", &"S#{&1},L1,#{&1}\n")
    )

    dir
  end

  test "ST-1 the converted files are accepted; headers bootstrap with the first real balance",
       ctx do
    out = convert!(ctx, @fixture, "o1")
    Fx.set_negative_balance!(ctx.schema, "stock", true)
    assert [[first | rest], [negative]] = rehearse!(ctx, out)
    assert first in ["unchanged", "updated"]
    assert length(rest) == 5
    assert Enum.all?(rest, &(&1 == "created"))
    assert negative in ["unchanged", "updated"]
    assert_counts(ctx, out)
  end

  test "ST-1 a full chunk of 100 lines ends with exactly 100 lines", ctx do
    out100 = convert!(ctx, big_input(ctx, "in100", 100), "o100")
    [outcomes] = rehearse!(ctx, out100)
    assert length(outcomes) == 100
    assert hd(outcomes) in ["unchanged", "updated"]
    assert Enum.all?(tl(outcomes), &(&1 == "created"))
    assert_counts(ctx, out100)
  end

  test "ST-1 101 balances make two headers, none over 100 lines", ctx do
    out = convert!(ctx, big_input(ctx, "in101", 101), "o101")
    assert [first, second] = rehearse!(ctx, out)
    assert length(first) == 100
    assert length(second) == 1
    assert_counts(ctx, out)
  end

  test "ST-2 repeat: masters and lines unchanged, headers reused (a second header POST is 409)",
       ctx do
    out = convert!(ctx, @fixture, "o2")
    Fx.set_negative_balance!(ctx.schema, "stock", true)
    rehearse!(ctx, out)
    resp = Path.join(ctx.dir, "again")
    File.mkdir_p!(resp)
    m = manifest(out)

    # the documented repeat: steps 3 and 6 only; steps 4 and 5 (headers and switch) are skipped
    for %{"file" => f, "entity_type" => t} <- m["files"] do
      outcomes = upload_ok!(ctx, t, Path.join(out, f), resp) |> Enum.map(& &1["outcome"])
      assert Enum.all?(outcomes, &(&1 == "unchanged")), "#{f}: #{inspect(outcomes)}"
    end

    assert_counts(ctx, out)

    # and why step 4 must be skipped: the header pair is taken
    %{"id" => hid} = hd(m["headers"])
    body = out |> Path.join("headers/#{hid}.json") |> File.read!() |> Jason.decode!()
    conn = D.request(:post, "/documents", ctx.tok_a, body)
    assert conn.status == 409, conn.resp_body
    assert_counts(ctx, out)
  end

  test "ST-3 masters import into a tenant with the core modules and without stock", ctx do
    out = convert!(ctx, @fixture, "o3")
    resp = Path.join(ctx.dir, "r3")
    File.mkdir_p!(resp)

    tenant = S.tenant!("stk-pn", ctx.names.b, install: false)
    schema = tenant.schema_name
    {:ok, _} = Letflow.Entities.EventTypes.seed!(schema)
    on_exit(fn -> S.drop_pack_rows!(tenant.tenant_id) end)

    for id <- ["org", "catalog_items", "locations", "codes"] do
      {:ok, _} =
        Installs.install(id, Ecto.UUID.generate(), prefix: schema, rationale: "test: T-1616")
    end

    installed = Installs.list_installed(prefix: schema) |> Enum.map(& &1.module_id)
    assert "locations" in installed and "catalog_items" in installed
    refute "stock" in installed

    tok = S.token(ctx, :b, ["TENANT_ADMIN"])

    for %{"file" => f, "entity_type" => t} <- manifest(out)["files"], t != "stock_opening_line" do
      conn = upload(ctx, t, Path.join(out, f), "?atomic=true", tok)
      assert conn.status == 200, conn.resp_body
      results = Jason.decode!(conn.resp_body)["results"]
      assert results != []
      assert Enum.all?(results, &(&1["outcome"] == "created")), inspect(results)
    end

    assert count(schema, "location_node") > 0
    assert count(schema, "catalog_item") > 0
    assert count(schema, "catalog_uom") > 0
  end

  test "ST-G3 the usual place is loaded from the converted file and counted", ctx do
    dir = Path.join(ctx.dir, "in_g3")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "locations.csv"),
      "loc_code,loc_name,loc_parent\nL1,Sample L1,\nL2,Sample L2,\n"
    )

    File.write!(
      Path.join(dir, "items.csv"),
      "sku,sku_name,unit,home_loc,alt_loc\nA,Sample A,pcs,L1,L2\nB,Sample B,pcs,L2,\nC,Sample C,pcs,,\n"
    )

    File.write!(Path.join(dir, "balances.csv"), "sku,loc,qty\nA,L1,1\n")
    out = convert!(ctx, dir, "og3")
    assert expected(out)["items_with_default_location"] == 2
    rehearse!(ctx, out)
    assert_counts(ctx, out)
    assert with_place(ctx.schema) - ctx.base["items_with_default_location"] == 2
  end

  test "ST-G12 code files import after their masters, resolve their targets and repeat unchanged",
       ctx do
    dir = Path.join(ctx.dir, "in_g12")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "locations.csv"),
      "loc_code,loc_name,loc_parent\nL1,Sample L1,\n"
    )

    File.write!(
      Path.join(dir, "items.csv"),
      "sku,sku_name,unit,barcode\nA,Sample A,pcs,4870001112223\nB,Sample B,pcs,\n"
    )

    File.write!(Path.join(dir, "balances.csv"), "sku,loc,qty\nA,L1,1\n")

    File.write!(Path.join(dir, "codes.csv"), """
    object_type,object_code,code_type,code
    sku,A,ean13,4870001112223
    sku,B,qr,QR-B
    location,L1,code128,LOC-L1
    """)

    out = convert!(ctx, dir, "og12")

    code_files =
      for %{"file" => f, "entity_type" => t} <- manifest(out)["files"],
          t in ["code_tag", "code_assignment"],
          do: f

    assert code_files == ["06-codes-01.xlsx", "07-code-assignments-01.xlsx"]

    rehearse!(ctx, out, fn f, results ->
      if f in code_files, do: send(self(), {:g12_upload, f, results})
    end)

    for f <- code_files do
      assert_received {:g12_upload, ^f, results}
      assert Enum.all?(results, &(&1["outcome"] == "created")), inspect(results)
    end

    assert_counts(ctx, out)

    record_id = fn type, code ->
      Repo.one!(
        from(r in Latest,
          where:
            r.entity_type == ^type and not r.deleted and
              fragment("?->>'code' = ?", r.field_values, ^code),
          select: r.record_id
        ),
        prefix: ctx.schema
      )
    end

    item_a = record_id.("catalog_item", "A")
    item_b = record_id.("catalog_item", "B")
    place = record_id.("location_node", "L1")

    assert {:ok, %{"status" => "assigned", "kind" => "barcode", "target_id" => ^item_a}} =
             Codes.resolve(ctx.schema, "4870001112223")

    assert {:ok, %{"status" => "assigned", "kind" => "qr", "target_id" => ^item_b}} =
             Codes.resolve(ctx.schema, "QR-B")

    assert {:ok,
            %{
              "status" => "assigned",
              "kind" => "barcode",
              "target_type" => "location_node",
              "target_id" => ^place
            }} = Codes.resolve(ctx.schema, "LOC-L1")

    again = Path.join(ctx.dir, "again_g12")
    File.mkdir_p!(again)

    for %{"file" => f, "entity_type" => t} <- manifest(out)["files"], f in code_files do
      results = upload_ok!(ctx, t, Path.join(out, f), again)
      assert Enum.all?(results, &(&1["outcome"] == "unchanged")), inspect(results)
    end

    assert_counts(ctx, out)
  end

  test "ST-5 balance keys that differ only in where a colon sits both survive", ctx do
    dir = Path.join(ctx.dir, "in_colon")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "locations.csv"),
      "loc_code,loc_name,loc_parent\nB:C,Sample BC,\nC,Sample C,\nL1,Sample L1,\n"
    )

    File.write!(
      Path.join(dir, "items.csv"),
      "sku,sku_name,unit\nA,Sample A,pcs\nA:B,Sample AB,pcs\nZ,Sample Z,pcs\n"
    )

    File.write!(Path.join(dir, "balances.csv"), "sku,loc,qty\nZ,L1,1\nA,B:C,5\nA:B,C,7\n")

    out = convert!(ctx, dir, "ocolon")
    assert [[_first | rest]] = rehearse!(ctx, out)
    assert Enum.all?(rest, &(&1 == "created")), inspect(rest)
    assert_counts(ctx, out)
    assert expected(out)["records.stock_opening_line"] == 3
  end

  test "ST-4 another tenant's token writes nothing from the lines file", ctx do
    out = convert!(ctx, @fixture, "o4")
    Fx.set_negative_balance!(ctx.schema, "stock", true)
    rehearse!(ctx, out)
    %{b: b, tok_b: tok_b} = P.tenant_b!(ctx)
    before = {O.counts(ctx.schema), O.counts(b.schema_name)}

    conn =
      upload(
        ctx,
        "stock_opening_line",
        Path.join(out, "04-opening-lines-01.xlsx"),
        "?atomic=true",
        tok_b
      )

    refute conn.status == 500
    results = if conn.status == 200, do: Jason.decode!(conn.resp_body)["results"], else: []
    refute Enum.any?(results, &(&1["outcome"] in ["created", "updated"]))
    assert {O.counts(ctx.schema), O.counts(b.schema_name)} == before
  end
end
