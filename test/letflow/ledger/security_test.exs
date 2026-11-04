defmodule Letflow.Ledger.SecurityTest do
  @moduledoc """
  REQ-685 criterion 4 (T-SEC-1): the run-time order is origin, authority, THEN the deferred
  refusal. An unauthorised caller gets the same denial for an invalid command as for a valid one
  (INV-5), the roles are read from the database inside the transaction, and the SERVICE origin
  is refused.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.Support.TokenMintFixture
  alias Letflow.LedgerPostFixture, as: Fx

  @invalid_postings [
    {"bad shape", %{"legs" => "nope"}},
    {"unknown cause", %{"cause" => "bogus"}},
    {"float quantity", %{"legs" => [%{"k" => ["a", ""], "quantity" => 1.5, "unit_ref" => "u1"}]}},
    {"bad slot", %{"legs" => [%{"k" => ["a", "x"], "quantity" => "1", "unit_ref" => "u1"}]}},
    {"declare raises", %{"explode" => "raise"}},
    {"late event",
     %{"device_id" => "d", "client_seq" => 1, "client_event_time" => "2001-01-01T00:00:00Z"}}
  ]

  defp line(extra \\ %{}),
    do: Fx.post_line("post_alpha", Fx.posting("receipt", "a", "5", extra))

  defp reason({:error, {:line, _, :ledger_post}, reason, _changes}), do: reason

  defp base_case(slug), do: Fx.case!(slug, [line()])

  defp holder(ctx, roles), do: TokenMintFixture.role_holder!(ctx.schema, roles)

  test "T-SEC-1a a subject without the post atom gets one denial, valid or not" do
    ctx = base_case("req685-sec1a")
    subject = holder(ctx, ["TASK_WORKER"])
    valid = reason(Fx.run_lines(ctx, [line()], subject: subject))
    assert valid == {:ledger_denied, :role_denied}

    for {_name, extra} <- @invalid_postings do
      assert reason(Fx.run_lines(ctx, [line(extra)], subject: subject)) == valid
    end

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "T-SEC-1b :api_token, nil and any other credential are denied the same way" do
    ctx = base_case("req685-sec1b")

    for credential <- [:api_token, nil, :basic, "oidc"] do
      valid = reason(Fx.run_lines(ctx, [line()], credential: credential))
      assert valid == {:ledger_denied, :credential_unsupported}

      for {_name, extra} <- @invalid_postings do
        assert reason(Fx.run_lines(ctx, [line(extra)], credential: credential)) == valid
      end
    end
  end

  test "T-SEC-1c an authorised subject gets each typed refusal at the Multi level" do
    ctx = base_case("req685-sec1c")

    assert {:ledger_refused, :invalid_posting, "invalid_posting", _} =
             reason(Fx.run_lines(ctx, [line(%{"legs" => []})]))

    assert {:ledger_refused, :invalid_posting, _, %{reason: :quantity_invalid}} =
             reason(
               Fx.run_lines(ctx, [
                 line(%{"legs" => [%{"k" => ["a", ""], "quantity" => 1.5, "unit_ref" => "u1"}]})
               ])
             )

    assert {:ledger_refused, :event_time_too_old, _, _} =
             reason(
               Fx.run_lines(ctx, [
                 line(%{
                   "device_id" => "d",
                   "client_seq" => 1,
                   "client_event_time" => "2001-01-01T00:00:00Z"
                 })
               ])
             )
  end

  test "T-SEC-1d a tenant-wide TENANT_ADMIN posts" do
    ctx = base_case("req685-sec1d")
    assert {:ok, _} = Fx.run_lines(ctx, [line()])
    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
  end

  test "T-SEC-1e a role revoked between claim and completion is refused" do
    ctx = Fx.case!("req685-sec1e", [line()])
    Fx.revoke_roles!(ctx)

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} = Fx.complete(ctx)
    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "T-SEC-1f PLATFORM_ADMIN in a non-platform tenant holds nothing" do
    ctx = base_case("req685-sec1f")
    subject = holder(ctx, ["PLATFORM_ADMIN"])

    assert {:ledger_denied, :role_denied} ==
             reason(Fx.run_lines(ctx, [line()], subject: subject))
  end

  test "T-SEC-1g a non-task origin is refused before authority and before the deferred refusal" do
    ctx = base_case("req685-sec1g")
    origin = {:dispatch, Ecto.UUID.generate()}

    assert {:ledger_denied, :ledger_origin_not_supported} ==
             reason(Fx.run_lines(ctx, [line()], origin: origin))

    assert {:ledger_denied, :ledger_origin_not_supported} ==
             reason(
               Fx.run_lines(ctx, [line(%{"cause" => "bogus"})], origin: origin, credential: nil)
             )
  end

  test "T-SEC-1h the engine answers the uniform write_not_permitted for a denied completion" do
    ctx =
      Fx.case!("req685-sec1h", [
        Fx.line("post_alpha", %{"posting" => Fx.posting("bogus", "a", "5")})
      ])

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, credential: :api_token)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # REQ-686: a build-time refusal released after authority is now the typed refusal
        assert {:error,
                {:entity_write_refused_detailed, 0, :invalid_posting, "invalid_posting", _}} =
                 Fx.complete(ctx)
      end)

    refute log =~ "bogus"
  end
end
