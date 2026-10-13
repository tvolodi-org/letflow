defmodule Letflow.Routers.PromotionReadStoredIdsTest do
  @moduledoc """
  ISS-1029 (Q-1011 / GH #2311): the three promotion READ routes re-check the review's STORED
  `source_tenant_id` / `target_tenant_id` against the caller, as approve, reject, apply and
  run-assertions already do (ISS-1026). A non-operator holder of `:PromotionsRead` (`TENANT_ADMIN`
  of tenant A; the platform pin is on P) who reads a review whose stored plan names a foreign
  tenant must get the SAME 404 as for a nonexistent review, and the list must not show it.
  The operator (`PLATFORM_ADMIN` of the pinned P) and own-tenant reviews are unchanged.

  Reviews are seeded through the real `PromotionReviewStore.insert_review/2`
  (`Scope.seed_review!/4`). `async: false` (VM-global platform pin, restored by the fixture).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [assign: 3]

  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @reader ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  setup do
    # a = the non-operator reader's tenant, b = a foreign tenant, p = the pinned platform tenant
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, Map.put(tenants, :caller, Ecto.UUID.generate())}
  end

  defp get_resp(fixture, path, roles, user_id) do
    conn = Fixture.router_conn(:get, path, fixture, roles, nil)
    ac = %{conn.assigns.auth_context | user_id: user_id}

    Letflow.Routers.Promotions.call(
      assign(conn, :auth_context, ac),
      Letflow.Routers.Promotions.init([])
    )
  end

  # The bytes a non-operator sees for a nonexistent review id: the baseline a foreign-named review
  # must reproduce on each per-review read route.
  defp baseline(ctx, suffix) do
    resp = get_resp(ctx.a, "/#{Ecto.UUID.generate()}#{suffix}", @reader, ctx.caller)
    assert resp.status == 404
    Scope.observable(resp)
  end

  defp list_ids(resp) do
    assert resp.status == 200
    resp.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["id"])
  end

  describe "non-operator reader, review naming a foreign tenant in its own schema" do
    setup %{a: a, b: b} do
      %{review: review} = Scope.seed_review!(a, a.tenant_id, b.tenant_id)
      {:ok, review_id: review.id}
    end

    test "GET /:id/context answers the nonexistent-review 404 bytes", ctx do
      resp = get_resp(ctx.a, "/#{ctx.review_id}/context", @reader, ctx.caller)
      assert Scope.observable(resp) == baseline(ctx, "/context")
    end

    test "GET /:id (assertion run) answers the nonexistent-review 404 bytes", ctx do
      resp = get_resp(ctx.a, "/#{ctx.review_id}", @reader, ctx.caller)
      assert Scope.observable(resp) == baseline(ctx, "")
    end

    test "GET / (list) omits the review", ctx do
      ids = list_ids(get_resp(ctx.a, "/", @reader, ctx.caller))
      refute ctx.review_id in ids
    end
  end

  describe "controls: own-tenant review and operator are unchanged" do
    test "a review naming only the reader's own tenant reads 200 and is listed", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id)

      ctx_resp = get_resp(ctx.a, "/#{review.id}/context", @reader, ctx.caller)
      assert ctx_resp.status == 200
      assert review.id in list_ids(get_resp(ctx.a, "/", @reader, ctx.caller))
    end

    test "the operator still reads a review naming foreign tenants (200)", ctx do
      %{review: review} = Scope.seed_review!(ctx.p, ctx.a.tenant_id, ctx.b.tenant_id)

      resp = get_resp(ctx.p, "/#{review.id}/context", @operator, ctx.caller)
      assert resp.status == 200
    end
  end
end
