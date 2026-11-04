defmodule Letflow.Ledger.PolicyPureTest do
  @moduledoc """
  REQ-685 criterion 2 (T-PL-1, T-PL-2): `declare/2` runs at build time with ZERO database queries,
  a raise, exit or throw keeps no text, and the maximum command (200 legs) is declared and
  re-validated within 200 ms. The caps themselves and the typed releases are in
  `handler_post_test.exs` (HP-7..HP-14).
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.LedgerFixture, as: LF
  alias Letflow.Ledger.Validate
  alias Letflow.Modules.Catalog

  defp registration do
    {:ok, registration} = Catalog.fetch_ledger("fixture_ledger_post", "alpha")
    registration
  end

  defp command(legs, extra \\ %{}) do
    Map.merge(
      %{ledger_id: "fixture_ledger_post", cause: "receipt", client_op_id: "op-1", legs: legs},
      extra
    )
  end

  defp leg(i), do: %{k: ["item#{i}", ""], quantity: "1", unit_ref: "u1"}

  test "T-PL-1 declare_posting/2 sends no database statement" do
    {result, statements} =
      LF.record(fn -> Catalog.declare_posting(registration(), command([leg(1)])) end)

    assert {:ok, %{ledger_id: "fixture_ledger_post"}} = result
    assert statements == []
  end

  test "T-PL-1b a raise, exit or throw of declare/2 is a closed error without text" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for kind <- [:raise, :exit, :throw] do
          assert {:error, :declare_raised} =
                   Catalog.declare_posting(registration(), command([leg(1)], %{explode: kind}))
        end
      end)

    refute log =~ "secret"

    assert {:error, {:invalid_posting, %{reason: :posting_shape}}} =
             Catalog.declare_posting(registration(), "not a map")

    assert {:error, :declare_refused} = Catalog.declare_posting(%{}, command([leg(1)]))

    assert {:error, :declare_refused} =
             Catalog.declare_posting(registration(), command([leg(1)], %{explode: :not_a_tuple}))
  end

  test "T-PL-2 a maximum command is declared and re-validated within 200 ms" do
    legs = for i <- 1..200, do: leg(i)
    command = command(legs)
    registration = registration()

    {micros, {:ok, posting}} = :timer.tc(fn -> Catalog.declare_posting(registration, command) end)

    {validate_micros, result} =
      :timer.tc(fn -> Validate.posting(posting, command, registration) end)

    assert {:ok, %{legs: normalised}} = result
    assert length(normalised) == 200
    assert micros + validate_micros < 200_000
  end

  test "T-PL-3 Validate.reasons/0 lists every member of the reason type" do
    {:ok, types} = Code.Typespec.fetch_types(Validate)

    {:type, {:reason, {:type, _, :union, members}, []}} =
      Enum.find(types, &match?({:type, {:reason, _, _}}, &1))

    from_type = for {:atom, _, name} <- members, do: name
    assert Enum.sort(from_type) == Enum.sort(Validate.reasons())
  end

  test "T-PL-4 the event window is one function for build and run time" do
    registration = registration()
    now = DateTime.utc_now()

    assert :ok = Validate.check_event_window(now, now, registration)

    assert {:error, {:ledger_refused, :event_time_too_old, _, _}} =
             Validate.check_event_window(DateTime.add(now, -97 * 3600), now, registration)

    assert {:error, {:ledger_refused, :event_time_in_future, _, _}} =
             Validate.check_event_window(DateTime.add(now, 301), now, registration)
  end
end
