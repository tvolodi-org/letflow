defmodule Letflow.Scripts.PolicyTest do
  @moduledoc """
  GH 2534 PR 7b-2a, design `lib/letflow/design/gh2534-7b2a-script-policy.md` section 12
  (`Letflow.Scripts.Policy`, real Postgres):

    * AC1: both tables and the singleton row exist after provisioning; replay is idempotent;
      DELETE of the row is refused (LF001), a second row is refused (check), identity columns
      are immutable; the masters table checks its key format.
    * AC4 / SEC F4: neither latch writer can change the other's latch; effective = OR; each
      changeset casts only its own columns.
    * AC13: `kill_switch_on?/1` is true without the row; `check_reads/2` refuses each run-time
      cause of section 8 item 2 (unflagged, inactive, type-restricted, field gone since
      publish, restricted match field not opted in).
    * `references/2`: published and retired versions listed, drafts/discarded/revoked not;
      capped at 100 with the total.
    * AC9: a publish holding `FOR SHARE` on a master row blocks a concurrent clear until it
      commits; the clear then lists the published version.
    * The platform latch refuses an unverifiable platform prefix (`:audit_failed`, nothing
      written) and a token; both latches audit in the section 7 shape.

  `async: false`: provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Scripts
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ReadableMaster
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.TenantProvisioning

  @source "return {name = 'x'}"
  @cases [
    %{"name" => "ok", "input" => %{"cid" => "c1"}, "expect" => %{"output" => %{"name" => "x"}}}
  ]

  setup do
    {:ok, Fixture.two_tenants!()}
  end

  defp body(reads),
    do: %{
      "hook_kind" => "service_task",
      "source" => @source,
      "manifest" => SP.manifest(reads),
      "test_cases" => @cases
    }

  defp key, do: "rule_#{System.unique_integer([:positive])}"

  defp policy(schema), do: Repo.get!(ScriptPolicy, 1, prefix: schema)

  defp assert_lf001(fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.pg_code == "LF001"
  end

  # ── AC1 ────────────────────────────────────────────────────────────────────

  describe "AC1: migration" do
    test "the singleton row exists after provisioning with both latches off; replay is idempotent",
         ctx do
      assert {:ok, %ScriptPolicy{id: 1} = row} = Policy.get(ctx.a.schema_name)
      refute row.tenant_kill_switch
      refute row.platform_kill_switch
      refute Policy.kill_switch_on?(ctx.a.schema_name)
      assert Policy.list_readable_masters(ctx.a.schema_name) == []

      assert {:ok, _applied} = TenantProvisioning.replay_migrations(ctx.a.tenant_id)
      assert Repo.aggregate(ScriptPolicy, :count, prefix: ctx.a.schema_name) == 1
    end

    test "the row cannot be deleted, a second row cannot be inserted, identity columns are immutable",
         ctx do
      schema = ctx.a.schema_name

      assert_lf001(fn -> Repo.delete_all(ScriptPolicy, prefix: schema) end)

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            ~s|INSERT INTO "#{schema}".script_policy (id, inserted_at, updated_at) VALUES (2, now(), now())|
          )
        end

      assert error.postgres.pg_code == "23514"
      assert error.postgres.constraint == "script_policy_singleton"

      assert_lf001(fn ->
        Repo.query!(
          ~s|UPDATE "#{schema}".script_policy SET inserted_at = now() - interval '1 day'|
        )
      end)

      assert Repo.aggregate(ScriptPolicy, :count, prefix: schema) == 1
    end

    test "script_readable_masters checks the entity type format and the reason length", ctx do
      schema = ctx.a.schema_name

      for {entity_type, reason, constraint} <- [
            {"Bad-Type", "r", "script_readable_masters_entity_type_format"},
            {"ok_type", String.duplicate("r", 501), "script_readable_masters_reason_length"}
          ] do
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.query!(
              ~s[INSERT INTO "#{schema}".script_readable_masters (entity_type, set_by, set_at, reason, inserted_at) VALUES ($1, gen_random_uuid(), now(), $2, now())],
              [entity_type, reason]
            )
          end

        assert error.postgres.constraint == constraint
      end
    end
  end

  # ── AC4 / SEC F4 ───────────────────────────────────────────────────────────

  describe "AC4: two latches" do
    test "effective = OR; the tenant admin cannot clear an operator stop; the operator cannot clear the tenant's",
         ctx do
      schema = ctx.a.schema_name

      operator = %{
        user_id: Ecto.UUID.generate(),
        credential: :oidc,
        platform_prefix: ctx.b.schema_name
      }

      assert {:ok, _} =
               Policy.set_platform_kill_switch(
                 schema,
                 ctx.a.tenant_id,
                 true,
                 "incident",
                 operator
               )

      assert Policy.kill_switch_on?(schema)

      # the tenant latch is already off: a tenant "off" is a no-op and the operator stop holds
      assert {:ok, row} = Policy.set_tenant_kill_switch(schema, false, "resume", SP.actor())
      assert row.platform_kill_switch
      assert Policy.kill_switch_on?(schema)

      # the tenant's own stop on top, then off again: the platform latch is untouched
      SP.kill_switch!(schema, true)
      SP.kill_switch!(schema, false)
      assert policy(schema).platform_kill_switch
      assert Policy.kill_switch_on?(schema)

      # the tenant stops; the operator clears its own latch only
      SP.kill_switch!(schema, true)

      assert {:ok, row} =
               Policy.set_platform_kill_switch(schema, ctx.a.tenant_id, false, "done", operator)

      assert row.tenant_kill_switch
      refute row.platform_kill_switch
      assert Policy.kill_switch_on?(schema)

      SP.kill_switch!(schema, false)
      refute Policy.kill_switch_on?(schema)
    end

    test "SEC F4: each latch changeset casts only its own columns", ctx do
      schema = ctx.a.schema_name
      before = policy(schema)

      after_tenant =
        before
        |> ScriptPolicy.tenant_latch_changeset(%{
          tenant_kill_switch: true,
          tenant_kill_switch_reason: "mine",
          platform_kill_switch: true,
          platform_kill_switch_reason: "smuggled",
          platform_kill_switch_set_at: DateTime.utc_now()
        })
        |> Repo.update!(prefix: schema)

      assert after_tenant.tenant_kill_switch
      reloaded = policy(schema)
      refute reloaded.platform_kill_switch
      assert reloaded.platform_kill_switch_reason == nil
      assert reloaded.platform_kill_switch_set_at == nil

      reloaded
      |> ScriptPolicy.platform_latch_changeset(%{
        platform_kill_switch: true,
        tenant_kill_switch: false,
        tenant_kill_switch_reason: "smuggled",
        tenant_kill_switch_set_by: Ecto.UUID.generate()
      })
      |> Repo.update!(prefix: schema)

      final = policy(schema)
      assert final.platform_kill_switch
      assert final.tenant_kill_switch
      assert final.tenant_kill_switch_reason == "mine"
      assert final.tenant_kill_switch_set_by == nil
    end
  end

  # ── writes: audit shape, refusals ──────────────────────────────────────────

  describe "latch writes" do
    test "the tenant latch audits once in the section 7 shape; a no-op and a refusal audit nothing",
         ctx do
      schema = ctx.a.schema_name
      user = Ecto.UUID.generate()

      assert {:ok, row} = Policy.set_tenant_kill_switch(schema, true, "  stop  ", SP.actor(user))
      assert row.tenant_kill_switch_set_by == user
      assert row.tenant_kill_switch_reason == "stop"
      assert %DateTime{} = row.tenant_kill_switch_set_at

      assert [entry] = SP.entries(schema, "script_policy.kill_switch_set")
      assert entry.actor_id == user
      assert entry.resource_type == "script_policy"
      assert entry.resource_id == "1"
      assert entry.trace_id == "script-policy-test-trace"
      assert entry.before_state == %{"tenant_kill_switch" => false}

      assert entry.after_state == %{
               "tenant_kill_switch" => true,
               "reason" => "stop",
               "effective" => true
             }

      assert {:ok, _} = Policy.set_tenant_kill_switch(schema, true, "again", SP.actor())

      for {on, reason, actor, error} <- [
            {false, "x", %{SP.actor() | credential: :api_token}, :api_token_not_allowed},
            {false, "x", %{user_id: user}, :api_token_not_allowed},
            {"false", "x", SP.actor(), :invalid_state},
            {false, "", SP.actor(), :invalid_reason}
          ] do
        assert Policy.set_tenant_kill_switch(schema, on, reason, actor) == {:error, error}
      end

      assert length(SP.policy_entries(schema)) == 1
      assert policy(schema).tenant_kill_switch
    end

    test "the platform latch writes a nil-actor tenant entry and an operator platform entry; an unverifiable platform prefix writes nothing",
         ctx do
      schema = ctx.a.schema_name
      operator_id = Ecto.UUID.generate()

      for operator <- [
            %{user_id: operator_id, credential: :oidc, platform_prefix: nil},
            %{user_id: operator_id, credential: :oidc}
          ] do
        assert Policy.set_platform_kill_switch(schema, ctx.a.tenant_id, true, "x", operator) ==
                 {:error, :audit_failed}
      end

      assert Policy.set_platform_kill_switch(
               schema,
               ctx.a.tenant_id,
               true,
               "x",
               %{user_id: operator_id, credential: :api_token, platform_prefix: ctx.b.schema_name}
             ) == {:error, :api_token_not_allowed}

      refute policy(schema).platform_kill_switch
      assert SP.policy_entries(schema) == []

      operator = %{
        user_id: operator_id,
        credential: :oidc,
        trace_id: "op-trace",
        platform_prefix: ctx.b.schema_name
      }

      assert {:ok, row} =
               Policy.set_platform_kill_switch(
                 schema,
                 ctx.a.tenant_id,
                 true,
                 "incident",
                 operator
               )

      assert row.platform_kill_switch_reason == "incident"

      assert [tenant_entry] = SP.entries(schema, "script_policy.platform_kill_switch_set")
      assert tenant_entry.actor_id == nil
      assert tenant_entry.trace_id == nil
      assert tenant_entry.before_state == %{"platform_kill_switch" => false}

      assert tenant_entry.after_state == %{
               "platform_kill_switch" => true,
               "reason" => "incident",
               "effective" => true,
               "actor_class" => "platform_operator"
             }

      assert [platform_entry] =
               SP.entries(ctx.b.schema_name, "platform.tenant_script_kill_switch.set")

      assert platform_entry.actor_id == operator_id
      assert platform_entry.trace_id == "op-trace"
      assert platform_entry.resource_type == "tenant"
      assert platform_entry.resource_id == ctx.a.tenant_id

      assert platform_entry.after_state == %{
               "tenant_id" => ctx.a.tenant_id,
               "platform_kill_switch" => true,
               "reason" => "incident"
             }

      # no-op: nothing more in either chain
      assert {:ok, _} =
               Policy.set_platform_kill_switch(schema, ctx.a.tenant_id, true, "again", operator)

      assert length(SP.policy_entries(schema)) == 1
      assert length(SP.entries(ctx.b.schema_name, "platform.tenant_script_kill_switch.set")) == 1
    end
  end

  # ── AC13 ───────────────────────────────────────────────────────────────────

  describe "AC13: fail closed" do
    test "kill_switch_on?/1 is true and get/1 is :not_found when the row is absent", ctx do
      schema = ctx.a.schema_name

      Repo.query!(~s(ALTER TABLE "#{schema}".script_policy DISABLE TRIGGER script_policy_guard))

      try do
        Repo.delete_all(ScriptPolicy, prefix: schema)
        assert Policy.kill_switch_on?(schema)
        assert Policy.get(schema) == {:error, :not_found}

        assert Policy.set_tenant_kill_switch(schema, true, "x", SP.actor()) ==
                 {:error, :not_found}
      after
        Repo.query!(
          ~s|INSERT INTO "#{schema}".script_policy (id, inserted_at, updated_at) VALUES (1, now(), now()) ON CONFLICT DO NOTHING|
        )

        Repo.query!(~s(ALTER TABLE "#{schema}".script_policy ENABLE TRIGGER script_policy_guard))
      end
    end

    test "check_reads/2 refuses every run-time cause of section 8 item 2", ctx do
      schema = ctx.a.schema_name

      SP.active_definition!(schema, "customer")
      SP.flag!(schema, "customer")
      read = SP.id_read("cust", "customer", ["name", "tier"])
      ok = SP.manifest([read])

      assert Policy.check_reads(schema, ok) == :ok
      assert Policy.check_reads(schema, SP.manifest([])) == :ok
      assert Policy.check_reads(schema, Map.delete(ok, "reads")) == :ok

      # unflagged
      SP.active_definition!(schema, "vendor")

      assert Policy.check_reads(schema, SP.manifest([SP.id_read("v", "vendor")])) ==
               {:error, :reads_not_allowed}

      # flagged but no ACTIVE definition (created, never activated)
      SP.inactive_definition!(schema, "draft_type")
      SP.flag_raw!(schema, "draft_type")

      assert Policy.check_reads(schema, SP.manifest([SP.id_read("d", "draft_type")])) ==
               {:error, :reads_not_allowed}

      # flagged, active, then type-restricted
      SP.active_definition!(schema, "secret")
      SP.flag!(schema, "secret")
      assert Policy.check_reads(schema, SP.manifest([SP.id_read("s", "secret")])) == :ok
      SP.restrict_type!(schema, "secret")

      assert Policy.check_reads(schema, SP.manifest([SP.id_read("s", "secret")])) ==
               {:error, :reads_not_allowed}

      # a declared field gone since publish (a newer active version drops "tier")
      SP.active_definition!(schema, "customer", ["name", "ssn"])
      assert Policy.check_reads(schema, ok) == {:error, :reads_not_allowed}
      assert Policy.check_reads(schema, SP.manifest([SP.id_read("cust", "customer")])) == :ok

      # P12: a restricted match field not opted in (restriction added after publish)
      by_ssn = SP.field_read("by_ssn", "customer", "ssn")
      assert Policy.check_reads(schema, SP.manifest([by_ssn])) == :ok
      SP.restrict_field!(schema, "customer", "ssn")
      assert Policy.check_reads(schema, SP.manifest([by_ssn])) == {:error, :reads_not_allowed}

      opted_in =
        SP.field_read("by_ssn", "customer", "ssn", %{
          "fields" => ["name", "ssn"],
          "restricted_fields" => ["ssn"]
        })

      assert Policy.check_reads(schema, SP.manifest([opted_in])) == :ok

      # a restricted field only in `fields` is not refused (7c redacts it)
      assert Policy.check_reads(schema, SP.manifest([SP.id_read("c", "customer", ["ssn"])])) ==
               :ok

      # one bad entry refuses the whole manifest
      assert Policy.check_reads(schema, SP.manifest([read, SP.id_read("v", "vendor")])) ==
               {:error, :reads_not_allowed}

      # cleared flag
      assert {:ok, _} = Policy.clear_readable_master(schema, "customer", "off", SP.actor())

      assert Policy.check_reads(schema, SP.manifest([SP.id_read("cust", "customer")])) ==
               {:error, :reads_not_allowed}

      # malformed manifests fail closed
      assert Policy.check_reads(schema, %{"reads" => "x"}) == {:error, :reads_not_allowed}
      assert Policy.check_reads(schema, nil) == {:error, :reads_not_allowed}
    end
  end

  # ── references/2 ───────────────────────────────────────────────────────────

  describe "references/2" do
    test "lists published and retired versions only, capped at 100 with the total", ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      SP.flag!(schema, "customer")

      statuses = ["published", "retired", "draft", "discarded", "revoked"]

      for {status, i} <- Enum.with_index(statuses) do
        insert_rule!(schema, "ref_#{i}", status, SP.manifest([SP.id_read("cust", "customer")]))
      end

      # a version reading another type is not a reference
      insert_rule!(schema, "ref_other", "published", SP.manifest([SP.id_read("v", "vendor")]))

      assert Policy.references(schema, "customer") ==
               {[
                  %{key: "ref_0", version: 1, status: "published"},
                  %{key: "ref_1", version: 1, status: "retired"}
                ], 2}

      for i <- 1..100 do
        insert_rule!(
          schema,
          "zz_#{String.pad_leading("#{i}", 3, "0")}",
          "published",
          SP.manifest([SP.id_read("cust", "customer")])
        )
      end

      {items, total} = Policy.references(schema, "customer")
      assert total == 102
      assert length(items) == 100
      assert hd(items).key == "ref_0"
      assert List.last(items).key == "zz_098"
    end
  end

  # ── AC9 ────────────────────────────────────────────────────────────────────

  describe "AC9: publish vs clear" do
    test "a publish holding FOR SHARE on the master row blocks a concurrent clear until commit; the clear then lists it",
         ctx do
      schema = ctx.a.schema_name
      SP.active_definition!(schema, "customer")
      SP.flag!(schema, "customer")
      k = key()

      assert {:ok, draft} =
               Scripts.create_draft(
                 schema,
                 k,
                 body([SP.id_read("cust", "customer")]),
                 SP.actor()
               )

      test_pid = self()

      publisher =
        Task.async(fn ->
          Repo.transaction(fn ->
            :ok = Policy.check_reads(schema, draft.manifest, lock: :share)

            {1, _} =
              Repo.update_all(
                from(r in ScriptRule, where: r.key == ^k and r.version == 1),
                [
                  set: [
                    status: "published",
                    publisher_id: Ecto.UUID.generate(),
                    published_at: DateTime.utc_now()
                  ]
                ],
                prefix: schema
              )

            send(test_pid, :share_lock_held)

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive :share_lock_held, 10_000

      clearer =
        Task.async(fn ->
          Policy.clear_readable_master(schema, "customer", "narrow", SP.actor())
        end)

      # still waiting on the share lock
      assert Task.yield(clearer, 500) == nil

      send(publisher.pid, :commit)
      assert {:ok, :ok} = Task.await(publisher, 10_000)

      assert {:ok, %{referenced_by: refs, referenced_total: 1}} = Task.await(clearer, 10_000)
      assert refs == [%{key: k, version: 1, status: "published"}]

      assert [entry] = SP.entries(schema, "script_policy.readable_master_cleared")

      assert entry.after_state["referenced_by"] == [
               %{"key" => k, "version" => 1, "status" => "published"}
             ]

      refute Repo.get(ReadableMaster, "customer", prefix: schema)
    end
  end

  defp insert_rule!(schema, key, status, manifest) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ScriptRule{
        id: Ecto.UUID.generate(),
        key: key,
        version: 1,
        hook_kind: "service_task",
        status: status,
        source: @source,
        manifest: manifest,
        test_cases: @cases,
        sha256: "x",
        contributors: [Ecto.UUID.generate()],
        publisher_id: if(status in ["published", "retired", "revoked"], do: Ecto.UUID.generate()),
        published_at: if(status in ["published", "retired", "revoked"], do: now)
      },
      prefix: schema
    )
  end
end
