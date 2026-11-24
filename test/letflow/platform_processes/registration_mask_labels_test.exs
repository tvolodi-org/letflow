defmodule Letflow.PlatformProcesses.RegistrationMaskLabelsTest do
  @moduledoc """
  T-2704 security_deep (SF-05 / INV-2): adding the registration labels must
  KEEP a label the stored data already carries on `admin_email` / `realm_id`
  (an entity sensitivity label), in the projection labels and in the event
  payload label fields. Before the fix `Map.merge` let the registration labels
  replace the existing ones, so a platform administrator's hidden set (which
  holds the existing restriction but not the registration labels) no longer
  matched and the value came back in plain text.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.VariableLabels
  alias Letflow.PlatformProcesses.RegistrationMask
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  @existing "person.email"
  @existing_realm "account.realm"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2704-mask")
    Fixture.pin!(platform.tenant_id)
    %{prefix: platform.schema_name}
  end

  test "SF-05: put_labels/2 keeps an existing label next to the registration label", %{prefix: p} do
    stored = %{"admin_email" => [@existing], "realm_id" => [@existing_realm]}
    labels = RegistrationMask.put_labels(stored, p)

    assert @existing in labels["admin_email"]
    assert @existing_realm in labels["realm_id"]
    assert "platform_registration.admin_email" in labels["admin_email"]
    assert "platform_registration.realm_id" in labels["realm_id"]
  end

  test "SF-05: an admin whose hidden set holds only the existing labels still sees the redaction",
       %{prefix: p} do
    vars = %{"admin_email" => "email-canary", "realm_id" => "realm-canary"}

    labels =
      RegistrationMask.put_labels(
        %{"admin_email" => [@existing], "realm_id" => [@existing_realm]},
        p
      )

    hidden = MapSet.new([@existing, @existing_realm])

    redacted = VariableLabels.redact_variables(vars, labels, hidden)

    assert redacted["admin_email"] == VariableLabels.representation()
    assert redacted["realm_id"] == VariableLabels.representation()
  end

  test "SF-05: put_payload_labels/2 keeps existing label fields in every value map", %{prefix: p} do
    payload = %{
      "variables" => %{"admin_email" => "e"},
      "labels" => %{"admin_email" => [@existing]},
      "output_variables" => %{"realm_id" => "r"},
      "output_labels" => %{"realm_id" => [@existing_realm]}
    }

    out = RegistrationMask.put_payload_labels(payload, p)

    assert @existing in out["labels"]["admin_email"]
    assert "platform_registration.admin_email" in out["labels"]["admin_email"]
    assert @existing_realm in out["output_labels"]["realm_id"]
    assert "platform_registration.realm_id" in out["output_labels"]["realm_id"]

    redacted = VariableLabels.redact_event_payload(out, MapSet.new([@existing, @existing_realm]))
    assert redacted["variables"]["admin_email"] == VariableLabels.representation()
    assert redacted["output_variables"]["realm_id"] == VariableLabels.representation()
  end

  test "outside the platform schema the labels are untouched" do
    stored = %{"admin_email" => [@existing]}
    assert RegistrationMask.put_labels(stored, "tenant_other") == stored
  end
end
