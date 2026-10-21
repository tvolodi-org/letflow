defmodule Letflow.Definitions.PromotionPlanClassifierTest do
  @moduledoc """
  REQ-469 (GH #2476): `PromotionPlan.default_tenant_classifier/1` reads `tenants.tenant_type`,
  and `compute_promotion_plan/5` with the default classifier refuses a `production` source.
  Real Postgres; `async: false` because `TenantFixture.provisioned_tenant!/1` needs
  `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture

  defp set_type!(tenant_id, type) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id), set: [tenant_type: type])
  end

  defp allow, do: fn _actor_id, _source_tenant_id -> true end

  test "returns :production for a production tenant and :test for a test tenant" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-cls")
    assert PromotionPlan.default_tenant_classifier(t.tenant_id) == :test

    set_type!(t.tenant_id, "production")
    assert PromotionPlan.default_tenant_classifier(t.tenant_id) == :production

    set_type!(t.tenant_id, "test")
    assert PromotionPlan.default_tenant_classifier(t.tenant_id) == :test
  end

  test "returns :test for an unknown id, a malformed id and nil" do
    assert PromotionPlan.default_tenant_classifier(Ecto.UUID.generate()) == :test
    assert PromotionPlan.default_tenant_classifier("not-a-uuid") == :test
    assert PromotionPlan.default_tenant_classifier(nil) == :test
  end

  test "compute_promotion_plan/5 with the default classifier rejects a production source" do
    source = TenantFixture.provisioned_tenant!(slug_prefix: "req469-src")
    target = TenantFixture.provisioned_tenant!(slug_prefix: "req469-tgt")
    set_type!(source.tenant_id, "production")

    assert {:error, :invalid_promotion_source} =
             PromotionPlan.compute_promotion_plan(
               Ecto.UUID.generate(),
               source.tenant_id,
               target.tenant_id,
               "req469-proc",
               permission_checker: allow()
             )
  end

  test "compute_promotion_plan/5 with the default classifier does not reject a test source" do
    source = TenantFixture.provisioned_tenant!(slug_prefix: "req469-src-test")
    target = TenantFixture.provisioned_tenant!(slug_prefix: "req469-tgt-test")

    result =
      PromotionPlan.compute_promotion_plan(
        Ecto.UUID.generate(),
        source.tenant_id,
        target.tenant_id,
        "req469-proc",
        permission_checker: allow()
      )

    refute result == {:error, :invalid_promotion_source}
  end
end
