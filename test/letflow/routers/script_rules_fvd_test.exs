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
  alias Letflow.Scripts.FormValidation
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
        user_id: Ecto.UUID.generate(),
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
    refuse = publish!(a, "eqr", @refuse)
    pin = %{script_key: "eqr", script_version: refuse.version, script_sha256: refuse.sha256}

    facts = %{
      variables: %{"note" => "x"},
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

    assert {:ok, {:refused, %{code: "too_short"}}} = FormValidation.run(a.schema_name, pin, facts)
    conn = fvd(a, "eqr", %{"version" => refuse.version, "variables" => %{"note" => "x"}})
    assert json(conn)["code"] == "too_short"
  end

  test "R4 the sandbox gets the constant facts", %{a: a} do
    rule = publish!(a, "cst", "return { ok = true }")

    stub!(
      {:ok,
       %{
         output: %{"ok" => true},
         stats: %{duration_us: 1, instructions_used: 2, heap_words_at_end: 3}
       }}
    )

    Application.put_env(:letflow, :scripts_test_hooks, true)
    on_exit(fn -> Application.delete_env(:letflow, :scripts_test_hooks) end)

    conn = fvd(a, "cst", %{"version" => rule.version, "variables" => %{"note" => "hi"}})
    assert conn.status == 200, conn.resp_body
    assert [{_source, input, _opts}] = StubRunner.calls()
    assert inspect(input) =~ "dry-run"
    assert [_one] = audit_rows(a)
  end

  test "R5 infrastructure outcomes are 200 without code or fields", %{a: a} do
    rule = publish!(a, "inf", "return { ok = true }")

    stub!({:error, :budget_exceeded, %{}})
    Application.put_env(:letflow, :scripts_test_hooks, true)
    on_exit(fn -> Application.delete_env(:letflow, :scripts_test_hooks) end)

    conn = fvd(a, "inf", %{"version" => rule.version, "variables" => %{}})
    assert conn.status == 200, conn.resp_body
    body = json(conn)
    assert body["outcome"] == "budget_exceeded"
    refute Map.has_key?(body, "code")
    refute Map.has_key?(body, "fields")
  end

  test "R5 flag off is a 200 script_rejected, no run", %{a: a} do
    rule = publish!(a, "off", "return { ok = true }")
    Application.put_env(:letflow, :form_validation_hook_enabled, false)
    conn = fvd(a, "off", %{"version" => rule.version, "variables" => %{}})
    assert conn.status == 200
    assert json(conn)["outcome"] == "script_rejected"
  end

  test "R6 unknown key, absent and bad versions are one 404; draft is script_rejected", %{a: a} do
    rule = publish!(a, "ver", "return { ok = true }")
    missing = fvd(a, "nokey", %{"version" => 1, "variables" => %{}})
    assert missing.status == 404

    for v <- [nil, 0, -1, 1.5, "abc", 99] do
      body = if v == nil, do: %{"variables" => %{}}, else: %{"version" => v, "variables" => %{}}
      conn = fvd(a, "ver", body)
      assert {conn.status, conn.resp_body} == {404, missing.resp_body}
    end

    assert fvd(a, "ver", %{"version" => "#{rule.version}", "variables" => %{}}).status == 200

    draft =
      F.draft!(a.schema_name, "drf", "return { ok = true }", @manifest,
        hook_kind: "form_validation"
      )

    conn = fvd(a, "drf", %{"version" => draft.version, "variables" => %{}})
    assert conn.status == 200
    assert json(conn)["outcome"] == "script_rejected"
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

  test "R8 one audit row with exactly four after_state keys", %{a: a} do
    rule = publish!(a, "aud", @refuse)
    fvd(a, "aud", %{"version" => rule.version, "variables" => %{"note" => @marker}})
    assert [entry] = audit_rows(a)
    assert entry.resource_type == "script_rule"

    assert entry.after_state |> Map.keys() |> Enum.sort() ==
             ~w(duration_us heap_words_at_end instructions_used outcome)

    assert entry.after_state["outcome"] == "refused"
    refute inspect(entry) =~ @marker
    refute inspect(entry) =~ "too_short"
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
