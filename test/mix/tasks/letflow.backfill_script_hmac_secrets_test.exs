defmodule Mix.Tasks.Letflow.BackfillScriptHmacSecretsTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC14 (design `lib/letflow/design/gh2534-7c-script-handler.md` 0.6, 7.2): a
  second backfill run over N tenants is a pure no-op -- `{0, N, []}` and every secret row
  (id, key_id, ciphertext, status) unchanged.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Secrets.Secret
  alias Letflow.TenantFixture
  alias Mix.Tasks.Letflow.BackfillScriptHmacSecrets

  defp rows(tenant_ids) do
    Repo.all(
      from(s in Secret,
        where: s.tenant_id in ^tenant_ids and s.namespace == "platform",
        order_by: [s.tenant_id, s.key_id]
      )
    )
    |> Enum.map(&Map.take(&1, [:id, :tenant_id, :key_id, :ciphertext, :status]))
  end

  test "T-backfill-rerun" do
    tenants = for _ <- 1..3, do: TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7c-bf")
    ids = Enum.map(tenants, & &1.tenant_id)
    on_exit(fn -> Repo.delete_all(from(s in Secret, where: s.tenant_id in ^ids)) end)
    registrations = Enum.map(ids, &%{tenant_id: &1})

    assert BackfillScriptHmacSecrets.backfill(registrations) == {3, 0, []}
    first = rows(ids)
    assert length(first) == 3

    assert BackfillScriptHmacSecrets.backfill(registrations) == {0, 3, []}
    assert rows(ids) == first
  end
end
