defmodule Letflow.Engine.PlatformCallCompleterRefusedTest do
  @moduledoc """
  S2 of the platform-call authority rule (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`, decision
  (b)): a person's input may not decide what a platform call reads.

  The threat S2 names: a human task in the platform definition writes
  `tenant_id` or `slug` that `tenant.create` then reads -- the escalation
  through the completer's own body.

  The rule: a catalogue call's write-like input reads only the start variables
  or an earlier platform step's output. The engine therefore refuses the key in
  a completion body (the T-2430 rule, extended to catalogue calls), and the
  answer is the retryable 422 `output_refused` -- nothing is written.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2588-s2")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  # START -> HUMAN_TASK -> SERVICE_TASK (the platform call) -> END. `human_attrs` is
  # merged into the HUMAN_TASK's attributes.
  defp graph(human_attrs \\ %{}) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "ht",
          "node_type" => "HUMAN_TASK",
          "attributes" => Map.merge(%{"role" => "REVIEWER"}, human_attrs)
        },
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"const" => "Acme"}
              })
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "call"},
        %{"id" => "e3", "source" => "call", "target" => "end"}
      ]
    }
  end

  test "S2-a: the activation refuses a graph whose human task may write the call's read key",
       ctx do
    graph_with_input = graph(%{"completer_inputs" => ["slug"]})

    draft = Fx.definition!(ctx.tenant.schema_name, graph_with_input, "pcf-s2a")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_input_source_refused}]}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )
  end

  test "S2-b: a completion body carrying the call's read key is refused with the 422 output_refused",
       ctx do
    draft = Fx.definition!(ctx.tenant.schema_name, graph(), "pcf-s2b")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    auth_context = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: draft.id,
                 initial_variables: %{"slug" => "acme"},
                 actor_id: ctx.admin.id,
                 idempotency_key: "pcf-s2b-start"
               },
               prefix: ctx.tenant.schema_name,
               auth_context: auth_context
             )

    task =
      Task
      |> where([t], t.instance_id == ^result.instance_id)
      |> Repo.one!(prefix: ctx.tenant.schema_name)

    assert {:error, {:output_refused, %{missing_keys: [], rejected_keys: ["slug"]}}} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{"slug" => "evil"},
                 actor_id: ctx.admin.id,
                 idempotency_key: "pcf-s2b-complete"
               },
               prefix: ctx.tenant.schema_name
             )

    # the task stays pending and the instance is untouched: nothing was written
    assert %{status: :pending} = Repo.get!(Task, task.id, prefix: ctx.tenant.schema_name)

    # the refusal is the retryable 422 with the constant code
    conn =
      Plug.Test.conn(:post, "/")
      |> Response.output_refused([], ["slug"])

    assert conn.status == 422

    assert %{"code" => "output_refused", "rejected_keys" => ["slug"]} =
             conn.resp_body |> Jason.decode!()
  end

  test "S2-c: a completion body without the key is accepted (the rule is about the key, not the task)",
       ctx do
    draft = Fx.definition!(ctx.tenant.schema_name, graph(), "pcf-s2c")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    auth_context = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: draft.id,
                 initial_variables: %{"slug" => "acme"},
                 actor_id: ctx.admin.id,
                 idempotency_key: "pcf-s2c-start"
               },
               prefix: ctx.tenant.schema_name,
               auth_context: auth_context
             )

    task =
      Task
      |> where([t], t.instance_id == ^result.instance_id)
      |> Repo.one!(prefix: ctx.tenant.schema_name)

    result =
      Engine.complete_task(
        task.id,
        %{
          output_variables: %{"note" => "done"},
          actor_id: ctx.admin.id,
          idempotency_key: "pcf-s2c-complete"
        },
        prefix: ctx.tenant.schema_name
      )

    # the KEY rule does not fire: the body carried no read key of the call. (The
    # step library of gap G1 does not dispatch the platform call yet, so the
    # instance may stop at the SERVICE_TASK -- a different failure, not a refusal
    # of the completion.)
    refute match?({:error, {:output_refused, _}}, result)
  end
end
