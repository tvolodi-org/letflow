defmodule Letflow.Definitions.NotifyCallsRefusedActivationTest do
  @moduledoc """
  T-2596 (pilot gap G12, the "file" channel of the notification step): the HTTP
  SURFACE of a refused notification step.

  The fence of the notification step (`Letflow.Definitions.NotifyCalls`) refuses
  a declaration the moment a version is switched on. The refusal must reach the
  caller as a TYPED 422 -- `notify_calls_invalid` with the fixed code of the
  violation -- and NEVER as a 500 (INV-8: a request a person made must not
  crash the request).

  This file drives that refusal through the ROUTES, not through the context
  function: the six renderer clauses of the diff (the write, the activation,
  the reactivation, the version rollback, the promotion apply and the
  review-free promotion) answer with the typed body, and the version is NOT
  switched on.

  ## The reachable case

  A path-like file name is refused EARLIER, at the write path, by the graph
  rule (`Graph.validate_node_attributes/1` -> `check_notify/1`, which calls the
  very same `NotifyCalls.violations/2`). So the fence's own code is reached
  only by a row that was stored WITHOUT the node-attribute validation: the
  promotion path writes such a graph (it runs the platform-call and notify
  fences, not the graph rule), and a row written before the rule existed is
  stored the same way. The rows below are inserted directly, exactly as the
  product's own precedent for this shape does
  (`test/letflow/definitions/reserved_references_activation_test.exs`).

  The ids: N1..N6.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Reactivation
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: F
  alias Letflow.Support.PlatformTenantFixture

  @definitions_opts Letflow.Routers.Definitions.init([])
  @promotions_opts Letflow.Routers.Promotions.init([])
  @tenants_opts Letflow.Routers.Tenants.init([])

  # The fixed code of the violation: the file name is path-like.
  @code "notify_file_name_invalid"

  setup do
    %{
      source: F.tenant!("t2596-notify-src"),
      target: F.tenant!("t2596-notify-tgt")
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── the graph ────────────────────────────────────────────────────────────────────────

  # START -> the notification step -> END. The step carries the "file" channel
  # (T-2596) and a PATH-LIKE file name: the refusal the fence owes.
  defp notify_graph(file_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "notify",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "notify" => %{
              "channel" => "file",
              "template_key" => "tenant_registered",
              "file_name" => file_name,
              "values" => %{
                "tenant_name" => %{"var" => "tenant_name"},
                "tenant_slug" => %{"const" => "acme"}
              }
            }
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "notify"},
        %{"id" => "e2", "source" => "notify", "target" => "end"}
      ]
    }
  end

  defp bad_graph, do: notify_graph("../etc/passwd")

  defp good_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # ── rows ──────────────────────────────────────────────────────────────────────────────

  # A row stored WITHOUT the save-time checks (the shape a promotion writes,
  # and the shape a row written before the rule existed has).
  defp raw_definition!(schema, name, version, graph, status) do
    row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: name,
        version: version,
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema)

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^row.id)
      |> Repo.update_all([set: [status: status]], prefix: schema)

    row
  end

  defp status(schema, id), do: Repo.get!(ProcessDefinition, id, prefix: schema).status

  defp rows_named(schema, name),
    do: Repo.all(from(d in ProcessDefinition, where: d.name == ^name), prefix: schema)

  defp activate_audit_rows(schema, id),
    do:
      Repo.all(
        from(e in Entry, where: e.action == "definition.activate" and e.resource_id == ^id),
        prefix: schema
      )

  # ── the request surface ──────────────────────────────────────────────────────────────

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
    |> assign(:trace_id, "t2596-notify-refused")
  end

  defp definitions(conn), do: Letflow.Routers.Definitions.call(conn, @definitions_opts)
  defp promotions(conn), do: Letflow.Routers.Promotions.call(conn, @promotions_opts)
  defp tenants(conn), do: Letflow.Routers.Tenants.call(conn, @tenants_opts)

  # The typed answer of the fence: 422, the fixed error name and the fixed code
  # of the violation. Nothing else -- no value, no template, no file name.
  defp assert_notify_422(resp) do
    assert resp.status == 422, resp.resp_body

    assert Jason.decode!(resp.resp_body) == %{
             "error" => "notify_calls_invalid",
             "violations" => [
               %{"node_id" => "notify", "index" => 0, "code" => @code}
             ]
           }
  end

  describe "a refused notification step over HTTP" do
    test "N1 the WRITE path refuses a path-like file name and stores nothing", %{target: t} do
      name = unique("t2596-notify-save")

      resp =
        build_conn(:post, "/", t, %{"name" => name, "version" => "1", "graph" => bad_graph()})
        |> definitions()

      assert resp.status == 422, resp.resp_body

      payload = Jason.decode!(resp.resp_body)

      assert payload["detail"] == "definition graph failed validation"

      assert Enum.any?(payload["errors"], &(&1["code"] == @code)),
             "the code of the refusal must be in the body: #{inspect(payload)}"

      assert rows_named(t.schema_name, name) == []
    end

    test "N2 the ACTIVATION path answers 422 with the fixed code; the version stays DRAFT", %{
      target: t
    } do
      draft = raw_definition!(t.schema_name, unique("t2596-notify-act"), "1", bad_graph(), :draft)

      resp = build_conn(:post, "/#{draft.id}/activate", t, nil) |> definitions()

      assert_notify_422(resp)

      assert status(t.schema_name, draft.id) == :draft
      assert activate_audit_rows(t.schema_name, draft.id) == []
    end

    test "N3 the REACTIVATION path answers 422 with the fixed code; the row stays ACTIVE", %{
      target: t
    } do
      row =
        raw_definition!(t.schema_name, unique("t2596-notify-react"), "1", bad_graph(), :active)

      # The flag the reactivation path looks for, written by the product's own
      # writer (both columns, never by hand).
      assert {:ok, [_id]} =
               Reactivation.mark_definition(row.id, :activator_absent, t.schema_name)

      resp = build_conn(:post, "/#{row.id}/reactivate", t, nil) |> definitions()

      assert_notify_422(resp)

      assert status(t.schema_name, row.id) == :active
    end

    test "N4 the VERSION ROLLBACK path answers 422 with the fixed code; the active stays", %{
      target: t
    } do
      key = unique("t2596-notify-rb")
      raw_definition!(t.schema_name, key, "1.0.0", bad_graph(), :deprecated)
      v2 = raw_definition!(t.schema_name, key, "2.0.0", good_graph(), :active)

      resp =
        build_conn(:post, "/#{key}/rollback", t, %{"target_version" => "1.0.0"}) |> definitions()

      assert_notify_422(resp)

      assert status(t.schema_name, v2.id) == :active
    end

    test "N5 the PROMOTION APPLY path answers 422 with the fixed code; the target holds nothing",
         %{source: source, target: target} do
      key = unique("t2596-notify-promo")
      raw_definition!(source.schema_name, key, "2.0.0", bad_graph(), :active)

      {review_id, digest} = submit_and_approve!(target, source, key)

      resp =
        build_conn(:post, "/#{review_id}/apply", target, %{"plan_digest" => digest})
        |> promotions()

      assert_notify_422(resp)

      assert rows_named(target.schema_name, key) == []
    end

    test "N6 the REVIEW-FREE PROMOTION path answers 422 with the fixed code; the target holds nothing",
         %{source: source, target: target} do
      key = unique("t2596-notify-tpromo")
      raw_definition!(source.schema_name, key, "1.0.0", bad_graph(), :active)

      resp = build_conn(:post, "/#{source.tenant_id}/promote/#{key}", target, nil) |> tenants()

      assert_notify_422(resp)

      assert rows_named(target.schema_name, key) == []
    end
  end

  # The promotion under review: submit, approve, rehearse. The apply is the
  # step that copies the source's graph into the target -- and the step the
  # notify fence refuses.
  defp submit_and_approve!(target, source, key) do
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
      idempotency_key: unique("t2596-notify-run"),
      plan_digest: digest,
      status: :passed,
      assertions_total: 1,
      assertions_passed: 1,
      assertions_failed: 0,
      completed_at: DateTime.utc_now()
    }
    |> Repo.insert!(prefix: target.schema_name)

    {review_id, digest}
  end
end
