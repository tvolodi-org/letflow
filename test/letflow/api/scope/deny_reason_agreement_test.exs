defmodule Letflow.Api.Scope.DenyReasonAgreementTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 22, REVIEWER finding F-1 (spec `test/specs/REQ-517-2b.md`): the
  closed set of deny reasons is spelled out in THREE places with no single source, so this test
  makes any drift loud:

    1. the `Letflow.Api.Scope.deny_reason()` type (what `Scope.allowed?/3` can answer);
    2. the metrics `Letflow.Api.Scope.ShadowEvidence` accepts and reports (`counts_between/3`
       answers `:requests` plus one key per reason);
    3. the `metric` CHECK of the tenant table `scope_shadow_counters`
       (`scope_shadow_counters_metric_check`: `requests` plus the same reasons).

  A seventh reason added to the type alone would make `record/3` silently swallow it (evidence
  lost, no error) and any flushed row hit the CHECK; a reason added to only one of the other two
  would make the persisted evidence disagree with what shadow observes. All three sets must be
  equal, as must the roster of the REAL decision function (every deny the six documented shapes
  produce is a member). The expected literal is pinned too, so a deliberate change shows up as a
  one-line diff here AND in the migration.

  `async: false`: it reads a provisioned tenant's live constraint definition.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Grants
  alias Letflow.Api.Scope.Principal
  alias Letflow.Api.Scope.ShadowEvidence
  alias Letflow.TenantFixture

  @expected MapSet.new(
              ~w(role_not_held no_grant_rows not_tenant_wide out_of_scope unresolvable grants_unavailable)a
            )

  # --- the three sources -----------------------------------------------------------------------

  # 1. the Scope.deny_reason() type, read from the compiled beam's typespec.
  defp type_reasons do
    {:ok, types} = Code.Typespec.fetch_types(Scope)

    {:deny_reason, ast, []} =
      Enum.find_value(types, fn
        {:type, {:deny_reason, _ast, _args} = type} -> type
        _other -> nil
      end)

    ast |> union_members() |> MapSet.new()
  end

  defp union_members({:type, _anno, :union, members}),
    do: Enum.flat_map(members, &union_members/1)

  defp union_members({:atom, _anno, atom}), do: [atom]

  # 2. the metrics ShadowEvidence reports, minus the request counter.
  defp evidence_reasons(schema) do
    counts = ShadowEvidence.counts_between(schema, ~D[2000-01-01], ~D[2000-01-02])
    assert Map.has_key?(counts, :requests)
    counts |> Map.keys() |> List.delete(:requests) |> MapSet.new()
  end

  # 3. the metric CHECK of scope_shadow_counters, read from the live definition.
  defp check_reasons(schema) do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE c.conname = 'scope_shadow_counters_metric_check' AND n.nspname = $1",
        [schema]
      )

    quoted = Regex.scan(~r/'([a-z_]+)'/, definition, capture: :all_but_first)
    values = quoted |> List.flatten() |> MapSet.new()

    assert MapSet.member?(values, "requests"), definition

    values
    |> MapSet.delete("requests")
    |> MapSet.new(&String.to_atom/1)
  end

  # ===========================================================================================
  test "the deny_reason type, the ShadowEvidence metrics and the CHECK list are the same six reasons" do
    # counts_between reads the table, so the schema must exist
    schema = TenantFixture.provisioned_tenant!(slug_prefix: "r517-reasons").schema_name

    type = type_reasons()
    evidence = evidence_reasons(schema)
    check = check_reasons(schema)

    assert MapSet.size(type) == 6
    assert type == @expected

    assert evidence == type,
           "ShadowEvidence metrics differ from Scope.deny_reason(): #{inspect({evidence, type})}"

    assert check == type,
           "scope_shadow_counters_metric_check differs from Scope.deny_reason(): #{inspect({check, type})}"
  end

  test "every reason the decision function can answer is a recordable metric" do
    # Five of the six deny shapes of allowed?/3 need no database (out_of_scope needs a tree
    # read and is covered by the shadow evidence test), built here with hand-made principals.
    grants = fn rows -> %Grants{user_id: "u", rows_by_role: rows} end

    principal = fn roles, grants ->
      %Principal{
        kind: :user,
        user_id: "u",
        prefix: "tenant_0123456789abcdef0123456789abcdef",
        platform_tenant?: false,
        roles: roles,
        grants: grants
      }
    end

    scoped =
      grants.(%{
        "TENANT_ADMIN" => [%{principal_type: :user, tenant_wide: false, scope_node_id: "n1"}]
      })

    answers = [
      Scope.allowed?(
        principal.([:TASK_WORKER], grants.(%{})),
        :UsersGroupsRolesManage,
        :tenant_wide
      ),
      Scope.allowed?(
        principal.([:TENANT_ADMIN], grants.(%{})),
        :UsersGroupsRolesManage,
        :tenant_wide
      ),
      Scope.allowed?(principal.([:TENANT_ADMIN], scoped), :UsersGroupsRolesManage, :tenant_wide),
      Scope.allowed?(
        principal.([:TENANT_ADMIN], :not_loaded),
        :UsersGroupsRolesManage,
        :tenant_wide
      ),
      Scope.allowed?(principal.([:TENANT_ADMIN], scoped), :UsersGroupsRolesManage, :unresolvable)
    ]

    reasons = for {:deny, reason} <- answers, do: reason

    assert reasons == [
             :role_not_held,
             :no_grant_rows,
             :not_tenant_wide,
             :grants_unavailable,
             :unresolvable
           ]

    for reason <- reasons do
      assert reason in @expected
      # recordable: record/3 stores it (it is swallowed, not stored, if it is not a known metric)
      assert ShadowEvidence.record(
               "tenant_0123456789abcdef0123456789abcdef",
               reason,
               ~D[2000-01-01]
             ) == :ok

      assert :ets.lookup(
               :letflow_scope_shadow_evidence,
               {"tenant_0123456789abcdef0123456789abcdef", ~D[2000-01-01], reason}
             ) != []
    end

    :ets.delete_all_objects(:letflow_scope_shadow_evidence)
  end
end
