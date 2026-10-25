defmodule Letflow.Documents.DocumentsRegisterTest do
  @moduledoc """
  REQ-542 / GH #3164 criteria 1, 2 and 4: `Letflow.Documents.register_type/3` (decision 0056 D1,
  D8, D9). Design: state/tasks/T-0474/design.md, tests T1..T12.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Documents.Retention
  alias Letflow.Documents.TestResolvers

  @actor "99999999-9999-4999-8999-999999999999"
  @ctx %{actor_id: @actor}

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req542-reg")
    %{schema: schema, tenant_id: tenant_id}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: "purchase_request",
        owner_module: "procurement",
        numbering_scope: :year,
        number_prefix: "PR",
        number_pad: 4,
        legal_entity_required: false,
        declared_fields: %{"purchase_request" => ["amount", "title"]}
      },
      overrides
    )
  end

  defp type_audit(schema) do
    %{rows: rows} =
      exec!(
        "SELECT resource_id, before_state, after_state FROM #{table(schema, "audit_entries")} WHERE action = 'document.type_registered' ORDER BY timestamp, id"
      )

    rows
  end

  defp type_count(schema),
    do: exec!("SELECT count(*) FROM #{table(schema, "document_types")}").rows |> hd() |> hd()

  defp restrict!(schema, type, field) do
    exec!(
      "INSERT INTO #{table(schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, now(), now())",
      [type, field]
    )
  end

  test "T1: stores the type and one type_registered entry; a repeat writes nothing", %{schema: s} do
    assert {:ok, type} = Documents.register_type(s, attrs(), @ctx)
    assert type.key == "purchase_request"
    assert type.owner_module == "procurement"
    assert type.declared_fields == %{"purchase_request" => ["amount", "title"]}
    assert type.restricted_fields_allowed == false
    assert [["purchase_request", nil, after_state]] = type_audit(s)
    assert after_state["declared_field_count"] == 2

    assert {:ok, _same} = Documents.register_type(s, attrs(), @ctx)
    assert length(type_audit(s)) == 1
    assert {:ok, :valid} = Audit.verify_chain(s)
  end

  describe "frozen types" do
    setup %{schema: s, tenant_id: t} do
      {:ok, _} = Documents.register_type(s, attrs(), @ctx)
      insert_document!(s, t, "purchase_request")
      :ok
    end

    test "T2: a changed frozen column is refused, row and audit unchanged", %{schema: s} do
      assert {:error, :document_type_frozen} =
               Documents.register_type(s, attrs(%{numbering_scope: :none}), @ctx)

      assert exec!("SELECT numbering_scope FROM #{table(s, "document_types")}").rows == [["year"]]
      assert length(type_audit(s)) == 1
    end

    test "T3: the retention columns stay changeable on the same type", %{schema: s} do
      policy = %{retention_period_days: 30, retention_from: "issued", retention_action: "purge"}

      assert {:ok, %{changed: true}} =
               Retention.change_policy(s, "purchase_request", policy, @actor, "audit_cycle")

      assert {:error, :document_type_frozen} =
               Documents.register_type(s, attrs(%{number_pad: 6}), @ctx)
    end

    test "T11b: a changed sensitivity list is a difference and is refused", %{schema: s} do
      free = attrs(%{declared_fields: %{"_free" => ["note"]}, sensitivity: %{"note" => :public}})
      assert {:error, :document_type_frozen} = Documents.register_type(s, free, @ctx)
    end
  end

  test "T4: without documents a changed registration updates and audits again", %{schema: s} do
    {:ok, _} = Documents.register_type(s, attrs(), @ctx)
    assert {:ok, type} = Documents.register_type(s, attrs(%{number_pad: 6}), @ctx)
    assert type.number_pad == 6
    assert [[_, nil, _], [_, before_state, after_state]] = type_audit(s)
    assert before_state["number_pad"] == 4
    assert after_state["number_pad"] == 6
    assert {:ok, :valid} = Audit.verify_chain(s)
  end

  describe "T5 restricted fields" do
    test "an entity field with a restriction is refused, nothing written", %{schema: s} do
      restrict!(s, "purchase_request", "amount")

      assert {:error, {:restricted_field, "purchase_request", "amount"}} =
               Documents.register_type(s, attrs(), @ctx)

      assert type_count(s) == 0
      assert type_audit(s) == []
    end

    test "a restriction on another entity type or field does not matter", %{schema: s} do
      restrict!(s, "employee", "amount")
      restrict!(s, "purchase_request", "salary")
      assert {:ok, _} = Documents.register_type(s, attrs(), @ctx)
    end

    test "free fields need a public mark", %{schema: s} do
      free = %{declared_fields: %{"_free" => ["note"]}}

      assert {:error, {:restricted_field, "_free", "note"}} =
               Documents.register_type(s, attrs(free), @ctx)

      assert {:error, {:restricted_field, "_free", "note"}} =
               Documents.register_type(
                 s,
                 attrs(Map.put(free, :sensitivity, %{"note" => :restricted})),
                 @ctx
               )

      assert type_count(s) == 0

      assert {:ok, type} =
               Documents.register_type(
                 s,
                 attrs(Map.put(free, :sensitivity, %{"note" => :public})),
                 @ctx
               )

      assert type.declared_fields == %{"_free" => %{"note" => "public"}}
    end
  end

  test "T6: the default resolver refuses a legal-entity type", %{schema: s} do
    assert {:error, :legal_entity_resolver_unavailable} =
             Documents.register_type(s, attrs(%{legal_entity_required: true}), @ctx)

    assert type_count(s) == 0
  end

  test "T9: a resolver that is declared allows a legal-entity type", %{schema: s} do
    Process.put(:letflow_document_org_resolver, TestResolvers.Entity)
    assert {:ok, type} = Documents.register_type(s, attrs(%{legal_entity_required: true}), @ctx)
    assert type.legal_entity_required
  end

  describe "T11 sensitivity is part of the stored fields" do
    defp free(fields),
      do:
        attrs(%{
          declared_fields: %{"_free" => fields},
          sensitivity: Map.new(fields, &{&1, :public})
        })

    test "a changed list updates an unfrozen type and audits it", %{schema: s} do
      {:ok, _} = Documents.register_type(s, free(["note"]), @ctx)
      assert {:ok, same} = Documents.register_type(s, free(["note"]), @ctx)
      assert same.declared_fields == %{"_free" => %{"note" => "public"}}
      assert length(type_audit(s)) == 1

      assert {:ok, type} = Documents.register_type(s, free(["note", "memo"]), @ctx)
      assert type.declared_fields == %{"_free" => %{"note" => "public", "memo" => "public"}}
      assert length(type_audit(s)) == 2
    end
  end

  test "T12: another module cannot take over a key", %{schema: s} do
    {:ok, _} = Documents.register_type(s, attrs(), @ctx)

    assert {:error, :type_owned_by_other_module} =
             Documents.register_type(s, attrs(%{owner_module: "intruder"}), @ctx)

    assert exec!("SELECT owner_module FROM #{table(s, "document_types")}").rows == [
             ["procurement"]
           ]

    assert length(type_audit(s)) == 1
  end

  test "shapes are refused before any write", %{schema: s} do
    for bad <- [
          %{key: "Bad Key"},
          %{numbering_scope: :month},
          %{number_pad: -1},
          %{declared_fields: ["x"]},
          %{declared_fields: %{"t" => "x"}},
          %{content_hash: "abc"}
        ] do
      assert {:error, {:unprocessable, _}} = Documents.register_type(s, attrs(bad), @ctx),
             inspect(bad)
    end

    assert {:error, {:unprocessable, :invalid_actor}} = Documents.register_type(s, attrs(), %{})
    assert {:error, :invalid_schema_name} = Documents.register_type("public", attrs(), @ctx)
    assert type_count(s) == 0
  end
end
