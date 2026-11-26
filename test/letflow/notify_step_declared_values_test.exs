defmodule Letflow.NotifyStepDeclaredValuesTest do
  @moduledoc """
  T-2597 (pilot gap G14; decision record G2, S6 -- "Exfiltration through a
  notification step", second half): the notification step sends only the
  values it DECLARES, and never a secret.

  A step that sends more than it declared is the hole the declaration exists to
  close:

    * a value that names a placeholder the template does not allow is refused
      (nothing is sent that the template never asked for);
    * a value that references a SECRET is refused (INV-4: a secret leaves the
      process only by reference, never inside a message);
    * a value that names a variable the DEFINITION does not declare is refused
      by the typed mapping rule (T-2594's rule, carried to the notify step).

  The rules themselves landed with the notification step (T-2592, pilot gap
  G4); this file is the acceptance the decision record names for the
  guardrail task: the notification step must not become a way around the
  allow-list.

  Test ids V1..V5.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Definitions.StepMapping

  defp declaration(overrides \\ %{}) do
    Map.merge(
      %{
        "template_key" => "tenant_registered",
        "recipient" => %{"var" => "admin_email"},
        "values" => %{
          "tenant_name" => %{"var" => "tenant_name"},
          "tenant_slug" => %{"const" => "acme"}
        }
      },
      overrides
    )
  end

  defp notify_node(raw) do
    %Graph.Node{id: "notify", node_type: :SERVICE_TASK, attributes: %{"notify" => raw}}
  end

  defp codes(raw) do
    node = notify_node(raw)

    node
    |> NotifyCalls.violations([node])
    |> Enum.map(& &1.code)
  end

  test "V1 a value that names a placeholder the template does not allow is refused" do
    raw = declaration(%{"values" => %{"password" => %{"var" => "tenant_password"}}})

    assert :notify_value_unknown in codes(raw)
  end

  test "V2 a value that references a SECRET is refused" do
    raw = declaration(%{"values" => %{"tenant_name" => %{"secret_ref" => "smtp_password"}}})

    assert :notify_value_source_invalid in codes(raw)
  end

  test "V3 a recipient that is a CONSTANT is refused: the address never sits in the definition" do
    raw = declaration(%{"recipient" => %{"const" => "person@example.com"}})

    assert :notify_recipient_invalid in codes(raw)
  end

  test "V4 a value that names a variable the DEFINITION does not declare is refused" do
    node = notify_node(declaration())

    violations =
      StepMapping.violations(NotifyCalls.mappings([node], %{}), %{}, MapSet.new())

    assert [
             %{code: :step_mapping_variable_undeclared, side: :reads, name: "admin_email"},
             %{code: :step_mapping_variable_undeclared, side: :reads, name: "tenant_name"}
           ] = violations
  end

  test "V5 the activation fence binds the notify step's reads to the variable schemas" do
    node = notify_node(declaration())

    violations = Definitions.step_mapping_violations([node], %{}, "a_tenant_schema")

    assert [
             %{code: :step_mapping_variable_undeclared, side: :reads, name: "admin_email"},
             %{code: :step_mapping_variable_undeclared, side: :reads, name: "tenant_name"}
           ] = violations
  end
end
