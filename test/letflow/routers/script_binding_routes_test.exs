defmodule Letflow.Routers.ScriptBindingRoutesTest do
  @moduledoc """
  GH 2534 PR 7c-1 (TDV T1; design `lib/letflow/design/gh2534-7c-script-handler.md` 4.5): the
  three routes that activate a definition answer a refused script binding with 422
  `{"error": "script_binding_invalid", "node_id", "reason"}` -- `POST /definitions/:id/activate`,
  `POST /definitions/:process_key/rollback` and `POST /promotions/:id/apply`. Driven through the
  real routers (dispatch helpers mirror `req077_promotion_pipeline_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @promotions_opts Letflow.Routers.Promotions.init([])
  @definitions_opts Letflow.Routers.Definitions.init([])

  defp build_conn(method, path, tenant, body) do
    conn = conn(method, path)

    conn =
      if body,
        do: put_req_header(%{conn | body_params: body}, "content-type", "application/json"),
        else: conn

    PlatformTenantFixture.pin!(tenant.tenant_id)

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    })
    |> assign(:trace_id, "gh2534-7c-routes")
  end

  defp definitions(conn), do: Letflow.Routers.Definitions.call(conn, @definitions_opts)
  defp promotions(conn), do: Letflow.Routers.Promotions.call(conn, @promotions_opts)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp assert_refused(resp, reason) do
    assert resp.status == 422, resp.resp_body

    assert Jason.decode!(resp.resp_body) == %{
             "error" => "script_binding_invalid",
             "node_id" => "svc",
             "reason" => reason
           }
  end

  test "POST /definitions/:id/activate -> 422 script_binding_invalid" do
    t = F.tenant_without_hmac!("gh2534-7c-rt-act")
    draft = F.draft_definition!(t.schema_name, F.script_graph("absent_key", 1), [])

    build_conn(:post, "/#{draft.id}/activate", t, nil)
    |> definitions()
    |> assert_refused("script_not_published")

    assert Repo.get!(ProcessDefinition, draft.id, prefix: t.schema_name).status == :draft
  end

  test "POST /definitions/:process_key/rollback -> 422 script_binding_invalid" do
    t = F.tenant_without_hmac!("gh2534-7c-rt-rb")
    key = unique("rb")
    rule = F.published!(t.schema_name, "rb_key", F.doubling_source(), F.closed_manifest())

    {:ok, v1} =
      Definitions.create(
        %{
          name: key,
          version: "1.0.0",
          graph: F.script_graph("rb_key", rule.version),
          created_by: Ecto.UUID.generate()
        },
        prefix: t.schema_name
      )

    {:ok, _} = Definitions.activate(v1.id, prefix: t.schema_name)

    {:ok, v2} =
      Definitions.create(
        %{
          name: key,
          version: "2.0.0",
          graph: %{
            "nodes" => [
              %{"id" => "start", "node_type" => "START"},
              %{"id" => "end", "node_type" => "END"}
            ],
            "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
          },
          created_by: Ecto.UUID.generate()
        },
        prefix: t.schema_name
      )

    {:ok, _} = Definitions.activate(v2.id, prefix: t.schema_name)
    F.revoke_raw!(t.schema_name, rule)

    build_conn(:post, "/#{key}/rollback", t, %{"target_version" => "1.0.0"})
    |> definitions()
    |> assert_refused("script_not_published")

    assert Repo.get!(ProcessDefinition, v2.id, prefix: t.schema_name).status == :active
  end

  test "POST /promotions/:id/apply -> 422 script_binding_invalid" do
    source = F.tenant_without_hmac!("gh2534-7c-rt-src")
    target = F.tenant_without_hmac!("gh2534-7c-rt-tgt")
    key = unique("promo")

    # the source runs a script the TARGET tenant has never published
    source_row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: key,
        version: "2.0.0",
        graph: F.script_graph("source_only_key", 1),
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: source.schema_name)

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^source_row.id)
      |> Repo.update_all([set: [status: :active]], prefix: source.schema_name)

    submit =
      build_conn(:post, "/", target, %{
        "source_tenant_id" => source.tenant_id,
        "target_tenant_id" => target.tenant_id,
        "process_key" => key,
        "base_version" => "1.0.0"
      })
      |> promotions()

    assert submit.status == 201, submit.resp_body
    %{"review_id" => review_id, "plan_digest" => digest} = Jason.decode!(submit.resp_body)

    approve =
      build_conn(:post, "/#{review_id}/approve", target, %{"plan_digest" => digest})
      |> promotions()

    assert approve.status == 200, approve.resp_body

    %PromotionAssertionRun{
      review_id: review_id,
      idempotency_key: unique("gh2534-7c-run"),
      plan_digest: digest,
      status: :passed,
      assertions_total: 1,
      assertions_passed: 1,
      assertions_failed: 0,
      completed_at: DateTime.utc_now()
    }
    |> Repo.insert!(prefix: target.schema_name)

    build_conn(:post, "/#{review_id}/apply", target, %{"plan_digest" => digest})
    |> promotions()
    |> assert_refused("script_not_published")

    assert Repo.all(from(d in ProcessDefinition, where: d.name == ^key),
             prefix: target.schema_name
           ) == []
  end
end
