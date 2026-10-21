defmodule Letflow.EnumStatusFieldsTest do
  @moduledoc """
  GH 2603: `service_task_dispatches.status`, `script_rules.status`, `script_policy.sod` and
  `script_task_dispatches.status` are `Ecto.Enum` over their existing `:string` columns.

  Per field: the enum values equal the DB CHECK set, an invalid value is a changeset error
  (not a DB error), a DB round trip yields the atom, and the stored column still holds the
  string (read through a schemaless source, so the external form stays byte-identical).

  The DB CHECK stays the backstop: a raw schemaless write of an invalid value is refused by
  Postgres. `async: false`: real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.ScriptTaskDispatcher.ScriptTaskDispatch
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    %{t: F.tenant!("gh2603-enum")}
  end

  defp enum_values(schema, field), do: Ecto.Enum.values(schema, field)

  defp assert_cast_error(changeset, field) do
    refute changeset.valid?
    assert {"is invalid", _opts} = changeset.errors[field]
  end

  defp raw_string(schema, table, id_field, id, column) do
    Repo.one(
      from(r in table,
        where: field(r, ^id_field) == ^id,
        select: field(r, ^column)
      ),
      prefix: schema
    )
  end

  describe "service_task_dispatches.status" do
    test "values equal the CHECK set; invalid is a changeset error", _ctx do
      assert enum_values(ServiceTaskDispatch, :status) == [:pending, :advanced, :given_up]

      cs =
        ServiceTaskDispatch.terminal_changeset(%ServiceTaskDispatch{}, %{
          status: "cancelled",
          dispatched_at: DateTime.utc_now()
        })

      assert_cast_error(cs, :status)
    end

    test "DB round trip yields the atom, the column holds the string", %{t: t} do
      id = Ecto.UUID.generate()

      assert {:ok, _} =
               %ServiceTaskDispatch{}
               |> ServiceTaskDispatch.arm_changeset(%{
                 id: id,
                 tenant_id: t.tenant_id,
                 instance_id: Ecto.UUID.generate(),
                 token_id: Ecto.UUID.generate(),
                 node_id: "n",
                 config_snapshot: %{},
                 next_attempt_at: DateTime.utc_now(),
                 created_at: DateTime.utc_now()
               })
               |> Repo.insert(prefix: t.schema_name)

      row = Repo.get!(ServiceTaskDispatch, id, prefix: t.schema_name)
      assert row.status == :pending

      assert raw_string(
               t.schema_name,
               "service_task_dispatches",
               :id,
               Ecto.UUID.dump!(id),
               :status
             ) == "pending"

      assert {:ok, done} =
               row
               |> ServiceTaskDispatch.terminal_changeset(%{
                 status: :given_up,
                 dispatched_at: DateTime.utc_now()
               })
               |> Repo.update(prefix: t.schema_name)

      assert done.status == :given_up

      assert raw_string(
               t.schema_name,
               "service_task_dispatches",
               :id,
               Ecto.UUID.dump!(id),
               :status
             ) == "given_up"
    end
  end

  describe "script_rules.status" do
    test "values equal the CHECK set; invalid is a cast error", _ctx do
      assert enum_values(ScriptRule, :status) ==
               [:draft, :discarded, :published, :retired, :revoked]

      assert_cast_error(
        Ecto.Changeset.cast(%ScriptRule{}, %{status: "bogus"}, [:status]),
        :status
      )
    end

    test "DB round trip yields the atom, the column holds the string", %{t: t} do
      rule = F.draft!(t.schema_name, "enum_rule", F.doubling_source(), F.closed_manifest())
      assert rule.status == :draft
      assert Repo.get!(ScriptRule, rule.id, prefix: t.schema_name).status == :draft

      assert raw_string(t.schema_name, "script_rules", :id, Ecto.UUID.dump!(rule.id), :status) ==
               "draft"
    end
  end

  describe "script_policy.sod" do
    test "values equal the CHECK set; invalid is a changeset error", %{t: t} do
      assert enum_values(ScriptPolicy, :sod) == [:strict, :solo_audited]

      policy = Repo.get!(ScriptPolicy, 1, prefix: t.schema_name)

      cs =
        ScriptPolicy.sod_changeset(policy, %{
          sod: "lenient",
          sod_set_by_class: "tenant_admin",
          sod_set_at: DateTime.utc_now()
        })

      assert_cast_error(cs, :sod)
    end

    test "DB round trip yields the atom, the column holds the string; CHECK is the backstop",
         %{t: t} do
      policy = Repo.get!(ScriptPolicy, 1, prefix: t.schema_name)
      assert policy.sod == :strict
      assert raw_string(t.schema_name, "script_policy", :id, 1, :sod) == "strict"
      assert {:ok, %ScriptPolicy{sod: :strict}} = Policy.get(t.schema_name)

      assert_raise Postgrex.Error, ~r/script_policy_sod_value/, fn ->
        Repo.update_all("script_policy", [set: [sod: "lenient"]], prefix: t.schema_name)
      end
    end
  end

  describe "script_task_dispatches.status" do
    test "values equal the CHECK set; invalid is a cast error", _ctx do
      assert enum_values(ScriptTaskDispatch, :status) ==
               [:pending, :running, :applied, :failed, :cancelled]

      assert_cast_error(
        Ecto.Changeset.cast(%ScriptTaskDispatch{}, %{status: "bogus"}, [:status]),
        :status
      )
    end

    test "DB round trip yields the atom, the column holds the string", %{t: t} do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {:ok, row} =
               %ScriptTaskDispatch{}
               |> ScriptTaskDispatch.arm_changeset(%{
                 id: id,
                 instance_id: Ecto.UUID.generate(),
                 token_id: Ecto.UUID.generate(),
                 node_id: "n",
                 script_key: "k",
                 script_version: 1,
                 script_sha256: String.duplicate("a", 64),
                 event_time: now,
                 next_attempt_at: now
               })
               |> Repo.insert(prefix: t.schema_name)

      assert row.status == :pending
      assert Repo.get!(ScriptTaskDispatch, id, prefix: t.schema_name).status == :pending

      assert raw_string(
               t.schema_name,
               "script_task_dispatches",
               :id,
               Ecto.UUID.dump!(id),
               :status
             ) == "pending"
    end
  end
end
