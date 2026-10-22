defmodule Letflow.Identity.SyncReadCountTest do
  @moduledoc """
  GH #2860: the reads one IdP role-claims sync makes per candidate group. The sync holds lock A
  and reads the user's held roles and applicable grant rows before each group's decision; those
  reads are made once per group, not repeated within it. The count still grows with the number
  of groups, because each insert changes what the next group's no-widening decision reads
  (SEC C-3), so the test pins the per-group slope, not a constant.

  The count is the SELECT statements issued by one `Identity.sync_role_claims_report/3` call,
  taken from Repo telemetry. Each group is a platform role with no rows, so every group is a
  real insert for a fresh user. `async: false`: real tenant schemas and committed writes.
  """

  use Letflow.DataCase, async: false

  import Letflow.Support.EnforcedWritersFixture, only: [tenant!: 2]
  import Letflow.Support.RoleScopeGrantsFixture, only: [user!: 1]

  alias Letflow.Identity
  alias Letflow.Support.SyncScopeFixture, as: S

  @small 1
  @large 8

  # Measured per-group SELECT slope of one sync, after GH #2860 (before: off 11, on 18; see the
  # task summary). A regression that brings back a repeated read per group fails here.
  @max_slope_off 10
  @max_slope_on 12

  describe "GH #2860 SELECTs per sync grow with the number of groups, not faster" do
    test "scope enforcement off: per-group SELECT slope" do
      fx = tenant!("req2860-off", :off)

      c1 = selects(fx.schema_name, @small, "OFF1")
      c8 = selects(fx.schema_name, @large, "OFF8")

      assert (c8 - c1) / (@large - @small) <= @max_slope_off
    end

    test "scope enforcement on: per-group SELECT slope" do
      fx = tenant!("req2860-on", :on)

      c1 = selects(fx.schema_name, @small, "ON1")
      c8 = selects(fx.schema_name, @large, "ON8")

      assert (c8 - c1) / (@large - @small) <= @max_slope_on
    end
  end

  # One sync of a fresh user into `n` new platform-role groups; returns the SELECT count.
  defp selects(schema, n, tag) do
    roles = for i <- 1..n, do: "RC_#{tag}_#{i}"
    Enum.each(roles, &S.platform_group!(schema, &1, []))
    user = user!(schema)

    ref = make_ref()
    id = {__MODULE__, ref}
    :telemetry.attach(id, [:letflow, :repo, :query], &__MODULE__.handle_query/4, {self(), ref})

    try do
      assert {:ok, _synced} =
               Identity.sync_role_claims_report(user, S.claims(roles),
                 prefix: schema,
                 audit_context: %{trace_id: S.trace()}
               )

      drain(ref, 0)
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def handle_query(_event, _measurements, %{query: query}, {pid, ref}) do
    if String.starts_with?(query, "SELECT"), do: send(pid, {:select, ref}), else: :ok
  end

  defp drain(ref, acc) do
    receive do
      {:select, ^ref} -> drain(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
