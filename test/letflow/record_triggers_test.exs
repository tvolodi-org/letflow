defmodule Letflow.RecordTriggersTest do
  @moduledoc """
  REQ-570 slice T-1 part 1 (GH #3248): `Letflow.RecordTriggers` bind / rebind / unbind / list with
  every bind-time refusal (B, R, U), the lock statements (B3), tenant isolation (I) and "nothing
  runs" (N). `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.EntityDefinition
  alias Letflow.EntityWritesFixture, as: EW
  alias Letflow.RecordTriggers, as: Triggers
  alias Letflow.RecordTriggers.Binding
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Scripts
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptPolicyFixture
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.TenantFixture

  @unknown_type "no_such_type"

  defp actor(user_id \\ Ecto.UUID.generate()),
    do: %{user_id: user_id, credential: :oidc, trace_id: "req570-trace"}

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  defp published!(schema, manifest \\ nil),
    do: RF.script!(schema, "entity_event", :published, manifest)

  defp writes_manifest(lines, extra \\ %{}),
    do: F.closed_manifest() |> Map.put("writes", lines) |> Map.merge(extra)

  defp line(type, fields, mode \\ "update_self"),
    do: %{"entity_type" => type, "mode" => mode, "fields" => fields}

  defp bindings(schema), do: Repo.aggregate(Binding, :count, :id, prefix: schema)
  defp audits(schema), do: Repo.aggregate(Entry, :count, :id, prefix: schema)

  defp audit_actions(schema),
    do: Repo.all(from(e in Entry, order_by: e.inserted_at, select: e.action), prefix: schema)

  defp define_managed!(schema, name) do
    base = Repo.one!(from(d in EntityDefinition, where: d.name == "r570_order"), prefix: schema)

    attrs =
      base
      |> Map.from_struct()
      |> Map.drop([:id, :__meta__])
      |> Map.merge(%{name: name, managed_by: "fixture_managed"})

    Repo.insert!(struct(EntityDefinition, attrs), prefix: schema)
  end

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r570")
    schema = tenant.schema_name
    type = EW.define_type!(schema, "r570_order", %{}).name
    {:ok, tenant: tenant, schema: schema, type: type}
  end

  describe "B bind" do
    test "B1 binds each event; the result lists type, event, key, version, sha, status; audited",
         %{schema: s, type: t} do
      rule = published!(s)

      for event <- ~w(created updated deleted) do
        assert {:ok, b} = Triggers.bind(s, t, event, pin(rule), actor())
        assert {b.entity_type, Atom.to_string(b.event), b.script_key} == {t, event, rule.key}

        assert {b.script_version, b.script_sha256, b.status} ==
                 {rule.version, rule.sha256, :active}
      end

      assert Enum.map(Triggers.list(s), &Atom.to_string(&1.event)) == ~w(created deleted updated)
      assert Enum.count(audit_actions(s), &(&1 == "record_trigger.bound")) == 3

      entry =
        Repo.one(from(e in Entry, where: e.action == "record_trigger.bound", limit: 1), prefix: s)

      assert Map.keys(entry.after_state) |> Enum.sort() ==
               ~w(entity_type event script_key script_sha256 script_version status)
    end

    test "B2 an audit failure leaves no row", %{schema: s, type: t} do
      rule = published!(s)
      Repo.query!(~s(DROP TABLE "#{s}".audit_entries))

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Triggers.bind(s, t, "created", pin(rule), actor())

      assert bindings(s) == 0
    end

    test "B2b rebind and unbind audit failures leave the row", %{schema: s, type: t} do
      first = published!(s)
      second = published!(s)
      {:ok, b} = Triggers.bind(s, t, "created", pin(first), actor())
      Repo.query!(~s(DROP TABLE "#{s}".audit_entries))

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Triggers.rebind(s, t, "created", pin(second), actor())

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Triggers.unbind(s, t, "created", actor())

      assert Repo.get!(Binding, b.id, prefix: s).script_key == first.key
    end

    test "B3 the bind locks the type's sequence row, then the audit chain row, nothing else",
         %{schema: s, type: t} do
      rule = published!(s)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Triggers.bind(s, t, "updated", pin(rule), actor())
        end)

      assert {:ok, _} = result
      sql = Enum.map(queries, & &1.query)
      for_update = Enum.filter(sql, &(&1 =~ "FOR UPDATE"))

      assert [seq] = Enum.filter(for_update, &(&1 =~ "\"instance_sequence\""))
      assert [chain] = Enum.filter(for_update, &(&1 =~ "audit_chain_locks"))
      assert length(for_update) == 2

      assert Enum.find_index(sql, &(&1 == seq)) < Enum.find_index(sql, &(&1 == chain))

      refute Enum.any?(sql, &(&1 =~ ~r/FOR SHARE|FOR NO KEY UPDATE|pg_advisory/))
    end

    test "B4 a type carries bindings for several events at once", %{schema: s, type: t} do
      {:ok, _} = Triggers.bind(s, t, "created", pin(published!(s)), actor())
      {:ok, _} = Triggers.bind(s, t, "deleted", pin(published!(s)), actor())
      assert bindings(s) == 2
    end
  end

  describe "R bind refusals (table and audit trail unchanged)" do
    defp refused(schema, type, params, code, event \\ "created") do
      {b, a} = {bindings(schema), audits(schema)}
      assert Triggers.bind(schema, type, event, params, actor()) == {:error, code}
      assert {bindings(schema), audits(schema)} == {b, a}
    end

    test("R1 draft", %{schema: s, type: t},
      do: refused(s, t, pin(RF.script!(s, "entity_event", :draft)), :script_not_published)
    )

    test("R2 retired", %{schema: s, type: t},
      do: refused(s, t, pin(RF.script!(s, "entity_event", :retired)), :script_not_published)
    )

    test("R3 revoked", %{schema: s, type: t},
      do: refused(s, t, pin(RF.script!(s, "entity_event", :revoked)), :script_not_published)
    )

    test "R4 another hook kind", %{schema: s, type: t} do
      for kind <- ~w(service_task entity_write) do
        refused(s, t, pin(RF.script!(s, kind, :published)), :hook_kind_mismatch)
      end
    end

    test("R5 sha mismatch", %{schema: s, type: t},
      do:
        refused(
          s,
          t,
          %{pin(published!(s)) | "script_sha256" => String.duplicate("a", 64)},
          :sha_mismatch
        )
    )

    test "R6 unknown key and version", %{schema: s, type: t} do
      rule = published!(s)
      refused(s, t, %{pin(rule) | "script_key" => "nokey"}, :script_not_found)
      refused(s, t, %{pin(rule) | "script_version" => 99}, :script_not_found)
    end

    test "R7 type not in the definitions", %{schema: s} do
      refused(s, @unknown_type, pin(published!(s)), :not_found)
    end

    test "R8 managed type", %{schema: s} do
      define_managed!(s, "r570_managed")
      refused(s, "r570_managed", pin(published!(s)), :entity_type_managed)
    end

    test "R9 a second bind of the pair is refused; another event is not", %{schema: s, type: t} do
      {:ok, _} = Triggers.bind(s, t, "created", pin(published!(s)), actor())
      refused(s, t, pin(published!(s)), :already_bound)
      assert {:ok, _} = Triggers.bind(s, t, "updated", pin(published!(s)), actor())
    end

    test "R10 a write line to a missing or managed type", %{schema: s, type: t} do
      refused(
        s,
        t,
        pin(published!(s, writes_manifest([line("ghost", ["note"])]))),
        :write_target_invalid
      )

      define_managed!(s, "r570_managed")

      refused(
        s,
        t,
        pin(published!(s, writes_manifest([line("r570_managed", ["note"])]))),
        :write_target_invalid
      )
    end

    test "R11a an undeclared write field", %{schema: s, type: t} do
      refused(
        s,
        t,
        pin(published!(s, writes_manifest([line(t, ["nope"])]))),
        :write_field_forbidden
      )
    end

    test "R11b a declared field named like a system field or managed_by", %{schema: s, type: t} do
      EW.define_type!(s, "r570_sys", %{
        fields: [
          %{name: "label", type: :string, required: true},
          %{name: "version", type: :string},
          %{name: "managed_by", type: :string}
        ]
      })

      for field <- ["version", "managed_by"] do
        refused(
          s,
          t,
          pin(published!(s, writes_manifest([line("r570_sys", [field])]))),
          :write_field_forbidden
        )
      end
    end

    test "R11c a scope-bearing write field", %{schema: s, type: t} do
      Application.put_env(:letflow, :entity_writes_scope_keys, ["note"])
      on_exit(fn -> Application.delete_env(:letflow, :entity_writes_scope_keys) end)

      refused(
        s,
        t,
        pin(published!(s, writes_manifest([line(t, ["note"])]))),
        :write_field_forbidden
      )
    end

    test "R12 the 0062 R5 predicate: a field would end with fewer restrictions than the taint",
         %{schema: s, type: t} do
      from = fn field -> [%{"entity_type" => t, "field" => field}] end

      restricted = fn field ->
        %{"restricted_inputs" => [%{"name" => "amount", "from" => from.(field)}]}
      end

      # tainted by `label`, written to `note`: refused
      refused(
        s,
        t,
        pin(published!(s, writes_manifest([line(t, ["note"])], restricted.("label")))),
        :write_restriction_widened
      )

      # tainted by `note` and `note` is restricted: accepted
      ScriptPolicyFixture.restrict_field!(s, t, "note")
      rule = published!(s, writes_manifest([line(t, ["note"])], restricted.("note")))
      assert {:ok, _} = Triggers.bind(s, t, "created", pin(rule), actor())

      # tainted by `note` (restricted), written to `label` (not restricted): refused
      refused(
        s,
        t,
        pin(published!(s, writes_manifest([line(t, ["label"])], restricted.("note")))),
        :write_restriction_widened,
        "updated"
      )
    end

    test "R13 an API token is refused for bind, rebind and unbind", %{schema: s, type: t} do
      token = %{actor() | credential: :api_token}
      rule = published!(s)
      assert Triggers.bind(s, t, "created", pin(rule), token) == {:error, :api_token_not_allowed}

      assert Triggers.rebind(s, t, "created", pin(rule), token) ==
               {:error, :api_token_not_allowed}

      assert Triggers.unbind(s, t, "created", token) == {:error, :api_token_not_allowed}
      assert bindings(s) == 0
    end

    test "R14 an invalid event, sha or version is invalid_input for an existing and an absent type",
         %{schema: s, type: t} do
      rule = published!(s)

      for type <- [t, @unknown_type] do
        assert Triggers.bind(s, type, "exploded", pin(rule), actor()) == {:error, :invalid_input}
        assert Triggers.bind(s, type, nil, pin(rule), actor()) == {:error, :invalid_input}

        assert Triggers.bind(s, type, "created", %{pin(rule) | "script_sha256" => "xyz"}, actor()) ==
                 {:error, :invalid_input}

        assert Triggers.bind(
                 s,
                 type,
                 "created",
                 %{pin(rule) | "script_version" => 2 ** 40},
                 actor()
               ) ==
                 {:error, :invalid_input}
      end
    end
  end

  describe "U rebind, unbind, retire, revoke" do
    test "U1 rebind replaces the row and audits; refusals leave it unchanged", %{
      schema: s,
      type: t
    } do
      first = published!(s)
      second = published!(s)
      {:ok, b} = Triggers.bind(s, t, "created", pin(first), actor())

      assert {:ok, r} = Triggers.rebind(s, t, "created", pin(second), actor())
      assert r.id == b.id
      assert r.script_key == second.key
      assert List.last(audit_actions(s)) == "record_trigger.rebound"

      n = audits(s)
      draft = RF.script!(s, "entity_event", :draft)

      assert Triggers.rebind(s, t, "created", pin(draft), actor()) ==
               {:error, :script_not_published}

      assert Triggers.rebind(
               s,
               t,
               "created",
               %{pin(second) | "script_sha256" => String.duplicate("b", 64)},
               actor()
             ) == {:error, :sha_mismatch}

      assert audits(s) == n
      assert Repo.get!(Binding, b.id, prefix: s).script_key == second.key
    end

    test "U2 rebind of an unbound pair is not_found", %{schema: s, type: t} do
      {:ok, _} = Triggers.bind(s, t, "created", pin(published!(s)), actor())

      assert Triggers.rebind(s, t, "updated", pin(published!(s)), actor()) == {:error, :not_found}
    end

    test "U3 unbind deletes and audits; an unbound pair answers as an unknown type",
         %{schema: s, type: t} do
      {:ok, _} = Triggers.bind(s, t, "created", pin(published!(s)), actor())
      assert {:ok, %Binding{}} = Triggers.unbind(s, t, "created", actor())
      assert bindings(s) == 0
      assert List.last(audit_actions(s)) == "record_trigger.unbound"

      unbound = Triggers.unbind(s, t, "created", actor())
      assert unbound == {:error, :not_found}
      assert unbound == Triggers.unbind(s, @unknown_type, "created", actor())
    end

    test "U4 retire of an unreferenced version works; of a bound one too (no retire block)",
         %{schema: s, type: t} do
      free = published!(s)

      assert {:ok, %{status: :retired}} =
               Scripts.retire(s, free.key, free.version, "done", actor())

      bound = published!(s)
      {:ok, _} = Triggers.bind(s, t, "created", pin(bound), actor())

      assert {:ok, %{status: :retired}} =
               Scripts.retire(s, bound.key, bound.version, "done", actor())

      assert length(Triggers.list(s)) == 1
    end

    test "U5 revoke of a bound version works and the binding stays listed", %{schema: s, type: t} do
      rule = published!(s)
      {:ok, _} = Triggers.bind(s, t, "created", pin(rule), actor())

      assert {:ok, %{status: :revoked}} =
               Scripts.revoke(s, rule.key, rule.version, "bad", actor())

      assert [%Binding{script_key: key}] = Triggers.list(s)
      assert key == rule.key
    end
  end

  describe "I tenant isolation" do
    test "I1 two tenants bind the same type and event independently", %{schema: a, type: t} do
      b = TenantFixture.provisioned_tenant!(slug_prefix: "r570-b").schema_name
      {:ok, binding} = Triggers.bind(a, t, "created", pin(published!(a)), actor())

      assert Triggers.bind(b, t, "created", pin(published!(b)), actor()) == {:error, :not_found}
      assert Triggers.unbind(b, t, "created", actor()) == {:error, :not_found}

      EW.define_type!(b, t, %{})
      assert {:ok, _} = Triggers.bind(b, t, "created", pin(published!(b)), actor())
      assert {:ok, _} = Triggers.unbind(b, t, "created", actor())

      assert Repo.get!(Binding, binding.id, prefix: a).script_key == binding.script_key
      assert length(Triggers.list(a)) == 1
      assert Triggers.list(b) == []
    end
  end

  describe "N nothing runs" do
    test "N1 only the context, its schema, its router, the manifest and the migration touch the table" do
      readers =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(fn f ->
          src = File.read!(f)
          src =~ "record_trigger_bindings" or src =~ "RecordTriggers"
        end)
        |> Enum.sort()

      assert readers == [
               "lib/letflow/record_triggers.ex",
               "lib/letflow/record_triggers/binding.ex",
               "lib/letflow/routers/record_trigger_bindings.ex",
               "lib/letflow/tenant_provisioning.ex"
             ]

      for f <- ~w(records step_writes handler_writes) do
        src = File.read!("lib/letflow/entities/#{f}.ex")
        refute src =~ "RecordTriggers"
        refute src =~ "record_trigger"
      end
    end

    test "N2 no migration creates a trigger outbox" do
      for f <- Path.wildcard("priv/repo/migrations/*.exs") do
        refute File.read!(f) =~ "record_trigger_outbox"
      end
    end
  end
end
