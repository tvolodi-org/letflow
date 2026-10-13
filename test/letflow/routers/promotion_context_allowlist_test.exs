defmodule Letflow.Routers.PromotionContextAllowlistTest do
  @moduledoc """
  ISS-1021 T-11 (`lib/letflow/design/iss1021-context-plan-allowlist.md` sections 3, 5, 6):
  `GET /promotions/:id/context` builds the non-operator `serialised_plan` from a top-level key
  ALLOWLIST (`process_key`, `base_version`, own tenant ids, own-side definition ids, `entries`
  as stored only when both plan tenant ids are own (ISS-1023)). Every other key, any non-scalar under a plain key and every non-map plan never
  reaches a non-operator. An operator sees the decoded plan unchanged. See
  `test/specs/ISS-1021.md`.

  Reviews are seeded through the real `PromotionReviewStore.insert_review/2`
  (`Scope.seed_review!/4`). Malformed and legacy plans cannot be inserted that way, so they use
  ONE recipe, `overwrite_plan!/3`: seed a normal review, then overwrite its `serialised_plan`
  column verbatim. `async: false` (VM-global platform pin; restored by the fixture's `on_exit`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.PromotionReview
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @allowlisted ~w(process_key base_version source_tenant_id target_tenant_id source_definition_id target_definition_id entries)

  # REQ-447 PR 2: the non-operator reader is a TENANT_ADMIN (a PLATFORM_ADMIN outside the pinned
  # platform tenant holds nothing); the operator is the PLATFORM_ADMIN of the pinned platform tenant.
  @reader ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp context_resp(fixture, review_id, roles) do
    Letflow.Routers.Promotions.call(
      Fixture.router_conn(:get, "/#{review_id}/context", fixture, roles, nil),
      Letflow.Routers.Promotions.init([])
    )
  end

  defp read_plan!(fixture, review_id, roles \\ @reader) do
    resp = context_resp(fixture, review_id, roles)
    assert resp.status == 200
    {resp.resp_body, Jason.decode!(resp.resp_body)["serialised_plan"]}
  end

  # ISS-1029: a review whose stored ids are not the reader's own is not readable by a
  # non-operator at all: the exact 404 bytes of a nonexistent review id.
  defp assert_not_found_like_absent!(fixture, review_id, roles \\ @reader) do
    resp = context_resp(fixture, review_id, roles)
    assert resp.status == 404

    assert Scope.observable(resp) ==
             Scope.observable(context_resp(fixture, Ecto.UUID.generate(), roles))
  end

  # The one recipe for a malformed or legacy plan (design section 6 file 3).
  defp overwrite_plan!(fixture, review_id, json_text) do
    query = from(r in PromotionReview, where: r.id == ^review_id)

    assert {1, _} =
             Repo.update_all(query, [set: [serialised_plan: json_text]],
               prefix: fixture.schema_name
             )

    :ok
  end

  defp seed_and_overwrite!(fixture, json_text) do
    %{review: review} = Scope.seed_review!(fixture, fixture.tenant_id, fixture.tenant_id)
    :ok = overwrite_plan!(fixture, review.id, json_text)
    review
  end

  describe "keys outside the allowlist" do
    test "odd_tenant_keys_never_reach_a_non_operator", ctx do
      b = ctx.b.tenant_id
      odd = %{tenantId: b, tenant_ids: [b], source_tenant: b, x_tenant_id: b}

      # each alone, then all four together
      variants = Enum.map(odd, fn {k, v} -> %{k => v} end) ++ [odd]

      for overrides <- variants do
        %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id, overrides)

        {raw, plan} = read_plan!(ctx.a, review.id)

        refute raw =~ b
        refute raw =~ String.upcase(b)

        for key <- ["tenantId", "tenant_ids", "source_tenant", "x_tenant_id"] do
          refute Map.has_key?(plan, key), "#{key} leaked"
        end

        assert Map.keys(plan) -- @allowlisted == []
      end
    end

    test "unknown_top_level_key_omitted", ctx do
      %{review: review} =
        Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id, %{plan_extra: "x"})

      {raw, plan} = read_plan!(ctx.a, review.id)

      # a benign scalar: omission is by allowlist, not by content
      refute Map.has_key?(plan, "plan_extra")
      refute raw =~ "plan_extra"
    end

    test "entries_kept_exactly_as_stored", ctx do
      b = ctx.b.tenant_id

      entries = [
        %{
          type: :graph_node,
          id: "n1-#{System.unique_integer([:positive, :monotonic])}",
          change_kind: :added,
          after: %{"id" => "n1", "node_type" => "START", "tenant_id" => b},
          before: %{"tenant_id" => b},
          tenant_id: b
        }
      ]

      %{review: review, plan: stored} =
        Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id, %{entries: entries})

      {_raw, plan} = read_plan!(ctx.a, review.id)

      # both sides own: kept exactly as stored (residual R1b); a foreign side is T-13
      assert plan["entries"] == stored.entries |> Jason.encode!() |> Jason.decode!()
      [entry] = plan["entries"]
      assert entry["tenant_id"] == b
      assert entry["after"]["tenant_id"] == b
    end

    test "non_scalar_under_plain_key_omitted", ctx do
      cases = [
        {"process_key", %{"a" => 1}},
        {"base_version", %{"a" => 1}},
        {"base_version", [1, 2]},
        {"process_key", [ctx.b.tenant_id]}
      ]

      for {key, value} <- cases do
        # own a/a ids: a non-operator can only reach (ISS-1029) a review naming its own tenant
        stored =
          Map.put(
            %{
              "process_key" => "p",
              "base_version" => "1.0.0",
              "source_tenant_id" => ctx.a.tenant_id,
              "target_tenant_id" => ctx.a.tenant_id,
              "entries" => []
            },
            key,
            value
          )

        review = seed_and_overwrite!(ctx.a, Jason.encode!(stored))

        {raw, plan} = read_plan!(ctx.a, review.id)

        refute Map.has_key?(plan, key)
        refute raw =~ ctx.b.tenant_id
        other = if key == "process_key", do: "base_version", else: "process_key"
        assert plan[other] == stored[other]
        assert plan["entries"] == []
      end
    end
  end

  describe "tenant id and definition id rules" do
    test "own_tenant_ids_kept_case_insensitively", ctx do
      upper = String.upcase(ctx.a.tenant_id)
      assert upper != ctx.a.tenant_id

      %{review: review} = Scope.seed_review!(ctx.a, upper, ctx.a.tenant_id)
      {_raw, plan} = read_plan!(ctx.a, review.id)

      # kept, and returned as stored (case preserved)
      assert plan["source_tenant_id"] == upper
      assert plan["target_tenant_id"] == ctx.a.tenant_id
    end

    test "foreign_side_definition_id_omitted_own_side_kept", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id
      src_def = Ecto.UUID.generate()
      tgt_def = Ecto.UUID.generate()
      overrides = %{source_definition_id: src_def, target_definition_id: tgt_def}

      # own/own: every id kept as stored
      %{review: review} = Scope.seed_review!(ctx.a, a, a, overrides)
      {raw, plan} = read_plan!(ctx.a, review.id)
      refute raw =~ b
      assert plan["source_tenant_id"] == a
      assert plan["target_tenant_id"] == a
      assert plan["source_definition_id"] == src_def
      assert plan["target_definition_id"] == tgt_def
      assert plan["entries"] != []

      # any foreign side (ISS-1029): the review is not readable, so none of its ids can be
      for {source, target} <- [{b, a}, {a, b}, {b, b}] do
        %{review: review} = Scope.seed_review!(ctx.a, source, target, overrides)
        assert_not_found_like_absent!(ctx.a, review.id)
        refute context_resp(ctx.a, review.id, @reader).resp_body =~ b
      end
    end

    test "null_definition_id_omitted_for_foreign_side_kept_for_own_side", ctx do
      %{review: review} =
        Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id, %{
          source_definition_id: nil,
          target_definition_id: nil
        })

      {_raw, plan} = read_plan!(ctx.a, review.id)

      assert Map.fetch(plan, "source_definition_id") == {:ok, nil}
      assert Map.fetch(plan, "target_definition_id") == {:ok, nil}

      # a foreign side is not readable at all (ISS-1029)
      %{review: foreign} =
        Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id, %{
          source_definition_id: nil,
          target_definition_id: nil
        })

      assert_not_found_like_absent!(ctx.a, foreign.id)
    end
  end

  describe "malformed and legacy plans" do
    test "non_map_plan_fails_closed", ctx do
      shapes = [
        {"string", "\"x\"", "x"},
        {"array", "[1,2]", [1, 2]},
        {"number", "7", 7},
        {"json_null", "null", nil}
      ]

      for {shape, json, operator_value} <- shapes do
        # ISS-1029: no readable stored ids, so the non-operator gets the nonexistent 404
        review = seed_and_overwrite!(ctx.a, json)
        assert_not_found_like_absent!(ctx.a, review.id)

        op_review = seed_and_overwrite!(ctx.p, json)
        {_raw, op_plan} = read_plan!(ctx.p, op_review.id, @operator)
        assert op_plan == operator_value, "operator, #{shape}"
      end
    end

    test "legacy_plan_missing_keys", ctx do
      b = ctx.b.tenant_id

      no_entries = "{\"process_key\":\"legacy-key\",\"tenant_ids\":[\"#{b}\"]}"
      only_entries = "{\"entries\":[],\"legacy_tenant\":\"#{b}\"}"

      review = seed_and_overwrite!(ctx.a, no_entries)
      assert_not_found_like_absent!(ctx.a, review.id)
      refute context_resp(ctx.a, review.id, @reader).resp_body =~ b

      op_review = seed_and_overwrite!(ctx.p, no_entries)
      {_raw, op_plan} = read_plan!(ctx.p, op_review.id, @operator)
      assert op_plan == %{"process_key" => "legacy-key", "tenant_ids" => [b]}

      review = seed_and_overwrite!(ctx.a, only_entries)
      assert_not_found_like_absent!(ctx.a, review.id)
      refute context_resp(ctx.a, review.id, @reader).resp_body =~ b

      op_review = seed_and_overwrite!(ctx.p, only_entries)
      {_raw, op_plan} = read_plan!(ctx.p, op_review.id, @operator)
      assert op_plan == %{"entries" => [], "legacy_tenant" => b}
    end

    test "entries_not_a_list_replaced_by_empty_list", ctx do
      for bad <- ["\"not-a-list\"", "{\"a\":1}", "null"] do
        # own a/a ids so a non-operator can reach the review (ISS-1029)
        a = ctx.a.tenant_id

        json =
          "{\"process_key\":\"p\",\"source_tenant_id\":\"#{a}\",\"target_tenant_id\":\"#{a}\",\"entries\":#{bad}}"

        review = seed_and_overwrite!(ctx.a, json)
        {raw, plan} = read_plan!(ctx.a, review.id)

        assert plan ==
                 %{
                   "process_key" => "p",
                   "source_tenant_id" => a,
                   "target_tenant_id" => a,
                   "entries" => []
                 },
               "entries #{bad}"

        refute raw =~ "not-a-list"
      end
    end

    test "nil_tenant_context_never_reaches_the_handler", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id)

      conn =
        :get
        |> Fixture.router_conn("/#{review.id}/context", ctx.a, @reader, nil)
        |> Plug.Conn.assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: nil,
          roles: @reader
        })

      resp = Letflow.Routers.Promotions.call(conn, Letflow.Routers.Promotions.init([]))

      # Authorize halts before the handler: the `{:tenant, nil}` shaping branch is unreachable
      # through the route (defence in depth); if this ever returns 200 the design must be revisited.
      assert resp.status == 500
      refute resp.resp_body =~ "serialised_plan"
      refute resp.resp_body =~ ctx.a.tenant_id
      refute resp.resp_body =~ ctx.b.tenant_id
    end
  end

  describe "operator and envelope" do
    test "operator_sees_all_unchanged", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id

      %{review: review, plan: stored} =
        Scope.seed_review!(ctx.p, b, a, %{
          tenantId: b,
          tenant_ids: [b],
          source_tenant: b,
          x_tenant_id: b,
          plan_extra: "x",
          meta: %{origin_tenant_id: b, own: a}
        })

      {raw, plan} = read_plan!(ctx.p, review.id, @operator)

      assert raw =~ b
      assert raw =~ a
      assert plan == stored |> Jason.encode!() |> Jason.decode!()
      assert plan["meta"] == %{"origin_tenant_id" => b, "own" => a}
    end

    test "envelope_has_nine_keys_for_both_views", ctx do
      expected =
        Enum.sort(~w(review_id plan_digest serialised_plan status requested_by def_type def_id
                     created_at row_version))

      # a reader can only reach an own/own review (ISS-1029); the operator reads a foreign one
      for {fixture, source} <- [{ctx.a, ctx.a.tenant_id}, {ctx.p, ctx.b.tenant_id}] do
        %{review: review} = Scope.seed_review!(fixture, source, fixture.tenant_id)
        roles = if fixture == ctx.p, do: @operator, else: @reader
        resp = context_resp(fixture, review.id, roles)
        assert resp.status == 200
        assert resp.resp_body |> Jason.decode!() |> Map.keys() |> Enum.sort() == expected
      end
    end

    test "pin_unset_would_be_operator_is_shaped_like_everyone_else", ctx do
      b = ctx.b.tenant_id

      %{review: foreign} =
        Scope.seed_review!(ctx.p, b, ctx.p.tenant_id, %{tenantId: b, plan_extra: "x"})

      %{review: own} =
        Scope.seed_review!(ctx.p, ctx.p.tenant_id, ctx.p.tenant_id, %{
          tenantId: b,
          plan_extra: "x"
        })

      Fixture.unpin!()

      # ISS-1029: the foreign-named review is not readable; the shaping is still applied to
      # an own/own one
      assert_not_found_like_absent!(ctx.p, foreign.id)

      {raw, plan} = read_plan!(ctx.p, own.id)

      refute raw =~ b
      assert Map.keys(plan) -- @allowlisted == []
      assert plan["source_tenant_id"] == ctx.p.tenant_id
      assert plan["target_tenant_id"] == ctx.p.tenant_id
      refute Map.has_key?(plan, "tenantId")
      refute Map.has_key?(plan, "plan_extra")
    end
  end
end
