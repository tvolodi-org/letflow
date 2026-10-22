defmodule Letflow.Routers.Gh2669UnknownAuditActionTest do
  @moduledoc """
  GH #2669 (decision 0051 D8, open "Consumers" check): an audit entry whose `action`
  name no code knows must be listed, filtered and rendered without error.

  Audit `action` is a free string (`Letflow.Audit.Entry`, no enumeration), so a new
  action can be written without a code change. This file reads the consumers on main
  and pins what they do with a made-up, well-formed action (`example_subject.tested`):

    * `Letflow.Audit.list_entries/1` -- no `action` filter exists; the function returns
      the entry unchanged, and its `resource_type` filter still discriminates.
    * `GET /api/v1/audit` (`Letflow.Routers.Audit`) -- the response allowlist passes
      `action` through as text; there is no `action` query parameter, so a caller that
      sends one gets the unfiltered page (200), not an empty page and not a 422.
    * The web audit view (`web/src/pages/admin/AuditLogPage.tsx`) renders `e.action` as
      plain text; it keeps no action-keyed lookup, so an unknown name renders as-is.
    * No audit export exists on main (no route or module exports `audit_entries`).

  Dispatches directly against `Letflow.Routers.Audit`, the convention of
  `test/letflow/routers/req196_audit_route_test.exs`. Uses `Letflow.DataCase` and
  `Letflow.TenantFixture` for real provisioned tenant schemas. `async: false`, as
  every tenant-provisioning test in this codebase.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.TenantFixture

  @audit_opts Letflow.Routers.Audit.init([])
  @unknown_action "example_subject.tested"
  @known_action "definition.create"

  defp build_conn(tenant_fixture, query_string \\ "") do
    path = if query_string == "", do: "/", else: "/?" <> query_string

    conn(:get, path)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_fixture.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "gh2669-test-trace-id")
  end

  defp seed_audit_entry!(schema_name, overrides) do
    attrs =
      Map.merge(
        %{
          actor_id: Ecto.UUID.generate(),
          action: @known_action,
          resource_type: "definition",
          resource_id: Ecto.UUID.generate(),
          before_state: nil,
          after_state: %{"name" => "sample"},
          trace_id: nil
        },
        Map.new(overrides)
      )

    assert {:ok, entry} = Audit.insert_entry(Repo, attrs, schema_name)
    entry
  end

  # One known-action entry and one entry with a name no code has ever written.
  defp seed_known_and_unknown!(tenant) do
    known = seed_audit_entry!(tenant.schema_name, action: @known_action)

    unknown =
      seed_audit_entry!(tenant.schema_name,
        action: @unknown_action,
        resource_type: "example_subject",
        after_state: %{"tested" => true}
      )

    {known, unknown}
  end

  defp get_audit(tenant, query_string \\ "") do
    tenant
    |> build_conn(query_string)
    |> Letflow.Routers.Audit.call(@audit_opts)
  end

  defp list_params(tenant, overrides \\ []) do
    Map.merge(
      %{prefix: tenant.schema_name, page_size: 25},
      Map.new(overrides)
    )
  end

  describe "Audit.list_entries/1 with an unknown action" do
    test "returns the entry with its action unchanged, and no error" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2669-list")
      {_known, unknown} = seed_known_and_unknown!(tenant)

      assert {:ok, %{items: items, has_more: false}} =
               Audit.list_entries(list_params(tenant))

      assert length(items) == 2
      assert [%{action: @unknown_action} = item] = Enum.filter(items, &(&1.id == unknown.id))
      assert item.resource_type == "example_subject"
      assert item.after_state == %{"tested" => true}
    end

    test "the resource_type filter returns the unknown-action entry" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2669-list-rt")
      {_known, unknown} = seed_known_and_unknown!(tenant)

      assert {:ok, %{items: [item], has_more: false}} =
               Audit.list_entries(list_params(tenant, resource_type: "example_subject"))

      assert item.id == unknown.id
      assert item.action == @unknown_action
    end

    test "an empty result is returned for a resource_type nobody wrote" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2669-list-empty")
      seed_known_and_unknown!(tenant)

      assert {:ok, %{items: [], has_more: false}} =
               Audit.list_entries(list_params(tenant, resource_type: "no_such_type"))
    end
  end

  describe "GET /api/v1/audit with an unknown action" do
    test "lists the entry with the unknown action as text, 200" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2669-http")
      {_known, unknown} = seed_known_and_unknown!(tenant)

      resp = get_audit(tenant)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 2

      assert [item] = Enum.filter(body["items"], &(&1["audit_id"] == unknown.id))
      assert item["action"] == @unknown_action
    end

    test "the resource_type filter returns the unknown-action entry, 200" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2669-http-rt")
      {_known, unknown} = seed_known_and_unknown!(tenant)

      resp = get_audit(tenant, "resource_type=example_subject")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [%{"audit_id" => audit_id, "action" => @unknown_action}] = body["items"]
      assert audit_id == unknown.id
    end

    test "an action query parameter is not a filter on main: it is ignored and the page is unfiltered" do
      # Pins main's behaviour (0051 D8 check, GH #2669). There is no `action` filter in
      # `list_entries/1` or the route, so a caller asking for one gets both entries, not an
      # empty page and not a 422. A missing filter is a finding to report, not a test to pass.
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2669-http-action")
      seed_known_and_unknown!(tenant)

      resp = get_audit(tenant, "action=" <> @unknown_action)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["count"] == 2

      assert Enum.sort(Enum.map(body["items"], & &1["action"])) ==
               Enum.sort([@known_action, @unknown_action])
    end
  end
end
