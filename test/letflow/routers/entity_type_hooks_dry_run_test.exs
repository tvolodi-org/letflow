defmodule Letflow.Routers.EntityTypeHooksDryRunTest do
  @moduledoc """
  REQ-633 (GH #3530, decision 0065 D9 E-5) part A, criteria 1-5 and 10: `POST
  /entity-type-hooks/:entity_type/dry-run`. A: route and permission; P: who may call it; N: nothing
  is written; D: the derived reply; T: INV-1 tenant prefix; V: validation; X: one 404.

  `async: false`: tenants are provisioned and the platform tenant pin is VM-global. The scripts
  run in the real sandbox (long `timeout_ms`, the runner deadline includes worker spawn).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Audit.Entry
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks
  alias Letflow.Routers.EntityTypeHooks, as: Router
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @auditor ["TENANT_AUDITOR"]
  @master "customer"
  @type_name "tt"

  @manifest %{
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"tier" => %{"type" => "string"}}
    },
    "output_schema" => %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "additionalProperties" => false
    },
    "derived_fields" => ["name"],
    "fail_codes" => [],
    "limits" => %{"instructions" => 200_000, "timeout_ms" => 5_000},
    "reads" => [
      %{
        "name" => "r",
        "entity_type" => "customer",
        "match" => %{"field" => "tier", "value_from" => "tier"},
        "fields" => ["name"],
        "limit" => 5
      }
    ]
  }

  @source """
  local rows = ctx.input.reads.r
  local first = rows[1]
  if first == nil then return {name = 'none'} end
  return {name = first.name}
  """

  setup do
    a = tenant!("r633a")
    b = tenant!("r633b")
    Fixture.pin!(F.tenant!("r633p").tenant_id)
    bind!(a, "ann")
    bind!(b, "bob")
    {:ok, a: a, b: b}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # A tenant with an HMAC key, the hooked type `tt`, and a readable master type with one row.
  defp tenant!(slug) do
    t = F.tenant!(slug)
    schema = t.schema_name
    assert {:ok, _} = Letflow.Entities.EventTypes.seed!(schema)
    P.active_definition!(schema, @master)
    P.active_definition!(schema, @type_name, ["name", "tier"])
    P.flag!(schema, @master)
    t
  end

  defp bind!(t, master_name) do
    schema = t.schema_name
    master!(schema, master_name)

    rule =
      F.published!(schema, "derive#{System.unique_integer([:positive])}", @source, @manifest,
        hook_kind: "entity_write"
      )

    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    actor = %{user_id: Ecto.UUID.generate(), credential: :oidc}
    assert {:ok, _} = EntityTypeHooks.bind(schema, @type_name, pin, actor)
    :ok
  end

  defp master!(schema, name) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: @master,
                 field_values: %{"name" => name, "tier" => "gold"},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record.record_id
  end

  defp call(path, fixture, roles, body, opts \\ []) do
    conn =
      Fixture.router_conn(:post, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: Keyword.get(opts, :credential, :oidc)
      })

    Router.call(conn, Router.init([]))
  end

  defp dry(
         fixture,
         type \\ @type_name,
         body \\ %{"candidate" => %{"tier" => "gold"}},
         roles \\ @admin
       ),
       do: call("/#{type}/dry-run", fixture, roles, body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Row count of every table of the tenant schema.
  defp snapshot(schema) do
    %{rows: tables} =
      Repo.query!("SELECT table_name FROM information_schema.tables WHERE table_schema = $1", [
        schema
      ])

    Map.new(tables, fn [table] ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".\"#{table}\"")
      {table, n}
    end)
  end

  defp audits(schema), do: Repo.aggregate(Entry, :count, :id, prefix: schema)

  defp count_reads(test_pid),
    do: Application.put_env(:letflow, :entity_write_before_reads, fn -> send(test_pid, :ran) end)

  setup do
    on_exit(fn -> Application.delete_env(:letflow, :entity_write_before_reads) end)
    :ok
  end

  # ── A: route and permission ────────────────────────────────────────────────

  describe "A route and permission" do
    test "A1 policy key and permission" do
      assert Authorization.endpoint_policy_key("POST", "/entity-type-hooks/:entity_type/dry-run") ==
               :EntityTypeHooksDryRun

      assert Authorization.required_permission(:EntityTypeHooksDryRun) == :ScriptsWrite

      assert {"POST", "/:entity_type/dry-run", :EntityTypeHooksDryRun} in Router.__authz_routes__()
    end
  end

  # ── P: who may call ────────────────────────────────────────────────────────

  describe "P permission and credential" do
    test "P1 TENANT_ADMIN gets 200", %{a: a} do
      conn = dry(a)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["outcome"] == "ok"
    end

    test "P2 a caller without ScriptsWrite gets the bindings-list refusal", %{a: a} do
      list = Router.call(Fixture.router_conn(:get, "/", a, @auditor, nil), Router.init([]))
      assert list.status == 403

      for roles <- [@auditor, []] do
        conn = dry(a, @type_name, %{"candidate" => %{}}, roles)
        assert conn.status == 403
        assert conn.resp_body == list.resp_body
      end
    end

    test "P3 PROCESS_DESIGNER holds ScriptsWrite", %{a: a} do
      assert dry(a, @type_name, %{"candidate" => %{"tier" => "gold"}}, @designer).status == 200
    end

    test "P4 an API token is refused and nothing runs", %{a: a} do
      count_reads(self())
      conn = call("/tt/dry-run", a, @admin, %{"candidate" => %{}}, credential: :api_token)
      assert conn.status == 403

      assert json(conn)["detail"] == "api_token_not_allowed" or
               json(conn)["code"] == "api_token_not_allowed"

      refute_received :ran
    end
  end

  # ── N: nothing is written ──────────────────────────────────────────────────

  describe "N no write" do
    # part B: the one write of a run is its `audit_entries` row (see the part B test file)
    test "N1 every table but the audit log keeps its row count", %{a: a} do
      before = snapshot(a.schema_name)
      assert dry(a).status == 200
      assert dry(a, @type_name, %{"candidate" => %{"tier" => "none"}}).status == 200
      after_run = snapshot(a.schema_name)
      assert Map.delete(after_run, "audit_entries") == Map.delete(before, "audit_entries")
      assert after_run["audit_entries"] == before["audit_entries"] + 2
    end

    test "N2 the context function and the action reference no write path" do
      source = File.read!("lib/letflow/entity_type_hooks.ex")
      [_, rest] = String.split(source, "def dry_run(", parts: 2)
      body = rest |> String.split(~r/\n  # ── shared path/, parts: 2) |> hd()

      for needle <- [
            "Records.",
            "EventStore.",
            "Multi.new",
            "Repo.insert",
            "Repo.update",
            "Repo.delete",
            "lock_instance_sequence"
          ] do
        refute body =~ needle, needle
      end

      router = File.read!("lib/letflow/routers/entity_type_hooks.ex")
      [_, action] = String.split(router, ~s(authz_post "/:entity_type/dry-run"), parts: 2)
      action = action |> String.split("authz_unmatched", parts: 2) |> hd()
      refute action =~ "Records."
      refute action =~ "Repo."
    end
  end

  # ── D: the derived reply ───────────────────────────────────────────────────

  describe "D derived output" do
    test "D1 derived comes from the seeded tenant row", %{a: a} do
      conn = dry(a)
      assert %{"outcome" => "ok", "derived" => %{"name" => "ann"}} = json(conn)

      # a different candidate that matches no row: the script's own fallback
      assert %{"derived" => %{"name" => "none"}} =
               a |> dry(@type_name, %{"candidate" => %{"tier" => "silver"}}) |> json()
    end

    test "D2 the reply has the allowlisted keys only", %{a: a} do
      body = a |> dry() |> json()
      assert Enum.sort(Map.keys(body)) == ["derived", "outcome", "stats"]

      assert Enum.sort(Map.keys(body["stats"])) == [
               "duration_us",
               "heap_words_at_end",
               "instructions_used"
             ]

      encoded = Jason.encode!(body)
      refute encoded =~ "fingerprint"
      refute encoded =~ "local rows"
    end
  end

  # ── T: INV-1 ───────────────────────────────────────────────────────────────

  describe "T tenant prefix" do
    test "T1 same key, different values: each tenant reads its own", %{a: a, b: b} do
      assert %{"derived" => %{"name" => "ann"}} = a |> dry() |> json()
      assert %{"derived" => %{"name" => "bob"}} = b |> dry() |> json()
    end

    test "T2 a tenant in the body is refused and a tenant in the query is ignored", %{a: a, b: b} do
      count_reads(self())
      conn = dry(a, @type_name, %{"candidate" => %{}, "tenant_id" => b.tenant_id})
      assert conn.status == 422
      refute_received :ran

      conn =
        Fixture.router_conn(
          :post,
          "/tt/dry-run?tenant_id=#{b.tenant_id}&prefix=#{b.schema_name}",
          a,
          @admin,
          %{
            "candidate" => %{"tier" => "gold"}
          }
        )
        |> Plug.Conn.assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: a.tenant_id,
          roles: @admin,
          credential: :oidc
        })
        |> Router.call(Router.init([]))

      assert %{"derived" => %{"name" => "ann"}} = json(conn)
    end
  end

  # ── V: validation ──────────────────────────────────────────────────────────

  describe "V validation" do
    @bad_bodies [
      %{},
      %{"_json" => []},
      %{"candidate" => []},
      %{"candidate" => 1},
      %{"candidate" => %{}, "extra" => 1},
      %{"candidate" => %{}, "tenant_id" => "t"}
    ]

    test "V1 a bad body answers 422 invalid_input, no run and no audit row", %{a: a} do
      count_reads(self())
      before = audits(a.schema_name)

      for type <- [@type_name, "unbound_type", "absent_type"], body <- @bad_bodies do
        conn = dry(a, type, body)
        assert conn.status == 422, inspect({type, body})
        assert conn.resp_body =~ "invalid_input"
      end

      refute_received :ran
      assert audits(a.schema_name) == before
    end

    test "V2 a non-string candidate key is script_rejected before the sandbox", %{a: a} do
      count_reads(self())
      actor = %{user_id: Ecto.UUID.generate(), credential: :oidc}

      assert {:ok, %{outcome: "script_rejected"}} =
               EntityTypeHooks.dry_run(a.schema_name, @type_name, %{1 => "x"}, actor)

      refute_received :ran
    end

    test "V3 an empty candidate is valid", %{a: a} do
      assert dry(a, @type_name, %{"candidate" => %{}}).status == 200
    end
  end

  # ── X: one 404 ─────────────────────────────────────────────────────────────

  describe "X not found" do
    test "X1 unbound, absent and foreign types answer the same 404", %{a: a, b: b} do
      P.active_definition!(a.schema_name, "unbound_type", ["name"])
      only_a = "only_a"
      P.active_definition!(a.schema_name, only_a, ["name"])

      responses =
        for {fixture, type} <- [{a, "unbound_type"}, {a, "absent_type"}, {b, only_a}] do
          conn = dry(fixture, type)
          {conn.status, conn.resp_body}
        end

      assert [{404, _body}] = Enum.uniq(responses)
    end
  end
end
