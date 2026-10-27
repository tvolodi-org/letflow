defmodule Letflow.LabelsTest do
  @moduledoc """
  REQ-599 part 1 (GH #3370): `Letflow.Labels.list_overrides/2`, the reader the configuration bundle
  export uses.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Labels
  alias Letflow.Labels.Override
  alias Letflow.TenantFixture

  defp insert!(t, id, locale, text),
    do:
      Repo.insert!(%Override{tenant_id: t.tenant_id, message_id: id, locale: locale, text: text},
        prefix: t.schema_name
      )

  test "L1 list_overrides is sorted by message_id, locale and scoped to the tenant" do
    a = TenantFixture.provisioned_tenant!(slug_prefix: "r599-l1a")
    b = TenantFixture.provisioned_tenant!(slug_prefix: "r599-l1b")
    insert!(a, "b.msg", "en", "B")
    insert!(a, "a.msg", "ru", "A ru")
    insert!(a, "a.msg", "en", "A en")
    insert!(b, "z.msg", "en", "other tenant")

    assert Labels.list_overrides(a.schema_name, a.tenant_id) == [
             %{message_id: "a.msg", locale: "en", text: "A en"},
             %{message_id: "a.msg", locale: "ru", text: "A ru"},
             %{message_id: "b.msg", locale: "en", text: "B"}
           ]

    assert [%{message_id: "z.msg"}] = Labels.list_overrides(b.schema_name, b.tenant_id)
    assert Labels.list_overrides(b.schema_name, a.tenant_id) == []
  end
end
