defmodule Letflow.Routers.EntityTypeHooksDryRunBTest do
  @moduledoc """
  REQ-633 (GH #3530, decision 0065 D9 E-5) part B, criteria 6 to 9 and 11: `POST
  /entity-type-hooks/:entity_type/dry-run`. X: one 404 across tenants (INV-10); O: one test per
  script outcome and the kill switch; R: restricted fields; U: the audit row; D: the docs.

  `async: false`: tenants are provisioned, the platform tenant pin is VM-global, the stub runner
  is application env, and `script_busy` fills the tenant's real admission pool.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks
  alias Letflow.Routers.EntityTypeHooks, as: Router
  alias Letflow.Scripts.EntityWrite
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F

  @admin ["TENANT_ADMIN"]
  @auditor ["TENANT_AUDITOR"]
  @master "customer"
  @t "tt"
  @action "entity_write_hook.dry_run"
  @marker "MARKER-9f3a"

  @manifest %{
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"tier" => %{"type" => "string"}, "memo" => %{"type" => "string"}}
    },
    "output_schema" => %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "additionalProperties" => false
    },
    "derived_fields" => ["name"],
    "fail_codes" => ["too_big"],
    "limits" => %{"instructions" => 200_000, "timeout_ms" => 5_000}
  }

  @reads [
    %{
      "name" => "r",
      "entity_type" => "customer",
      "match" => %{"field" => "tier", "value_from" => "tier"},
      "fields" => ["name"],
      "limit" => 5
    }
  ]

  @read_source """
  local first = ctx.input.reads.r[1]
  if first == nil then return {name = 'none'} end
  return {name = first.name}
  """

  @trivial "return { name = 'x' }"

  defmodule StubRunner do
    @moduledoc false
    def start,
      do: Agent.start_link(fn -> %{pid: nil, reply: nil, inputs: []} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def setup(pid, reply), do: Agent.update(__MODULE__, &%{&1 | pid: pid, reply: reply})
    def inputs, do: Agent.get(__MODULE__, &Enum.reverse(&1.inputs))

    def run(_source, input, _opts) do
      %{pid: pid, reply: reply} =
        Agent.get_and_update(__MODULE__, fn s -> {s, %{s | inputs: [input | s.inputs]}} end)

      send(pid, {:ran, input})
      if is_function(reply, 0), do: reply.(), else: reply
    end
  end

  setup do
    a = tenant!("r633ba")
    b = tenant!("r633bb")
    Fixture.pin!(F.tenant!("r633bp").tenant_id)

    on_exit(fn ->
      Application.delete_env(:letflow, :entity_write_script_runner)
      Application.delete_env(:letflow, :entity_write_before_reads)
    end)

    {:ok, a: a, b: b}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant!(slug) do
    t = F.tenant!(slug)
    schema = t.schema_name
    assert {:ok, _} = Letflow.Entities.EventTypes.seed!(schema)
    P.active_definition!(schema, @master)
    P.active_definition!(schema, @t, ["name", "tier", "memo"])
    P.flag!(schema, @master)
    t
  end

  defp stub!(reply) do
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    Application.put_env(:letflow, :entity_write_script_runner, StubRunner)
    StubRunner.setup(self(), reply)
  end

  defp bind_type!(t, type, key, manifest, source) do
    schema = t.schema_name
    rule = F.published!(schema, key, source, manifest, hook_kind: "entity_write")

    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    actor = %{user_id: Ecto.UUID.generate(), credential: :oidc}
    assert {:ok, _} = EntityTypeHooks.bind(schema, type, pin, actor)
    rule
  end

  defp bind!(t, manifest \\ @manifest, source \\ @trivial),
    do: bind_type!(t, @t, "derive#{System.unique_integer([:positive])}", manifest, source)

  defp master!(schema, name) do
    assert {:ok, _} =
             Records.create_record(
               %{
                 entity_type: @master,
                 field_values: %{"name" => name, "tier" => "gold"},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )
  end

  defp call(path, fixture, roles, body, opts \\ []) do
    conn =
      Fixture.router_conn(:post, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: Keyword.get(opts, :credential, :oidc)
      })

    Router.call(conn, Router.init([]))
  end

  defp dry(fixture, type \\ @t, body \\ %{"candidate" => %{"tier" => "gold"}}, roles \\ @admin),
    do: call("/#{type}/dry-run", fixture, roles, body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

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

  defp hook_rows(schema),
    do: Repo.all(from(e in Entry, where: e.action == ^@action), prefix: schema)

  defp ok_reply(output \\ %{"name" => "x"}),
    do:
      {:ok,
       %{output: output, stats: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}}}

  # ── X: one 404 (INV-10) ────────────────────────────────────────────────────

  describe "X not found across tenants" do
    test "X2 foreign, absent and unbound types answer one 404, no row, no run", %{a: a, b: b} do
      stub!(ok_reply())
      P.active_definition!(b.schema_name, "only_b", ["name"])
      P.active_definition!(a.schema_name, "unbound_a", ["name"])
      bind_type!(b, "only_b", "bkey#{System.unique_integer([:positive])}", @manifest, @trivial)

      audits_a = audits(a.schema_name)
      audits_b = audits(b.schema_name)
      snap_b = snapshot(b.schema_name)

      conns = for type <- ["only_b", "absent_type", "unbound_a"], do: dry(a, type)

      for conn <- conns, do: assert(conn.status == 404)
      assert [_one] = conns |> Enum.map(& &1.resp_body) |> Enum.uniq()

      assert [_one] =
               conns |> Enum.map(&Plug.Conn.get_resp_header(&1, "content-type")) |> Enum.uniq()

      refute_received {:ran, _}
      assert audits(a.schema_name) == audits_a
      assert audits(b.schema_name) == audits_b
      assert snapshot(b.schema_name) == snap_b
    end

    test "X3 a malformed body is 422 before any lookup, never 404", %{a: a, b: b} do
      stub!(ok_reply())
      P.active_definition!(b.schema_name, "only_b", ["name"])
      bind_type!(b, "only_b", "bkey#{System.unique_integer([:positive])}", @manifest, @trivial)
      before = audits(a.schema_name)

      for type <- ["only_b", "absent_type", "unbound_a"], body <- [%{}, %{"candidate" => []}] do
        conn = dry(a, type, body)
        assert conn.status == 422, inspect({type, body})
        assert conn.resp_body =~ "invalid_input"
      end

      refute_received {:ran, _}
      assert audits(a.schema_name) == before
    end
  end

  # ── O: one test per script outcome ─────────────────────────────────────────

  describe "O script outcomes are a plain 200" do
    defp assert_outcome(a, outcome, extra_keys \\ []) do
      conn = dry(a)
      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert body["outcome"] == outcome
      refute Map.has_key?(body, "derived")
      assert Enum.sort(Map.keys(body)) == Enum.sort(["outcome", "stats"] ++ extra_keys)
      refute conn.resp_body =~ "secret-detail"
      body
    end

    test "O1 script_failed with a declared code", %{a: a} do
      bind!(a)

      stub!({:error, :script_failed, %{fail: %{code: "too_big", details: "secret-detail"}}})

      body = assert_outcome(a, "script_failed", ["fail_code"])
      assert body["fail_code"] == "too_big"
    end

    for {id, code} <- [
          {"O2", :script_error},
          {"O3", :budget_exceeded},
          {"O4", :memory_limit_exceeded},
          {"O5", :timeout}
        ] do
      test "#{id} #{code}", %{a: a} do
        bind!(a)
        stub!({:error, unquote(code), %{detail: "secret-detail"}})
        assert_outcome(a, Atom.to_string(unquote(code)))
      end
    end

    test "O6 output_invalid", %{a: a} do
      bind!(a)
      stub!(ok_reply(%{"not_derived" => "secret-detail"}))
      assert_outcome(a, "output_invalid")
    end

    test "O7 script_busy through a full real admission", %{a: a} do
      bind!(a)
      holders = F.hold_all_slots!(a.schema_name)
      assert holders != []

      try do
        assert_outcome(a, "script_busy")
      after
        Enum.each(holders, &Process.exit(&1, :kill))
      end
    end

    test "O9 the tenant kill switch: 200 script_rejected, no run, no read", %{a: a} do
      bind!(a, Map.put(@manifest, "reads", @reads), @read_source)
      stub!(ok_reply())
      pid = self()
      Application.put_env(:letflow, :entity_write_before_reads, fn -> send(pid, :read) end)
      P.kill_switch!(a.schema_name, true)

      assert_outcome(a, "script_rejected")
      refute_received {:ran, _}
      refute_received :read
    end

    test "O9b the platform kill switch: 200 script_rejected, no run, no read", %{a: a} do
      bind!(a, Map.put(@manifest, "reads", @reads), @read_source)
      stub!(ok_reply())
      pid = self()
      Application.put_env(:letflow, :entity_write_before_reads, fn -> send(pid, :read) end)

      {1, _} =
        Repo.update_all(
          from(p in "script_policy",
            where: p.id == 1,
            update: [set: [platform_kill_switch: true]]
          ),
          [],
          prefix: a.schema_name
        )

      assert_outcome(a, "script_rejected")
      refute_received {:ran, _}
      refute_received :read
    end
  end

  # ── R: restricted fields ───────────────────────────────────────────────────

  describe "R restricted fields" do
    defp restricted_manifest(derived) do
      @manifest
      |> Map.put("derived_fields", derived)
      |> put_in(["output_schema", "properties"], %{
        "tier" => %{"type" => "string"},
        "name" => %{"type" => "string"}
      })
      |> Map.put("restricted_inputs", [
        %{"name" => "tier", "from" => [%{"entity_type" => @t, "field" => "tier"}]}
      ])
    end

    test "R1 a restricted field is omitted although the manifest names it", %{a: a} do
      schema = a.schema_name
      P.restrict_field!(schema, @t, "tier")
      rule = bind!(a, restricted_manifest(["tier"]))
      stub!(ok_reply(%{"tier" => "x"}))
      candidate = %{"tier" => "gold-marker", "memo" => "m"}

      assert dry(a, @t, %{"candidate" => candidate}).status == 200
      assert [route_input] = StubRunner.inputs()
      refute Map.has_key?(route_input, "tier")
      assert route_input["memo"] == "m"

      pin = %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}
      facts = %{entity_type: @t, candidate: candidate, now: DateTime.utc_now()}

      assert {:ok, %{derived: %{"tier" => "x"}}} =
               EntityWrite.run(schema, pin, facts, publisher_may_restricted?: false)

      assert [^route_input, direct_input] = StubRunner.inputs()
      assert Map.delete(direct_input, "now") == Map.delete(route_input, "now")

      source = File.read!("lib/letflow/entity_type_hooks.ex")
      refute source =~ "publisher_may_restricted?: true"
    end

    test "R2 a taint reaching an unrestricted target is widened, nothing runs", %{a: a} do
      P.restrict_field!(a.schema_name, @t, "tier")
      bind!(a, restricted_manifest(["name"]))
      stub!(ok_reply())

      conn = dry(a)
      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert body["outcome"] == "script_output_restriction_widened"
      refute Map.has_key?(body, "derived")
      assert body["stats"]["duration_us"] == 0
      refute_received {:ran, _}
    end
  end

  # ── U: the audit row ───────────────────────────────────────────────────────

  describe "U audit row" do
    @keys ~w(duration_us heap_words_at_end hmac_hex hmac_key_version instructions_used outcome_class principal script_key script_sha256 script_version)

    test "U1 one row with the designed key set", %{a: a} do
      master!(a.schema_name, "ann")
      rule = bind!(a, Map.put(@manifest, "reads", @reads), @read_source)
      user = Ecto.UUID.generate()
      before = audits(a.schema_name)

      conn =
        call("/#{@t}/dry-run", a, @admin, %{"candidate" => %{"tier" => "gold"}}, user_id: user)

      assert %{"outcome" => "ok", "derived" => %{"name" => "ann"}} = json(conn)

      assert audits(a.schema_name) == before + 1
      assert [row] = hook_rows(a.schema_name)
      assert row.resource_type == @t and row.resource_id == @t
      assert row.actor_id == user
      assert row.before_state == nil
      assert row.after_state |> Map.keys() |> Enum.sort() == Enum.sort(@keys)
      assert row.after_state["principal"] == "tenant_wide"
      assert row.after_state["outcome_class"] == "ok"
      assert row.after_state["script_key"] == rule.key
      assert row.after_state["script_version"] == rule.version
      assert row.after_state["script_sha256"] == rule.sha256
      assert is_binary(row.after_state["hmac_hex"])
      assert is_integer(row.after_state["hmac_key_version"])
    end

    test "U2 no candidate value, derived value or error text in the row", %{a: a} do
      master!(a.schema_name, "ann")
      bind!(a, Map.put(@manifest, "reads", @reads), @read_source)

      body = %{"candidate" => %{"tier" => "gold", "memo" => @marker}}
      assert %{"derived" => %{"name" => "ann"}} = a |> dry(@t, body) |> json()

      stub!({:error, :script_failed, %{fail: %{code: "too_big", details: "secret-detail"}}})
      assert dry(a, @t, body).status == 200

      rows = hook_rows(a.schema_name)
      assert length(rows) == 2
      encoded = Jason.encode!(Enum.map(rows, & &1.after_state)) <> inspect(rows)
      refute encoded =~ @marker
      refute encoded =~ "ann"
      refute encoded =~ "secret-detail"
      refute encoded =~ "too_big"

      assert Enum.map(rows, & &1.after_state["outcome_class"]) |> Enum.sort() ==
               ["ok", "script_failed"]
    end

    test "U3 a call the sandbox never started still has a row, with a nil hmac", %{a: a} do
      bind!(a)
      P.kill_switch!(a.schema_name, true)
      assert json(dry(a))["outcome"] == "script_rejected"

      assert [row] = hook_rows(a.schema_name)
      assert row.after_state["outcome_class"] == "script_rejected"
      assert row.after_state["hmac_hex"] == nil
      assert row.after_state["hmac_key_version"] == nil
      assert row.after_state["duration_us"] == 0
    end

    test "U4 a refused call appends no row, each successful call exactly one", %{a: a} do
      bind!(a)
      before = audits(a.schema_name)

      assert dry(a, "unbound_type").status == 404
      assert dry(a, @t, %{"candidate" => []}).status == 422
      assert dry(a, @t, %{"candidate" => %{}}, @auditor).status == 403

      assert call("/tt/dry-run", a, @admin, %{"candidate" => %{}}, credential: :api_token).status ==
               403

      assert audits(a.schema_name) == before

      assert dry(a).status == 200
      assert dry(a).status == 200
      assert audits(a.schema_name) == before + 2
      assert length(hook_rows(a.schema_name)) == 2
    end

    test "U5 an audit table that cannot be written answers a bare 500", %{a: a} do
      master!(a.schema_name, "ann")
      bind!(a, Map.put(@manifest, "reads", @reads), @read_source)
      Repo.query!("DROP TABLE \"#{a.schema_name}\".audit_entries CASCADE")

      conn = dry(a)
      assert conn.status == 500
      body = String.downcase(conn.resp_body)

      for leak <- ["audit", "entry", a.schema_name, "relation", "undefined", "ann"] do
        refute body =~ String.downcase(leak), leak
      end
    end
  end

  # ── D: docs ────────────────────────────────────────────────────────────────

  describe "D docs" do
    test "D1 the router moduledoc has the dry-run row and the audit sentence" do
      source = File.read!("lib/letflow/routers/entity_type_hooks.ex")
      [moduledoc | _] = String.split(source, "use Letflow.Api.AuthorizedRouter", parts: 2)
      assert moduledoc =~ "`POST /:entity_type/dry-run`"
      assert moduledoc =~ "`:EntityTypeHooksDryRun` | `:ScriptsWrite`"
      assert moduledoc =~ "appends one `entity_write_hook.dry_run` audit row"
    end
  end
end
