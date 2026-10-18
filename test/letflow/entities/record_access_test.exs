defmodule Letflow.Entities.RecordAccessTest do
  @moduledoc """
  GH #2784 (design `lib/letflow/design/gh2784-write-routes-typeaccess.md` section 2, I1-I3, I5):
  `Letflow.Entities.RecordAccess.write/3` is one decision over four unconditional reads, with the
  precedence hidden > managed > open, and writes nothing.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.RecordAccess
  alias Letflow.EntityWritesFixture
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @gate_calls [
    {Letflow.Entities.ManagedTypes, :owner_of, 2},
    {Letflow.Entities.TypeAccess, :authorized?, 3},
    {Letflow.Entities.Definitions, :get_active_definition_by_name, 2},
    {Letflow.Entities.Query.FieldGrants, :load_restrictions, 3}
  ]

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2784-ra")
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2784-ra-#{Ecto.UUID.generate()}",
        display_name: "GH-2784 unit user",
        email: "gh2784-ra-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: "customer",
            display_name: "customer",
            fields: [
              %{name: "customer_name", type: :string, required: true},
              %{name: "credit_limit", type: :string}
            ]
          },
          created_by: user.id
        },
        tenant.schema_name
      )

    {:ok, _} = Definitions.activate_definition("customer", user.id, "gh2784", tenant.schema_name)
    %{schema: tenant.schema_name, user_id: user.id}
  end

  defp insert_type_restriction!(schema, type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp insert_field_restriction!(schema, type, field) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  # A separate tracer process collects the call order (a process never receives its own trace).
  defp traced_calls(fun) do
    for {m, _f, _a} <- @gate_calls, do: Code.ensure_loaded!(m)
    tracer = spawn_link(fn -> tracer_loop([]) end)
    for mfa <- @gate_calls, do: :erlang.trace_pattern(mfa, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      for mfa <- @gate_calls, do: :erlang.trace_pattern(mfa, false, [])
    end

    send(tracer, {:collect, self()})

    receive do
      {:calls, calls} -> calls
    after
      5_000 -> flunk("tracer did not answer")
    end
  end

  defp tracer_loop(acc) do
    receive do
      {:trace, _pid, :call, {m, f, args}} -> tracer_loop([{m, f, length(args)} | acc])
      {:collect, from} -> send(from, {:calls, Enum.reverse(acc)})
    end
  end

  defp seed_open_type!(ctx) do
    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: "open_type",
            display_name: "open_type",
            fields: [%{name: "n", type: :string}]
          },
          created_by: ctx.user_id
        },
        ctx.schema
      )

    {:ok, _} = Definitions.activate_definition("open_type", ctx.user_id, "gh2784", ctx.schema)
  end

  describe "write/3 decisions" do
    test "a failed read is :hidden (fail closed), whatever the type", ctx do
      assert RecordAccess.write(ctx.user_id, "customer", "no_such_schema") == :hidden
      assert RecordAccess.write(ctx.user_id, "org_unit", "no_such_schema") == :hidden
    end

    test "I3: an unrestricted caller on an unmanaged type is open with an empty set", ctx do
      assert RecordAccess.write(ctx.user_id, "customer", ctx.schema) == {:open, MapSet.new()}
    end

    test "an open decision carries the caller's restricted fields", ctx do
      insert_field_restriction!(ctx.schema, "customer", "credit_limit")

      assert RecordAccess.write(ctx.user_id, "customer", ctx.schema) ==
               {:open, MapSet.new(["credit_limit"])}
    end

    test "I2: a denied type and an absent type are the identical :hidden", ctx do
      insert_type_restriction!(ctx.schema, "customer")
      insert_field_restriction!(ctx.schema, "customer", "credit_limit")

      denied = RecordAccess.write(ctx.user_id, "customer", ctx.schema)
      absent = RecordAccess.write(ctx.user_id, "no_such_type", ctx.schema)
      assert denied == :hidden
      assert absent == :hidden
    end

    test "a visible managed type is :managed, a denied managed type is :hidden", ctx do
      EntityWritesFixture.install_managed_fixture!(ctx.schema)
      assert RecordAccess.write(ctx.user_id, "org_unit", ctx.schema) == :managed

      insert_type_restriction!(ctx.schema, "org_unit")
      assert RecordAccess.write(ctx.user_id, "org_unit", ctx.schema) == :hidden
    end

    test "I1: the four gate calls happen in order for open, denied, absent and managed", ctx do
      EntityWritesFixture.install_managed_fixture!(ctx.schema)
      insert_type_restriction!(ctx.schema, "customer")
      seed_open_type!(ctx)

      for type <- ["customer", "no_such_type", "org_unit", "open_type"] do
        assert traced_calls(fn -> RecordAccess.write(ctx.user_id, type, ctx.schema) end) ==
                 @gate_calls,
               "type #{type}"
      end
    end

    test "I5: writes nothing", ctx do
      tables =
        ~w(events entity_record_latest entity_type_instances event_idempotency audit_entries)

      count = fn -> for t <- tables, do: Repo.aggregate(t, :count, prefix: ctx.schema) end
      before = count.()
      RecordAccess.write(ctx.user_id, "customer", ctx.schema)
      RecordAccess.write(ctx.user_id, "no_such_type", ctx.schema)
      assert count.() == before
    end
  end

  describe "names_restricted?/2" do
    test "true only for a map with a top-level restricted key" do
      restricted = MapSet.new(["a"])
      assert RecordAccess.names_restricted?(%{"a" => 1, "b" => 2}, restricted)
      refute RecordAccess.names_restricted?(%{"b" => 2}, restricted)
      refute RecordAccess.names_restricted?(%{"b" => %{"a" => 1}}, restricted)
      refute RecordAccess.names_restricted?(%{"a" => 1}, MapSet.new())
      refute RecordAccess.names_restricted?("a", restricted)
      refute RecordAccess.names_restricted?(nil, restricted)
    end
  end

  describe "hidden_result/1" do
    test "is the result Records gives an absent type", ctx do
      assert RecordAccess.hidden_result("x") == {:error, {:definition_not_found, "x"}}

      assert Letflow.Entities.Records.create_record(
               %{
                 entity_type: "x",
                 field_values: %{},
                 actor_id: ctx.user_id,
                 idempotency_key: Ecto.UUID.generate()
               },
               ctx.schema
             ) == RecordAccess.hidden_result("x")

      base = %{
        entity_type: "x",
        record_id: Ecto.UUID.generate(),
        actor_id: ctx.user_id,
        idempotency_key: Ecto.UUID.generate()
      }

      assert Letflow.Entities.Records.update_record(
               Map.put(base, :field_values, %{}),
               ctx.schema
             ) == RecordAccess.hidden_result("x")

      assert Letflow.Entities.Records.delete_record(base, ctx.schema) ==
               RecordAccess.hidden_result("x")
    end
  end
end
