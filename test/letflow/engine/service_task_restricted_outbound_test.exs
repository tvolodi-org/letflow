defmodule Letflow.Engine.ServiceTaskRestrictedOutboundTest do
  @moduledoc """
  SR-OPT-11 (decision 0062 R12, GH #2616 part 2): a labelled variable never renders into a
  SERVICE_TASK URL or body. The check reads the labels of the in-memory state of the same advance,
  not the projection loaded at the start of the transaction, so a label that a form computes in the
  completion itself (R14) is seen by the SERVICE_TASK that follows it. The refusal is an
  EXECUTION_ERROR, names the key only, and dispatches nothing.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ReservedReferences
  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Support.ScriptTaskFixture, as: F

  @label "customer.salary"

  @form %{
    "type" => "object",
    "properties" => %{
      "total" => %{"type" => "number"},
      "y" => %{"type" => "number", "x-ui" => %{"computed" => "total + 1"}}
    }
  }

  setup do
    %{t: F.tenant!("gh2616-outbound")}
  end

  # START -> svc (script: total = 4, labelled) -> review (HUMAN_TASK, computes y from total)
  #       -> out (SERVICE_TASK, url_template) -> END
  defp graph(url_template) do
    fn key, version ->
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"script_key" => key, "script_version" => version}
          },
          %{
            "id" => "review",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{"role" => "REVIEWER", "form_schema" => @form}
          },
          %{
            "id" => "out",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{
              "endpoint" => url_template,
              "method" => "POST",
              "timeout_ms" => 5000
            }
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "review"},
          %{"id" => "e3", "source" => "review", "target" => "out"},
          %{"id" => "e4", "source" => "out", "target" => "end"}
        ]
      }
    end
  end

  # The script result carries `total` labelled, so the review's computed `y` inherits the label.
  defp labelled_review!(t, url_template) do
    b =
      F.bound_graph!(
        t,
        F.doubling_source(),
        F.closed_manifest(),
        %{"amount" => 2},
        graph(url_template),
        []
      )

    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    result =
      {:ok, %{"total" => 4},
       %{
         row: row,
         phase: :ran,
         outcome: :ok,
         detail: nil,
         fail_code: nil,
         hmac: nil,
         stats: nil,
         output_labels: %{"total" => [@label]}
       }}

    assert {:ok, :applied} = Engine.apply_script_task_result(F.claim(row), result, t.schema_name)
    b
  end

  defp complete_review(t, instance_id) do
    task =
      Repo.one!(
        from(x in Letflow.Engine.Task,
          where: x.instance_id == ^instance_id and x.status == :pending
        ),
        prefix: t.schema_name
      )

    completer = Ecto.UUID.generate()

    Engine.complete_task(
      task.id,
      %{output_variables: %{}, actor_id: completer, idempotency_key: "out-#{completer}"},
      prefix: t.schema_name
    )
  end

  defp dispatch_rows(t, instance_id) do
    Repo.all(
      from(d in ServiceTaskDispatcher.ServiceTaskDispatch,
        where: d.instance_id == ^instance_id
      ),
      prefix: t.schema_name
    )
  end

  describe "SR-OPT-11(b) the same advance" do
    test "a labelled key computed by the completion refuses the next SERVICE_TASK; nothing is dispatched",
         %{t: t} do
      b = labelled_review!(t, "https://example.test/orders/{{variables.y}}")

      assert {:error, {:instance_execution_error, :service_task_restricted_variable_outbound, _}} =
               complete_review(t, b.instance_id)

      assert dispatch_rows(t, b.instance_id) == []

      assert [_ | _] = F.payloads(t.schema_name, b.instance_id, "EXECUTION_ERROR")
    end

    test "an unlabelled placeholder renders as today: the dispatch is armed", %{t: t} do
      b = labelled_review!(t, "https://example.test/orders/{{variables.amount}}")

      assert {:ok, _result} = complete_review(t, b.instance_id)
      assert [_] = dispatch_rows(t, b.instance_id)
    end
  end

  describe "SR-OPT-11(a) the static check" do
    test "restricted_reference_keys/2 names the placeholders that are in the taint set" do
      templates = ["https://x/{{variables.a}}/{{variables.b}}", "{\"k\": \"{{variables.c}}\"}"]

      assert ReservedReferences.restricted_reference_keys(templates, MapSet.new(["b", "c"])) ==
               ["b", "c"]
    end

    test "an empty taint set (every part-2 activation) refuses nothing" do
      templates = ["https://x/{{variables.a}}"]

      assert ReservedReferences.restricted_reference_keys(templates, MapSet.new()) == []
    end

    test "nil templates contribute no keys" do
      assert ReservedReferences.restricted_reference_keys([nil], MapSet.new(["a"])) == []
    end
  end
end
