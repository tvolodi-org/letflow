defmodule Letflow.CompanyTemplateFixture do
  @moduledoc """
  T-1985: company official-form templates for router tests. `active!/4` goes through the context
  (upload and activate); `outdated!/4` stores, raw, an active row that misses one data name, as a
  later release would leave it (the context refuses to store it).
  """

  import Letflow.DocumentSqlFixture, only: [exec!: 2, table: 2]

  alias Letflow.Documents.FormTemplate
  alias Letflow.Documents.OfficialFormTemplates, as: OFT
  alias Letflow.FormTemplateDocx, as: D

  @actor "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @marker "SKIN-T1985"

  def marker, do: @marker

  @doc "A valid template of `form` with the marker text in its body, uploaded and activated."
  def active!(schema, form, locale) do
    bytes = D.valid(form) |> D.body("<w:p>" <> D.run(@marker) <> "</w:p>") |> D.zip()
    {:ok, row} = OFT.upload(schema, %{form: form, locale: locale, bytes: bytes}, @actor)
    {:ok, row} = OFT.activate(schema, row.id, %{reason_code: "go_live"}, @actor)
    row
  end

  @doc "An active row of `form`/`locale` whose bytes miss a data name. Returns the row id."
  def outdated!(schema, tenant_id, form, locale) do
    {:ok, keys} = FormTemplate.Keys.for_form(form)

    bytes =
      D.valid(form)
      |> D.body("<w:p>" <> D.run(@marker) <> "</w:p>")
      |> D.remove(hd(keys.data))
      |> D.zip()

    id = Ecto.UUID.generate()

    exec!(
      """
      INSERT INTO #{table(schema, "official_form_templates")}
        (id, tenant_id, form_id, locale, version_no, status, content, byte_size, sha256, summary,
         created_by, activated_by, activated_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, $4, 50, 'active', $5, $6, repeat('a', 64), '{}'::jsonb,
         $7::uuid, $7::uuid, now(), now(), now())
      """,
      [id, tenant_id, form, locale, bytes, byte_size(bytes), @actor]
    )

    id
  end
end
