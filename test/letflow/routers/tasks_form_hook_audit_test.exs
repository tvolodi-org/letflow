defmodule Letflow.Routers.TasksFormHookAuditTest do
  @moduledoc """
  REQ-632 / GH #3524 (decision 0067 D9, slice F-4 part B, criterion 8; INV-1 / INV-5 / INV-10):
  `POST /tasks/:id/complete` through the full `Letflow.Router` pipeline with real API tokens. A
  caller of another tenant gets the answer given for an unknown task id, the sandbox is not started
  and no `task.form_hook_run` row is written in either tenant; the owner's completion writes its
  row in its own tenant only. `async: false` (application env).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.ScriptTaskFixture, as: F

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def calls, do: Agent.get(__MODULE__, & &1)

    def run(_source, _input, _opts) do
      Agent.update(__MODULE__, &(&1 + 1))

      {:ok,
       %{
         output: %{"ok" => true},
         stats: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}
       }}
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

  defp manifest do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}}
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
      "fields" => ["amount"],
      "limits" => %{"timeout_ms" => 50}
    }
  end

  defp user!(schema, label) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "#{label}-#{System.unique_integer([:positive])}",
      display_name: "F3B #{label}",
      email: "#{label}-#{System.unique_integer([:positive])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp token!(user, schema, roles) do
    {:ok, %{plaintext: token}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    token
  end

  # A tenant with one user, a published hook script (when `rule?`), a definition whose only human
  # node is assigned to that user (hook attributes when `rule?`), a started instance and its task.
  defp tenant_case!(label, rule?) do
    t = F.tenant!(label)
    schema = t.schema_name
    %Tenant{slug: slug} = Repo.get!(Tenant, t.tenant_id)
    assignee = user!(schema, "#{label}-assignee")

    hook =
      if rule? do
        rule =
          F.published!(
            schema,
            "fv_#{String.replace(label, "-", "_")}",
            "return { ok = true }",
            manifest(),
            hook_kind: "form_validation"
          )

        %{"validation_script_key" => rule.key, "validation_script_version" => rule.version}
      else
        %{}
      end

    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => Map.merge(%{"role" => assignee.id, "assignee_type" => "USER"}, hook)
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

    %{schema: schema, slug: slug, assignee: assignee, task: task}
  end

  defp post_complete(task_id, token, slug) do
    conn(:post, "/api/v1/tasks/#{task_id}/complete", Jason.encode!(%{"amount" => 5}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  # Response headers that differ per request by design (request correlation), removed before
  # comparing; everything else must be byte-identical.
  @per_request_headers ["x-request-id", "x-trace-id"]

  defp answer(conn) do
    headers = Enum.reject(conn.resp_headers, fn {k, _} -> k in @per_request_headers end)

    {conn.status, Enum.sort(headers),
     Regex.replace(~r/"trace_id":"[^"]*"/, conn.resp_body, "\"trace_id\":\"T\"")}
  end

  setup do
    set_env(:form_validation_hook_enabled, true)
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:form_validation_script_runner, StubRunner)
    :ok
  end

  defp hook_rows(schema),
    do:
      Repo.all(from(a in Letflow.Audit.Entry, where: a.action == "task.form_hook_run"),
        prefix: schema
      )

  test "F4B-13 another tenant's caller gets the unknown-task answer; no sandbox, no row anywhere" do
    a = tenant_case!("f4b-a", true)
    b = tenant_case!("f4b-b", false)
    caller_b = user!(b.schema, "f4b-b-admin")
    token_b = token!(caller_b, b.schema, ["TENANT_ADMIN"])

    foreign = post_complete(a.task.id, token_b, b.slug)
    unknown = post_complete(Ecto.UUID.generate(), token_b, b.slug)

    assert foreign.status in [403, 404]
    assert answer(foreign) == answer(unknown)
    assert StubRunner.calls() == 0
    assert hook_rows(a.schema) == []
    assert hook_rows(b.schema) == []
    assert Repo.get!(EngineTask, a.task.id, prefix: a.schema).status == :pending
  end

  test "F4B-14 the owner's completion writes its row in its own tenant only" do
    a = tenant_case!("f4b-own", true)
    b = tenant_case!("f4b-oth", false)

    conn = post_complete(a.task.id, token!(a.assignee, a.schema, ["TENANT_ADMIN"]), a.slug)

    assert conn.status == 200
    assert StubRunner.calls() == 1
    assert [row] = hook_rows(a.schema)
    assert row.resource_id == a.task.id
    assert hook_rows(b.schema) == []
  end
end
