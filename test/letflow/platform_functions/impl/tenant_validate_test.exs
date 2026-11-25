defmodule Letflow.PlatformFunctions.Impl.TenantValidateTest do
  @moduledoc """
  The body of `tenant.validate` (T-2704, pilot gap G17b): the read-only first
  step of the registration chain. It writes nothing and refuses with the
  vocabulary of `tenant.create`.
  """

  use Letflow.DataCase, async: true

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Impl.TenantValidate

  @slug "t2704-validate"
  @name "T-2704 Validate Ltd"

  defp run(overrides \\ %{}) do
    TenantValidate.run(%{inputs: Map.merge(%{"slug" => @slug, "name" => @name}, overrides)})
  end

  test "V1 a free slug passes and nothing is written" do
    assert {:ok, %{}} = run()
    assert Repo.all(from(t in Tenant, where: t.slug == ^@slug)) == []
  end

  test "V2 the same registration passes (a repeat adopts), another tenant's slug is refused" do
    {:ok, _tenant} = Letflow.Identity.create_tenant(%{"slug" => @slug, "display_name" => @name})

    assert {:ok, %{}} = run()
    assert {:error, :platform_call_duplicate_slug} = run(%{"name" => "Somebody Else"})
  end

  test "V3 a value over the byte cap, empty or not a string is refused first" do
    big = String.duplicate("a", 256)

    assert {:error, :platform_call_arg_invalid} = run(%{"slug" => big})
    assert {:error, :platform_call_arg_invalid} = run(%{"name" => big})
    assert {:error, :platform_call_arg_invalid} = run(%{"slug" => ""})
    assert {:error, :platform_call_arg_invalid} = run(%{"slug" => 7})
    assert {:error, :platform_call_arg_invalid} = TenantValidate.run(%{})
  end

  test "V3b the cap is 255 characters: multibyte at the cap passes, one over is refused" do
    assert {:ok, %{}} = run(%{"name" => String.duplicate("é", 255)})
    assert {:error, :platform_call_arg_invalid} = run(%{"name" => String.duplicate("é", 256)})
    # A huge value is refused by the byte bound before any character work.
    assert {:error, :platform_call_arg_invalid} = run(%{"name" => String.duplicate("a", 100_000)})
  end

  test "V4 a reserved slug is refused" do
    assert {:error, :platform_call_arg_invalid} = run(%{"slug" => "pwa"})
  end
end
