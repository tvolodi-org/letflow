defmodule Letflow.Definitions.ReservedReferencesActivationTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1b (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2A.3, 2A.4, 2A.6; supervisor ruling 2026-10-15): a definition whose expressions or variable
  bindings name the reserved engine namespace is refused at save (CHK-29/CHK-30) and at every
  activation path (activate, version rollback, promotion apply), with
  `expression_references_reserved_variable` (HTTP 422). A refusal writes nothing.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Definitions.Graph.Violation
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @code :expression_references_reserved_variable
  @promotions_opts Letflow.Routers.Promotions.init([])
  @definitions_opts Letflow.Routers.Definitions.init([])

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── one graph per location (each otherwise passes every save check) ───────────────────

  defp entry(name), do: %{"name" => name, "json_schema" => %{"type" => "string"}}

  # START -> <node> -> END
  defp around(node) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        node,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => node["id"]},
        %{"id" => "e2", "source" => node["id"], "target" => "end"}
      ]
    }
  end

  defp human_form(field_schema) do
    around(%{
      "id" => "ht",
      "node_type" => "HUMAN_TASK",
      "attributes" => %{
        "role" => "REVIEWER",
        "form_schema" => %{
          "type" => "object",
          "properties" => %{"_sys" => %{"type" => "boolean"}, "f" => field_schema}
        }
      }
    })
  end

  defp service(attrs),
    do:
      around(%{
        "id" => "svc",
        "node_type" => "SERVICE_TASK",
        "attributes" => Map.put(attrs, "timeout_ms", 1_000)
      })

  defp sub_process(interface),
    do:
      around(%{
        "id" => "sp",
        "node_type" => "SUB_PROCESS",
        "attributes" => %{"interface" => interface}
      })

  # L1: a HUMAN_TASK with a conditioned edge naming the namespace and an unconditioned fallback.
  defp l1_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"},
        %{"id" => "end2", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{
          "id" => "e2",
          "source" => "ht",
          "target" => "end",
          "condition" => "variables._sys.r.seq > 0"
        },
        %{"id" => "e3", "source" => "ht", "target" => "end2"}
      ]
    }
  end

  defp ref(element, id, location, field, name),
    do: %{element: element, id: id, location: location, field: field, name: name}

  # {label, graph, expected reference}
  defp locations do
    [
      {"L1 edge condition", l1_graph(), ref(:edge, "e2", :edge_condition, nil, "_sys.r.seq")},
      {"L2 form visible_when",
       human_form(%{"type" => "string", "x-ui" => %{"visible_when" => "_sys == true"}}),
       ref(:node, "ht", :form_visible_when, "f", "_sys")},
      {"L3 form computed", human_form(%{"type" => "boolean", "x-ui" => %{"computed" => "_sys"}}),
       ref(:node, "ht", :form_computed, "f", "_sys")},
      {"L4 form cross_field_validation",
       human_form(%{
         "type" => "string",
         "x-ui" => %{
           "cross_field_validation" => %{"expression" => "_sys != null", "message" => "m"}
         }
       }), ref(:node, "ht", :form_cross_field_validation, "f", "_sys")},
      {"L5 service endpoint",
       service(%{"endpoint" => "https://example.invalid/{{variables._sys}}"}),
       ref(:node, "svc", :service_task_endpoint, nil, "_sys")},
      {"L6 service body_template",
       service(%{
         "endpoint" => "https://example.invalid/x",
         "body_template" => "{\"a\":\"{{variables._sys}}\"}"
       }), ref(:node, "svc", :service_task_body_template, nil, "_sys")},
      {"L7 sub-process input", sub_process(%{"inputs" => [entry("_sys.x")]}),
       ref(:node, "sp", :sub_process_input, "_sys.x", "_sys.x")},
      {"L8 sub-process output", sub_process(%{"outputs" => [entry("_sys.x")]}),
       ref(:node, "sp", :sub_process_output, "_sys.x", "_sys.x")}
    ]
  end

  defp trivial_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # ── rows ──────────────────────────────────────────────────────────────────────────────

  # A row stored before A1b: inserted directly, bypassing save-time checks.
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

  defp activate_audit_rows(schema, id),
    do:
      Repo.all(
        from(e in Entry, where: e.action == "definition.activate" and e.resource_id == ^id),
        prefix: schema
      )

  defp rows_named(schema, name),
    do: Repo.all(from(d in ProcessDefinition, where: d.name == ^name), prefix: schema)

  # ── the three activation paths (domain) ───────────────────────────────────────────────

  defp activate_path(schema, graph) do
    name = unique("a1b-act")
    prior = raw_definition!(schema, name, "0", trivial_graph(), :active)
    draft = raw_definition!(schema, name, "1", graph, :draft)
    result = Definitions.activate(draft.id, prefix: schema)

    {result, status(schema, draft.id), status(schema, prior.id),
     activate_audit_rows(schema, draft.id)}
  end

  defp rollback_path(schema, graph) do
    key = unique("a1b-rb")
    raw_definition!(schema, key, "1", graph, :deprecated)
    v2 = raw_definition!(schema, key, "2", trivial_graph(), :active)
    test_pid = self()

    result =
      Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
        prefix: schema,
        permission_checker: fn _actor, _tenant -> true end,
        event_appender: fn _attrs, _prefix ->
          send(test_pid, :event_appender_called)
          {:ok, %{event_id: Ecto.UUID.generate()}}
        end
      )

    {result, status(schema, v2.id)}
  end

  defp promote_path(source, target, graph) do
    key = unique("a1b-promo")
    source_def = raw_definition!(source.schema_name, key, "1.0.0", graph, :active)

    plan = %{
      source_tenant_id: source.tenant_id,
      target_tenant_id: target.tenant_id,
      process_key: key,
      source_definition_id: source_def.id,
      target_definition_id: nil,
      base_version: nil,
      entries: []
    }

    review =
      struct(PromotionReview, %{
        id: Ecto.UUID.generate(),
        plan_digest: PromotionDigest.compute_plan_digest(plan),
        def_id: key,
        serialised_plan: Jason.encode!(plan),
        requested_by: Ecto.UUID.generate(),
        status: :approved,
        row_version: 2
      })

    result =
      Promotion.promote_definition(Ecto.UUID.generate(), review,
        permission_checker: fn _actor, _tenant -> true end,
        event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
      )

    {result, rows_named(target.schema_name, key)}
  end

  setup do
    %{
      source: F.tenant_without_hmac!("gh2587-a1b-src"),
      target: F.tenant_without_hmac!("gh2587-a1b-tgt")
    }
  end

  # ── save ──────────────────────────────────────────────────────────────────────────────

  describe "save: Definitions.create/2 refuses each location (CHK-29/CHK-30)" do
    test "L1-L8 -> graph_validation_failed with only the reserved violation; nothing stored", %{
      target: t
    } do
      for {label, graph, _ref} <- locations() do
        name = unique("a1b-save")

        assert {:error, {:graph_validation_failed, violations}} =
                 Definitions.create(
                   %{name: name, version: "1", graph: graph, created_by: Ecto.UUID.generate()},
                   prefix: t.schema_name
                 ),
               label

        assert [%Violation{code: @code}] = violations, "#{label}: #{inspect(violations)}"
        assert rows_named(t.schema_name, name) == [], label
      end
    end

    test "validate_definition_graph/2 on a stored row lists the violation", %{target: t} do
      row = raw_definition!(t.schema_name, unique("a1b-val"), "1", l1_graph(), :draft)

      assert {:ok, %{valid: false, violations: violations}} =
               Definitions.validate_definition_graph(row.id, prefix: t.schema_name)

      assert @code in Enum.map(violations, & &1.code)
    end
  end

  # ── activation ────────────────────────────────────────────────────────────────────────

  describe "an existing definition cannot reference the reserved namespace" do
    test "activate/2 refuses every location L1-L8; draft stays draft, prior stays active, no audit",
         %{target: t} do
      for {label, graph, expected} <- locations() do
        assert {{:error, {@code, [^expected]}}, :draft, :active, []} =
                 activate_path(t.schema_name, graph),
               label
      end
    end

    test "control: the trivial graph activates", %{target: t} do
      assert {{:ok, %{already_active: false}}, :active, :deprecated, [_audit]} =
               activate_path(t.schema_name, trivial_graph())
    end

    test "version rollback to an L1 version is refused; v2 stays active; no event", %{target: t} do
      [{_label, graph, expected} | _] = locations()
      assert {{:error, {@code, [^expected]}}, :active} = rollback_path(t.schema_name, graph)
      refute_received :event_appender_called
    end

    test "promotion of an L2 source is refused; nothing in the target", %{source: s, target: t} do
      {_label, graph, expected} = Enum.at(locations(), 1)
      assert {{:error, {@code, [^expected]}}, []} = promote_path(s, t, graph)
    end
  end

  defp script_with_input!(schema, property) do
    key = "a1b_#{System.unique_integer([:positive])}"

    manifest =
      put_in(F.closed_manifest(), ["input_schema", "properties"], %{
        "amount" => %{"type" => "integer"},
        property => %{"type" => "string"}
      })

    {key, F.published!(schema, key, F.doubling_source(), manifest).version}
  end

  # ── L9: bound script inputs ───────────────────────────────────────────────────────────

  describe "L9: a bound script declaring a reserved input" do
    test "is refused in all three paths with location :script_input", %{source: s, target: t} do
      {key, version} = script_with_input!(t.schema_name, "_sys.r")
      graph = F.script_graph(key, version)
      expected = {:error, {@code, [ref(:node, "svc", :script_input, "_sys.r", "_sys.r")]}}

      assert {^expected, :draft, :active, []} = activate_path(t.schema_name, graph)
      assert {^expected, :active} = rollback_path(t.schema_name, graph)
      assert {^expected, []} = promote_path(s, t, graph)
    end

    test "regression: an ordinary property activates in all three paths", %{source: s, target: t} do
      {key, version} = script_with_input!(t.schema_name, "system_r")
      graph = F.script_graph(key, version)

      assert {{:ok, _}, :active, :deprecated, [_]} = activate_path(t.schema_name, graph)
      assert {{:ok, _}, :deprecated} = rollback_path(t.schema_name, graph)
      assert {{:ok, _}, [%{status: :active}]} = promote_path(s, t, graph)
    end

    test "ordering: an L1 reference AND an unpublished binding -> the reserved error (runs first)",
         %{source: s, target: t} do
      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"script_key" => "a1b_never_published", "script_version" => 1}
          },
          %{"id" => "end", "node_type" => "END"},
          %{"id" => "end2", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "ht"},
          %{"id" => "e2", "source" => "ht", "target" => "svc"},
          %{"id" => "e3", "source" => "ht", "target" => "end2", "condition" => "_sys == 1"},
          %{"id" => "e4", "source" => "svc", "target" => "end"}
        ]
      }

      expected = {:error, {@code, [ref(:edge, "e3", :edge_condition, nil, "_sys")]}}

      assert {^expected, :draft, :active, []} = activate_path(t.schema_name, graph)
      assert {^expected, :active} = rollback_path(t.schema_name, graph)
      assert {^expected, []} = promote_path(s, t, graph)
    end
  end

  # ── HTTP ──────────────────────────────────────────────────────────────────────────────

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
    |> assign(:trace_id, "gh2587-a1b")
  end

  defp definitions(conn), do: Letflow.Routers.Definitions.call(conn, @definitions_opts)
  defp promotions(conn), do: Letflow.Routers.Promotions.call(conn, @promotions_opts)

  defp assert_422(resp, reference) do
    assert resp.status == 422, resp.resp_body

    assert Jason.decode!(resp.resp_body) == %{
             "error" => "expression_references_reserved_variable",
             "references" => [reference]
           }
  end

  @l1_body %{
    "element" => "edge",
    "id" => "e2",
    "location" => "edge_condition",
    "field" => nil,
    "name" => "_sys.r.seq"
  }

  describe "HTTP 422" do
    test "POST /definitions refuses at save", %{target: t} do
      name = unique("a1b-http-save")

      resp =
        build_conn(:post, "/", t, %{"name" => name, "version" => "1", "graph" => l1_graph()})
        |> definitions()

      assert resp.status == 422, resp.resp_body
      assert Enum.any?(Jason.decode!(resp.resp_body)["errors"], &(&1["code"] == "#{@code}"))
      assert rows_named(t.schema_name, name) == []
    end

    test "POST /definitions/:id/activate", %{target: t} do
      draft = raw_definition!(t.schema_name, unique("a1b-http-act"), "1", l1_graph(), :draft)

      build_conn(:post, "/#{draft.id}/activate", t, nil)
      |> definitions()
      |> assert_422(@l1_body)

      assert status(t.schema_name, draft.id) == :draft
    end

    test "POST /definitions/:process_key/rollback", %{target: t} do
      key = unique("a1b-http-rb")
      raw_definition!(t.schema_name, key, "1.0.0", l1_graph(), :deprecated)
      v2 = raw_definition!(t.schema_name, key, "2.0.0", trivial_graph(), :active)

      build_conn(:post, "/#{key}/rollback", t, %{"target_version" => "1.0.0"})
      |> definitions()
      |> assert_422(@l1_body)

      assert status(t.schema_name, v2.id) == :active
    end

    test "POST /promotions/:id/apply", %{source: source, target: target} do
      key = unique("a1b-http-promo")
      raw_definition!(source.schema_name, key, "2.0.0", l1_graph(), :active)

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
        idempotency_key: unique("gh2587-a1b-run"),
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
      |> assert_422(@l1_body)

      assert rows_named(target.schema_name, key) == []
    end
  end
end
