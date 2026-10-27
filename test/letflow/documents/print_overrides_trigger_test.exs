defmodule Letflow.Documents.PrintOverridesTriggerTest do
  @moduledoc """
  REQ-579 / GH #3289, part 1: the `document_print_overrides` immutability trigger by direct SQL
  (S2-immutable-a..f). Design: state/tasks/T-0650/design.md.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @bob "1e6a7a66-6b4d-4c3f-8b38-7b8e8b5b2d22"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req579-trg")
    %{schema: schema, tenant_id: tenant_id}
  end

  defp t(ctx), do: table(ctx.schema, "document_print_overrides")

  defp insert!(ctx, opts \\ []) do
    id = Ecto.UUID.generate()
    status = Keyword.get(opts, :status, "draft")
    activated_by = if status == "draft", do: nil, else: @bob

    exec!(
      """
      INSERT INTO #{t(ctx)}
        (id, tenant_id, type_key, locale, version_no, status, layout, layout_hash,
         layout_schema_version, created_by, activated_by, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, '{"a": 1}'::jsonb, $7, 1, $8::uuid, $9::uuid, now(), now())
      """,
      [
        id,
        ctx.tenant_id,
        Keyword.get(opts, :type_key, "invoice"),
        Keyword.get(opts, :locale, "ru"),
        Keyword.get(opts, :version_no, 1),
        status,
        String.duplicate("a", 64),
        @alice,
        activated_by
      ]
    )

    id
  end

  defp upd(ctx, id, set), do: attempt("UPDATE #{t(ctx)} SET #{set} WHERE id = $1::uuid", [id])

  defp refused?({:refused, e}), do: e.postgres.code == :restrict_violation
  defp refused?(_), do: false

  @cols [
    "layout = '{\"b\": 2}'::jsonb",
    "layout_hash = '#{String.duplicate("b", 64)}'",
    "type_key = 'other'",
    "locale = 'kk'",
    "version_no = 9",
    "created_by = '#{@bob}'::uuid"
  ]

  test "S2-immutable-a: an active row's immutable columns cannot change", ctx do
    id = insert!(ctx, status: "active")
    for set <- @cols, do: assert(refused?(upd(ctx, id, set)), set)
    assert refused?(upd(ctx, id, "status = 'active'"))
  end

  test "S2-immutable-b: a retired row cannot change at all", ctx do
    id = insert!(ctx, status: "retired")

    for set <- @cols ++ ["reason_code = 'x'", "status = 'active'"] do
      assert refused?(upd(ctx, id, set)), set
    end
  end

  test "S2-immutable-c: active -> retired succeeds; layout in the same update does not", ctx do
    id = insert!(ctx, status: "active")
    assert refused?(upd(ctx, id, "status = 'retired', layout = '{}'::jsonb"))

    assert :accepted =
             upd(
               ctx,
               id,
               "status = 'retired', retired_at = now(), reason_code = 'x', updated_at = now()"
             )
  end

  test "S2-immutable-d: a draft layout may change, its version_no may not", ctx do
    id = insert!(ctx)
    assert :accepted = upd(ctx, id, "layout = '{\"b\": 2}'::jsonb")
    assert refused?(upd(ctx, id, "version_no = 9"))
    assert refused?(upd(ctx, id, "status = 'retired'"))
  end

  test "S2-immutable-e: DELETE and TRUNCATE are refused for every status", ctx do
    for {status, v} <- [{"draft", 1}, {"active", 2}, {"retired", 3}] do
      id = insert!(ctx, status: status, version_no: v)

      assert refused?(attempt("DELETE FROM #{t(ctx)} WHERE id = $1::uuid", [id]))
    end

    assert refused?(attempt("TRUNCATE #{t(ctx)}"))
  end

  test "S2-immutable-f: one active row per (type_key, locale)", ctx do
    insert!(ctx, status: "active")

    assert {:refused, e} = attempt_active(ctx, "invoice", "ru", 2)
    assert e.postgres.constraint == "document_print_overrides_one_active_index"
    assert :accepted = attempt_active(ctx, "invoice", "kk", 1)
    assert :accepted = attempt_active(ctx, "other", "ru", 1)
  end

  defp attempt_active(ctx, type_key, locale, version_no) do
    attempt(
      """
      INSERT INTO #{t(ctx)}
        (id, tenant_id, type_key, locale, version_no, status, layout, layout_hash,
         layout_schema_version, created_by, activated_by, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1::uuid, $2, $3, $4, 'active', '{}'::jsonb, $5, 1, $6::uuid, $7::uuid, now(), now())
      """,
      [ctx.tenant_id, type_key, locale, version_no, String.duplicate("a", 64), @alice, @bob]
    )
  end
end
