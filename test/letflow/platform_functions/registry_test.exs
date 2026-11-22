defmodule Letflow.PlatformFunctions.RegistryTest do
  @moduledoc """
  The CLOSED registry of platform function bodies (T-2589, pilot gap G1a).

  Two closures, both proved here:

    * a body exists only for a name the compiled catalogue declares (the
      catalogue is the only list of names a definition may call);
    * a name the catalogue declares but that has no body yet is refused with
      `:not_implemented` -- the dispatcher never pretends such a call
      succeeded.

  No database.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Impl.ValidateRegistration
  alias Letflow.PlatformFunctions.Registry

  test "every body the registry knows is declared in the compiled catalogue" do
    names = Registry.names()

    assert "platform.validate_registration" in names

    for name <- names do
      assert {:ok, entry} = Catalog.fetch(name),
             "#{name} has a body but is not declared in the compiled catalogue"

      assert entry.name == name
    end
  end

  test "a name that is not in the catalogue has no body" do
    assert {:error, :not_found} = Registry.fetch("platform.not_in_the_catalogue")
    assert {:error, :not_found} = Catalog.fetch("platform.not_in_the_catalogue")
  end

  test "a declared name without a body is refused as not implemented" do
    # The pilot's tenant family is DECLARED (the authority rule of gap G2
    # needs the names); its bodies arrive with the rest of gap G1.
    assert {:ok, _entry} = Catalog.fetch("tenant.create")
    assert {:error, :not_implemented} = Registry.fetch("tenant.create")
  end

  test "the registered body of the validation entry is the implementation module" do
    assert {:ok, {ValidateRegistration, :run, 1}} =
             Registry.fetch("platform.validate_registration")
  end
end
