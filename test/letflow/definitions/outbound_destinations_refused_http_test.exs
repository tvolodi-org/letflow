defmodule Letflow.Definitions.OutboundDestinationsRefusedHttpTest do
  @moduledoc """
  T-2597 (pilot gap G14): the HTTP SURFACE of a refused outbound destination.

  The allow-list fence (`Letflow.Definitions.check_outbound_destinations/2`) refuses a
  version whose destination the tenant's list does not allow. Over HTTP the refusal
  is a TYPED 422 -- `outbound_destinations_invalid`, the node, the index and a fixed
  code, never a value -- and NEVER a 500 (INV-8). One test per switch-on surface:
  activate, reactivate, version rollback, promotion apply, review-free promotion.
  Each asserts the body shape AND that nothing was activated or promoted.

  The rows are inserted directly (as the sibling
  `notify_calls_refused_activation_test.exs` does): the promotion writes such a
  graph without the write-path graph rule. The ids: H1..H5.
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

  setup do
    %{
      source: F.tenant!("t2597-notify-src"),
      target: F.tenant!("t2597-notify-tgt")
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── the graph ────────────────────────────────────────────────────────────────────────

  # START -> an inline HTTP step -> END. The tenant's list is empty (deny by default),
  # so the HTTP channel is not allowed.
  defp bad_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "step",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "endpoint" => "https://api.example.com/hook",
            "method" => "POST",
            "timeout_ms" => 30_000
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "step"},
        %{"id" => "e2", "source" => "step", "target" => "end"}
      ]
    }
  end

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
    |> assign(:trace_id, "t2597-notify-refused")
  end

  defp definitions(conn), do: Letflow.Routers.Definitions.call(conn, @definitions_opts)
  defp promotions(conn), do: Letflow.Routers.Promotions.call(conn, @promotions_opts)
  defp tenants(conn), do: Letflow.Routers.Tenants.call(conn, @tenants_opts)

  # The typed answer of the fence: 422, the fixed error name, the node, the index and a
  # fixed code. Nothing else -- no value, no host.
  defp assert_outbound_422(resp) do
    assert resp.status == 422, resp.resp_body

    assert %{"error" => "outbound_destinations_invalid", "violations" => [violation]} =
             Jason.decode!(resp.resp_body)

    assert %{"node_id" => "step", "index" => 0, "code" => code} = violation
    assert code in ["outbound_channel_not_allowed", "outbound_destination_not_allowed"]
    refute resp.resp_body =~ "api.example.com"
  end

  describe "a refused outbound destination over HTTP" do
    test "H1 the ACTIVATION path answers 422 with the fixed code; the version stays DRAFT", %{
      target: t
    } do
      draft = raw_definition!(t.schema_name, unique("t2597-notify-act"), "1", bad_graph(), :draft)

      resp = build_conn(:post, "/#{draft.id}/activate", t, nil) |> definitions()

      assert_outbound_422(resp)

      assert status(t.schema_name, draft.id) == :draft
      assert activate_audit_rows(t.schema_name, draft.id) == []
    end

    test "H2 the REACTIVATION path answers 422 with the fixed code; the row stays ACTIVE", %{
      target: t
    } do
      row =
        raw_definition!(t.schema_name, unique("t2597-notify-react"), "1", bad_graph(), :active)

      # The flag the reactivation path looks for, written by the product's own
      # writer (both columns, never by hand).
      assert {:ok, [_id]} =
               Reactivation.mark_definition(row.id, :activator_absent, t.schema_name)

      resp = build_conn(:post, "/#{row.id}/reactivate", t, nil) |> definitions()

      assert_outbound_422(resp)

      assert status(t.schema_name, row.id) == :active
    end

    test "H3 the VERSION ROLLBACK path answers 422 with the fixed code; the active stays", %{
      target: t
    } do
      key = unique("t2597-notify-rb")
      raw_definition!(t.schema_name, key, "1.0.0", bad_graph(), :deprecated)
      v2 = raw_definition!(t.schema_name, key, "2.0.0", good_graph(), :active)

      resp =
        build_conn(:post, "/#{key}/rollback", t, %{"target_version" => "1.0.0"}) |> definitions()

      assert_outbound_422(resp)

      assert status(t.schema_name, v2.id) == :active
    end

    test "H4 the PROMOTION APPLY path answers 422 with the fixed code; the target holds nothing",
         %{source: source, target: target} do
      key = unique("t2597-notify-promo")
      raw_definition!(source.schema_name, key, "2.0.0", bad_graph(), :active)

      {review_id, digest} = submit_and_approve!(target, source, key)

      resp =
        build_conn(:post, "/#{review_id}/apply", target, %{"plan_digest" => digest})
        |> promotions()

      assert_outbound_422(resp)

      assert rows_named(target.schema_name, key) == []
    end

    test "H5 the REVIEW-FREE PROMOTION path answers 422 with the fixed code; the target holds nothing",
         %{source: source, target: target} do
      key = unique("t2597-notify-tpromo")
      raw_definition!(source.schema_name, key, "1.0.0", bad_graph(), :active)

      resp = build_conn(:post, "/#{source.tenant_id}/promote/#{key}", target, nil) |> tenants()

      assert_outbound_422(resp)

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
      idempotency_key: unique("t2597-notify-run"),
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
