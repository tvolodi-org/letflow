defmodule Letflow.Documents.PrintOverrideIssueTest do
  @moduledoc """
  REQ-624 / GH #3485 (decision 0068 D8 S3), issue half: resolution of the active print override at
  `Letflow.Documents.issue/2`, the pre-check before the number, and the pin on the version.
  Design: state/tasks/T-1281/design.md, tests R1a..R1d, D5, S3-invalid, S1, P1, N1, Q1.
  The render half is in `print_override_attach_test.exs`; the guard cases are in
  `triggers_test.exs`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Letflow.DocumentSqlFixture

  alias Letflow.Documents
  alias Letflow.Documents.PrintOverrides
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @bob "1e6a7a66-6b4d-4c3f-8b38-7b8e8b5b2d22"
  @sentinel "SENTINEL-LAYOUT-TEXT-77"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req624-is")

    {:ok, _} =
      Documents.register_type(
        schema,
        %{
          key: "invoice",
          owner_module: "procurement",
          numbering_scope: :year,
          number_prefix: "IN",
          number_pad: 4,
          legal_entity_required: false,
          declared_fields: %{"order" => ["number", "total"]}
        },
        %{actor_id: @actor}
      )

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    %{schema: schema, tenant_id: tenant_id, unit: unit}
  end

  defp layout(text) do
    %{
      "layout_schema_version" => 1,
      "blocks" => [
        %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"},
        %{"type" => "text", "text" => text},
        %{"type" => "field", "entity_type" => "order", "field_name" => "number"}
      ]
    }
  end

  defp active!(ctx, locale, text) do
    {:ok, row} =
      PrintOverrides.save_draft(
        ctx.schema,
        %{type_key: "invoice", locale: locale, layout: layout(text)},
        @alice
      )

    {:ok, row} = PrintOverrides.activate(ctx.schema, row.id, %{reason_code: "go_live"}, @bob)
    row
  end

  defp draft!(ctx, locale, text) do
    {:ok, row} =
      PrintOverrides.save_draft(
        ctx.schema,
        %{type_key: "invoice", locale: locale, layout: layout(text)},
        @alice
      )

    row
  end

  defp insert_invalid_active!(ctx) do
    exec!(
      """
      INSERT INTO #{table(ctx.schema, "document_print_overrides")}
        (id, tenant_id, type_key, locale, version_no, status, layout, layout_hash,
         layout_schema_version, created_by, activated_by, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1::uuid, 'invoice', 'default', 1, 'active', $2, $3, 1,
              $4::uuid, $5::uuid, now(), now())
      """,
      [
        ctx.tenant_id,
        %{
          "layout_schema_version" => 1,
          "blocks" => [%{"type" => "bogus", "text" => @sentinel}]
        },
        String.duplicate("c", 64),
        @alice,
        @bob
      ]
    )
  end

  defp create!(ctx, content \\ %{}) do
    content = Map.merge(%{"order" => %{"number" => "N-1", "total" => 5}}, content)

    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: "invoice", issuing_org_unit_id: ctx.unit, content: content},
        @actor
      )

    d.id
  end

  defp issue(ctx, id), do: Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})

  defp pin(ctx, id) do
    exec!(
      """
      SELECT print_override_id::text, print_override_version, print_override_layout_hash, template_version
      FROM #{table(ctx.schema, "document_versions")} WHERE document_id = $1::uuid
      """,
      [id]
    ).rows
    |> hd()
  end

  defp counter(ctx) do
    exec!("SELECT coalesce(sum(counter), 0)::int FROM #{table(ctx.schema, "document_sequences")}").rows
    |> hd()
    |> hd()
  end

  defp issued_audit(ctx) do
    exec!(
      "SELECT after_state FROM #{table(ctx.schema, "audit_entries")} WHERE action = 'document.issued' ORDER BY timestamp, id"
    ).rows
    |> List.flatten()
  end

  test "R1a the locale row wins over the default row", ctx do
    _default = active!(ctx, "default", "D")
    ru = active!(ctx, "ru", "R")
    id = create!(ctx, %{"locale" => "ru"})
    assert {:ok, _} = issue(ctx, id)
    assert [ru_id, 1, hash, "print-layout-v1"] = pin(ctx, id)
    assert ru_id == ru.id
    assert hash == ru.layout_hash
  end

  test "R1b only the default row is active: it is pinned", ctx do
    default = active!(ctx, "default", "D")
    id = create!(ctx, %{"locale" => "kk"})
    assert {:ok, _} = issue(ctx, id)
    assert [pinned, _, _, _] = pin(ctx, id)
    assert pinned == default.id
  end

  test "R1c a draft or retired row is never selected", ctx do
    _draft = draft!(ctx, "default", "D")
    retired = active!(ctx, "ru", "R")
    {:ok, _} = PrintOverrides.retire(ctx.schema, retired.id, %{reason_code: "stop"}, @alice)
    id = create!(ctx, %{"locale" => "ru"})
    assert {:ok, _} = issue(ctx, id)
    assert [nil, nil, nil, nil] = pin(ctx, id)
  end

  test "R1d a locale other than ru or kk, or none, is the default", ctx do
    default = active!(ctx, "default", "D")
    _ru = active!(ctx, "ru", "R")

    for content <- [%{"locale" => "en"}, %{}, %{"locale" => 5}, %{"locale" => nil}] do
      id = create!(ctx, content)
      assert {:ok, _} = issue(ctx, id)
      assert [pinned, _, _, _] = pin(ctx, id)
      assert pinned == default.id, inspect(content)
    end
  end

  test "D5 a restriction added after activation refuses before the number and writes nothing",
       ctx do
    active!(ctx, "default", "D")
    id = create!(ctx)
    before_counter = counter(ctx)
    before_audit = length(issued_audit(ctx))

    exec!(
      "INSERT INTO #{table(ctx.schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), 'order', 'total', now(), now())"
    )

    assert {:error, {:restricted_field, "order", "total"}} = issue(ctx, id)
    assert counter(ctx) == before_counter
    assert length(issued_audit(ctx)) == before_audit

    assert [["draft"]] =
             exec!(
               "SELECT status FROM #{table(ctx.schema, "document_versions")} WHERE document_id = $1::uuid",
               [id]
             ).rows

    exec!("DELETE FROM #{table(ctx.schema, "entity_field_restrictions")}")
    assert {:ok, _} = issue(ctx, id)
  end

  test "S3-invalid a stored layout that no longer validates refuses with no number spent", ctx do
    insert_invalid_active!(ctx)
    id = create!(ctx)
    before_counter = counter(ctx)
    before_audit = length(issued_audit(ctx))
    ref = :telemetry_test.attach_event_handlers(self(), [[:letflow, :documents, :refused]])

    log = capture_log(fn -> send(self(), {:res, issue(ctx, id)}) end)
    assert_received {:res, {:error, :print_override_invalid} = res}

    refute inspect(res) =~ @sentinel
    refute log =~ @sentinel
    assert counter(ctx) == before_counter
    assert length(issued_audit(ctx)) == before_audit

    assert [["draft"]] =
             exec!(
               "SELECT status FROM #{table(ctx.schema, "document_versions")} WHERE document_id = $1::uuid",
               [id]
             ).rows

    assert_received {[:letflow, :documents, :refused], ^ref, _, %{reason: _}}
  end

  test "S1 a layout that is not an object is refused the same way", ctx do
    exec!(
      """
      INSERT INTO #{table(ctx.schema, "document_print_overrides")}
        (id, tenant_id, type_key, locale, version_no, status, layout, layout_hash,
         layout_schema_version, created_by, activated_by, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1::uuid, 'invoice', 'default', 1, 'active', '"x"'::jsonb, $2, 1,
              $3::uuid, $4::uuid, now(), now())
      """,
      [ctx.tenant_id, String.duplicate("d", 64), @alice, @bob]
    )

    id = create!(ctx)
    assert {:error, :print_override_invalid} = issue(ctx, id)
  end

  test "P1 the pin and the audit entry carry the id, version and hash only", ctx do
    row = active!(ctx, "default", @sentinel)
    id = create!(ctx)
    assert {:ok, _} = issue(ctx, id)
    assert [pinned, 1, hash, "print-layout-v1"] = pin(ctx, id)
    assert pinned == row.id and hash == row.layout_hash

    assert [after_state] = issued_audit(ctx)
    assert after_state["print_override_id"] == row.id
    assert after_state["print_override_version"] == 1
    assert after_state["print_override_layout_hash"] == row.layout_hash
    refute inspect(after_state) =~ @sentinel
  end

  test "N1 with no override the columns are NULL and the audit entry has no new keys", ctx do
    id = create!(ctx)
    assert {:ok, _} = issue(ctx, id)
    assert [nil, nil, nil, nil] = pin(ctx, id)
    assert [after_state] = issued_audit(ctx)

    assert Enum.sort(Map.keys(after_state)) ==
             Enum.sort(~w(type_key version_no number period number_label content_hash))
  end

  test "Q1 every override query of documents.ex passes a prefix" do
    source = File.read!("lib/letflow/documents.ex")
    [_, body] = String.split(source, "defp find_override(", parts: 2)
    [query | _] = String.split(body, "defp override_locale", parts: 2)
    assert query =~ "Repo.one(prefix: prefix)"
  end
end
