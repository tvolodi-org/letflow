defmodule Letflow.Definitions.ActivatedBySignatureTest do
  @moduledoc """
  T-0250 / GH #2644 (design `state/tasks/T-0250/design.md`, option (a)): the `activated_by`
  document is signed when a path makes a definition ACTIVE, and the run-time entity-write path
  refuses any document that is unsigned, forged, edited, copied, or verified with a key that is
  no longer the resolved one.

  Real Postgres through the real `Letflow.Engine.complete_task/3`. Direct writes go through
  `Repo.update_all` and `Ecto.Adapters.SQL.query!` (the two paths the issue names), and the
  request path is covered by the B-19 test in `entity_writes_activator_test.exs`.

  `async: false`: the per-tenant `activated-by-hmac` key lives in the shared `secrets` table.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.Secrets.Secret

  @key_name "activated-by-hmac"

  defp line(type), do: Fx.line(type, %{"label" => %{"var" => "label"}})

  defp case_with_writes! do
    Fx.case!("t0250", [line("stock_move")])
  end

  defp stored(ctx), do: Repo.get!(ProcessDefinition, ctx.definition.id, prefix: ctx.schema)

  defp set_activated_by!(ctx, doc) do
    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
      |> Repo.update_all([set: [activated_by: doc]], prefix: ctx.schema)

    :ok
  end

  defp unsigned(doc), do: Map.delete(doc, "signature")

  defp forged(ctx) do
    %{
      "user_id" => ctx.user.id,
      "roles" => ["TENANT_ADMIN"],
      "permissions" => ["DefinitionsActivate", "EntitiesRecordsWrite"],
      "authorized" => [%{"entity_type" => "stock_move", "op" => "create"}],
      "activated_at" => "2026-01-01T00:00:00Z"
    }
  end

  defp refused?(ctx) do
    assert {:error, :entity_write_needs_reactivation} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert Fx.all_records(ctx.schema) == []
  end

  defp key_row(tenant_id) do
    Repo.one(
      from(s in Secret,
        where:
          s.tenant_id == ^tenant_id and s.namespace == "platform" and s.name == ^@key_name and
            s.status == :active
      )
    )
  end

  defp put_new_key_version!(tenant) do
    {:ok, %{key_id: key_id}} =
      Secrets.put(
        %{
          tenant_id: tenant.tenant_id,
          namespace: "platform",
          name: @key_name,
          purpose: :generic,
          plaintext: :crypto.strong_rand_bytes(32),
          created_by: "test:t0250"
        },
        platform: true
      )

    key_id
  end

  defp resign!(ctx) do
    row = stored(ctx)
    doc = unsigned(row.activated_by)
    {:ok, signed} = ActivatedBy.sign(doc, row, ctx.schema)
    set_activated_by!(ctx, signed)
  end

  describe "signing on activation" do
    test "activate writes a signature with alg, key_version and a hex mac, under the platform key" do
      ctx = case_with_writes!()

      doc = stored(ctx).activated_by
      assert %{"alg" => "HMAC-SHA256", "key_version" => kv, "mac" => mac} = doc["signature"]
      assert is_integer(kv)
      assert mac =~ ~r/\A[0-9a-f]{64}\z/

      assert %Secret{purpose: :generic, key_id: ^kv} = key_row(ctx.tenant.tenant_id)
    end

    test "the stored key is not in the activated_by document (INV-4)" do
      ctx = case_with_writes!()
      %{ciphertext: ct} = key_row(ctx.tenant.tenant_id)
      refute Jason.encode!(stored(ctx).activated_by) =~ Base.encode64(ct)

      assert Map.keys(stored(ctx).activated_by["signature"]) |> Enum.sort() ==
               ["alg", "key_version", "mac"]
    end

    test "a valid signed document completes a human task (happy path)" do
      ctx = case_with_writes!()

      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert [_] = Fx.records(ctx.schema, "stock_move")
    end
  end

  describe "forged or edited documents are refused" do
    test "T-FORGE-1: a forged unsigned document written with Repo.update_all is refused" do
      ctx = case_with_writes!()
      set_activated_by!(ctx, forged(ctx))
      refused?(ctx)
    end

    test "T-FORGE-2: a forged unsigned document written with a raw SQL UPDATE is refused" do
      ctx = case_with_writes!()

      Ecto.Adapters.SQL.query!(
        Repo,
        ~s(UPDATE "#{ctx.schema}".process_definitions SET activated_by = $1::jsonb WHERE id = $2),
        [forged(ctx), Ecto.UUID.dump!(ctx.definition.id)]
      )

      refused?(ctx)
    end

    test "T-FORGE-3: a signed document with its roles edited keeps the old signature: MAC mismatch" do
      ctx = case_with_writes!()
      signed = stored(ctx).activated_by

      set_activated_by!(
        ctx,
        Map.put(signed, "permissions", ["EntitiesRecordsWrite", "DefinitionsActivate"])
        |> Map.put("authorized", [
          %{"entity_type" => "stock_move", "op" => "create"},
          %{"entity_type" => "stock_note", "op" => "create"}
        ])
      )

      refused?(ctx)
    end
  end

  describe "a signed document copied elsewhere is refused" do
    test "T-COPY-1: copied to another definition id (same tenant)" do
      a = case_with_writes!()

      b =
        Fx.legacy_activate!(a.schema, a.user, Fx.graph([line("stock_move")]), [
          {"stock_move", "create"}
        ])

      {_instance, task} = Fx.start!(a.schema, b)
      from_a = stored(a).activated_by

      {1, _} =
        from(d in ProcessDefinition, where: d.id == ^b.id)
        |> Repo.update_all([set: [activated_by: from_a]], prefix: a.schema)

      assert {:error, :entity_write_needs_reactivation} =
               Fx.complete(%{schema: a.schema, user: a.user, task: task}, %{"label" => "L1"})
    end

    test "T-COPY-2: copied to another version (same id, version edited)" do
      ctx = case_with_writes!()

      {1, _} =
        from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
        |> Repo.update_all([set: [version: "9.9.9"]], prefix: ctx.schema)

      refused?(ctx)
    end

    test "T-COPY-3: the graph edited after activation (raw UPDATE) is refused" do
      ctx = case_with_writes!()
      graph = stored(ctx).graph

      edited = %{
        graph
        | "nodes" =>
            Enum.map(graph["nodes"], fn
              %{"id" => "ht"} = node ->
                put_in(node, ["attributes", "note"], "edited after activation")

              node ->
                node
            end)
      }

      {1, _} =
        from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
        |> Repo.update_all([set: [graph: edited]], prefix: ctx.schema)

      refused?(ctx)
    end

    test "T-COPY-4: copied to a definition of another tenant (the key is per tenant)" do
      a = case_with_writes!()
      b = Fx.tenant_case!("t0250b")

      other =
        Fx.legacy_activate!(b.schema, b.user, Fx.graph([line("stock_move")]), [
          {"stock_move", "create"}
        ])

      {_instance, task} = Fx.start!(b.schema, other)

      {1, _} =
        from(d in ProcessDefinition, where: d.id == ^other.id)
        |> Repo.update_all([set: [activated_by: stored(a).activated_by]], prefix: b.schema)

      assert {:error, :entity_write_needs_reactivation} =
               Fx.complete(%{schema: b.schema, user: b.user, task: task}, %{"label" => "L1"})
    end
  end

  describe "documents without a signature (pre-deploy rows, NULL authority)" do
    test "T-LEGACY-1: an ACTIVE row with entity_writes and NULL activated_by is refused and stays NULL" do
      ctx = case_with_writes!()
      set_activated_by!(ctx, nil)

      refused?(ctx)
      assert stored(ctx).activated_by == nil
    end

    test "T-LEGACY-2: a well-formed UNSIGNED document is refused and is not re-signed by the refusal" do
      ctx = case_with_writes!()
      set_activated_by!(ctx, unsigned(stored(ctx).activated_by))

      refused?(ctx)
      refute Map.has_key?(stored(ctx).activated_by, "signature")
    end

    test "T-LEGACY-3: a definition without entity_writes activates with NULL activated_by and completes" do
      tenant = Fx.tenant_case!("t0250c")
      definition = Fx.activate!(tenant.schema, tenant.user, Fx.graph([]))
      {_instance, task} = Fx.start!(tenant.schema, definition)

      assert Repo.get!(ProcessDefinition, definition.id, prefix: tenant.schema).activated_by ==
               nil

      assert {:ok, _} =
               Fx.complete(%{schema: tenant.schema, user: tenant.user, task: task}, %{})
    end
  end

  describe "rollback re-signs the row it makes ACTIVE" do
    test "T-ROLLBACK-1: a rollback to v1 leaves a v1 document that verifies, and a completion succeeds" do
      tenant = Fx.tenant_case!("t0250r")
      Fx.define_type!(tenant.schema, "stock_move", %{})
      name = Fx.unique("t0250-rb")
      lines = [line("stock_move")]

      activator =
        Activator.from_auth_context(%{user_id: tenant.user.id, roles: ["TENANT_ADMIN"]}, false)

      v1 = create_and_activate!(tenant, name, "1", lines, activator)
      _v2 = create_and_activate!(tenant, name, "2", lines, activator)

      assert {:ok, _} =
               Definitions.rollback_definition_version(name, "1", Ecto.UUID.generate(),
                 prefix: tenant.schema,
                 activator: activator,
                 permission_checker: fn _actor, _tenant -> true end,
                 event_appender: fn _attrs, _prefix ->
                   {:ok, %{event_id: Ecto.UUID.generate()}}
                 end
               )

      row = Repo.get!(ProcessDefinition, v1.id, prefix: tenant.schema)
      assert row.status == :active
      assert {:ok, :verified} = ActivatedBy.verify(row.activated_by, row, tenant.schema)

      {_instance, task} = Fx.start!(tenant.schema, row)

      assert {:ok, _} =
               Fx.complete(%{schema: tenant.schema, user: tenant.user, task: task}, %{
                 "label" => "L1"
               })
    end
  end

  describe "the key and its versions" do
    test "T-KEY-1: no key row means needs_reactivation, and the read path creates no key" do
      ctx = case_with_writes!()

      Repo.delete_all(
        from(s in Secret, where: s.tenant_id == ^ctx.tenant.tenant_id and s.name == ^@key_name)
      )

      refused?(ctx)
      assert key_row(ctx.tenant.tenant_id) == nil
    end

    test "T-KEY-2a: a rotation (new newest version) refuses the document signed under the old one" do
      ctx = case_with_writes!()
      put_new_key_version!(ctx.tenant)

      refused?(ctx)

      resign!(ctx)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    end

    test "T-KEY-2b: disabling the newest version refuses the documents signed with it" do
      ctx = case_with_writes!()
      v2 = put_new_key_version!(ctx.tenant)
      resign!(ctx)
      assert stored(ctx).activated_by["signature"]["key_version"] == v2

      {:ok, _} =
        Secrets.disable("sec://tenant/#{ctx.tenant.tenant.slug}/platform/#{@key_name}##{v2}",
          tenant_id: ctx.tenant.tenant_id,
          platform: true
        )

      refused?(ctx)
    end

    test "T-KEY-2c: disabling every version refuses with no key" do
      ctx = case_with_writes!()
      v1 = stored(ctx).activated_by["signature"]["key_version"]

      {:ok, _} =
        Secrets.disable("sec://tenant/#{ctx.tenant.tenant.slug}/platform/#{@key_name}##{v1}",
          tenant_id: ctx.tenant.tenant_id,
          platform: true
        )

      refused?(ctx)
    end
  end

  # A definition with `lines`, created and activated as `activator` (a real activation path).
  defp create_and_activate!(tenant, name, version, lines, activator) do
    {:ok, definition} =
      Definitions.create(
        %{name: name, version: version, graph: Fx.graph(lines), created_by: tenant.user.id},
        prefix: tenant.schema
      )

    {:ok, %{definition: active}} =
      Definitions.activate(definition.id, prefix: tenant.schema, activator: activator)

    active
  end
end
