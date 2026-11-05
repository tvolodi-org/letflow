defmodule Letflow.Routers.ScriptRulesFvdTest do
  @moduledoc """
  REQ-639 / GH #3567 (decision 0067 D9, slice F-5): `POST /script-rules/:key/form-validation-dry-run`.
  Verdict shape (accepted, refused, infrastructure codes), the check order (token, body, 404,
  flag), no write except one audit row, tenant isolation and the audit failure path.
  `async: false`: the platform tenant pin and the application env are VM-global.
  """

  use Letflow.DataCase, async: false
  @moduletag :slow

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Scripts.FormValidation
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @admin ["TENANT_ADMIN"]
  @marker "MARKER-SECRET-VALUE"

  @manifest %{
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"note" => %{"type" => "string"}}
    },
    "output_schema" => %{
      "type" => "object",
      "properties" => %{
        "ok" => %{"type" => "boolean"},
        "code" => %{"type" => "string"},
        "fields" => %{"type" => "array"}
      },
      "additionalProperties" => false
    },
    "fail_codes" => [],
    "refusal_codes" => ["too_short"],
    "fields" => ["note"],
    "limits" => %{"timeout_ms" => 50}
  }

  @refuse ~S|return { ok = false, code = "too_short", fields = { { field = "note", code = "too_short" } } }|

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: [], reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def run(source, input, opts) do
      Agent.update(__MODULE__, &%{&1 | calls: [{source, input, opts} | &1.calls]})
      Agent.get(__MODULE__, & &1.reply)
    end
  end

  # The first call in a fresh VM loads code and takes about 60 ms, above the 50 ms cap: warm the
  # runner once so the real-sandbox rows measure the steady state.
  setup_all do
    opts = [
      tenant: "tenant_warmup",
      timeout_ms: 5_000,
      ctx: %{
        instance_id: "i",
        node_id: "n",
        token_id: "t",
        now: ~U[2026-10-26 08:00:00.000000Z]
      }
    ]

    {:ok, _} = ScriptRunner.run("return { ok = true }", %{}, opts)
    :ok
  end

  setup do
    previous = Application.fetch_env(:letflow, :form_validation_hook_enabled)
    Application.put_env(:letflow, :form_validation_hook_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :form_validation_hook_enabled, old)
        :error -> Application.delete_env(:letflow, :form_validation_hook_enabled)
      end
    end)

    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    F.with_hmac!(tenants.a)
    F.with_hmac!(tenants.b)
    {:ok, tenants}
  end

  defp publish!(fx, key, source, manifest \\ @manifest),
    do: F.published!(fx.schema_name, key, source, manifest, hook_kind: "form_validation")

  defp call(path, fx, body, opts) do
    roles = Keyword.get(opts, :roles, @admin)
    credential = Keyword.get(opts, :credential, :oidc)

    conn =
      Fixture.router_conn(:post, path, fx, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: fx.tenant_id,
        roles: roles,
        credential: credential
      })

    Letflow.Routers.ScriptRules.call(conn, Letflow.Routers.ScriptRules.init([]))
  end

  defp fvd(fx, key, body, opts \\ []),
    do: call("/#{key}/form-validation-dry-run", fx, body, opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp audit_rows(fx),
    do:
      Entry
      |> where([e], e.action == "script_rule.form_validation_dry_run")
      |> Repo.all(prefix: fx.schema_name)

  defp stub!(reply) do
    {:ok, _} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    StubRunner.reply(reply)
    previous = Application.fetch_env(:letflow, :form_validation_script_runner)
    Application.put_env(:letflow, :form_validation_script_runner, StubRunner)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :form_validation_script_runner, old)
        :error -> Application.delete_env(:letflow, :form_validation_script_runner)
      end
    end)
  end

  defp hooks_on! do
    previous = Application.fetch_env(:letflow, :scripts_test_hooks)
    Application.put_env(:letflow, :scripts_test_hooks, true)

    # restore, never delete: config/test.exs sets it true for the whole VM
    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :scripts_test_hooks, old)
        :error -> Application.delete_env(:letflow, :scripts_test_hooks)
      end
    end)
  end

  @ok_reply {:ok,
             %{
               output: %{"ok" => true},
               stats: %{duration_us: 1, instructions_used: 2, heap_words_at_end: 3}
             }}

  @counted ~w(tasks instance_projections tokens events event_idempotency event_payload_store
              instance_state_snapshots script_task_dispatches script_rules entity_record_latest
              entity_type_instances)

  defp counts(fx) do
    for table <- @counted, into: %{} do
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{fx.schema_name}"."#{table}"|)
      {table, n}
    end
  end

  defp audit_count(fx) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{fx.schema_name}".audit_entries|)
    n
  end

  defp without_stats(conn), do: conn |> json() |> Map.delete("stats")

  defp direct_facts(variables) do
    %{
      variables: variables,
      variable_labels: %{},
      instance_id: "00000000-0000-0000-0000-000000000000",
      token_id: "dry-run",
      form: %{
        definition_id: "dry-run",
        definition_version: 0,
        node_id: "dry-run",
        schema_version_hash: "dry-run"
      },
      task: %{
        id: "dry-run",
        node_id: "dry-run",
        assignee_kind: "dry-run",
        now: DateTime.utc_now()
      }
    }
  end

  defp pin(rule),
    do: %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}

  test "R2 accepted and refused bodies are allowlisted", %{a: a} do
    ok = publish!(a, "okr", "return { ok = true }")
    refuse = publish!(a, "refr", @refuse)

    conn = fvd(a, "okr", %{"version" => ok.version, "variables" => %{"note" => @marker}})
    assert conn.status == 200, conn.resp_body
    assert json(conn)["outcome"] == "accepted"
    assert json(conn) |> Map.keys() |> Enum.sort() == ~w(outcome stats)
    refute conn.resp_body =~ @marker
    refute conn.resp_body =~ ok.sha256

    conn = fvd(a, "refr", %{"version" => refuse.version, "variables" => %{"note" => @marker}})
    body = json(conn)
    assert body |> Map.keys() |> Enum.sort() == ~w(code fields outcome stats)
    assert body["outcome"] == "refused"
    assert body["code"] == "too_short"
    assert body["fields"] == [%{"field" => "note", "code" => "too_short"}]
    refute conn.resp_body =~ @marker
  end

  test "R3 the verdict equals a direct FormValidation.run", %{a: a} do
    accept = publish!(a, "eqa", "return { ok = true }")
    refuse = publish!(a, "eqr", @refuse)

    assert {:ok, :accepted} =
             FormValidation.run(a.schema_name, pin(accept), direct_facts(%{"note" => "fine"}))

    conn = fvd(a, "eqa", %{"version" => accept.version, "variables" => %{"note" => "fine"}})
    assert json(conn)["outcome"] == "accepted"
    refute Map.has_key?(json(conn), "code")
    refute Map.has_key?(json(conn), "fields")

    assert {:ok, {:refused, %{code: code, fields: fields}}} =
             FormValidation.run(a.schema_name, pin(refuse), direct_facts(%{"note" => "x"}))

    body = json(fvd(a, "eqr", %{"version" => refuse.version, "variables" => %{"note" => "x"}}))
    assert body["outcome"] == "refused"
    assert body["code"] == code
    assert body["fields"] == fields |> Jason.encode!() |> Jason.decode!()
  end

  test "R4 constant facts reach the sandbox and nothing but one audit row is written", %{a: a} do
    rule = publish!(a, "cst", "return { ok = true }")
    stub!(@ok_reply)
    hooks_on!()

    before = counts(a)
    audits = audit_count(a)
    conn = fvd(a, "cst", %{"version" => rule.version, "variables" => %{"note" => "hi"}})
    assert conn.status == 200, conn.resp_body

    assert counts(a) == before
    assert audit_count(a) == audits + 1

    assert [{_source, input, opts}] = StubRunner.calls()
    assert input["output"] == %{"note" => "hi"}

    assert input["form"] == %{
             "definition_id" => "dry-run",
             "definition_version" => 0,
             "node_id" => "dry-run",
             "schema_version_hash" => "dry-run"
           }

    assert %{"id" => "dry-run", "node_id" => "dry-run", "assignee_kind" => "dry-run"} =
             input["task"]

    assert opts[:ctx].instance_id == "00000000-0000-0000-0000-000000000000"
    assert opts[:ctx].token_id == "dry-run"
    assert opts[:ctx].node_id == "dry-run"
    assert opts[:fail_codes] == []
  end

  test "R4 source scan: the dry-run path touches no engine, task, record or event module" do
    scripts = File.read!("lib/letflow/scripts.ex")
    router = File.read!("lib/letflow/routers/script_rules.ex")

    {i, _} = :binary.match(scripts, "def dry_run_form_validation(")
    {j, _} = :binary.match(scripts, "defp dry_run_response(")
    fun = binary_part(scripts, i, j - i)

    {k, _} = :binary.match(router, ~S|authz_post "/:key/form-validation-dry-run"|)
    {l, _} = :binary.match(router, "authz_unmatched(:ordinary)")
    action = binary_part(router, k, l - k)

    for {name, text} <- [function: fun, action: action],
        forbidden <- ~w(Engine Tasks Records EventStore) do
      refute Regex.match?(~r/\b#{forbidden}\./, text), "#{name} references #{forbidden}"
    end

    # the only Repo access in the function body is through get/3 and Audit.insert_entry
    refute Regex.match?(~r/\bRepo\.\w+/, fun)
    assert fun =~ "get(prefix, key, version)"
    assert fun =~ "Audit.insert_entry(Repo, attrs, prefix)"

    # and the two Repo reads below it are Repo.get_by on ScriptRule
    scripts_get = binary_part(scripts, elem(:binary.match(scripts, "def get(prefix"), 0), 400)
    assert scripts_get =~ "Repo.get_by(ScriptRule"
    form_validation = File.read!("lib/letflow/scripts/form_validation.ex")
    assert form_validation =~ "Repo.get_by(ScriptRule, [key: key, version: version]"
  end

  for {label, reply, outcome} <- [
        {"script_error", {:error, :script_error, %{}}, "script_error"},
        {"budget_exceeded", {:error, :budget_exceeded, %{}}, "budget_exceeded"},
        {"memory_limit_exceeded", {:error, :memory_limit_exceeded, %{}}, "memory_limit_exceeded"},
        {"timeout", {:error, :timeout, %{}}, "timeout"},
        {"output_invalid", {:error, :output_invalid, %{}}, "output_invalid"},
        {"script_busy", {:error, :script_busy, %{}}, "script_busy"}
      ] do
    test "R5 #{label} is a 200 without code or fields", %{a: a} do
      rule = publish!(a, "inf", "return { ok = true }")
      stub!(unquote(Macro.escape(reply)))
      hooks_on!()

      conn = fvd(a, "inf", %{"version" => rule.version, "variables" => %{}})
      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert body["outcome"] == unquote(outcome)
      assert body |> Map.keys() |> Enum.sort() == ~w(outcome stats)
      assert [entry] = audit_rows(a)
      assert entry.after_state["outcome"] == unquote(outcome)
    end
  end

  test "R5 script_busy from the real admission with every slot held", %{a: a} do
    rule = publish!(a, "busy", "return { ok = true }")
    F.hold_all_slots!(a.schema_name)

    conn = fvd(a, "busy", %{"version" => rule.version, "variables" => %{}})
    assert conn.status == 200, conn.resp_body
    assert json(conn)["outcome"] == "script_busy"
    assert [entry] = audit_rows(a)
    assert entry.after_state["outcome"] == "script_busy"
  end

  test "R5 flag off is a 200 script_rejected, no run, audited", %{a: a} do
    rule = publish!(a, "off", "return { ok = true }")
    stub!(@ok_reply)
    hooks_on!()
    Application.put_env(:letflow, :form_validation_hook_enabled, false)

    conn = fvd(a, "off", %{"version" => rule.version, "variables" => %{}})
    assert conn.status == 200
    assert json(conn)["outcome"] == "script_rejected"
    assert StubRunner.calls() == []
    assert [entry] = audit_rows(a)
    assert entry.after_state["outcome"] == "script_rejected"
  end

  test "R6 unknown key, absent and bad versions are one 404", %{a: a} do
    rule = publish!(a, "ver", "return { ok = true }")
    missing = fvd(a, "nokey", %{"version" => 1, "variables" => %{}})
    assert missing.status == 404

    for v <- [nil, 0, -1, 1.5, "abc", 99] do
      body = if v == nil, do: %{"variables" => %{}}, else: %{"version" => v, "variables" => %{}}
      conn = fvd(a, "ver", body)
      assert {conn.status, conn.resp_body} == {404, missing.resp_body}
    end

    assert fvd(a, "ver", %{"version" => "#{rule.version}", "variables" => %{}}).status == 200
  end

  test "R6 draft, revoked and other-kind versions answer one script_rejected body; discarded is 404",
       %{a: a} do
    draft =
      F.draft!(a.schema_name, "drf", "return { ok = true }", @manifest,
        hook_kind: "form_validation"
      )

    revoked =
      F.revoke_raw!(a.schema_name, publish!(a, "rev", "return { ok = true }"))

    other = F.published!(a.schema_name, "oth", "return { ok = true }", @manifest)

    discarded =
      F.draft!(a.schema_name, "dis", "return { ok = true }", @manifest,
        hook_kind: "form_validation"
      )

    actor = %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "t1279"}

    assert {:ok, %{status: :discarded}} =
             Letflow.Scripts.discard(a.schema_name, "dis", discarded.version, actor)

    bodies =
      for {key, rule} <- [{"drf", draft}, {"rev", revoked}, {"oth", other}] do
        conn = fvd(a, key, %{"version" => rule.version, "variables" => %{"note" => "x"}})
        assert conn.status == 200, conn.resp_body
        assert json(conn)["outcome"] == "script_rejected"
        without_stats(conn)
      end

    assert bodies |> Enum.uniq() |> length() == 1
    assert hd(bodies) == %{"outcome" => "script_rejected"}

    gone = fvd(a, "dis", %{"version" => discarded.version, "variables" => %{}})
    missing = fvd(a, "nokey", %{"version" => 1, "variables" => %{}})
    assert {gone.status, gone.resp_body} == {404, missing.resp_body}
  end

  test "R13 restricted_inputs naming an active definition and a known field run", %{a: a} do
    P.active_definition!(a.schema_name, "customer", ["name", "email"])

    manifest =
      Map.put(@manifest, "restricted_inputs", [
        %{"name" => "note", "from" => [%{"entity_type" => "customer", "field" => "name"}]}
      ])

    rule = publish!(a, "rsok", @refuse, manifest)
    before = counts(a)
    conn = fvd(a, "rsok", %{"version" => rule.version, "variables" => %{"note" => "x"}})
    assert conn.status == 200, conn.resp_body
    assert json(conn)["outcome"] == "refused"
    assert json(conn)["code"] == "too_short"
    assert counts(a) == before
  end

  test "R13 an unknown entity type or field is script_rejected with no run", %{a: a} do
    P.active_definition!(a.schema_name, "customer", ["name", "email"])
    stub!(@ok_reply)
    hooks_on!()

    for {key, from} <- [
          {"rsfld", %{"entity_type" => "customer", "field" => "nope"}},
          {"rsent", %{"entity_type" => "ghost", "field" => "name"}}
        ] do
      manifest =
        Map.put(@manifest, "restricted_inputs", [%{"name" => "note", "from" => [from]}])

      rule = publish!(a, key, "return { ok = true }", manifest)
      conn = fvd(a, key, %{"version" => rule.version, "variables" => %{"note" => "x"}})
      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert body["outcome"] == "script_rejected"
      assert body |> Map.keys() |> Enum.sort() == ~w(outcome stats)
    end

    assert StubRunner.calls() == []
  end

  test "R7 bad bodies are 422, no run, no audit", %{a: a} do
    rule = publish!(a, "bad", "return { ok = true }")
    v = rule.version
    big = %{"note" => String.duplicate("a", 70_000)}

    for body <- [
          %{"version" => v},
          %{"version" => v, "variables" => "x"},
          %{"version" => v, "variables" => [1]},
          %{"version" => v, "variables" => %{}, "tenant_id" => "t"},
          %{"version" => v, "variables" => %{}, "sha256" => "x"},
          %{"_json" => [1]},
          %{"version" => v, "variables" => big}
        ],
        key <- ["bad", "nokey"] do
      conn = fvd(a, key, body)
      assert conn.status == 422, conn.resp_body
      assert json(conn)["detail"] == "invalid_input"
    end

    assert audit_rows(a) == []
  end

  test "R7 the cap is on the canonical size, exactly 65536 passes", %{a: a} do
    rule = publish!(a, "cap", "return { ok = true }")
    overhead = byte_size(Letflow.Scripts.Hash.canon(%{"note" => ""}))
    exact = %{"note" => String.duplicate("a", 65_536 - overhead)}
    assert byte_size(Letflow.Scripts.Hash.canon(exact)) == 65_536
    assert fvd(a, "cap", %{"version" => rule.version, "variables" => exact}).status == 200

    over = %{"note" => String.duplicate("a", 65_537 - overhead)}
    assert fvd(a, "cap", %{"version" => rule.version, "variables" => over}).status == 422
  end

  test "R8 one audit row with exactly four after_state keys, no payload, caller as actor", %{a: a} do
    rule = publish!(a, "aud", @refuse)
    caller = Ecto.UUID.generate()

    fvd(a, "aud", %{"version" => rule.version, "variables" => %{"note" => @marker}},
      user_id: caller
    )

    assert [entry] = audit_rows(a)
    assert entry.resource_type == "script_rule"
    assert entry.actor_id == caller

    assert entry.after_state |> Map.keys() |> Enum.sort() ==
             ~w(duration_us heap_words_at_end instructions_used outcome)

    assert entry.after_state["outcome"] == "refused"

    dump = inspect(entry)
    refute dump =~ @marker
    refute dump =~ "too_short"
    refute dump =~ "note"
    refute dump =~ "return {"
  end

  test "R8 a failing audit insert is a 500 without a verdict", %{a: a} do
    rule = publish!(a, "afl", @refuse)
    Repo.query!(~s|DROP TABLE "#{a.schema_name}".audit_entries CASCADE|)
    conn = fvd(a, "afl", %{"version" => rule.version, "variables" => %{}})
    assert conn.status == 500
    refute conn.resp_body =~ "too_short"
    refute conn.resp_body =~ "refused"
  end

  test "R9 tokens and unauthorised roles are refused", %{a: a} do
    rule = publish!(a, "tok", "return { ok = true }")
    body = %{"version" => rule.version, "variables" => %{}}

    token = fvd(a, "tok", body, credential: :api_token)
    assert token.status == 403
    assert json(token)["detail"] == "api_token_not_allowed"

    # token check precedes body validation
    assert fvd(a, "tok", %{"x" => 1}, credential: :api_token).status == 403

    for roles <- [["TENANT_AUDITOR"], []] do
      conn = fvd(a, "tok", body, roles: roles)
      other = call("/tok/dry-run", a, %{"version" => rule.version, "input" => %{}}, roles: roles)
      assert conn.status == 403
      assert conn.resp_body == other.resp_body
    end

    assert audit_rows(a) == []
  end

  test "R10 another tenant's key is the same 404; each tenant runs its own", %{a: a, b: b} do
    publish!(b, "bonly", "return { ok = true }")
    other = fvd(a, "bonly", %{"version" => 1, "variables" => %{}})
    absent = fvd(a, "absent", %{"version" => 1, "variables" => %{}})
    assert other.status == 404
    assert other.resp_body == absent.resp_body
    assert audit_rows(a) == [] and audit_rows(b) == []

    ra = publish!(a, "same", "return { ok = true }")
    rb = publish!(b, "same", @refuse)

    assert json(fvd(a, "same", %{"version" => ra.version, "variables" => %{}}))["outcome"] ==
             "accepted"

    assert json(fvd(b, "same", %{"version" => rb.version, "variables" => %{}}))["outcome"] ==
             "refused"

    assert fvd(a, "same", %{
             "version" => ra.version,
             "variables" => %{},
             "tenant_id" => b.tenant_id
           }).status == 422
  end

  test "R10 a malformed body for another tenant's key is 422; a tenant query param is ignored",
       %{a: a, b: b} do
    rb = publish!(b, "bonly2", "return { ok = true }")

    for key <- ["bonly2", "absent"] do
      conn = fvd(a, key, %{"version" => rb.version, "variables" => "x"})
      assert conn.status == 422, conn.resp_body
    end

    # a tenant named in the query string does not move the call into that tenant
    conn =
      call(
        "/bonly2/form-validation-dry-run?tenant_id=#{b.tenant_id}&prefix=#{b.schema_name}",
        a,
        %{"version" => rb.version, "variables" => %{}},
        []
      )

    absent = fvd(a, "absent", %{"version" => 1, "variables" => %{}})
    assert conn.status == 404
    assert conn.resp_body == absent.resp_body
    assert audit_rows(a) == [] and audit_rows(b) == []
  end

  test "R5 the tenant kill switch is a 409 with no run and no audit", %{a: a} do
    rule = publish!(a, "ks", "return { ok = true }")

    Repo.query!(
      ~s|UPDATE "#{a.schema_name}".script_policy SET tenant_kill_switch = true WHERE id = 1|
    )

    conn = fvd(a, "ks", %{"version" => rule.version, "variables" => %{}})
    assert conn.status == 409
    assert audit_rows(a) == []
  end
end
