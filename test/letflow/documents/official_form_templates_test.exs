defmodule Letflow.Documents.OfficialFormTemplatesTest do
  @moduledoc """
  T-1982 / decision 0089 D5, slice S4a: `Letflow.Documents.OfficialFormTemplates` (context level;
  the routes and the permission are S4b). IDs U1-U4, A1-A4, R1, B1-B2, G1, X1, D1-D2 of the design.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents.FormTemplate
  alias Letflow.Documents.OfficialFormTemplates, as: OFT
  alias Letflow.FormTemplateDocx, as: D

  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @bob "1e6a7a66-6b4d-4c3f-8b38-7b8e8b5b2d22"
  @sentinel "SENTINEL-1982-literal"
  @eicar "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
  @actions ~w(document.official_form_template_uploaded document.official_form_template_activated
              document.official_form_template_retired document.official_form_template_rolled_back)
  @audit_keys ~w(actor_id form locale reason_code rollback_of self_activated sha256 superseded_id
                 template_id version_no)

  defmodule InfectedScanner do
    def scan(_, _), do: {:ok, :infected, "x"}
  end

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("t1982-oft")
    %{schema: schema, tenant_id: tenant_id}
  end

  defp raw(extra_xml \\ ""), do: D.valid("z2") |> D.body(extra_xml) |> D.zip()

  defp upload!(ctx, locale \\ "ru", actor \\ @alice) do
    {:ok, row} = OFT.upload(ctx.schema, %{form: "z2", locale: locale, bytes: raw()}, actor)
    row
  end

  defp activate!(ctx, row, actor \\ @alice) do
    {:ok, row} = OFT.activate(ctx.schema, row.id, %{reason_code: "go_live"}, actor)
    row
  end

  defp audit_rows(ctx) do
    %{rows: rows} =
      exec!(
        "SELECT action, after_state::text FROM #{table(ctx.schema, "audit_entries")} WHERE action = ANY($1) ORDER BY timestamp, id",
        [@actions]
      )

    Enum.map(rows, fn [action, state] -> {action, Jason.decode!(state)} end)
  end

  defp count(ctx),
    do:
      exec!("SELECT count(*) FROM #{table(ctx.schema, "official_form_templates")}").rows
      |> hd()
      |> hd()

  # An outdated template: stored raw (the context refuses to store it), as a later release would leave it.
  defp insert_outdated!(ctx, status, activated? \\ false) do
    {:ok, keys} = FormTemplate.Keys.for_form("z2")
    bytes = D.valid("z2") |> D.remove(hd(keys.data)) |> D.zip()
    id = Ecto.UUID.generate()

    exec!(
      """
      INSERT INTO #{table(ctx.schema, "official_form_templates")}
        (id, tenant_id, form_id, locale, version_no, status, content, byte_size, sha256, summary,
         created_by, activated_by, activated_at, retired_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, 'z2', 'kk', 50, $3, $4, $5, repeat('a', 64), '{}'::jsonb, $6::uuid,
         CASE WHEN $7 THEN $6::uuid END, CASE WHEN $7 THEN now() END,
         CASE WHEN $3 = 'retired' THEN now() END, now(), now())
      """,
      [id, ctx.tenant_id, status, bytes, byte_size(bytes), @alice, activated?]
    )

    id
  end

  defp force_audit_fail(ctx) do
    exec!(
      "ALTER TABLE #{table(ctx.schema, "audit_entries")} ADD CONSTRAINT force_fail CHECK (false) NOT VALID"
    )
  end

  describe "upload" do
    test "U1 stores the checker's bytes as a draft, versions per pair", ctx do
      source = raw()
      {:ok, checked} = FormTemplate.check("z2", source)
      {:ok, row} = OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: source}, @alice)

      assert row.status == "draft"
      assert row.version_no == 1
      assert row.content == checked.bytes
      assert row.content != source
      assert row.sha256 == :crypto.hash(:sha256, row.content) |> Base.encode16(case: :lower)
      assert row.byte_size == byte_size(row.content)
      assert row.tenant_id == ctx.tenant_id
      assert row.created_by == @alice
      assert upload!(ctx).version_no == 2
      assert upload!(ctx, "kk").version_no == 1
      assert [{"document.official_form_template_uploaded", _} | _] = audit_rows(ctx)
    end

    test "U2 a refused upload writes no row and no audit", ctx do
      pkg = D.valid("z2") |> Map.put("word/vbaProject.bin", "x")

      assert {:error, {:refused, [%{} | _] = refusals}} =
               OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: D.zip(pkg)}, @alice)

      assert Enum.all?(refusals, &is_atom(&1.code))
      assert count(ctx) == 0
      assert audit_rows(ctx) == []
    end

    test "U3 input refusals write nothing", ctx do
      good = raw()

      for {attrs, actor, reason} <- [
            {%{form: "zz9", locale: "ru", bytes: good}, @alice, :unknown_form},
            {%{form: "z2", locale: "en", bytes: good}, @alice, :invalid_locale},
            {%{form: "z2", locale: "ru", bytes: nil}, @alice, :invalid_bytes},
            {%{form: "z2", locale: "ru", bytes: good}, "x", :invalid_actor}
          ] do
        assert {:error, {:unprocessable, ^reason}} = OFT.upload(ctx.schema, attrs, actor)
      end

      assert count(ctx) == 0
      assert audit_rows(ctx) == []
    end

    test "U4 a scanner verdict refuses and writes nothing", ctx do
      assert {:error, {:refused, [%{code: :infected} | _]}} =
               OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: raw()}, @alice,
                 scanner: InfectedScanner
               )

      eicar = D.valid("z2") |> Map.put("word/styles.xml", "<x><!--#{@eicar}--></x>") |> D.zip()

      assert {:error, {:refused, [%{code: :infected}]}} =
               OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: eicar}, @alice)

      assert count(ctx) == 0
    end
  end

  describe "activate" do
    test "A1 activates a draft and records self_activated", ctx do
      row = upload!(ctx)
      active = activate!(ctx, row)
      assert active.status == "active"
      assert active.activated_by == @alice
      assert active.reason_code == "go_live"
      assert %DateTime{} = active.activated_at

      [_, {"document.official_form_template_activated", after_state}] = audit_rows(ctx)
      assert after_state["self_activated"] == true
      assert after_state["superseded_id"] == nil

      other = upload!(ctx, "kk")
      activate!(ctx, other, @bob)
      assert [_, _, _, {_, second}] = audit_rows(ctx)
      assert second["self_activated"] == false
    end

    test "A2 activating v2 retires v1 as superseded", ctx do
      v1 = activate!(ctx, upload!(ctx))
      v2 = activate!(ctx, upload!(ctx))
      {:ok, old} = OFT.get(ctx.schema, v1.id)
      assert old.status == "retired"
      assert old.reason_code == "superseded"
      assert %DateTime{} = old.retired_at
      assert v2.version_no == 2

      assert [%{status: "active"}] =
               Enum.filter(
                 elem(OFT.list(ctx.schema, %{form: "z2", locale: "ru"}), 1),
                 &(&1.status == "active")
               )

      rows = audit_rows(ctx)
      {_, after_state} = List.last(rows)
      assert after_state["superseded_id"] == v1.id
      assert Enum.count(rows, fn {a, _} -> a =~ "retired" end) == 0
    end

    test "A3 reason and status refusals write no audit", ctx do
      draft = upload!(ctx)
      before = length(audit_rows(ctx))

      for bad <- [%{}, %{reason_code: "Bad Code"}, %{reason_code: nil}, nil] do
        assert {:error, {:unprocessable, :invalid_reason_code}} =
                 OFT.activate(ctx.schema, draft.id, bad, @alice)
      end

      active = activate!(ctx, draft)
      before = before + 1

      assert {:error, {:conflict, :not_a_draft}} =
               OFT.activate(ctx.schema, active.id, %{reason_code: "x"}, @alice)

      {:ok, _} = OFT.retire(ctx.schema, active.id, %{reason_code: "x"}, @alice)

      assert {:error, {:conflict, :not_a_draft}} =
               OFT.activate(ctx.schema, active.id, %{reason_code: "x"}, @alice)

      assert length(audit_rows(ctx)) == before + 1
    end

    test "A4 the re-check refuses an outdated draft and changes nothing", ctx do
      current = activate!(ctx, upload!(ctx, "kk"))
      id = insert_outdated!(ctx, "draft")
      before = audit_rows(ctx)

      assert {:error, {:refused, refusals}} =
               OFT.activate(ctx.schema, id, %{reason_code: "x"}, @bob)

      assert Enum.any?(refusals, &(&1.code == :missing_data))
      assert {:ok, %{status: "draft"}} = OFT.get(ctx.schema, id)
      assert {:ok, %{status: "active"}} = OFT.get(ctx.schema, current.id)
      assert audit_rows(ctx) == before
    end
  end

  describe "retire" do
    test "R1 retires a draft and an active row, once", ctx do
      draft = upload!(ctx)

      assert {:ok, %{status: "retired"}} =
               OFT.retire(ctx.schema, draft.id, %{reason_code: "drop"}, @alice)

      active = activate!(ctx, upload!(ctx))

      assert {:ok, %{status: "retired", retired_at: %DateTime{}, reason_code: "old"}} =
               OFT.retire(ctx.schema, active.id, %{reason_code: "old"}, @bob)

      assert {:error, {:conflict, :not_retirable}} =
               OFT.retire(ctx.schema, active.id, %{reason_code: "old"}, @bob)

      assert {:error, {:unprocessable, :invalid_reason_code}} =
               OFT.retire(ctx.schema, draft.id, %{}, @bob)

      retired = Enum.filter(audit_rows(ctx), fn {a, _} -> a =~ "_retired" end)
      assert length(retired) == 2
    end
  end

  describe "rollback" do
    test "B1 copies the bytes into a new active version", ctx do
      v1 = activate!(ctx, upload!(ctx))
      v2 = activate!(ctx, upload!(ctx))

      assert {:ok, v3} = OFT.rollback(ctx.schema, v1.id, %{reason_code: "undo"}, @bob)
      assert v3.status == "active"
      assert v3.version_no == 3
      assert v3.sha256 == v1.sha256
      assert v3.content == v1.content
      assert v3.rollback_of == v1.id
      assert v3.activated_by == @bob
      assert {:ok, %{status: "retired", reason_code: "superseded"}} = OFT.get(ctx.schema, v2.id)

      assert {:ok, %{status: "retired", reason_code: "superseded"} = old} =
               OFT.get(ctx.schema, v1.id)

      assert old.version_no == 1

      {action, after_state} = List.last(audit_rows(ctx))
      assert action == "document.official_form_template_rolled_back"
      assert after_state["rollback_of"] == v1.id
      assert after_state["superseded_id"] == v2.id
      assert after_state["template_id"] == v3.id

      assert audit_rows(ctx)
             |> Enum.count(fn {_, a} -> a["template_id"] == v3.id end) == 1
    end

    test "B2 refusals write nothing", ctx do
      draft = upload!(ctx)
      active = activate!(ctx, upload!(ctx))
      discarded = upload!(ctx)
      {:ok, _} = OFT.retire(ctx.schema, discarded.id, %{reason_code: "x"}, @alice)
      outdated = insert_outdated!(ctx, "retired", true)
      before = {count(ctx), audit_rows(ctx)}

      for id <- [draft.id, active.id, discarded.id] do
        assert {:error, {:conflict, :not_rollbackable}} =
                 OFT.rollback(ctx.schema, id, %{reason_code: "x"}, @alice)
      end

      assert {:error, {:refused, refusals}} =
               OFT.rollback(ctx.schema, outdated, %{reason_code: "x"}, @alice)

      assert Enum.any?(refusals, &(&1.code == :missing_data))
      assert {count(ctx), audit_rows(ctx)} == before
    end
  end

  describe "read" do
    test "G1 list is metadata only, ordered and filtered; get has content", ctx do
      a = upload!(ctx, "ru")
      upload!(ctx, "ru")
      upload!(ctx, "kk")

      assert {:ok, rows} = OFT.list(ctx.schema)
      assert Enum.map(rows, &{&1.locale, &1.version_no}) == [{"kk", 1}, {"ru", 2}, {"ru", 1}]
      refute Enum.any?(rows, &Map.has_key?(&1, :content))
      assert {:ok, [_, _]} = OFT.list(ctx.schema, %{locale: "ru"})
      assert {:ok, [_, _, _]} = OFT.list(ctx.schema, %{form: "z2"})
      assert {:ok, []} = OFT.list(ctx.schema, %{form: "z3"})
      assert {:ok, %{content: content}} = OFT.get(ctx.schema, a.id)
      assert byte_size(content) > 0
    end
  end

  describe "tenant isolation" do
    test "X1 another tenant's id is not found, identical to absent and malformed", ctx do
      %{schema_name: other} = provisioned_tenant!("t1982-oft-b")
      {:ok, theirs} = OFT.upload(other, %{form: "z2", locale: "ru", bytes: raw()}, @bob)
      absent = Ecto.UUID.generate()
      args = %{reason_code: "x"}

      for id <- [theirs.id, absent, "not-a-uuid", nil] do
        assert {:error, :not_found} = OFT.get(ctx.schema, id)
        assert {:error, :not_found} = OFT.activate(ctx.schema, id, args, @alice)
        assert {:error, :not_found} = OFT.retire(ctx.schema, id, args, @alice)
        assert {:error, :not_found} = OFT.rollback(ctx.schema, id, args, @alice)
      end

      assert {:ok, %{status: "draft"}} = OFT.get(other, theirs.id)
      assert {:ok, []} = OFT.list(ctx.schema)

      hostile = %{
        form: "z2",
        locale: "ru",
        bytes: raw(),
        tenant_id: Ecto.UUID.generate(),
        version_no: 99,
        status: "active",
        created_by: @bob
      }

      assert {:ok, row} = OFT.upload(ctx.schema, hostile, @alice)

      assert {row.tenant_id, row.version_no, row.status, row.created_by} ==
               {ctx.tenant_id, 1, "draft", @alice}
    end
  end

  describe "audit" do
    test "D1 the key set is fixed and no template content reaches an audit row", ctx do
      sentinel = "<w:p><w:r><w:t>#{@sentinel}</w:t></w:r></w:p>"
      source = raw(sentinel)
      {:ok, row} = OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: source}, @alice)
      activated = activate!(ctx, row)
      _v2 = activate!(ctx, upload!(ctx))
      {:ok, v3} = OFT.rollback(ctx.schema, activated.id, %{reason_code: "undo"}, @bob)
      {:ok, _} = OFT.retire(ctx.schema, v3.id, %{reason_code: "x"}, @bob)

      rows = audit_rows(ctx)
      assert rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == Enum.sort(@actions)

      for {_, after_state} <- rows do
        assert after_state |> Map.keys() |> Enum.sort() == @audit_keys
      end

      %{rows: texts} =
        exec!(
          "SELECT row_to_json(a)::text FROM #{table(ctx.schema, "audit_entries")} a WHERE action = ANY($1)",
          [@actions]
        )

      json = Enum.join(List.flatten(texts))
      raw_sha = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
      refute json =~ @sentinel
      refute json =~ raw_sha
      refute json =~ "Times New Roman"
      refute json =~ "summary"
    end

    test "D2 a failing audit write leaves nothing behind", ctx do
      draft = upload!(ctx)
      force_audit_fail(ctx)
      rows = count(ctx)

      assert_raise Ecto.ConstraintError, fn ->
        OFT.upload(ctx.schema, %{form: "z2", locale: "ru", bytes: raw()}, @alice)
      end

      assert_raise Ecto.ConstraintError, fn ->
        OFT.activate(ctx.schema, draft.id, %{reason_code: "x"}, @bob)
      end

      assert count(ctx) == rows
      assert {:ok, %{status: "draft"}} = OFT.get(ctx.schema, draft.id)
    end
  end
end
