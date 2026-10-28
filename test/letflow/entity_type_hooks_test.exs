defmodule Letflow.EntityTypeHooksTest do
  @moduledoc """
  REQ-567 slice E-1 part 1 (GH #3217): the `entity_write` hook kind (K), the binding table and its
  migration (M), `Letflow.EntityTypeHooks` bind / rebind / unbind / list with every bind-time
  refusal (B, R, H, U), tenant isolation (I) and "nothing runs" (N). `async: false` (tenant
  provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.EntityDefinition
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.Scripts
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.ScriptRule
  alias Letflow.EntityWritesFixture, as: EW
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @unknown_type "no_such_type"

  defp actor(user_id \\ Ecto.UUID.generate()),
    do: %{user_id: user_id, credential: :oidc, trace_id: "req567-trace"}

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  # A script row of `hook_kind` / `status`, hashed over its own content (the legal INSERT shape).
  defp script!(schema, hook_kind, status) do
    key = "hk#{System.unique_integer([:positive])}"
    test_cases = [%{"name" => "c1", "input" => %{}, "expect" => %{"fail" => "x"}}]
    manifest = F.closed_manifest()
    source = F.doubling_source()

    rule =
      Repo.insert!(
        %ScriptRule{
          key: key,
          version: 1,
          hook_kind: hook_kind,
          status: :draft,
          source: source,
          manifest: manifest,
          test_cases: test_cases,
          sha256: "pending",
          contributors: [Ecto.UUID.generate()]
        },
        prefix: schema
      )

    sha = Hash.compute(key, 1, hook_kind, manifest, test_cases, source)

    rule = rule |> Ecto.Changeset.change(sha256: sha) |> Repo.update!(prefix: schema)

    changes =
      case status do
        :draft ->
          []

        :discarded ->
          [status: :discarded, discarded_at: DateTime.utc_now()]

        _ ->
          publisher = Ecto.UUID.generate()

          [
            status: :published,
            publisher_id: publisher,
            published_at: DateTime.utc_now(),
            sod_excluded: rule.contributors ++ [publisher]
          ]
      end

    rule = rule |> Ecto.Changeset.change(changes) |> Repo.update!(prefix: schema)

    case status do
      :retired -> F.retire_raw!(schema, rule)
      :revoked -> F.revoke_raw!(schema, rule)
      _ -> rule
    end
  end

  defp published!(schema), do: script!(schema, "entity_write", :published)

  defp bindings(schema), do: Repo.aggregate(Binding, :count, :id, prefix: schema)
  defp audits(schema), do: Repo.aggregate(Entry, :count, :id, prefix: schema)

  defp audit_actions(schema) do
    Repo.all(from(e in Entry, order_by: e.inserted_at, select: e.action), prefix: schema)
  end

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r567")
    schema = tenant.schema_name
    type = EW.define_type!(schema, "r567_order", %{}).name
    {:ok, tenant: tenant, schema: schema, type: type}
  end

  describe "K hook kind" do
    test "K1 an entity_write script can be created and published; an unknown kind is refused",
         %{tenant: t, schema: schema} do
      :ok = Letflow.Scripts.HmacSecret.ensure(%{id: t.tenant_id})

      on_exit(fn ->
        Repo.delete_all(from(s in Letflow.Secrets.Secret, where: s.tenant_id == ^t.tenant_id))
      end)

      body = fn kind ->
        manifest =
          if kind == "entity_write",
            do: Map.put(F.closed_manifest(), "derived_fields", ["total"]),
            else: F.closed_manifest()

        %{
          "hook_kind" => kind,
          "source" => F.doubling_source(),
          "manifest" => manifest,
          "test_cases" => [
            %{
              "name" => "c1",
              "input" => %{"amount" => 2},
              "expect" => %{"output" => %{"total" => 4}}
            }
          ]
        }
      end

      assert {:ok, draft} = Scripts.create_draft(schema, "k1key", body.("entity_write"), actor())
      assert draft.hook_kind == "entity_write"
      assert draft.manifest["derived_fields"] == ["total"]

      assert {:ok, published} =
               Scripts.publish(schema, "k1key", draft.version, draft.sha256, actor(), false)

      assert published.status == :published
      assert published.hook_kind == "entity_write"

      assert Scripts.create_draft(schema, "k1bad", body.("nope"), actor()) ==
               {:error, :invalid_hook_kind}
    end

    test "K2 a service_task version cannot be bound to an entity type", %{
      schema: schema,
      type: type
    } do
      rule = script!(schema, "service_task", :published)
      assert Hooks.bind(schema, type, pin(rule), actor()) == {:error, :hook_kind_mismatch}
    end

    test "K3 an entity_write version cannot be bound to a SERVICE_TASK node", %{schema: schema} do
      rule = published!(schema)
      {:ok, graph} = Letflow.Definitions.Graph.from_map(F.script_graph(rule.key, rule.version))

      assert {:error, {:script_binding_invalid, "svc", :script_not_published}} =
               Letflow.Scripts.Runtime.check_bindings(graph, schema)
    end
  end

  describe "M migration" do
    test "M1 the table, its columns, the unique index and the widened CHECK", %{schema: schema} do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name, is_nullable FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'entity_type_hook_bindings'",
          [schema]
        )

      cols = Map.new(rows, fn [n, nullable] -> {n, nullable} end)

      assert Map.keys(cols) |> Enum.sort() ==
               ~w(bound_by entity_type id inserted_at script_key script_sha256 script_version tenant_id updated_at)

      assert cols["tenant_id"] == "NO"
      assert bindings(schema) == 0

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND " <>
            "indexname = 'entity_type_hook_bindings_entity_type_index'",
          [schema]
        )

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "(entity_type)"

      assert %ScriptRule{hook_kind: "entity_write"} = script!(schema, "entity_write", :draft)

      assert_raise Ecto.ConstraintError, ~r/script_rules_hook_kind/, fn ->
        script!(schema, "bogus", :draft)
      end
    end

    test "M2 a newly provisioned tenant has the table" do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "r567-new")

      %{rows: [[reg]]} =
        Repo.query!("SELECT to_regclass($1)::text", [
          ~s|"#{other.schema_name}".entity_type_hook_bindings|
        ])

      assert reg =~ "entity_type_hook_bindings"

      assert Enum.any?(
               TenantProvisioning.tenant_scoped_migrations(),
               &match?(
                 {20_261_025_500_002, Letflow.Repo.Migrations.CreateEntityTypeHookBindings},
                 &1
               )
             )
    end

    test "M3 the migration over an existing tenant (old CHECK, no table)", %{schema: schema} do
      version = 20_261_025_500_002
      mod = Letflow.Repo.Migrations.CreateEntityTypeHookBindings
      _ = TenantProvisioning.tenant_scoped_migrations()

      # `down` returns the schema to the state of an existing tenant before this migration
      Ecto.Migrator.run(Repo, [{version, mod}], :down, all: true, prefix: schema, log: false)

      assert_raise Ecto.ConstraintError, ~r/script_rules_hook_kind/, fn ->
        script!(schema, "entity_write", :draft)
      end

      Ecto.Migrator.run(Repo, [{version, mod}], :up, all: true, prefix: schema, log: false)

      assert bindings(schema) == 0
      assert %ScriptRule{} = script!(schema, "entity_write", :draft)
    end
  end

  describe "B bind" do
    test "B1 binds a published entity_write version; one audit record", %{
      tenant: tenant,
      schema: schema,
      type: type
    } do
      rule = published!(schema)
      user = Ecto.UUID.generate()
      before = audits(schema)

      assert {:ok, %Binding{} = b} = Hooks.bind(schema, type, pin(rule), actor(user))
      assert b.entity_type == type
      assert b.script_key == rule.key
      assert b.script_version == rule.version
      assert b.script_sha256 == rule.sha256
      assert b.bound_by == user
      assert b.tenant_id == tenant.tenant_id

      assert audits(schema) == before + 1

      entry =
        Repo.one(from(e in Entry, where: e.action == "entity_type_hook.bound"), prefix: schema)

      assert entry.resource_id == b.id

      assert Map.keys(entry.after_state) |> Enum.sort() ==
               ~w(entity_type script_key script_sha256 script_version)
    end

    test "B2 an audit failure leaves no row", %{schema: schema, type: type} do
      rule = published!(schema)
      Repo.query!(~s(DROP TABLE "#{schema}".audit_entries))

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Hooks.bind(schema, type, pin(rule), actor())

      assert bindings(schema) == 0
    end

    test "B2b a rebind audit failure leaves the row unchanged", %{schema: schema, type: type} do
      first = published!(schema)
      second = published!(schema)
      {:ok, b} = Hooks.bind(schema, type, pin(first), actor())
      Repo.query!(~s(DROP TABLE "#{schema}".audit_entries))

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Hooks.rebind(schema, type, pin(second), actor())

      assert %Binding{script_key: key} = Repo.get!(Binding, b.id, prefix: schema)
      assert key == first.key
    end

    test "B2c an unbind audit failure leaves the row", %{schema: schema, type: type} do
      {:ok, _} = Hooks.bind(schema, type, pin(published!(schema)), actor())
      Repo.query!(~s(DROP TABLE "#{schema}".audit_entries))

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Hooks.unbind(schema, type, actor())

      assert bindings(schema) == 1
    end
  end

  describe "R bind refusals (table and audit trail unchanged)" do
    defp refused(schema, type, params, code, actor \\ actor()) do
      {b, a} = {bindings(schema), audits(schema)}
      assert Hooks.bind(schema, type, params, actor) == {:error, code}
      assert {bindings(schema), audits(schema)} == {b, a}
    end

    test("R1 draft", %{schema: s, type: t},
      do: refused(s, t, pin(script!(s, "entity_write", :draft)), :script_not_published)
    )

    test("R2 retired", %{schema: s, type: t},
      do: refused(s, t, pin(script!(s, "entity_write", :retired)), :script_not_published)
    )

    test("R3 revoked", %{schema: s, type: t},
      do: refused(s, t, pin(script!(s, "entity_write", :revoked)), :script_not_published)
    )

    test("R4 service_task kind", %{schema: s, type: t},
      do: refused(s, t, pin(script!(s, "service_task", :published)), :hook_kind_mismatch)
    )

    test "R5 sha mismatch", %{schema: s, type: t} do
      params = Map.put(pin(published!(s)), "script_sha256", String.duplicate("a", 64))
      refused(s, t, params, :sha_mismatch)
    end

    test("R6 unknown script", %{schema: s, type: t},
      do: refused(s, t, %{pin(published!(s)) | "script_key" => "nokey"}, :script_not_found)
    )

    test("R7 unknown version", %{schema: s, type: t},
      do: refused(s, t, %{pin(published!(s)) | "script_version" => 99}, :script_not_found)
    )

    test("R8 type not in the tenant's definitions", %{schema: s},
      do: refused(s, @unknown_type, pin(published!(s)), :not_found)
    )

    test "R9 managed type", %{schema: s} do
      base = Repo.one!(from(d in EntityDefinition, where: d.name == "r567_order"), prefix: s)

      attrs =
        base
        |> Map.from_struct()
        |> Map.drop([:id, :__meta__])
        |> Map.merge(%{name: "r567_managed", managed_by: "fixture_managed"})

      Repo.insert!(struct(EntityDefinition, attrs), prefix: s)
      refused(s, "r567_managed", pin(published!(s)), :entity_type_managed)
    end

    test "R10 already bound", %{schema: s, type: t} do
      params = pin(published!(s))
      {:ok, _} = Hooks.bind(s, t, params, actor())
      refused(s, t, params, :already_bound)
    end

    test "R11 invalid params", %{schema: s, type: t} do
      refused(s, t, %{"script_key" => "k"}, :invalid_input)
      refused(s, t, %{pin(published!(s)) | "script_version" => 0}, :invalid_input)
      refused(s, t, %{pin(published!(s)) | "script_sha256" => "XYZ"}, :invalid_input)
      refused(s, t, nil, :invalid_input)
    end

    test("R12 API-token actor", %{schema: s, type: t},
      do:
        refused(s, t, pin(published!(s)), :api_token_not_allowed, %{
          actor()
          | credential: :api_token
        })
    )

    test("R13 discarded draft", %{schema: s, type: t},
      do: refused(s, t, pin(script!(s, "entity_write", :discarded)), :script_not_found)
    )
  end

  describe "H entity_type_hooked" do
    defp definition!(schema, type, status, extra_attrs \\ %{}) do
      user = EW.user!(schema, "h")
      graph = EW.graph([EW.line(type, %{"label" => %{"const" => "x"}})])

      graph =
        put_in(
          graph,
          ["nodes", Access.at(1), "attributes"],
          Map.merge(graph["nodes"] |> Enum.at(1) |> Map.fetch!("attributes"), extra_attrs)
        )

      row = EW.activate!(schema, user, graph)

      if status == :active,
        do: row,
        else:
          row
          |> Ecto.Changeset.change(status: status)
          |> Repo.update!(prefix: schema)
    end

    test "H1 an ACTIVE definition with an entity_writes line refuses the bind", %{
      schema: s,
      type: t
    } do
      definition!(s, t, :active)
      refused(s, t, pin(published!(s)), :entity_type_hooked)
    end

    test "H2 a draft definition does not", %{schema: s, type: t} do
      definition!(s, t, :draft)
      assert {:ok, _} = Hooks.bind(s, t, pin(published!(s)), actor())
    end

    test "H3 a deprecated definition does not", %{schema: s, type: t} do
      definition!(s, t, :deprecated)
      assert {:ok, _} = Hooks.bind(s, t, pin(published!(s)), actor())
    end

    test "H4 an ACTIVE definition with a line on a DIFFERENT type does not", %{schema: s, type: t} do
      other = EW.define_type!(s, "r567_other", %{}).name
      definition!(s, other, :active)
      assert {:ok, _} = Hooks.bind(s, t, pin(published!(s)), actor())
    end

    defp handler_definition!(schema, status) do
      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "ht",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{
              "role" => "REVIEWER",
              "module_writes" => [
                %{
                  "module" => "fixture_ledger",
                  "handler" => "post_balance_only",
                  "args" => %{"item" => %{"var" => "item"}}
                }
              ]
            }
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "ht"},
          %{"id" => "e2", "source" => "ht", "target" => "end"}
        ]
      }

      {:ok, row} =
        Letflow.Definitions.create(
          %{
            name: "h5-def-#{System.unique_integer([:positive])}",
            version: "1",
            graph: graph,
            created_by: Ecto.UUID.generate()
          },
          prefix: schema
        )

      row |> Ecto.Changeset.change(status: status) |> Repo.update!(prefix: schema)
    end

    test "H5 an ACTIVE definition with a handler line on the type refuses; a draft does not", %{
      schema: s
    } do
      # The Catalog handler `post_balance_only` targets "fxl_balance". The name is reserved for
      # the module, so an unmanaged row of that name is made by renaming a tenant type.
      EW.define_type!(s, "r567_h5", %{})

      {1, _} =
        Repo.update_all(
          from(e in EntityDefinition, where: e.name == "r567_h5"),
          [set: [name: "fxl_balance"]],
          prefix: s
        )

      target = "fxl_balance"
      handler_definition!(s, :draft)
      assert {:ok, _} = Hooks.bind(s, target, pin(published!(s)), actor())
      assert {:ok, _} = Hooks.unbind(s, target, actor())

      handler_definition!(s, :active)
      before_b = bindings(s)
      before_a = audits(s)
      assert Hooks.bind(s, target, pin(published!(s)), actor()) == {:error, :entity_type_hooked}
      assert bindings(s) == before_b
      assert audits(s) == before_a
    end

    test "H6 the query is bound-parameter jsonb containment" do
      src = File.read!("lib/letflow/entity_type_hooks.ex")
      assert src =~ ~s|fragment("? @> ?", d.graph, type(^document, :map))|
      refute src =~ ~r/fragment\([^\n]*\#\{/
      refute src =~ "Repo.query"
    end
  end

  describe "U rebind, unbind, retire block, list" do
    test "U1 rebind replaces the row and audits; refusals leave it unchanged", %{
      schema: s,
      type: t
    } do
      first = published!(s)
      second = published!(s)
      {:ok, b} = Hooks.bind(s, t, pin(first), actor())

      assert {:ok, r} = Hooks.rebind(s, t, pin(second), actor())
      assert r.id == b.id
      assert r.script_key == second.key
      assert DateTime.compare(r.updated_at, b.updated_at) == :gt
      assert List.last(audit_actions(s)) == "entity_type_hook.rebound"

      n = audits(s)
      draft = script!(s, "entity_write", :draft)
      assert Hooks.rebind(s, t, pin(draft), actor()) == {:error, :script_not_published}
      assert Hooks.rebind(s, "r567_other", pin(second), actor()) == {:error, :not_found}
      assert audits(s) == n
      assert Repo.get!(Binding, b.id, prefix: s).script_key == second.key
    end

    test "U2 unbind deletes and audits; an unbound or absent type is not_found", %{
      schema: s,
      type: t
    } do
      {:ok, _} = Hooks.bind(s, t, pin(published!(s)), actor())
      assert {:ok, %Binding{}} = Hooks.unbind(s, t, actor())
      assert bindings(s) == 0
      assert List.last(audit_actions(s)) == "entity_type_hook.unbound"

      assert Hooks.unbind(s, t, actor()) == {:error, :not_found}
      assert Hooks.unbind(s, @unknown_type, actor()) == {:error, :not_found}
    end

    test "U3 retire of a bound version is refused; revoke is not", %{schema: s, type: t} do
      rule = published!(s)
      {:ok, _} = Hooks.bind(s, t, pin(rule), actor())

      assert Scripts.retire(s, rule.key, rule.version, "no longer needed", actor()) ==
               {:error, :version_in_use}

      assert {:ok, _} = Hooks.unbind(s, t, actor())

      assert {:ok, %{status: :retired}} =
               Scripts.retire(s, rule.key, rule.version, "done", actor())

      other = published!(s)
      {:ok, _} = Hooks.bind(s, t, pin(other), actor())

      assert {:ok, %{status: :revoked}} =
               Scripts.revoke(s, other.key, other.version, "bad", actor())
    end

    test "U4 list is ordered by entity type", %{schema: s, type: t} do
      other = EW.define_type!(s, "a567_first", %{}).name
      {:ok, _} = Hooks.bind(s, t, pin(published!(s)), actor())
      {:ok, _} = Hooks.bind(s, other, pin(published!(s)), actor())
      assert Enum.map(Hooks.list(s), & &1.entity_type) == [other, t]
    end
  end

  describe "I tenant isolation" do
    test "I1 tenant A's binding is invisible to tenant B", %{schema: a, type: t} do
      b_tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r567-b")
      b = b_tenant.schema_name
      {:ok, binding} = Hooks.bind(a, t, pin(published!(a)), actor())

      # B has no such type: every write answers as for a type that exists nowhere
      assert Hooks.bind(b, t, pin(published!(b)), actor()) == {:error, :not_found}
      assert Hooks.rebind(b, t, pin(published!(b)), actor()) == {:error, :not_found}
      assert Hooks.unbind(b, t, actor()) == {:error, :not_found}
      assert Hooks.unbind(b, @unknown_type, actor()) == {:error, :not_found}

      # B can bind its own type of the same name independently
      EW.define_type!(b, t, %{})
      assert {:ok, _} = Hooks.bind(b, t, pin(published!(b)), actor())

      assert Repo.get!(Binding, binding.id, prefix: a).script_key == binding.script_key
      assert length(Hooks.list(a)) == 1
      assert length(Hooks.list(b)) == 1
    end
  end

  describe "N nothing runs" do
    test "N1 records, step writes and handler writes do not mention the hook" do
      for f <- ~w(records step_writes handler_writes) do
        src = File.read!("lib/letflow/entities/#{f}.ex")
        refute src =~ "EntityTypeHooks"
        refute src =~ "entity_type_hook_bindings"
      end
    end
  end
end
