defmodule Letflow.Scripts.ScriptsReadsAndKillSwitchTest do
  @moduledoc """
  GH 2534 PR 7b-2a, design `lib/letflow/design/gh2534-7b2a-script-policy.md` sections 3-5 and 12
  ("Extend the 7b-1 suites"), at the `Letflow.Scripts` context:

    * AC5: the kill switch refuses publish before any test case; a switch turned on between two
      stored cases (the `:before_case` seam) stops the publish before case 2; the seam is
      ignored when `:scripts_test_hooks` is not true; dry-run is refused without running or
      auditing.
    * AC8: a read of an unflagged / inactive / type-restricted type or an unknown field is
      `:reads_not_allowed` at save AND at publish; a flag cleared between save and publish
      refuses the publish (pre-check, and in the transaction via the seam).
    * AC10: a script reading `ctx.input.reads.<name>` passes its stored tests with fixtures;
      dry-run uses a fixture and performs no entity query (query capture).
    * AC11 / AC11a: `restricted_fields` needs `:EntitiesRestrictionsManage` at publish; a
      restricted `match.field` must be opted in (save, publish pre-check, publish transaction);
      a restricted field only in `fields` is accepted.

  `async: false`: provisioning switches the sandbox to `:auto`; one test flips application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Scripts
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.TenantFixture

  # Reads the first row of the `cust` read; "none" when the read delivered no row.
  @source """
  local rows = ctx.input.reads.cust
  local first = rows[1]
  if first == nil then return {name = 'none'} end
  return {name = first.name}
  """

  @two_cases [
    %{
      "name" => "with_fixture",
      "input" => %{"cid" => "c1"},
      "reads" => %{"cust" => [%{"id" => "c1", "name" => "Ann"}]},
      "expect" => %{"output" => %{"name" => "Ann"}}
    },
    %{
      "name" => "no_fixture",
      "input" => %{"cid" => "c2"},
      "expect" => %{"output" => %{"name" => "none"}}
    }
  ]

  setup do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7b2a-ctx")
    schema = fixture.schema_name
    SP.active_definition!(schema, "customer")
    SP.flag!(schema, "customer")
    {:ok, schema: schema, fixture: fixture}
  end

  defp body(reads, overrides \\ %{}) do
    Map.merge(
      %{
        "hook_kind" => "service_task",
        "source" => @source,
        "manifest" => SP.manifest(reads),
        "test_cases" => @two_cases
      },
      overrides
    )
  end

  defp cust(fields \\ ["name"]), do: SP.id_read("cust", "customer", fields)

  defp key, do: "rule_#{System.unique_integer([:positive])}"

  defp draft!(schema, reads, overrides \\ %{}) do
    k = key()
    assert {:ok, rule} = Scripts.create_draft(schema, k, body(reads, overrides), SP.actor())
    rule
  end

  defp publish(schema, rule, may_restricted? \\ true, opts \\ []) do
    Scripts.publish(
      schema,
      rule.key,
      rule.version,
      rule.sha256,
      SP.actor(),
      may_restricted?,
      opts
    )
  end

  defp status(schema, rule),
    do: Repo.get_by!(ScriptRule, [key: rule.key, version: rule.version], prefix: schema).status

  # ── AC10 ───────────────────────────────────────────────────────────────────

  describe "AC10: fixtures reach the script" do
    test "a script reading input.reads passes its stored tests (fixture and absent read)", ctx do
      rule = draft!(ctx.schema, [cust()])
      assert {:ok, published} = publish(ctx.schema, rule)
      assert published.status == "published"
      assert published.test_cases == @two_cases
    end

    test "a stored case whose expectation needs the fixture fails without it", ctx do
      cases = [Map.delete(hd(@two_cases), "reads")]
      rule = draft!(ctx.schema, [cust()], %{"test_cases" => cases})

      assert {:error, :test_case_failed, %{name: "with_fixture", outcome: "output_mismatch"}} =
               publish(ctx.schema, rule)
    end

    test "dry-run runs on a fixture and issues no entity query", ctx do
      rule = draft!(ctx.schema, [cust()])

      {result, queries} =
        Fixture.capture_repo_queries(fn ->
          Scripts.dry_run(
            ctx.schema,
            rule.key,
            rule.version,
            %{"cid" => "c9"},
            %{"cust" => [%{"name" => "Zed"}]},
            SP.actor()
          )
        end)

      assert {:ok, %{outcome: "ok", output: %{"name" => "Zed"}}} = result

      sql = Enum.map(queries, &(Map.get(&1, :query) || ""))
      assert sql != []

      refute Enum.any?(
               sql,
               &(&1 =~ ~r/entity_record|entity_definitions|entity_type_instances|"entity_/)
             ),
             Enum.join(sql, "\n")

      refute Enum.any?(sql, &(&1 =~ "script_readable_masters"))

      # no fixture: the declared read is []
      assert {:ok, %{output: %{"name" => "none"}}} =
               Scripts.dry_run(
                 ctx.schema,
                 rule.key,
                 rule.version,
                 %{"cid" => "c9"},
                 nil,
                 SP.actor()
               )

      # an invalid fixture is invalid_input
      assert Scripts.dry_run(
               ctx.schema,
               rule.key,
               rule.version,
               %{"cid" => "c9"},
               %{"other" => []},
               SP.actor()
             ) == {:error, :invalid_input}
    end

    test "a stored case with an invalid fixture is refused at save", ctx do
      bad = [Map.put(hd(@two_cases), "reads", %{"cust" => [%{"ssn" => "1"}]})]

      assert Scripts.create_draft(
               ctx.schema,
               key(),
               body([cust()], %{"test_cases" => bad}),
               SP.actor()
             ) ==
               {:error, :invalid_test_case}
    end
  end

  # ── AC8 ────────────────────────────────────────────────────────────────────

  describe "AC8: reads checked at save and at publish" do
    test "unflagged, inactive and type-restricted types and unknown fields are refused at save",
         ctx do
      schema = ctx.schema
      SP.active_definition!(schema, "vendor")
      SP.inactive_definition!(schema, "draft_type")
      SP.flag_raw!(schema, "draft_type")
      SP.active_definition!(schema, "secret")
      SP.flag!(schema, "secret")
      SP.restrict_type!(schema, "secret")

      for read <- [
            SP.id_read("cust", "vendor"),
            SP.id_read("cust", "draft_type"),
            SP.id_read("cust", "secret"),
            SP.id_read("cust", "customer", ["name", "nope"]),
            SP.field_read("cust", "customer", "nope")
          ] do
        assert Scripts.create_draft(schema, key(), body([read]), SP.actor()) ==
                 {:error, :reads_not_allowed},
               inspect(read)
      end

      # save_draft too
      rule = draft!(schema, [cust()])

      assert Scripts.save_draft(
               schema,
               rule.key,
               rule.version,
               body([SP.id_read("cust", "vendor")]),
               SP.actor()
             ) ==
               {:error, :reads_not_allowed}

      assert {:ok, _} =
               Scripts.save_draft(schema, rule.key, rule.version, body([cust()]), SP.actor())
    end

    test "a flag cleared between save and publish refuses the publish (pre-check)", ctx do
      rule = draft!(ctx.schema, [cust()])
      assert {:ok, _} = Policy.clear_readable_master(ctx.schema, "customer", "narrow", SP.actor())

      assert publish(ctx.schema, rule) == {:error, :reads_not_allowed}
      assert status(ctx.schema, rule) == "draft"
    end

    test "a flag cleared while the stored tests run refuses the publish in its transaction",
         ctx do
      rule = draft!(ctx.schema, [cust()])

      clear = fn
        2 ->
          {:ok, _} = Policy.clear_readable_master(ctx.schema, "customer", "narrow", SP.actor())
          :ok

        _ ->
          :ok
      end

      assert publish(ctx.schema, rule, true, before_case: clear) == {:error, :reads_not_allowed}
      assert status(ctx.schema, rule) == "draft"
    end
  end

  # ── AC11 / AC11a ───────────────────────────────────────────────────────────

  describe "AC11 / AC11a: restricted fields" do
    test "a non-empty restricted_fields needs the publisher's EntitiesRestrictionsManage", ctx do
      read =
        SP.id_read("cust", "customer", ["name", "ssn"]) |> Map.put("restricted_fields", ["ssn"])

      rule = draft!(ctx.schema, [read])

      assert publish(ctx.schema, rule, false) == {:error, :restricted_inputs_not_allowed}
      assert {:ok, _} = publish(ctx.schema, rule, true)
    end

    test "a restricted match.field must be opted in (save); opted in it needs the publisher check",
         ctx do
      schema = ctx.schema
      SP.restrict_field!(schema, "customer", "ssn")
      by_ssn = SP.field_read("cust", "customer", "ssn")

      assert Scripts.create_draft(schema, key(), body([by_ssn]), SP.actor()) ==
               {:error, :reads_not_allowed}

      opted_in =
        SP.field_read("cust", "customer", "ssn", %{
          "fields" => ["name", "ssn"],
          "restricted_fields" => ["ssn"]
        })

      rule = draft!(schema, [opted_in])
      assert publish(schema, rule, false) == {:error, :restricted_inputs_not_allowed}
      assert {:ok, _} = publish(schema, rule, true)

      # a restricted field only in `fields` is accepted at save and publish (7c redacts it)
      plain = draft!(schema, [cust(["name", "ssn"])])
      assert {:ok, _} = publish(schema, plain, false)
    end

    test "a restriction on match.field added between save and publish refuses the publish (pre-check and in the transaction); added after publish check_reads refuses",
         ctx do
      schema = ctx.schema
      by_tier = SP.field_read("cust", "customer", "tier")

      before_publish = draft!(schema, [by_tier])
      SP.restrict_field!(schema, "customer", "tier")
      assert publish(schema, before_publish) == {:error, :reads_not_allowed}

      # in the transaction: the restriction lands while the stored tests run
      by_name = SP.field_read("cust", "customer", "name")
      during = draft!(schema, [by_name])

      restrict = fn
        2 -> SP.restrict_field!(schema, "customer", "name")
        _ -> :ok
      end

      assert publish(schema, during, true, before_case: restrict) == {:error, :reads_not_allowed}
      assert status(schema, during) == "draft"

      # after publish: the 7c run-time check refuses
      SP.active_definition!(schema, "order", ["name", "tier", "ssn"])
      SP.flag!(schema, "order")
      by_ssn = SP.field_read("cust", "order", "ssn")
      published = draft!(schema, [by_ssn])
      assert {:ok, published} = publish(schema, published)
      assert Policy.check_reads(schema, published.manifest) == :ok
      SP.restrict_field!(schema, "order", "ssn")
      assert Policy.check_reads(schema, published.manifest) == {:error, :reads_not_allowed}
    end
  end

  # ── AC5 ────────────────────────────────────────────────────────────────────

  describe "AC5: kill switch at the context" do
    test "publish is refused before any test case runs", ctx do
      rule = draft!(ctx.schema, [cust()])
      SP.kill_switch!(ctx.schema, true)
      test_pid = self()

      assert publish(ctx.schema, rule, true, before_case: &send(test_pid, {:case, &1})) ==
               {:error, :scripts_disabled}

      refute_received {:case, _}
      assert status(ctx.schema, rule) == "draft"
    end

    test "a switch turned on between two cases stops the publish before case 2", ctx do
      # case 2 would FAIL if it ran: without the switch the same publish is test_case_failed
      broken = [hd(@two_cases), put_in(Enum.at(@two_cases, 1), ["expect", "output", "name"], "x")]
      rule = draft!(ctx.schema, [cust()], %{"test_cases" => broken})

      assert {:error, :test_case_failed, %{name: "no_fixture"}} = publish(ctx.schema, rule)

      test_pid = self()

      switch_on = fn
        2 ->
          send(test_pid, {:case, 2})
          SP.kill_switch!(ctx.schema, true)

        index ->
          send(test_pid, {:case, index})
          :ok
      end

      assert publish(ctx.schema, rule, true, before_case: switch_on) ==
               {:error, :scripts_disabled}

      assert_received {:case, 1}
      assert_received {:case, 2}
      assert status(ctx.schema, rule) == "draft"
    end

    test "the :before_case seam is ignored unless :scripts_test_hooks is true", ctx do
      original = Application.fetch_env(:letflow, :scripts_test_hooks)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:letflow, :scripts_test_hooks, value)
          :error -> Application.delete_env(:letflow, :scripts_test_hooks)
        end
      end)

      test_pid = self()

      switch_on = fn index ->
        send(test_pid, {:case, index})
        SP.kill_switch!(ctx.schema, true)
      end

      for value <- [false, "true", nil] do
        Application.put_env(:letflow, :scripts_test_hooks, value)
        rule = draft!(ctx.schema, [cust()])

        assert {:ok, published} = publish(ctx.schema, rule, true, before_case: switch_on),
               inspect(value)

        assert published.status == "published"
        refute_received {:case, _}
        refute Policy.kill_switch_on?(ctx.schema)
      end
    end

    test "dry-run is refused without running and without a dry-run audit; an unknown version is still 404",
         ctx do
      rule = draft!(ctx.schema, [cust()])
      SP.kill_switch!(ctx.schema, true)

      assert Scripts.dry_run(ctx.schema, rule.key, 1, %{"cid" => "c"}, nil, SP.actor()) ==
               {:error, :scripts_disabled}

      assert Scripts.dry_run(ctx.schema, rule.key, 99, %{"cid" => "c"}, nil, SP.actor()) ==
               {:error, :not_found}

      assert Repo.all(
               from(e in Entry, where: e.action == "script_rule.dry_run"),
               prefix: ctx.schema
             ) == []
    end
  end
end
