defmodule Letflow.Entities.TypeExtensionsTest do
  @moduledoc """
  REQ-609 / GH #3417 (design IDs K, S, C, A): `TypeExtensions` is the only writer of the tenant
  `x_` extension layer; each D4 refusal writes neither a row nor an audit entry.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeExtension
  alias Letflow.Entities.TypeExtensions
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo

  @type_name "fxm_site"

  setup do
    base = Fx.tenant_case!("gh3417-ctx")
    :ok = Fx.install_managed_fixture!(base.schema)
    Fx.define_type!(base.schema, "tx_owned", %{append_only: false})

    %{
      base: base,
      schema: base.schema,
      actor: %{user_id: base.user.id, trace_id: "trace-3417"}
    }
  end

  defp create(ctx, name, spec \\ %{"type" => "string"}, type \\ @type_name),
    do:
      TypeExtensions.create_extension_audited(
        %{"entity_type" => type, "name" => name, "spec" => spec},
        ctx.actor,
        ctx.schema
      )

  defp rows(ctx), do: Repo.all(EntityTypeExtension, prefix: ctx.schema)
  defp audits(ctx), do: Repo.aggregate(Entry, :count, :id, prefix: ctx.schema)

  describe "K key rules" do
    test "K1 a bad key is refused with no row and no audit entry", ctx do
      before = audits(ctx)
      long = "x_" <> String.duplicate("a", 63)

      for name <- ["foo", "x_Bad", "x_a-b", ~s(x_"; drop), long, "", nil, 5] do
        assert {:error, {:extension_key_invalid, ^name}} = create(ctx, name)
      end

      assert rows(ctx) == []
      assert audits(ctx) == before
    end

    test "K2 valid keys are accepted", ctx do
      for name <- ["x_amount", "x_a1_b2", "x_" <> String.duplicate("a", 62)] do
        assert {:ok, %EntityTypeExtension{name: ^name, kind: "field", status: "active"}} =
                 create(ctx, name)
      end

      assert {:error, {:extension_key_invalid, _}} =
               create(ctx, "x_" <> String.duplicate("a", 63))
    end

    test "K3 a key that is a field of the module definition is reserved", ctx do
      Repo.update_all(
        from(e in EntityDefinition, where: e.name == @type_name),
        [
          set: [
            definition_json: %{
              "name" => @type_name,
              "fields" => [%{"name" => "x_reserved_probe", "type" => "string"}]
            }
          ]
        ],
        prefix: ctx.schema
      )

      before = audits(ctx)

      assert {:error, {:extension_key_reserved, "x_reserved_probe"}} =
               create(ctx, "x_reserved_probe")

      assert rows(ctx) == []
      assert audits(ctx) == before
    end

    test "K4 an active or a retired name is taken", ctx do
      assert {:ok, row} = create(ctx, "x_dup")
      assert {:error, :extension_key_taken} = create(ctx, "x_dup")
      assert {:ok, _} = TypeExtensions.retire_extension_audited(row.id, ctx.actor, ctx.schema)
      assert {:error, :extension_key_taken} = create(ctx, "x_dup")
      assert length(rows(ctx)) == 1
    end

    test "K5 check order: the type check runs before the key check, reserved before taken",
         ctx do
      assert {:error, :not_found} = create(ctx, "foo", %{"type" => "string"}, "nope_type")
      assert {:error, :not_found} = create(ctx, "x_ok", %{"type" => "string"}, "tx_owned")
      assert {:error, :not_found} = create(ctx, "x_ok", %{"type" => "string"}, "fxm_ledger")
      assert {:error, :not_found} = create(ctx, "x_ok", %{"type" => "string"}, 5)
      assert rows(ctx) == []
    end

    test "K6 a type restricted for the actor is not found; a grant restores it", ctx do
      Letflow.TestSupport.DefinitionsListFixture.restrict!(ctx.schema, @type_name)
      assert {:error, :not_found} = create(ctx, "x_ok")

      assert {:error, :not_found} =
               TypeExtensions.list_extensions(@type_name, ctx.actor.user_id, ctx.schema)

      Letflow.TestSupport.DefinitionsListFixture.grant!(ctx.schema, ctx.actor.user_id, @type_name)
      assert {:ok, _} = create(ctx, "x_ok")
    end

    test "K7 an unauthenticated actor is not found", ctx do
      assert {:error, :not_found} =
               TypeExtensions.create_extension_audited(
                 %{"entity_type" => @type_name, "name" => "x_a", "spec" => %{"type" => "string"}},
                 %{user_id: nil},
                 ctx.schema
               )
    end

    test "K8 a tenant_id in the attrs is ignored", ctx do
      assert {:ok, row} =
               TypeExtensions.create_extension_audited(
                 %{
                   "entity_type" => @type_name,
                   "name" => "x_t",
                   "spec" => %{"type" => "string"},
                   "tenant_id" => Ecto.UUID.generate()
                 },
                 ctx.actor,
                 ctx.schema
               )

      assert row.tenant_id == ctx.base.tenant.tenant_id
    end
  end

  describe "S spec" do
    test "S1 each of the six types is accepted", ctx do
      specs = [
        %{"type" => "string", "default" => "a"},
        %{"type" => "integer", "min" => 0, "max" => 9, "non_negative" => true},
        %{"type" => "boolean", "required" => true, "default" => false},
        %{"type" => "date", "default" => "2026-01-02"},
        %{"type" => "datetime", "default" => "2026-01-02T03:04:05Z"},
        %{"type" => "enum", "enum_values" => ["a", "b"], "default" => "a"},
        %{type: :string}
      ]

      for {spec, i} <- Enum.with_index(specs) do
        assert {:ok, %{spec: %{"type" => type}}} = create(ctx, "x_s#{i}", spec)
        assert is_binary(type)
      end
    end

    test "S2 every other spec is refused with no row", ctx do
      before = audits(ctx)

      bad = [
        %{"type" => "json"},
        %{"type" => "localized_text"},
        %{"type" => "decimal"},
        %{"type" => "mystery"},
        %{"type" => "string", "unique" => true},
        %{"type" => "string", "promoted" => true},
        %{"type" => "enum"},
        %{"type" => "enum", "enum_values" => []},
        %{"type" => "string", "enum_values" => ["a"]},
        %{"type" => "string", "required" => true},
        %{"type" => "integer", "default" => "x"},
        %{"type" => "date", "default" => "nope"},
        %{"type" => "enum", "enum_values" => ["a"], "default" => "z"},
        %{"type" => "integer", "min" => "1"},
        %{},
        "x",
        [],
        nil
      ]

      for spec <- bad do
        assert {:error, :invalid_extension_spec} = create(ctx, "x_bad", spec), inspect(spec)
      end

      assert rows(ctx) == []
      assert audits(ctx) == before
    end
  end

  describe "C cap" do
    test "C1/C2 50 succeed, the 51st is refused, retired rows count, other scopes are free",
         ctx do
      assert TypeExtensions.max_per_type() == 50
      Fx.define_type!(ctx.schema, "tx_other", %{append_only: false})

      for i <- 1..50 do
        assert {:ok, %{position: ^i}} = create(ctx, "x_f#{i}")
      end

      assert {:error, :extension_limit_reached} = create(ctx, "x_over")
      [first | _] = rows(ctx)
      assert {:ok, _} = TypeExtensions.retire_extension_audited(first.id, ctx.actor, ctx.schema)
      assert {:error, :extension_limit_reached} = create(ctx, "x_over")
      assert length(rows(ctx)) == 50

      # another managed type of the same tenant is not capped by this one
      assert {:ok, _} = create(ctx, "x_f1", %{"type" => "string"}, "fxm_unit")
    end
  end

  describe "R retire and list" do
    test "R1 retire keeps the row, a second retire writes no audit entry", ctx do
      {:ok, row} = create(ctx, "x_keep")

      assert {:ok, %{status: "retired", name: "x_keep"}} =
               TypeExtensions.retire_extension_audited(row.id, ctx.actor, ctx.schema)

      count = audits(ctx)

      assert {:ok, %{status: "retired"}} =
               TypeExtensions.retire_extension_audited(row.id, ctx.actor, ctx.schema)

      assert audits(ctx) == count
      assert [%{status: "retired"}] = rows(ctx)
    end

    test "R2 retire of an unknown or malformed id, or of a no longer extensible type, is not found",
         ctx do
      {:ok, row} = create(ctx, "x_gone")

      assert {:error, :not_found} =
               TypeExtensions.retire_extension_audited(
                 Ecto.UUID.generate(),
                 ctx.actor,
                 ctx.schema
               )

      assert {:error, :not_found} =
               TypeExtensions.retire_extension_audited("not-a-uuid", ctx.actor, ctx.schema)

      assert {:error, :not_found} =
               TypeExtensions.retire_extension_audited(nil, ctx.actor, ctx.schema)

      Letflow.TestSupport.DefinitionsListFixture.restrict!(ctx.schema, @type_name)

      assert {:error, :not_found} =
               TypeExtensions.retire_extension_audited(row.id, ctx.actor, ctx.schema)

      assert [%{status: "active"}] = rows(ctx)
    end

    test "R3 list is ordered by position and keeps retired rows", ctx do
      {:ok, a} = create(ctx, "x_b")
      {:ok, _} = create(ctx, "x_a")
      {:ok, _} = TypeExtensions.retire_extension_audited(a.id, ctx.actor, ctx.schema)

      assert {:ok, [first, second]} =
               TypeExtensions.list_extensions(@type_name, ctx.actor.user_id, ctx.schema)

      assert {first.name, first.position, first.status} == {"x_b", 1, "retired"}
      assert {second.name, second.position, second.status} == {"x_a", 2, "active"}
    end
  end

  describe "A audit" do
    test "A1 one audit entry per create and per retire", ctx do
      {:ok, row} = create(ctx, "x_aud", %{"type" => "integer"})
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_type_extension.create")
      assert entry.actor_id == ctx.actor.user_id
      assert entry.resource_id == row.id
      assert entry.before_state == nil

      assert entry.after_state |> Map.keys() |> Enum.sort() ==
               ~w(entity_type kind name position spec status)

      {:ok, _} = TypeExtensions.retire_extension_audited(row.id, ctx.actor, ctx.schema)
      assert [retire] = Fx.audit_rows(ctx.schema, "entity_type_extension.retire")
      assert retire.before_state["status"] == "active"
      assert retire.after_state["status"] == "retired"
    end

    test "A2 an audit failure stores no row and does not raise", ctx do
      Repo.query!(~s(DROP TABLE "#{ctx.schema}".audit_entries))
      assert {:error, {:transaction_failed, _}} = create(ctx, "x_boom")
      assert rows(ctx) == []
    end

    test "A3 an audit failure on retire leaves the row active", ctx do
      {:ok, row} = create(ctx, "x_boom2")
      Repo.query!(~s(DROP TABLE "#{ctx.schema}".audit_entries))

      assert {:error, {:transaction_failed, _}} =
               TypeExtensions.retire_extension_audited(row.id, ctx.actor, ctx.schema)

      assert [%{status: "active"}] = rows(ctx)
    end
  end
end
