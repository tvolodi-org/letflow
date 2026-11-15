defmodule Letflow.Documents.FormPrintCompanyTemplateTest do
  @moduledoc """
  T-1985 / decision 0089 D5 + D6, slice S3: `FormPrint.build/5` with `tenant:` prints the docx from the
  company's active template, fails closed, leaves the PDF alone. IDs P1-P10 of the design.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture
  import ExUnit.CaptureLog

  alias Letflow.Documents.FormPrint
  alias Letflow.Documents.FormTemplate
  alias Letflow.Documents.OfficialFormTemplates, as: OFT
  alias Letflow.FormTemplateDocx, as: D

  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"

  defmodule Unavailable do
    def scan(_, _), do: raise("scanner down")
  end

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("t1985-print")
    %{schema: schema, tenant_id: tenant_id}
  end

  defp data do
    %{
      "org_name" => "ТОО Ромашка",
      "sender" => "ТОО Ромашка",
      "org_bin" => "123456789012",
      "number" => "DOC-7",
      "date" => "05.11.2026",
      "responsible" => "Иванов И.",
      "released" => "Иванов И.",
      "lines" => [
        %{"no" => "1", "name" => "Болт", "nom" => "B-1", "unit" => "шт", "qty_issued" => "1.5"}
      ]
    }
  end

  defp bytes(marker),
    do: D.valid("z2") |> D.body("<w:p>" <> D.run(marker) <> "</w:p>") |> D.zip()

  defp active!(prefix, locale, marker, form \\ "z2") do
    pkg = if form == "z2", do: bytes(marker), else: D.valid(form) |> D.zip()

    {:ok, row} = OFT.upload(prefix, %{form: form, locale: locale, bytes: pkg}, @alice)
    {:ok, row} = OFT.activate(prefix, row.id, %{reason_code: "go_live"}, @alice)
    row
  end

  defp text(bin) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp insert_outdated!(ctx, locale, status) do
    {:ok, keys} = FormTemplate.Keys.for_form("z2")
    content = D.valid("z2") |> D.remove(hd(keys.data)) |> D.zip()
    id = Ecto.UUID.generate()

    exec!(
      """
      INSERT INTO #{table(ctx.schema, "official_form_templates")}
        (id, tenant_id, form_id, locale, version_no, status, content, byte_size, sha256, summary,
         created_by, activated_by, activated_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, 'z2', $3, 50, $4, $5, $6, repeat('a', 64), '{}'::jsonb, $7::uuid,
         $7::uuid, now(), now(), now())
      """,
      [id, ctx.tenant_id, locale, status, content, byte_size(content), @alice]
    )

    {id, hd(keys.data)}
  end

  defp standard(format \\ :docx), do: FormPrint.build("z2", data(), "ru", format)

  test "P1 no template: the platform docx, byte for byte", ctx do
    assert FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema) == standard()
  end

  test "P2 an active ru template is used and filled", ctx do
    row = active!(ctx.schema, "ru", "SKIN-T1985")
    {:ok, bin} = FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema)
    assert text(bin) =~ "SKIN-T1985"
    assert text(bin) =~ "Болт"
    assert {:ok, bin} == FormTemplate.fill("z2", row_content(ctx, row), data(), "ru")
    refute bin == elem(standard(), 1)
  end

  defp row_content(ctx, row) do
    {:ok, full} = OFT.get(ctx.schema, row.id)
    full.content
  end

  test "P3 the language row wins over default", ctx do
    active!(ctx.schema, "default", "MARK-AAA")
    active!(ctx.schema, "ru", "MARK-BBB")
    {:ok, ru} = FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema)
    {:ok, kk} = FormPrint.build("z2", data(), "kk", :docx, tenant: ctx.schema)
    assert text(ru) =~ "MARK-BBB"
    refute text(ru) =~ "MARK-AAA"
    assert text(kk) =~ "MARK-AAA"
  end

  test "P4 drafts and retired rows are ignored", ctx do
    {:ok, draft} =
      OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: bytes("DRAFT-X")}, @alice)

    assert FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema) == standard()

    {:ok, _} = OFT.activate(ctx.schema, draft.id, %{reason_code: "go_live"}, @alice)
    {:ok, _} = OFT.retire(ctx.schema, draft.id, %{reason_code: "old"}, @alice)
    assert FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema) == standard()
  end

  test "P5 S3-fail-closed: an outdated active template refuses, no fallback, no text in the log",
       ctx do
    {id, removed} = insert_outdated!(ctx, "ru", "active")

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :form_template_outdated} =
                 FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema)
      end)

    assert log =~ "codes=missing_data"
    assert log =~ "template_id=#{id}"
    refute log =~ removed
    refute log =~ "SKIN"
  end

  test "P6 the PDF never reads the table", ctx do
    active!(ctx.schema, "ru", "SKIN-T1985")
    assert FormPrint.build("z2", data(), "ru", :pdf, tenant: ctx.schema) == standard(:pdf)

    %{schema_name: other, tenant_id: tid} = provisioned_tenant!("t1985-pdf")
    insert_outdated!(%{schema: other, tenant_id: tid}, "ru", "active")
    assert FormPrint.build("z2", data(), "ru", :pdf, tenant: other) == standard(:pdf)
  end

  test "P7 a scanner outage is unavailable, not outdated", ctx do
    active!(ctx.schema, "ru", "SKIN-T1985")

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :form_template_unavailable} =
                 FormPrint.build("z2", data(), "ru", :docx,
                   tenant: ctx.schema,
                   scanner: Unavailable
                 )
      end)

    assert log =~ "codes=scan_unavailable"
  end

  test "P8 another tenant's template is not visible", ctx do
    %{schema_name: other} = provisioned_tenant!("t1985-other")
    active!(other, "ru", "SKIN-OTHER")
    assert FormPrint.build("z2", data(), "ru", :docx, tenant: ctx.schema) == standard()
    {:ok, bin} = FormPrint.build("z2", data(), "ru", :docx, tenant: other)
    assert text(bin) =~ "SKIN-OTHER"
  end

  test "P9 every router call site passes tenant:" do
    sources =
      for r <- ["stock", "assets"],
          do: File.read!("lib/letflow/modules/#{r}/router.ex")

    calls =
      Enum.flat_map(sources, fn src ->
        Regex.scan(~r/FormPrint\.build\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)/s, src)
        |> Enum.map(&hd/1)
      end)

    # stock: z3, z1/z2/z5/z6, inv10/inv18; assets: inv8, da1/da3/da4, da2
    assert length(calls) == 6
    assert Enum.all?(calls, &(&1 =~ "tenant:"))
  end

  test "P10 active_for_print/3 returns the print shape only", ctx do
    assert OFT.active_for_print(ctx.schema, "z2", "ru") == :none
    active!(ctx.schema, "ru", "SKIN-T1985")
    assert {:ok, row} = OFT.active_for_print(ctx.schema, "z2", "ru")
    assert Enum.sort(Map.keys(row)) == [:content, :id, :locale, :version_no]
    assert row.locale == "ru"
    assert OFT.active_for_print(ctx.schema, "z2", "kk") == :none
  end
end
