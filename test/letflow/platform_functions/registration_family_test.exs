defmodule Letflow.PlatformFunctions.RegistrationFamilyTest do
  @moduledoc """
  The registration family's catalogue entry (T-2589, pilot gap G1a): the
  DECLARATION of `platform.validate_registration`.

  The entry is what a designer reads and what the activation fence checks
  against, so its shape is pinned here: the name, the typed inputs and their
  source class, the typed outputs, the permission, the side effects and the
  idempotency key.

  No database: the catalogue is compiled into the build.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.RegistrationFamily

  @name "platform.validate_registration"

  setup do
    [entry] = RegistrationFamily.entries()
    %{entry: entry}
  end

  test "the family declares the one entry of the pilot", %{entry: entry} do
    assert entry.name == @name
    assert entry.family == :platform
    assert entry.version == "1"
  end

  test "the entry needs the platform atom and runs only in the platform tenant", %{entry: entry} do
    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only == true
  end

  test "the inputs are typed and come from the start form", %{entry: entry} do
    assert Enum.map(entry.inputs, &{&1.name, &1.type, &1.required, &1.source_class}) == [
             {"slug", :string, true, :start},
             {"display_name", :string, true, :start},
             {"email", :string, true, :start}
           ]
  end

  test "the outputs are the two names the body returns", %{entry: entry} do
    assert Enum.map(entry.outputs, &{&1.name, &1.type}) == [
             {"normalized_slug", :string},
             {"email_domain", :string}
           ]
  end

  test "the entry has no side effect and is therefore not write-like", %{entry: entry} do
    assert Enum.map(entry.side_effects, & &1.class) == [:read]
    refute Entry.write_like?(entry)
  end

  test "the idempotency key is the slug: the same slug is the same registration", %{entry: entry} do
    assert entry.idempotency_key == ["slug"]
  end
end
