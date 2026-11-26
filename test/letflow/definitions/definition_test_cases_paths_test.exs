defmodule Letflow.Definitions.DefinitionTestCasesPathsTest do
  @moduledoc """
  T-2604 (pilot gap G16, class SF-04): ONE NEGATIVE TEST PER SIBLING PATH.

  The declared-test-cases fence runs on every path that switches a version on:
  reactivation, version rollback and promotion apply (activate and create are
  proved in `definition_test_cases_activation_test.exs`). This file proves each
  of those refuses a failing declaration, that the route answers the typed 422
  (never the catch-all 500), that PUT and PATCH refuse a MALFORMED declaration,
  and that the 422 body carries only name/reason/key -- never a variable value
  (INV-4, class SF-08).

  A promoted definition CARRIES its declared cases (docs/definition-test-cases.md).

  `async: false`: the platform tenant pin is application configuration.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @definitions_opts Letflow.Routers.Definitions.init([])
  @promotions_opts Letflow.Routers.Promotions.init([])

  setup do
    tenant = Fx.tenant!("t2604-paths")
    PlatformFx.pin!(tenant.tenant_id)
    admin = Fx.user!(tenant.schema_name, "paths-admin")
    Fx.platform_admin!(tenant.schema_name, admin)
    %{tenant: tenant, admin: admin, prefix: tenant.schema_name}
  end

  defp activator(ctx),
    do: Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # The run ends with approved = true, but the case expects the canary.
  defp failing_case do
    %{
      "name" => "the applicant is approved",
      "complete_tasks" => [%{"node_id" => "task", "outputs" => %{"approved" => "CANARY-s3cr3t"}}],
      "expect" => %{"variables" => %{"approved" => "CANARY-expected"}}
    }
  end

  defp insert_raw!(prefix, key, version, test_cases) do
    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(%{
      name: key,
      version: version,
      graph: graph(),
      created_by: Ecto.UUID.generate(),
      test_cases: test_cases
    })
    |> Repo.insert!(prefix: prefix)
  end

  defp set!(prefix, id, fields) do
    {1, _} =
      Repo.update_all(from(d in ProcessDefinition, where: d.id == ^id), [set: fields],
        prefix: prefix
      )
  end

  defp build_conn(method, path, tenant, body) do
    conn = conn(method, path)

    conn =
      if body,
        do: put_req_header(%{conn | body_params: body}, "content-type", "application/json"),
        else: conn

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    })
    |> assign(:trace_id, "t2604-paths")
  end

  defp definitions(conn), do: Letflow.Routers.Definitions.call(conn, @definitions_opts)
  defp promotions(conn), do: Letflow.Routers.Promotions.call(conn, @promotions_opts)

  defp assert_refused_422(resp) do
    assert resp.status == 422, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["error"] == "definition_test_cases_failed"
    assert [failure] = body["failures"]
    assert failure |> Map.keys() |> Enum.sort() == ["key", "name", "reason"]
    assert failure["reason"] == "variable_mismatch"
    refute resp.resp_body =~ "CANARY"
  end

  # v1 (failing cases, forged raw: activation would refuse it) is deprecated;
  # v2 is the active version.
  defp rollback_setup(ctx, key) do
    v1 = insert_raw!(ctx.prefix, key, "1.0.0", [failing_case()])
    set!(ctx.prefix, v1.id, status: :deprecated)
    v2 = insert_raw!(ctx.prefix, key, "2.0.0", nil)
    assert {:ok, _} = Definitions.activate(v2.id, prefix: ctx.prefix, activator: activator(ctx))
  end

  test "the reactivation path refuses a failing declaration", ctx do
    draft = insert_raw!(ctx.prefix, unique("t2604-re"), "1.0.0", nil)

    assert {:ok, _} =
             Definitions.activate(draft.id, prefix: ctx.prefix, activator: activator(ctx))

    set!(ctx.prefix, draft.id,
      test_cases: [failing_case()],
      needs_reactivation_at: DateTime.utc_now(),
      needs_reactivation_reason: "test"
    )

    assert {:error, {:definition_test_cases_failed, [%{reason: :variable_mismatch}]}} =
             Definitions.reactivate(draft.id, prefix: ctx.prefix, activator: activator(ctx))
  end

  test "the version rollback path refuses a failing declaration", ctx do
    key = unique("t2604-rb")
    rollback_setup(ctx, key)

    assert {:error, {:definition_test_cases_failed, [%{reason: :variable_mismatch}]}} =
             Definitions.rollback_definition_version(key, "1.0.0", Ecto.UUID.generate(),
               prefix: ctx.prefix,
               activator: activator(ctx),
               permission_checker: fn _actor, _tenant -> true end,
               event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
             )
  end

  test "POST /:process_key/rollback answers the typed 422, never 500", ctx do
    key = unique("t2604-rbr")
    rollback_setup(ctx, key)

    build_conn(:post, "/#{key}/rollback", ctx.tenant, %{"target_version" => "1.0.0"})
    |> definitions()
    |> assert_refused_422()
  end

  describe "promotion apply" do
    setup do
      source = Fx.tenant!("t2604-src")
      target = Fx.tenant!("t2604-tgt")
      %{source: source, target: target}
    end

    defp promote(source, target, key) do
      PlatformFx.pin!(target.tenant_id)

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
        idempotency_key: unique("t2604-run"),
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
    end

    test "the promoted copy carries the declared cases and the fence refuses (422)", ctx do
      key = unique("t2604-promo")
      row = insert_raw!(ctx.source.schema_name, key, "2.0.0", [failing_case()])
      set!(ctx.source.schema_name, row.id, status: :active)

      resp = promote(ctx.source, ctx.target, key)
      assert_refused_422(resp)

      assert Repo.all(from(d in ProcessDefinition, where: d.name == ^key),
               prefix: ctx.target.schema_name
             ) == []
    end

    test "a source without declared cases is promoted as before", ctx do
      key = unique("t2604-promo-ok")
      row = insert_raw!(ctx.source.schema_name, key, "2.0.0", nil)
      set!(ctx.source.schema_name, row.id, status: :active)

      resp = promote(ctx.source, ctx.target, key)
      assert resp.status == 200, resp.resp_body
    end
  end

  describe "PUT and PATCH refuse a malformed declaration" do
    test "PUT answers 422 and the draft is unchanged", ctx do
      draft = insert_raw!(ctx.prefix, unique("t2604-put"), "1.0.0", nil)

      resp =
        build_conn(:put, "/#{draft.id}", ctx.tenant, %{
          "name" => draft.name,
          "version" => draft.version,
          "graph" => graph(),
          "test_cases" => [%{"name" => "no expectation"}]
        })
        |> definitions()

      assert resp.status == 422, resp.resp_body
      body = Jason.decode!(resp.resp_body)
      assert body["error"] == "definition_test_cases_invalid"
      assert body["reason"] == "expect_required"

      assert Repo.get!(ProcessDefinition, draft.id, prefix: ctx.prefix).test_cases == nil
    end

    test "PATCH answers 422 and the draft is unchanged", ctx do
      draft = insert_raw!(ctx.prefix, unique("t2604-patch"), "1.0.0", nil)

      resp =
        build_conn(:patch, "/#{draft.id}", ctx.tenant, %{
          "test_cases" => [%{"name" => "no expectation"}]
        })
        |> definitions()

      assert resp.status == 422, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"] == "definition_test_cases_invalid"
      assert Repo.get!(ProcessDefinition, draft.id, prefix: ctx.prefix).test_cases == nil
    end
  end

  test "the activate 422 body carries no variable value (canary)", ctx do
    draft = insert_raw!(ctx.prefix, unique("t2604-canary"), "1.0.0", [failing_case()])

    build_conn(:post, "/#{draft.id}/activate", ctx.tenant, nil)
    |> definitions()
    |> assert_refused_422()
  end
end
