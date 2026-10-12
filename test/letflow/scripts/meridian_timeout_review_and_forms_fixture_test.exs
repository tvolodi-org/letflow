defmodule Letflow.Scripts.MeridianTimeoutReviewAndFormsFixtureTest do
  @moduledoc """
  ISS-1015 / Q-997 (GH #2284), audit finding PA-MERIDIAN-003 -- two defects in the QA Meridian
  fixtures.

  ## 1. Timeouts reached `eligibility-gate` with the gate's variables never collected

  Loan Origination v1.8: `credit-memo-timeout` -> `assessment-join` (e5) and
  `risk-assessment-timeout` -> `assessment-join` (e7). After either timeout `credit_decision` /
  `risk_rating` were never recorded, so the gateway fell to `eligibility-gate-default` and the
  loan was declined without anyone judging it. v1.9 routes both timeouts to an escalation
  review (a HUMAN_TASK for an existing, more senior role) that records the missing value, then
  rejoins at `assessment-join`. The gate's default edge to `decline-application` is untouched:
  it stays the fail-closed fallback if the review is completed without the value.

  ## 2. No human task stated what must be recorded

  Every HUMAN_TASK in both definitions now has a `form_schema` whose `required` list names the
  decision field(s) and whose enums are the values the edge conditions compare against.

  CAVEAT (REQ-273, `Letflow.Engine.TaskActivation` moduledoc): `form_schema` is a UI RENDERING
  PAYLOAD ONLY. The engine does not reject a completion that violates it; the real protection is
  the fail-closed gateway defaults (Q-1002 gate, `eligibility-gate-default`, `e15`, the tally
  default...). Server-side enforcement would be a `variable_schemas` row (REQ-109).

  Pure: no DB, no HTTP. The graph walk uses the real `Letflow.Engine.Expr` evaluator and real
  `Letflow.Engine.Transition` dispatch.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.{Graph, JsonSchemaShape}
  alias Letflow.Engine.{Expr, InstanceState, Token, Transition}

  @fixtures Path.expand("../../fixtures", __DIR__)
  @loan Path.join(@fixtures, "qa/meridian_loan_origination_process_definition.json")
  @reg Path.join(@fixtures, "qa/meridian_regulatory_compliance_review_process_definition.json")
  @loan_yaml Path.join(@fixtures, "simulation/meridian/process_claim_intake.yaml")
  @reg_yaml Path.join(@fixtures, "simulation/meridian/process_policy_binding.yaml")
  @actors Path.join(@fixtures, "uat/actors.yaml")

  defp json!(path), do: path |> File.read!() |> Jason.decode!()
  defp loan, do: json!(@loan)
  defp reg, do: json!(@reg)
  defp yaml!(path), do: YamlElixir.read_from_file!(path)

  defp nodes(d), do: d["graph"]["nodes"]
  defp edges(d), do: d["graph"]["edges"]
  defp node(d, id), do: Enum.find(nodes(d), &(&1["id"] == id))
  defp edges_from(d, id), do: Enum.filter(edges(d), &(&1["source"] == id))

  defp graph!(d) do
    assert {:ok, graph} = Graph.from_map(d["graph"])
    graph
  end

  # ---- real-engine helpers ----------------------------------------------------------------

  defp settle(graph, node_id, variables) do
    state = %InstanceState{
      instance_id: "inst-iss1015",
      tokens: [%Token{node_id: node_id, token_id: "t1"}],
      variables: variables
    }

    do_settle(graph, state)
  end

  defp do_settle(graph, %InstanceState{tokens: [%Token{node_id: node_id}]} = state) do
    if Enum.find(graph.nodes, &(&1.id == node_id)).node_type == :EXCLUSIVE_GATEWAY do
      assert {:ok, next, []} = Transition.transition(graph, state, {:advance_token, "t1"})
      do_settle(graph, next)
    else
      node_id
    end
  end

  # What the real engine does when the human task `node_id` is completed.
  defp complete(graph, node_id, variables) do
    state = %InstanceState{
      instance_id: "inst-iss1015",
      tokens: [%Token{node_id: node_id, token_id: "t1"}],
      variables: variables
    }

    assert {:ok, %InstanceState{tokens: [%Token{node_id: next}]}, _} =
             Transition.transition(graph, state, {:complete_task, "t1"})

    next
  end

  # Nodes reachable from `start`, edges that can fire under `variables` (unconditioned edges,
  # default edges, conditions the real evaluator holds true), optionally with `blocked` removed.
  defp reachable(d, start, variables, blocked \\ []) do
    walk(d, [start], MapSet.new([start]), variables, blocked)
  end

  defp walk(_d, [], seen, _v, _b), do: seen

  defp walk(d, [n | rest], seen, v, blocked) do
    next =
      for e <- edges_from(d, n),
          is_nil(e["condition"]) or Expr.evaluate_condition(e["condition"], v),
          e["target"] not in seen,
          e["target"] not in blocked,
          uniq: true,
          do: e["target"]

    walk(d, rest ++ next, Enum.into(next, seen), v, blocked)
  end

  @pass %{
    "credit_decision" => "pass",
    "risk_rating" => "low",
    "kyc_status" => "clear",
    "requested_amount_eur" => 100_000
  }

  @reviews [
    # timeout node, escalation review node, role, decision variable
    {"credit-memo-timeout", "credit-memo-escalation-review", "role-credit-director",
     "credit_decision"},
    {"risk-assessment-timeout", "risk-assessment-escalation-review", "role-cro", "risk_rating"}
  ]

  describe "versions" do
    test "loan is 1.14 and regulatory is 1.10 (the bumps force the QA re-seed); seed header names both" do
      assert loan()["version"] == "1.14"
      assert reg()["version"] == "1.10"
      script = File.read!(Path.expand("../../../scripts/seed_meridian_definition.sh", __DIR__))
      assert script =~ ~s("Loan Origination" v1.14 )
      assert script =~ ~s("Regulatory Compliance Review" v1.10 )
    end
  end

  describe "timeouts do not reach eligibility-gate with unset variables" do
    test "each timeout node's only outgoing edge goes to its escalation review, not to assessment-join" do
      for {timeout, review, _role, _var} <- @reviews do
        assert [%{"target" => ^review} = e] = edges_from(loan(), timeout)
        refute Map.has_key?(e, "condition")
        assert node(loan(), review)["node_type"] == "HUMAN_TASK"
      end
    end

    test "the review is a single hop to assessment-join; no edge hides a second exit (ISS-1013: 'true' completion plus one timeout edge)" do
      for {_timeout, review, _role, _var} <- @reviews do
        edges = edges_from(loan(), review)
        assert Enum.all?(edges, &(&1["target"] == "assessment-join"))
        assert [%{"condition" => "true"}] = Enum.filter(edges, &Map.has_key?(&1, "condition"))

        assert [e] = Enum.reject(edges, &Map.has_key?(&1, "condition"))
        assert e["id"] == "timeout-" <> review
        refute e["is_default"] == true
      end
    end

    test "review roles are existing roles declared in the UAT actor roster (no invented role)" do
      declared =
        @actors
        |> yaml!()
        |> Map.fetch!("actors")
        |> Map.values()
        |> Enum.flat_map(&(&1["routing_roles"] || []))
        |> MapSet.new()

      for {_t, review, role, _v} <- @reviews do
        assert node(loan(), review)["attributes"]["role"] == role
        assert role in declared, "#{role} not held by any actor in actors.yaml"
      end
    end

    test "structure: without the review node, eligibility-gate is unreachable from either timeout node (non-vacuous with it)" do
      d = loan()

      for {timeout, review, _role, _var} <- @reviews do
        assert "eligibility-gate" in reachable(d, timeout, @pass)
        assert review in reachable(d, timeout, @pass)

        refute "eligibility-gate" in reachable(d, timeout, @pass, [review]),
               "#{timeout} reaches eligibility-gate without going through #{review}"
      end
    end

    test "after a timeout the gate's variable is only ever reached through the review that records it" do
      graph = graph!(loan())

      for {_timeout, review, _role, var} <- @reviews do
        # review completed with a real value -> rejoin
        assert "assessment-join" == complete(graph, review, Map.delete(@pass, var))
      end

      # credit timeout, review records the credit decision
      no_credit = Map.delete(@pass, "credit_decision")

      assert "l1-approval" ==
               settle(graph, "eligibility-gate", Map.put(no_credit, "credit_decision", "pass"))

      assert "decline-application" ==
               settle(graph, "eligibility-gate", Map.put(no_credit, "credit_decision", "fail"))

      # risk timeout, review records the rating
      no_risk = Map.delete(@pass, "risk_rating")

      assert "l1-approval" ==
               settle(graph, "eligibility-gate", Map.put(no_risk, "risk_rating", "medium"))

      assert "decline-application" ==
               settle(graph, "eligibility-gate", Map.put(no_risk, "risk_rating", "unacceptable"))
    end

    test "the fail-closed fallback is kept: a review completed WITHOUT the value still declines (never approves)" do
      graph = graph!(loan())

      for var <- ["credit_decision", "risk_rating"], missing <- [:absent, nil, ""] do
        vars =
          if missing == :absent, do: Map.delete(@pass, var), else: Map.put(@pass, var, missing)

        assert "decline-application" == settle(graph, "eligibility-gate", vars),
               "#{var}=#{inspect(missing)}"
      end

      assert [%{"target" => "decline-application"}] =
               Enum.filter(edges_from(loan(), "eligibility-gate"), &(&1["is_default"] == true))
    end

    test "Q-1002 kyc contract and the 'clear' fast path are intact" do
      d = loan()
      graph = graph!(d)
      ids = Enum.map(edges_from(d, "eligibility-gate"), & &1["id"])
      assert "e15" in ids and "e15-kyc-cleared" in ids
      assert "l1-approval" == settle(graph, "eligibility-gate", @pass)

      assert "decline-application" ==
               settle(
                 graph,
                 "eligibility-gate",
                 @pass |> Map.delete("kyc_status") |> Map.put("kyc_outcome", "rejected")
               )
    end

    test "no silent decline: with the review recorded and a passing application, the timeout paths reach create-facility" do
      d = loan()

      for {timeout, _review, _role, _var} <- @reviews do
        reached =
          reachable(
            d,
            timeout,
            Map.put(@pass, "l1_decision", "approve") |> Map.put("l2_decision", "approve")
          )

        assert "create-facility" in reached
      end
    end

    test "the updated graph validates clean" do
      graph = graph!(loan())
      assert %{valid: true, violations: []} = Graph.validate_graph(graph)
      assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
      assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
      assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph!(reg()))
    end
  end

  describe "every HUMAN_TASK carries a form_schema with required decision fields" do
    # node id -> {required fields, %{field => enum | :free}}
    @loan_forms %{
      "credit-memo-review" => %{"credit_decision" => ["pass", "fail"]},
      "credit-memo-escalation-review" => %{"credit_decision" => ["pass", "fail"]},
      "risk-assessment" => %{"risk_rating" => ["low", "medium", "high", "unacceptable"]},
      "risk-assessment-escalation-review" => %{
        "risk_rating" => ["low", "medium", "high", "unacceptable"]
      },
      "kyc-manual-review" => %{"kyc_outcome" => ["cleared", "rejected"]},
      "l1-approval" => %{"l1_decision" => ["approve", "escalate", "reject"]},
      "l2-approval" => %{"l2_decision" => ["approve", "reject"]},
      "committee-vote-cro" => %{"committee_vote_cro" => ["approve", "reject"]},
      "committee-vote-director" => %{"committee_vote_director" => ["approve", "reject"]},
      "committee-vote-ceo" => %{"committee_vote_ceo" => ["approve", "reject"]},
      "disburse-loan" => %{"disbursement_reference" => :optional_free},
      "escalate-l2-approval-to-ceo" => %{"l2_decision" => ["approve", "reject"]},
      "escalate-disburse-loan-to-credit-director" => %{"disbursement_reference" => :optional_free}
    }

    @reg_forms %{
      "evidence-collection" => %{"evidence_summary" => :optional_free},
      "risk-evaluation" => %{"highest_severity" => ["none", "low", "medium", "high", "critical"]},
      "remediation-subprocess" => %{"remediation_status" => ["resolved", "unresolved"]},
      "findings-sign-off" => %{"cro_decision" => ["sign_off", "reject_and_reopen"]},
      "ceo-override" => %{"ceo_decision" => ["sign_off", "reject_and_reopen"]}
    }

    defp human_ids(d), do: for(n <- nodes(d), n["node_type"] == "HUMAN_TASK", do: n["id"])

    for {label, fun, forms_attr, yaml_attr} <- [
          {"loan", :loan, :loan_forms, :loan_yaml},
          {"regulatory", :reg, :reg_forms, :reg_yaml}
        ] do
      test "#{label}: the form table covers exactly the HUMAN_TASK nodes" do
        d = unquote(fun) |> apply_doc()
        assert Enum.sort(human_ids(d)) == Enum.sort(Map.keys(forms(unquote(forms_attr))))
      end

      test "#{label}: per task, form_schema is well formed, requires exactly the decision fields, enums match" do
        d = unquote(fun) |> apply_doc()

        for {id, fields} <- forms(unquote(forms_attr)) do
          fs = node(d, id)["attributes"]["form_schema"]
          assert is_map(fs), "#{id} has no form_schema"
          assert :ok == JsonSchemaShape.check(fs), "#{id} form_schema not well formed"
          assert fs["type"] == "object"
          # :optional_free = documented optional audit text that no gateway reads (BA: keep as
          # OPTIONAL free text, no personal data): present in properties, NOT required.
          required_fields = for {f, allowed} <- fields, allowed != :optional_free, do: f

          assert Enum.sort(Map.get(fs, "required", [])) == Enum.sort(required_fields),
                 "#{id} required"

          assert Enum.sort(Map.keys(fs["properties"])) == Enum.sort(Map.keys(fields)),
                 "#{id} properties"

          for {field, allowed} <- fields do
            prop = fs["properties"][field]
            assert prop["type"] == "string", "#{id}.#{field} type"

            assert is_binary(prop["description"]) and prop["description"] != "",
                   "#{id}.#{field} description"

            case allowed do
              :optional_free ->
                assert prop["minLength"] == 1,
                       "#{id}.#{field} free text must be non-empty when given"

                assert prop["description"] =~ "Optional.",
                       "#{id}.#{field} must be documented as optional"

                assert prop["description"] =~ "No personal data beyond what the process needs.",
                       "#{id}.#{field} must carry the no-personal-data note"

              enum ->
                assert prop["enum"] == enum, "#{id}.#{field} enum"
            end
          end
        end
      end

      test "#{label}: every enumerated decision field covers every literal an edge condition compares it to" do
        d = unquote(fun) |> apply_doc()
        conds = for e <- edges(d), e["condition"], do: e["condition"]

        for {id, fields} <- forms(unquote(forms_attr)),
            {field, allowed} <- fields,
            allowed not in [:free, :optional_free] do
          literals =
            for cond <- conds,
                [_, lit] <- Regex.scan(~r/variables\.#{field} (?:==|!=) '([^']*)'/, cond),
                lit != "",
                do: lit

          for lit <- literals,
              do:
                assert(
                  lit in allowed,
                  "#{id}.#{field}: condition compares to '#{lit}' not in enum"
                )
        end
      end

      test "#{label}: the simulation YAML copy mirrors the nodes, forms and edges" do
        d = unquote(fun) |> apply_doc()
        y = yaml!(unquote(yaml_attr) |> apply_path())

        assert Enum.sort(
                 Enum.map(
                   nodes(d),
                   &{&1["id"], &1["node_type"], &1["attributes"]["role"],
                    &1["attributes"]["form_schema"]}
                 )
               ) ==
                 Enum.sort(
                   Enum.map(
                     nodes(y),
                     &{&1["id"], &1["node_type"], &1["attributes"]["role"],
                      &1["attributes"]["form_schema"]}
                   )
                 )

        # edge ids ignored: the sim copy names the kyc-routing default edge differently (pre-existing)
        shape = fn x ->
          x
          |> edges()
          |> Enum.map(&{&1["source"], &1["target"], &1["condition"], &1["is_default"] == true})
          |> Enum.sort()
        end

        assert shape.(d) == shape.(y)
      end
    end

    test "kyc-manual-review records a REQUIRED kyc_outcome of cleared|rejected (BA acceptance criterion)" do
      fs = node(loan(), "kyc-manual-review")["attributes"]["form_schema"]
      assert fs["required"] == ["kyc_outcome"]
      assert fs["properties"]["kyc_outcome"]["enum"] == ["cleared", "rejected"]
    end

    test "the escalation reviews' forms require exactly the variable the gate reads" do
      for {_t, review, _role, var} <- @reviews do
        assert node(loan(), review)["attributes"]["form_schema"]["required"] == [var]
      end
    end

    defp forms(:loan_forms), do: @loan_forms
    defp forms(:reg_forms), do: @reg_forms
    defp apply_doc(:loan), do: loan()
    defp apply_doc(:reg), do: reg()
    defp apply_path(:loan_yaml), do: @loan_yaml
    defp apply_path(:reg_yaml), do: @reg_yaml
  end
end
