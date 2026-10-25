defmodule Letflow.Routers.WebhooksMappingLinkTest do
  @moduledoc """
  REQ-565 slice 2 (GH #3201): linking a webhook subscription to an outbound integration mapping
  through `PATCH /subscriptions/:id`, and the delete guard on `DELETE /integration-mappings/:id`.
  L1-L5 and L7 follow the T-0511 design (criteria 12 and 13); L6 (the FOR SHARE / FOR UPDATE
  interleaving) is race-only and is not forced here.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.IntegrationMappings
  alias Letflow.Routers.IntegrationMappings, as: MappingsRouter
  alias Letflow.Routers.Webhooks, as: WebhooksRouter
  alias Letflow.TenantFixture

  @admin ["TENANT_ADMIN"]

  defp call(router, method, path, tenant, roles, body) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "req565-link-trace")
    |> router.call(router.init([]))
  end

  defp patch(tenant, roles, sub_id, body),
    do: call(WebhooksRouter, :patch, "/subscriptions/#{sub_id}", tenant, roles, body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  defp subscription!(tenant) do
    conn =
      call(WebhooksRouter, :post, "/subscriptions", tenant, @admin, %{
        "target_url" => "https://example.com/hook"
      })

    assert conn.status == 201
    json(conn)
  end

  defp mapping!(tenant, direction \\ "outbound") do
    {:ok, mapping} =
      IntegrationMappings.create(
        %{
          "name" => "m-" <> Ecto.UUID.generate(),
          "direction" => direction,
          "rules" => [%{"to" => "x", "const" => 1}]
        },
        nil,
        tenant.schema_name
      )

    mapping
  end

  defp stored(tenant, sub_id) do
    Repo.get!(Letflow.Webhooks.Subscription, sub_id, prefix: tenant.schema_name)
  end

  describe "L1: link and clear (criterion 12)" do
    test "an outbound mapping of the tenant is stored; null clears it" do
      t = tenant!("r565-l1")
      sub = subscription!(t)
      assert sub["outbound_mapping_id"] == nil
      m = mapping!(t)

      conn = patch(t, @admin, sub["id"], %{"outbound_mapping_id" => m.id})
      assert conn.status == 200
      assert json(conn)["outbound_mapping_id"] == m.id
      assert stored(t, sub["id"]).outbound_mapping_id == m.id

      list = call(WebhooksRouter, :get, "/subscriptions", t, @admin, %{})
      assert [%{"outbound_mapping_id" => id}] = json(list)["items"]
      assert id == m.id

      conn = patch(t, @admin, sub["id"], %{"outbound_mapping_id" => nil})
      assert conn.status == 200
      assert json(conn)["outbound_mapping_id"] == nil
      assert stored(t, sub["id"]).outbound_mapping_id == nil
    end

    test "linking together with a status change applies both" do
      t = tenant!("r565-l1b")
      sub = subscription!(t)
      m = mapping!(t)

      conn = patch(t, @admin, sub["id"], %{"outbound_mapping_id" => m.id, "status" => "PAUSED"})
      assert conn.status == 200
      assert %{"status" => "PAUSED", "outbound_mapping_id" => id} = json(conn)
      assert id == m.id
    end
  end

  describe "L2: refused links are one identical 422 (criterion 12)" do
    test "inbound, other tenant, unknown, malformed and non-string ids change nothing" do
      t = tenant!("r565-l2")
      other = tenant!("r565-l2-other")
      sub = subscription!(t)
      kept = mapping!(t)
      {:ok, _} = link_in_context(t, sub["id"], kept.id)

      refused = [
        mapping!(t, "inbound").id,
        mapping!(other).id,
        Ecto.UUID.generate(),
        "not-a-uuid",
        42,
        true
      ]

      bodies =
        for bad <- refused do
          conn =
            patch(t, @admin, sub["id"], %{"outbound_mapping_id" => bad, "status" => "PAUSED"})

          assert conn.status == 422
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
      refute hd(bodies) =~ kept.id

      after_state = stored(t, sub["id"])
      assert after_state.outbound_mapping_id == kept.id
      assert after_state.status == :ACTIVE
    end
  end

  defp link_in_context(t, sub_id, mapping_id) do
    {:ok, _} =
      Letflow.Webhooks.update(sub_id, %{outbound_mapping_id: mapping_id}, prefix: t.schema_name)
  end

  describe "L3: delete guard (criterion 12)" do
    test "409 while linked, nothing deleted; 204 once the link is cleared" do
      t = tenant!("r565-l3")
      sub = subscription!(t)
      m = mapping!(t)
      assert patch(t, @admin, sub["id"], %{"outbound_mapping_id" => m.id}).status == 200

      conn = call(MappingsRouter, :delete, "/#{m.id}", t, @admin, %{})
      assert conn.status == 409
      refute conn.resp_body =~ m.id
      assert {:ok, _} = IntegrationMappings.get(m.id, t.schema_name)

      assert patch(t, @admin, sub["id"], %{"outbound_mapping_id" => nil}).status == 200
      assert call(MappingsRouter, :delete, "/#{m.id}", t, @admin, %{}).status == 204
      assert {:error, :not_found} = IntegrationMappings.get(m.id, t.schema_name)
    end
  end

  describe "L4: permission branch (criterion 12)" do
    test "PROCESS_OPERATOR gets the uniform 403 when the body has the key, not for other fields" do
      t = tenant!("r565-l4")
      sub = subscription!(t)
      m = mapping!(t)

      # the same 403 a role without :WebhooksManage gets from the route gate
      route_denied = patch(t, ["TASK_WORKER"], sub["id"], %{"status" => "PAUSED"})
      assert route_denied.status == 403

      for value <- [m.id, nil] do
        conn = patch(t, ["PROCESS_OPERATOR"], sub["id"], %{"outbound_mapping_id" => value})
        assert conn.status == 403
        assert conn.resp_body == route_denied.resp_body

        assert get_resp_header(conn, "content-type") ==
                 get_resp_header(route_denied, "content-type")
      end

      assert stored(t, sub["id"]).outbound_mapping_id == nil

      assert patch(t, ["PROCESS_OPERATOR"], sub["id"], %{"status" => "PAUSED"}).status == 200
      assert patch(t, @admin, sub["id"], %{"outbound_mapping_id" => m.id}).status == 200
    end
  end

  describe "L5: tenant isolation (criterion 13, INV-10)" do
    test "tenant B cannot link its subscription to tenant A's mapping" do
      a = tenant!("r565-l5a")
      b = tenant!("r565-l5b")
      a_mapping = mapping!(a)
      b_sub = subscription!(b)
      unknown = patch(b, @admin, b_sub["id"], %{"outbound_mapping_id" => Ecto.UUID.generate()})

      conn = patch(b, @admin, b_sub["id"], %{"outbound_mapping_id" => a_mapping.id})
      assert conn.status == 422
      assert conn.resp_body == unknown.resp_body
      assert stored(b, b_sub["id"]).outbound_mapping_id == nil
      assert {:ok, _} = IntegrationMappings.get(a_mapping.id, a.schema_name)

      # a tenant id in the body is ignored: it never selects a schema
      conn =
        patch(b, @admin, b_sub["id"], %{
          "outbound_mapping_id" => a_mapping.id,
          "tenant_id" => a.tenant_id
        })

      assert conn.status == 422
      assert stored(b, b_sub["id"]).outbound_mapping_id == nil
    end
  end

  describe "L7: empty updates keep the 400" do
    test "an empty body and an unrelated key still answer invalid_status" do
      t = tenant!("r565-l7")
      sub = subscription!(t)
      assert patch(t, @admin, sub["id"], %{}).status == 400
      assert patch(t, @admin, sub["id"], %{"description" => "x"}).status == 400
    end
  end
end
