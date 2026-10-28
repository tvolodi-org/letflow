defmodule Letflow.Routers.TasksFormHookTest do
  @moduledoc """
  REQ-605 / GH #3409 (decision 0067 D8, slice F-3 part A), test T4r: `POST /tasks/:id/complete`
  through the full `Letflow.Router` pipeline with a real API token answers a refusing
  `form_validation` hook with a 422 `form_hook_refused` problem (manifest codes only), leaves the
  task pending and writes no `task.completion_refused` audit row. `async: false` (application env).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.ScriptTaskFixture, as: F

  @submitted "SUBMITTED-VALUE-3409"
  @source "local secret = 'SOURCE-MARKER-3409'; return { ok = false }"

  defmodule StubRunner do
    @moduledoc false
    def run(_source, _input, _opts) do
      {:ok,
       %{
         output: %{
           "ok" => false,
           "code" => "too_small",
           "fields" => [%{"field" => "amount", "code" => "too_small"}]
         },
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
      "limits" => %{"timeout_ms" => 50}
    }
  end

  defp setup_case! do
    set_env(:form_validation_hook_enabled, true)
    set_env(:form_validation_script_runner, StubRunner)

    t = F.tenant!("f3r")
    schema = t.schema_name
    %Tenant{slug: slug} = Repo.get!(Tenant, t.tenant_id)

    caller =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "f3r-#{System.unique_integer([:positive])}",
        display_name: "F3 Caller",
        email: "f3r-#{System.unique_integer([:positive])}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    rule = F.published!(schema, "fv_route", @source, manifest(), hook_kind: "form_validation")

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

    %{t: t, schema: schema, slug: slug, caller: caller, rule: rule, task: task}
  end

  test "T4r a refusing hook answers 422 with manifest codes only; the task stays pending" do
    ctx = setup_case!()

    {:ok, %{plaintext: token}} =
      Identity.create_token(ctx.caller.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: ctx.schema
      )

    conn =
      conn(
        :post,
        "/api/v1/tasks/#{ctx.task.id}/complete",
        Jason.encode!(%{"amount" => 1, "note" => @submitted})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-tenant-slug", ctx.slug)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

    assert conn.status == 422
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "form_hook_refused"
    assert body["hook_code"] == "too_small"
    assert body["fields"] == [%{"field" => "amount", "code" => "too_small"}]

    for text <- [@submitted, "SOURCE-MARKER-3409", ctx.rule.key, ctx.rule.sha256, "Elixir."] do
      refute conn.resp_body =~ text, "body leaked #{inspect(text)}"
    end

    assert Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema).status == :pending

    assert Repo.all(from(a in Audit.Entry, where: a.action == "task.completion_refused"),
             prefix: ctx.schema
           ) == []
  end
end
