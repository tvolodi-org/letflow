defmodule Letflow.Routers.TasksFormHookFailureTest do
  @moduledoc """
  REQ-632 / GH #3524 (decision 0067 D5 + D8, slice F-4 part A): `POST /tasks/:id/complete` through
  the full `Letflow.Router` pipeline with a real API token. Every D5 row that gives no verdict
  answers HTTP 503 `service-unavailable` with the top-level `code` equal to the infrastructure
  code, never 500; the task stays pending and nothing is committed (F4-01..F4-07, F4-10, F4-11,
  F4-12, F4-13, F4-14). The crash rows (F4-08, F4-09, F4-13b) are in
  `Letflow.Engine.CompleteTaskFormHookCrashTest`. Audit rows are part B. `async: false`
  (application env).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Engine.Lua.ScriptRunner
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Scripts.FormValidation
  alias Letflow.Support.ScriptTaskFixture, as: F

  @submitted "SUBMITTED-VALUE-3524"
  @marker "SOURCE-MARKER-3524"
  @codes ~w(script_rejected input_invalid script_error budget_exceeded memory_limit_exceeded
            timeout output_invalid script_busy)

  defmodule FunRunner do
    @moduledoc false
    # `fun.(call_no)` is kept in the application env; the Agent counts the calls.
    def start, do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _gone -> :ok
    end

    def calls, do: Agent.get(__MODULE__, & &1)

    def run(_source, _input, _opts) do
      n = Agent.get_and_update(__MODULE__, &{&1 + 1, &1 + 1})
      Application.fetch_env!(:letflow, :f4_runner_fun).(n)
    end
  end

  defp set_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  defp stub(fun) do
    case FunRunner.start() do
      {:ok, _pid} -> on_exit(&FunRunner.stop/0)
      {:error, {:already_started, _pid}} -> Agent.update(FunRunner, fn _ -> 0 end)
    end

    set_env(:f4_runner_fun, fun)
    set_env(:form_validation_script_runner, FunRunner)
  end

  # The published script row is immutable and never deleted (LF001 triggers); the pin problems of
  # D5 row 11 are provoked with the triggers off for this statement only (the sandbox transaction
  # is rolled back at the end of the test).
  defp raw_row_change!(schema, sql, params) do
    Repo.query!(~s(ALTER TABLE "#{schema}".script_rules DISABLE TRIGGER USER))
    Repo.query!(sql, params)
    Repo.query!(~s(ALTER TABLE "#{schema}".script_rules ENABLE TRIGGER USER))
  end

  defp break_sha!(ctx, sha) do
    raw_row_change!(
      ctx.schema,
      ~s(UPDATE "#{ctx.schema}".script_rules SET sha256 = $1 WHERE id = $2),
      [sha, Ecto.UUID.dump!(ctx.rule.id)]
    )
  end

  defp drop_row!(ctx) do
    raw_row_change!(
      ctx.schema,
      ~s(DELETE FROM "#{ctx.schema}".script_rules WHERE id = $1),
      [Ecto.UUID.dump!(ctx.rule.id)]
    )
  end

  defp stats, do: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}
  defp accept, do: {:ok, %{output: %{"ok" => true}, stats: stats()}}

  defp refuse,
    do:
      {:ok,
       %{
         output: %{
           "ok" => false,
           "code" => "too_small",
           "fields" => [%{"field" => "amount", "code" => "too_small"}]
         },
         stats: stats()
       }}

  defp manifest(limits \\ %{"timeout_ms" => 50}) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}, "note" => %{"type" => "string"}}
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
      "refusal_codes" => ["too_small"],
      "fields" => ["amount", "note"],
      "limits" => limits
    }
  end

  defp setup_case!(opts \\ []) do
    source = Keyword.get(opts, :source, "local m = '#{@marker}'; return { ok = true }")
    limits = Map.merge(%{"timeout_ms" => 50}, Keyword.get(opts, :limits, %{}))

    set_env(:form_validation_hook_enabled, true)

    t = F.tenant!("f4")
    schema = t.schema_name
    %Tenant{slug: slug} = Repo.get!(Tenant, t.tenant_id)

    caller =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "f4-#{System.unique_integer([:positive])}",
        display_name: "F4 Caller",
        email: "f4-#{System.unique_integer([:positive])}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    rule =
      F.published!(
        schema,
        "fv_f4_#{System.unique_integer([:positive])}",
        source,
        manifest(limits),
        hook_kind: "form_validation"
      )

    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => caller.id,
            "assignee_type" => "USER",
            "validation_script_key" => rule.key,
            "validation_script_version" => rule.version
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }

    definition = F.definition!(schema, graph, [])
    instance_id = F.start!(schema, definition, %{}, Ecto.UUID.generate())

    task =
      Repo.one!(from(x in EngineTask, where: x.instance_id == ^instance_id), prefix: schema)

    {:ok, %{plaintext: token}} =
      Identity.create_token(caller.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: schema
      )

    %{
      t: t,
      schema: schema,
      slug: slug,
      caller: caller,
      rule: rule,
      task: task,
      instance_id: instance_id,
      token: token
    }
  end

  defp post_complete(ctx) do
    conn(
      :post,
      "/api/v1/tasks/#{ctx.task.id}/complete",
      Jason.encode!(%{"amount" => 1, "note" => @submitted})
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  # What a failed completion must leave untouched.
  defp snapshot(ctx) do
    %{
      status: Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema).status,
      projection: F.projection(ctx.schema, ctx.instance_id),
      events: F.event_types(ctx.schema, ctx.instance_id)
    }
  end

  defp assert_503(conn, code, ctx) do
    assert conn.status == 503
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"
    body = Jason.decode!(conn.resp_body)
    assert body["code"] == code
    assert String.ends_with?(body["type"], "service-unavailable")

    for text <- [
          @submitted,
          @marker,
          ctx.rule.key,
          ctx.rule.sha256,
          "Elixir.",
          "Exception",
          "stacktrace",
          "** (",
          "BOOM-SECRET"
        ] do
      refute conn.resp_body =~ text, "body leaked #{inspect(text)}"
    end

    body
  end

  # Runs one completion and checks it left nothing behind. Returns the problem body.
  defp complete_503(ctx, code) do
    before = snapshot(ctx)
    conn = post_complete(ctx)
    body = assert_503(conn, code, ctx)
    assert snapshot(ctx) == before
    assert snapshot(ctx).status == :pending
    refute Repo.in_transaction?()
    body
  end

  defp without_request_members(body), do: Map.drop(body, ["trace_id", "instance"])

  test "F4-01 a refusing verdict stays 422 form_hook_refused (not 503)" do
    stub(fn _n -> refuse() end)
    ctx = setup_case!()
    before = snapshot(ctx)
    conn = post_complete(ctx)
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["code"] == "form_hook_refused"
    assert snapshot(ctx) == before
    assert snapshot(ctx).status == :pending
  end

  describe "real sandbox rows" do
    setup do
      set_env(:form_validation_script_runner, ScriptRunner)
      :ok
    end

    test "F4-02 script_error" do
      ctx = setup_case!(source: "error('#{@marker}')")
      assert %{"code" => "script_error"} = complete_503(ctx, "script_error")
    end

    test "F4-03 budget_exceeded" do
      ctx = setup_case!(source: "while true do end", limits: %{"instructions" => 1000})
      assert %{"code" => "budget_exceeded"} = complete_503(ctx, "budget_exceeded")
    end

    test "F4-04 memory_limit_exceeded" do
      ctx =
        setup_case!(
          source: "local t = {} for i = 1, 100000000 do t[i] = {i} end return { ok = true }",
          limits: %{"heap_words" => 20_000, "instructions" => 10_000_000}
        )

      assert %{"code" => "memory_limit_exceeded"} = complete_503(ctx, "memory_limit_exceeded")
    end

    test "F4-05 timeout" do
      ctx =
        setup_case!(
          source: "while true do local s = string.rep('x', 1000000) end",
          limits: %{
            "instructions" => 10_000_000,
            "timeout_ms" => FormValidation.max_timeout_ms()
          }
        )

      assert %{"code" => "timeout"} = complete_503(ctx, "timeout")
    end

    test "F4-06 output_invalid" do
      ctx = setup_case!(source: "return { ok = false, code = 'not_in_manifest', fields = {} }")
      assert %{"code" => "output_invalid"} = complete_503(ctx, "output_invalid")
    end
  end

  describe "F4-07 script_busy" do
    test "busy on every attempt: exactly 3 calls, then 503 script_busy" do
      stub(fn _n -> {:error, :script_busy, %{}} end)
      ctx = setup_case!()
      assert %{"code" => "script_busy"} = complete_503(ctx, "script_busy")
      assert FunRunner.calls() == 3
    end

    test "busy once, then accepted: 200 after 2 calls" do
      stub(fn
        1 -> {:error, :script_busy, %{}}
        _ -> accept()
      end)

      ctx = setup_case!()
      conn = post_complete(ctx)
      assert conn.status == 200
      assert FunRunner.calls() == 2
      assert Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema).status == :completed
    end
  end

  describe "F4-10 kill switch (criterion 7)" do
    test "flag false at run time: 503 script_rejected, the runner is never called" do
      stub(fn _n -> accept() end)
      ctx = setup_case!()
      Application.put_env(:letflow, :form_validation_hook_enabled, false)
      assert %{"code" => "script_rejected"} = complete_503(ctx, "script_rejected")
      assert FunRunner.calls() == 0
    end

    test "same completion with the flag true is accepted" do
      stub(fn _n -> accept() end)
      ctx = setup_case!()
      assert post_complete(ctx).status == 200
      assert FunRunner.calls() == 1
    end

    test "the flag defaults to false when the key is absent" do
      Application.delete_env(:letflow, :form_validation_hook_enabled)
      on_exit(fn -> Application.delete_env(:letflow, :form_validation_hook_enabled) end)
      refute Letflow.Scripts.form_validation_enabled?()
    end
  end

  describe "F4-11 pin problems answer script_rejected" do
    setup do
      stub(fn _n -> accept() end)
      :ok
    end

    test "revoked version" do
      ctx = setup_case!()
      F.revoke_raw!(ctx.schema, ctx.rule)
      assert %{"code" => "script_rejected"} = complete_503(ctx, "script_rejected")
      assert FunRunner.calls() == 0
    end

    test "sha256 mismatch" do
      ctx = setup_case!()

      break_sha!(ctx, String.duplicate("a", 64))

      assert %{"code" => "script_rejected"} = complete_503(ctx, "script_rejected")
      assert FunRunner.calls() == 0
    end

    test "pin row missing" do
      ctx = setup_case!()

      drop_row!(ctx)

      assert %{"code" => "script_rejected"} = complete_503(ctx, "script_rejected")
      assert FunRunner.calls() == 0
    end
  end

  describe "F4-12 all eight infrastructure codes" do
    test "seven reach the router through the real route: 503, code equal, never 500" do
      for code <- @codes -- ["script_rejected", "input_invalid"] do
        stub(fn _n -> {:error, String.to_existing_atom(code), %{}} end)
        ctx = setup_case!()
        assert %{"code" => ^code} = complete_503(ctx, code)
      end

      # script_rejected: the kill switch
      stub(fn _n -> accept() end)
      ctx = setup_case!()
      Application.put_env(:letflow, :form_validation_hook_enabled, false)
      assert %{"code" => "script_rejected"} = complete_503(ctx, "script_rejected")
    end

    test "input_invalid is covered at the constructor: check_facts never fails on a real completion" do
      problem = Error.form_hook_failed(:input_invalid)
      assert problem.status == 503
      assert problem.extensions == %{"code" => "input_invalid"}

      conn = Response.form_hook_failed(conn(:post, "/x"), :input_invalid)
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == "input_invalid"
      assert String.ends_with?(body["type"], "service-unavailable")
    end

    test "the constructor takes only the eight atoms" do
      for code <- @codes,
          do: assert(Error.form_hook_failed(String.to_existing_atom(code)).status == 503)

      assert_raise FunctionClauseError, fn -> Error.form_hook_failed(:anything_else) end
      assert_raise FunctionClauseError, fn -> Error.form_hook_failed("script_error") end
    end

    test "two different scripts failing with one code give identical bodies" do
      stub(fn _n -> {:error, :script_error, %{}} end)
      a = setup_case!(source: "return { ok = true } -- first")
      b = setup_case!(source: "return { ok = true } -- second")
      body_a = complete_503(a, "script_error")
      body_b = complete_503(b, "script_error")
      assert without_request_members(body_a) == without_request_members(body_b)
    end
  end

  describe "criterion 9 unexpected exception in the hook" do
    test "F4-13 a raising runner answers 503 script_error with no stack trace and no oracle" do
      stub(fn _n -> raise "BOOM-SECRET" end)
      ctx = setup_case!()
      assert %{"code" => "script_error"} = complete_503(ctx, "script_error")
    end

    test "F4-14 the five script_rejected causes answer identical bodies" do
      stub(fn _n -> accept() end)

      # 1 kill switch
      one = setup_case!()
      Application.put_env(:letflow, :form_validation_hook_enabled, false)
      b1 = complete_503(one, "script_rejected")
      Application.put_env(:letflow, :form_validation_hook_enabled, true)

      # 2 revoked
      two = setup_case!()
      F.revoke_raw!(two.schema, two.rule)
      b2 = complete_503(two, "script_rejected")

      # 3 sha mismatch
      three = setup_case!()

      break_sha!(three, String.duplicate("b", 64))

      b3 = complete_503(three, "script_rejected")

      # 4 pin row missing
      four = setup_case!()

      drop_row!(four)

      b4 = complete_503(four, "script_rejected")

      # 5 a version number that exists only in another tenant: a rule published in tenant one
      # under the same key does not exist in tenant five's schema
      five = setup_case!()

      drop_row!(five)

      F.published!(one.schema, five.rule.key, "return { ok = true }", manifest(),
        hook_kind: "form_validation"
      )

      b5 = complete_503(five, "script_rejected")

      bodies = Enum.map([b1, b2, b3, b4, b5], &without_request_members/1)
      assert bodies |> Enum.uniq() |> length() == 1
    end
  end
end
