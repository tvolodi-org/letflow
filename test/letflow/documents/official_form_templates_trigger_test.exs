defmodule Letflow.Documents.OfficialFormTemplatesTriggerTest do
  @moduledoc """
  T-1982 / decision 0089 D5, S4a: the database guard of `official_form_templates` (IDs T1-T4).
  Raw SQL, so the context's own checks cannot hide a missing trigger or constraint.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("t1982-trg")
    %{schema: schema, tenant_id: tenant_id, t: table(schema, "official_form_templates")}
  end

  defp insert!(ctx, opts \\ []) do
    id = Ecto.UUID.generate()
    status = Keyword.get(opts, :status, "draft")
    version = Keyword.get(opts, :version, 1)
    form = Keyword.get(opts, :form, "z2")
    locale = Keyword.get(opts, :locale, "ru")
    sha = Keyword.get(opts, :sha, String.duplicate("a", 64))
    size = Keyword.get(opts, :size, 3)
    actor = if status == "draft" or Keyword.get(opts, :no_actor), do: nil, else: @alice

    exec!(
      """
      INSERT INTO #{ctx.t}
        (id, tenant_id, form_id, locale, version_no, status, content, byte_size, sha256, summary,
         created_by, activated_by, activated_at, retired_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, 'abc'::bytea, $7, $8, '{}'::jsonb, $9::uuid,
         $10::uuid, CASE WHEN $10::uuid IS NULL THEN NULL ELSE now() END,
         CASE WHEN $6 = 'retired' THEN now() END, now(), now())
      """,
      [id, ctx.tenant_id, form, locale, version, status, size, sha, @alice, actor]
    )

    id
  end

  defp refused(fun) do
    assert %Postgrex.Error{postgres: %{code: :restrict_violation}} = catch_error(fun.())
  end

  defp check_violation(fun) do
    assert %Postgrex.Error{postgres: %{code: code}} = catch_error(fun.())
    assert code in [:check_violation, :unique_violation]
  end

  test "T1 bytes, hash and summary never change", ctx do
    draft = insert!(ctx)
    active = insert!(ctx, status: "active", version: 2)

    for id <- [draft, active],
        set <- [
          "content = 'x'::bytea",
          "sha256 = repeat('b', 64)",
          "summary = '{\"a\":1}'::jsonb"
        ] do
      refused(fn -> exec!("UPDATE #{ctx.t} SET #{set} WHERE id = $1::uuid", [id]) end)
    end
  end

  test "T2 only draft->active, draft->retired and active->retired are allowed", ctx do
    active = insert!(ctx, status: "active")
    retired = insert!(ctx, status: "retired", version: 2, no_actor: true)
    draft = insert!(ctx, version: 3)

    refused(fn -> exec!("UPDATE #{ctx.t} SET status = 'draft' WHERE id = $1::uuid", [active]) end)

    refused(fn ->
      exec!("UPDATE #{ctx.t} SET status = 'active' WHERE id = $1::uuid", [retired])
    end)

    refused(fn ->
      exec!("UPDATE #{ctx.t} SET status = 'draft' WHERE id = $1::uuid", [retired])
    end)

    refused(fn ->
      exec!(
        "UPDATE #{ctx.t} SET status = 'retired', retired_at = now(), form_id = 'z3' WHERE id = $1::uuid",
        [draft]
      )
    end)

    refused(fn ->
      exec!(
        "UPDATE #{ctx.t} SET status = 'active', activated_by = $2::uuid, activated_at = now(), form_id = 'z3' WHERE id = $1::uuid",
        [draft, @alice]
      )
    end)

    exec!("UPDATE #{ctx.t} SET status = 'retired', retired_at = now() WHERE id = $1::uuid", [
      draft
    ])

    exec!("UPDATE #{ctx.t} SET status = 'retired', retired_at = now() WHERE id = $1::uuid", [
      active
    ])
  end

  test "T3 DELETE and TRUNCATE are refused", ctx do
    id = insert!(ctx)
    refused(fn -> exec!("DELETE FROM #{ctx.t} WHERE id = $1::uuid", [id]) end)
    refused(fn -> exec!("TRUNCATE #{ctx.t}") end)
  end

  test "T4 indexes and CHECK constraints", ctx do
    insert!(ctx, status: "active", version: 1)
    check_violation(fn -> insert!(ctx, status: "active", version: 2) end)
    check_violation(fn -> insert!(ctx, version: 1) end)
    check_violation(fn -> insert!(ctx, version: 5, size: 4) end)
    check_violation(fn -> insert!(ctx, version: 6, sha: "xyz") end)
    check_violation(fn -> insert!(ctx, version: 7, locale: "en") end)

    check_violation(fn ->
      insert!(ctx, version: 8, status: "active", locale: "kk", no_actor: true)
    end)

    check_violation(fn -> insert!(ctx, version: 9, form: "Z 2") end)
    assert insert!(ctx, version: 10, locale: "kk")
  end
end
