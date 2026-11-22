defmodule Letflow.PlatformFunctions.Impl.ValidateRegistrationTest do
  @moduledoc """
  The body of `platform.validate_registration` (T-2589, pilot gap G1a): the
  harmless function that proves the path of a platform step end to end.

  What the tests prove:

    * the accepted values return exactly the outputs the catalogue entry
      declares (no other key);
    * every refused value has its own stable code;
    * the function has NO side effect: it issues no query at all (the repo
      telemetry is captured around the call).

  No database is written; the "no side effect" proof reads the repo query
  telemetry.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Impl.ValidateRegistration
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  defp inputs(overrides \\ %{}) do
    Map.merge(
      %{"slug" => "acme", "display_name" => "Acme Ltd", "email" => "admin@acme.test"},
      overrides
    )
  end

  test "the accepted values return exactly the declared outputs" do
    assert {:ok, outputs} = ValidateRegistration.run(%{inputs: inputs()})

    assert outputs == %{
             "normalized_slug" => "acme",
             "email_domain" => "acme.test"
           }

    {:ok, entry} = Catalog.fetch("platform.validate_registration")
    declared = Enum.map(entry.outputs, & &1.name) |> Enum.sort()
    assert Enum.sort(Map.keys(outputs)) == declared
  end

  test "a slug that is not a slug is refused with its own code" do
    for slug <- ["", "   ", "Acme", "-acme", "acme-", "a", "ac me", "acme_x"] do
      assert {:error, :platform_call_invalid_slug} =
               ValidateRegistration.run(%{inputs: inputs(%{"slug" => slug})}),
             "#{inspect(slug)} should not be accepted"
    end
  end

  test "a blank or oversized display name is refused with its own code" do
    assert {:error, :platform_call_invalid_display_name} =
             ValidateRegistration.run(%{inputs: inputs(%{"display_name" => "  "})})

    assert {:error, :platform_call_invalid_display_name} =
             ValidateRegistration.run(%{
               inputs: inputs(%{"display_name" => String.duplicate("x", 201)})
             })
  end

  test "an e-mail that is not an e-mail is refused with its own code" do
    for email <- ["", "admin", "admin@", "@acme.test", "admin@acme", "admin acme@test"] do
      assert {:error, :platform_call_invalid_email} =
               ValidateRegistration.run(%{inputs: inputs(%{"email" => email})}),
             "#{inspect(email)} should not be accepted"
    end
  end

  test "a missing value is refused, not guessed" do
    assert {:error, :platform_call_invalid_slug} =
             ValidateRegistration.run(%{inputs: inputs(%{"slug" => nil})})

    assert {:error, :platform_call_invalid_email} =
             ValidateRegistration.run(%{inputs: inputs(%{"email" => 42})})
  end

  test "the function has no side effect: it issues no query at all" do
    {result, queries} =
      PlatformFx.capture_repo_queries(fn ->
        ValidateRegistration.run(%{inputs: inputs()})
      end)

    assert {:ok, _outputs} = result
    assert queries == []
  end
end
