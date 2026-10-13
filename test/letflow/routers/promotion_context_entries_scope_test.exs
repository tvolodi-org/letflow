defmodule Letflow.Routers.PromotionContextEntriesScopeTest do
  @moduledoc """
  ISS-1023 T-13 (`lib/letflow/design/iss1023-context-entries-own-sides.md` sections 3, 5, 6):
  `GET /promotions/:id/context` returns the `entries` of a NON-operator's `serialised_plan` as
  stored only when BOTH stored `source_tenant_id` and `target_tenant_id` are the caller's own
  tenant (case-insensitive); in every other case (a foreign id on either side, a missing, `null`
  or non-binary id, an empty or whitespace-padded id) it is `[]`. An operator sees the decoded
  plan unchanged. `entries` is the definition diff of BOTH sides' graphs, so a review naming
  tenants B and C held in the platform tenant P's schema must not hand B's and C's graph content
  to a non-operator reader of P. See `test/specs/ISS-1023.md`.

  The non-operator reader is `TENANT_ADMIN` (REQ-447 PR 2: a `PLATFORM_ADMIN` outside the pinned
  platform tenant holds nothing, so an ordinary tenant's admin identity is `TENANT_ADMIN`): of an
  ordinary tenant, or of P with the pin cleared (`Fixture.unpin!/0`), where it is a non-operator
  (`tenant_view/1`). The operator is the `PLATFORM_ADMIN` of the pinned P (`@operator`).
  `TENANT_AUDITOR` does not exist in `lib/` yet.

  Reviews are seeded through the real `PromotionReviewStore.insert_review/2`
  (`Scope.seed_review!/4`); legacy shapes use ONE recipe, `overwrite_plan!/3` (seed, then
  overwrite the `serialised_plan` column verbatim). `async: false` (VM-global platform pin;
  restored by the fixture's `on_exit`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.PromotionReview
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @allowlisted ~w(process_key base_version source_tenant_id target_tenant_id source_definition_id target_definition_id entries)
  @envelope ~w(review_id plan_digest serialised_plan status requested_by def_type def_id created_at row_version)
  @reader ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # --- helpers (copied from T-11, design OQ-7) ---------------------------------------------

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
  # non-operator at all: the exact 404 bytes of a nonexistent review id, carrying no marker.
  defp assert_not_found_like_absent!(ctx, fixture, review_id, label \\ "") do
    resp = context_resp(fixture, review_id, @reader)
    assert resp.status == 404, "#{label}: #{resp.status}"

    assert Scope.observable(resp) ==
             Scope.observable(context_resp(fixture, Ecto.UUID.generate(), @reader)),
           label

    refute_markers!(resp.resp_body, markers(ctx))
  end

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

  # Two entries carrying B's and C's graph content (B = ctx.b, C = ctx.a; both foreign to P).
  defp foreign_entries(ctx) do
    b = ctx.b.tenant_id
    c = ctx.a.tenant_id
    # the plan digest covers `entries` only and is unique per schema while pending, so every
    # seeded review needs distinct entries; `seq` is not a marker
    seq = System.unique_integer([:positive, :monotonic])

    [
      %{
        type: :graph_node,
        seq: seq,
        id: "n-iss1023-b",
        change_kind: :added,
        before: nil,
        after: %{
          "id" => "n-iss1023-b",
          "node_type" => "SERVICE_TASK",
          "service_id" => "svc-iss1023-b-secret",
          "label" => "B-ONLY-LABEL-iss1023",
          "tenant_id" => b
        }
      },
      %{
        type: :service_binding,
        seq: seq,
        id: "n-iss1023-c",
        change_kind: :modified,
        before: %{"service_id" => "svc-iss1023-c-before"},
        after: %{"service_id" => "svc-iss1023-c-after", "owner" => c}
      }
    ]
  end

  # Graph content and tenant ids that must never reach a non-operator reader.
  defp markers(ctx) do
    [
      ctx.b.tenant_id,
      ctx.a.tenant_id,
      "n-iss1023-b",
      "n-iss1023-c",
      "svc-iss1023-b-secret",
      "svc-iss1023-c-before",
      "svc-iss1023-c-after",
      "B-ONLY-LABEL-iss1023"
    ]
  end

  # `process_key` is NOT a marker (residual R4/R8): it is excluded on purpose.
  defp overrides(ctx, src_def, tgt_def) do
    %{
      entries: foreign_entries(ctx),
      source_definition_id: src_def,
      target_definition_id: tgt_def,
      process_key: Scope.unique_key("iss1023-key")
    }
  end

  defp refute_markers!(raw, list) do
    for m <- list do
      refute raw =~ m, "marker #{m} leaked"
      refute raw =~ String.upcase(m), "upper-cased marker #{m} leaked"
    end

    :ok
  end

  defp roundtrip(term), do: term |> Jason.encode!() |> Jason.decode!()

  # --- operator control --------------------------------------------------------------------

  describe "operator" do
    test "operator_reads_the_same_foreign_review_with_entries_unchanged", ctx do
      src_def = Ecto.UUID.generate()
      tgt_def = Ecto.UUID.generate()

      %{review: review, plan: stored} =
        Scope.seed_review!(
          ctx.p,
          ctx.b.tenant_id,
          ctx.a.tenant_id,
          overrides(ctx, src_def, tgt_def)
        )

      # pin is on P and the caller is P's PLATFORM_ADMIN: the operator
      {raw, plan} = read_plan!(ctx.p, review.id, @operator)

      assert plan["entries"] == roundtrip(stored.entries)
      assert plan == roundtrip(stored)

      # every marker is in the body, so the refutations below are not vacuous
      for m <- markers(ctx) ++ [src_def, tgt_def], do: assert(raw =~ m, "marker #{m} missing")
    end
  end

  # --- the AC: foreign reviews, non-operator reader in P -----------------------------------

  describe "foreign reviews, non-operator reader" do
    test "foreign_reviews_entries_are_empty_for_a_non_operator_reader_in_p", ctx do
      b = ctx.b.tenant_id
      c = ctx.a.tenant_id

      # (B source, C target), (C source, B target), (B, B)
      for {source, target} <- [{b, c}, {c, b}, {b, b}] do
        src_def = Ecto.UUID.generate()
        tgt_def = Ecto.UUID.generate()

        %{review: review} =
          Scope.seed_review!(ctx.p, source, target, overrides(ctx, src_def, tgt_def))

        Fixture.unpin!()
        assert_not_found_like_absent!(ctx, ctx.p, review.id, "#{source}/#{target}")
        resp = context_resp(ctx.p, review.id, @reader)
        refute_markers!(resp.resp_body, [src_def, tgt_def])
        Fixture.pin!(ctx.p.tenant_id)
      end
    end

    test "one_foreign_side_is_enough_to_withhold_entries", ctx do
      p = ctx.p.tenant_id
      b = ctx.b.tenant_id

      Fixture.unpin!()

      for {source, target} <- [{p, b}, {b, p}] do
        # own-side definition ids stay out of the marker set (design: they are shown for the own side)
        %{review: review} =
          Scope.seed_review!(
            ctx.p,
            source,
            target,
            overrides(ctx, Ecto.UUID.generate(), Ecto.UUID.generate())
          )

        {raw, plan} = read_plan!(ctx.p, review.id)

        assert plan["entries"] == []
        refute_markers!(raw, markers(ctx))
      end

      # control: both sides own (P/P) shows the stored entries
      %{review: review, plan: stored} =
        Scope.seed_review!(ctx.p, p, p, overrides(ctx, Ecto.UUID.generate(), nil))

      {_raw, plan} = read_plan!(ctx.p, review.id)
      assert plan["entries"] == roundtrip(stored.entries)
      assert plan["entries"] != []
    end

    test "own_tenant_reviews_still_show_entries", ctx do
      a = ctx.a.tenant_id

      # A's TENANT_ADMIN is a non-operator (pin on P)
      %{review: review, plan: stored} =
        Scope.seed_review!(ctx.a, a, a, overrides(ctx, Ecto.UUID.generate(), nil))

      {_raw, plan} = read_plan!(ctx.a, review.id)
      assert plan["entries"] == roundtrip(stored.entries)
      assert plan["entries"] != []
      assert plan["source_tenant_id"] == a
      assert plan["target_tenant_id"] == a

      # P/P read as P's TENANT_ADMIN with the pin cleared (a non-operator)
      %{review: p_review, plan: p_stored} =
        Scope.seed_review!(ctx.p, ctx.p.tenant_id, ctx.p.tenant_id, overrides(ctx, nil, nil))

      Fixture.unpin!()
      {_raw, p_plan} = read_plan!(ctx.p, p_review.id)
      assert p_plan["entries"] == roundtrip(p_stored.entries)
      assert p_plan["entries"] != []
    end

    test "own_ids_case_insensitive_keep_entries", ctx do
      a = ctx.a.tenant_id
      upper = String.upcase(a)
      assert upper != a

      %{review: review, plan: stored} =
        Scope.seed_review!(ctx.a, upper, a, overrides(ctx, nil, nil))

      {_raw, plan} = read_plan!(ctx.a, review.id)
      assert plan["entries"] == roundtrip(stored.entries)
      assert plan["entries"] != []
    end

    test "withheld_entries_leave_the_rest_of_the_response_unchanged", ctx do
      # ISS-1029: the foreign-named review is withheld as a whole (404), not shaped
      %{review: review} =
        Scope.seed_review!(
          ctx.p,
          ctx.b.tenant_id,
          ctx.a.tenant_id,
          overrides(ctx, Ecto.UUID.generate(), Ecto.UUID.generate())
        )

      Fixture.unpin!()
      assert_not_found_like_absent!(ctx, ctx.p, review.id)

      resp = context_resp(ctx.p, review.id, @reader)
      body = Jason.decode!(resp.resp_body)
      assert Enum.all?(~w(review_id plan_digest serialised_plan), &(not Map.has_key?(body, &1)))
    end
  end

  # --- legacy and malformed stored ids -----------------------------------------------------

  describe "legacy plans" do
    test "legacy_plans_with_missing_or_non_binary_tenant_ids_fail_closed", ctx do
      a = ctx.a.tenant_id
      b = ctx.b.tenant_id

      entries_json =
        ~s([{"type":"graph_node","id":"n-iss1023-legacy","change_kind":"added","before":null,"after":{"label":"LEGACY-MARKER-iss1023"}}])

      plan_text = fn fields ->
        fields
        |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> v end)
        |> Kernel.++([~s("process_key":"p"), ~s("entries":#{entries_json})])
        |> Enum.join(",")
        |> then(&("{" <> &1 <> "}"))
      end

      own = Jason.encode!(a)
      bad_values = ["7", ~s(["#{a}"]), ~s({"id":"#{a}"}), "true", "null"]

      cases =
        [
          {"both ids missing", []},
          {"source missing", [{"target_tenant_id", own}]},
          {"target missing", [{"source_tenant_id", own}]},
          {"foreign source, own target",
           [{"source_tenant_id", Jason.encode!(b)}, {"target_tenant_id", own}]},
          {"own source, foreign target",
           [{"source_tenant_id", own}, {"target_tenant_id", Jason.encode!(b)}]},
          {"both foreign",
           [{"source_tenant_id", Jason.encode!(b)}, {"target_tenant_id", Jason.encode!(b)}]},
          {"odd keys only", [{"tenantId", own}, {"tenant_ids", ~s(["#{a}"])}]}
        ] ++
          for(
            v <- bad_values,
            do: {"source #{v}", [{"source_tenant_id", v}, {"target_tenant_id", own}]}
          ) ++
          for(
            v <- bad_values,
            do: {"target #{v}", [{"source_tenant_id", own}, {"target_tenant_id", v}]}
          ) ++
          for(
            v <- [" " <> a, a <> " ", ""],
            do:
              {"source #{inspect(v)}",
               [{"source_tenant_id", Jason.encode!(v)}, {"target_tenant_id", own}]}
          )

      # ISS-1029 split: a case with at least ONE readable own id is a named PARTY and keeps
      # the ISS-1023 view (200, entries withheld); only a case with no readable own id is a
      # non-party (fail closed) and answers the nonexistent-review 404.
      non_parties = ["both ids missing", "both foreign", "odd keys only"]

      for {label, fields} <- cases, label not in non_parties do
        review = seed_and_overwrite!(ctx.a, plan_text.(fields))
        {raw, plan} = read_plan!(ctx.a, review.id)

        assert plan["entries"] == [], label
        refute raw =~ "LEGACY-MARKER-iss1023", label
        refute raw =~ "n-iss1023-legacy", label
        refute raw =~ b, label
      end

      for {label, fields} <- cases, label in non_parties do
        review = seed_and_overwrite!(ctx.a, plan_text.(fields))
        resp = context_resp(ctx.a, review.id, @reader)
        assert resp.status == 404, label

        assert Scope.observable(resp) ==
                 Scope.observable(context_resp(ctx.a, Ecto.UUID.generate(), @reader)),
               label

        refute resp.resp_body =~ "LEGACY-MARKER-iss1023", label
        refute resp.resp_body =~ "n-iss1023-legacy", label
        refute resp.resp_body =~ b, label
      end

      # positive control: both ids own shows the decoded fixture entries
      control = plan_text.([{"source_tenant_id", own}, {"target_tenant_id", own}])
      review = seed_and_overwrite!(ctx.a, control)
      {_raw, plan} = read_plan!(ctx.a, review.id)
      assert plan["entries"] == Jason.decode!(entries_json)
      assert plan["entries"] != []

      # operator view of the same legacy text: the decoded stored plan, unchanged
      op_text = plan_text.([{"source_tenant_id", Jason.encode!(b)}, {"target_tenant_id", own}])
      op_review = seed_and_overwrite!(ctx.p, op_text)
      {_raw, op_plan} = read_plan!(ctx.p, op_review.id, @operator)
      assert op_plan == Jason.decode!(op_text)
    end
  end

  # --- AC5 tripwire ------------------------------------------------------------------------

  describe "AC5" do
    # The platform tenant's PLATFORM_ADMIN and (REQ-447 PR 1) TENANT_ADMIN hold :PromotionsRead; the string
    # TENANT_AUDITOR still resolves to no role (`role_from_string/1`). When REQ-448 adds
    # TENANT_AUDITOR with :PromotionsRead this test fails: MOVE that row to the allowed side
    # (next test) and re-assert it against the new rule (a non-operator reader of P's
    # operator-created reviews naming foreign tenants must get the nonexistent 404, ISS-1029).
    test "non_admin_core_roles_in_the_platform_tenant_are_denied_promotions_read", ctx do
      %{review: review} =
        Scope.seed_review!(
          ctx.p,
          ctx.b.tenant_id,
          ctx.a.tenant_id,
          overrides(ctx, Ecto.UUID.generate(), Ecto.UUID.generate())
        )

      for roles <- [
            ["PROCESS_DESIGNER"],
            ["PROCESS_OPERATOR"],
            ["TASK_WORKER"],
            ["AGENT_RUNNER"],
            ["CANDIDATE"],
            ["TENANT_AUDITOR"],
            []
          ] do
        resp = context_resp(ctx.p, review.id, roles)

        assert resp.status == 403, "#{inspect(roles)}"
        refute_markers!(resp.resp_body, markers(ctx))
      end
    end

    # REQ-447 PR 1 (D3's binding condition for :PromotionsRead being tenant scope): the platform
    # tenant's own TENANT_ADMIN holds :PromotionsRead, is NOT an operator (no PLATFORM_ADMIN), and
    # therefore reads an operator-created review naming foreign tenants B and C with `entries == []`
    # and none of B's or C's graph content or ids, with the pin on P and with no pin.
    test "tenant_admin_of_the_platform_tenant_reads_a_foreign_review_without_entries", ctx do
      src_def = Ecto.UUID.generate()
      tgt_def = Ecto.UUID.generate()

      %{review: review} =
        Scope.seed_review!(
          ctx.p,
          ctx.b.tenant_id,
          ctx.a.tenant_id,
          overrides(ctx, src_def, tgt_def)
        )

      # ISS-1029: with the pin on P and with no pin the review is the nonexistent 404
      for pinned? <- [true, false] do
        if pinned?, do: Fixture.pin!(ctx.p.tenant_id), else: Fixture.unpin!()

        resp = context_resp(ctx.p, review.id, ["TENANT_ADMIN"])
        assert resp.status == 404, "pinned=#{pinned?}"

        assert Scope.observable(resp) ==
                 Scope.observable(context_resp(ctx.p, Ecto.UUID.generate(), ["TENANT_ADMIN"]))

        refute_markers!(resp.resp_body, markers(ctx) ++ [src_def, tgt_def])
      end

      # Control: the operator (PLATFORM_ADMIN of the pinned P) sees the same review in full.
      Fixture.pin!(ctx.p.tenant_id)
      {raw, operator_plan} = read_plan!(ctx.p, review.id, @operator)
      assert operator_plan["entries"] != []
      for m <- markers(ctx), do: assert(raw =~ m, "marker #{m} missing")
    end
  end
end
