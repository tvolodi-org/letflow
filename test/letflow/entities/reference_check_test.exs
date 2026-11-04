defmodule Letflow.Entities.ReferenceCheckTest do
  @moduledoc """
  REQ-636 (decision 0070 slice C): `Letflow.Entities.ReferenceCheck` directly, on fresh tenants.

    * D4-optin / D4-dangling: the field list and the failing names, in definition order.
    * D4-empty / D4-shape: absent, nil and "" values are not checked; a non-map or non-binary
      input is `:ok` (the check refuses nothing it does not understand, INV-8).
    * D4-xtenant: the lookup runs in the prefix given, never another tenant's.
    * D4-source-scan: the file reads modules only through `Catalog`, `Installs` and the entry
      module's public `lookup/2` / `active?/2` (decision 0050 D8).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ReferenceCheck
  alias Letflow.ReferenceFixture
  alias Letflow.Test.SandboxAutoMode

  @holder ReferenceFixture.holder()

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    {:ok, a: ReferenceFixture.tenant!("req636-ca"), b: ReferenceFixture.tenant!("req636-cb")}
  end

  test "D4-optin and failing names in definition order", %{a: a} do
    live = ReferenceFixture.target!(a)
    other = ReferenceFixture.target!(a, "frt_other")

    assert ReferenceCheck.check(@holder, %{"target" => live}, a.schema_name) == :ok

    assert ReferenceCheck.check(@holder, %{"other" => other, "target" => "nope"}, a.schema_name) ==
             {:error, {:reference_invalid, ["target", "other"]}}
  end

  test "D4-empty and D4-shape", %{a: a} do
    for fv <- [%{}, %{"target" => nil}, %{"target" => ""}, %{"title" => "x"}] do
      assert ReferenceCheck.check(@holder, fv, a.schema_name) == :ok
    end

    assert ReferenceCheck.check(@holder, "not a map", a.schema_name) == :ok
    assert ReferenceCheck.check(@holder, %{}, nil) == :ok
    assert ReferenceCheck.check(nil, %{}, a.schema_name) == :ok
    # an unknown type has no definition: nothing to check
    assert ReferenceCheck.check("no_such_type", %{"target" => "x"}, a.schema_name) == :ok
    # a nested value is not a binary
    assert ReferenceCheck.check(@holder, %{"target" => %{"id" => "x"}}, a.schema_name) ==
             {:error, {:reference_invalid, ["target"]}}
  end

  test "D4-xtenant: only the given tenant's records count", %{a: a, b: b} do
    in_a = ReferenceFixture.target!(a)
    in_b = ReferenceFixture.target!(b)

    assert ReferenceCheck.check(@holder, %{"target" => in_a}, a.schema_name) == :ok
    assert ReferenceCheck.check(@holder, %{"target" => in_b}, b.schema_name) == :ok

    assert ReferenceCheck.check(@holder, %{"target" => in_b}, a.schema_name) ==
             {:error, {:reference_invalid, ["target"]}}

    assert ReferenceCheck.check(@holder, %{"target" => in_a}, b.schema_name) ==
             {:error, {:reference_invalid, ["target"]}}
  end

  test "retired target is refused, field_errors is constant text", %{a: a} do
    retired = ReferenceFixture.target!(a, "frt_target", false)

    assert {:error, {:reference_invalid, names}} =
             ReferenceCheck.check(@holder, %{"target" => retired}, a.schema_name)

    assert [
             %{
               field: "target",
               constraint: "reference",
               message: "must refer to an available record"
             }
           ] =
             ReferenceCheck.field_errors(names)
  end

  test "D4-source-scan: no module table, repo or query access in the check" do
    src = File.read!("lib/letflow/entities/reference_check.ex")

    code =
      src
      |> String.split("\"\"\"")
      |> Enum.take(1)
      |> Enum.join()
      |> Kernel.<>(Enum.at(String.split(src, "\"\"\""), 2, ""))

    for banned <- [
          "Repo",
          "Latest",
          "Ecto.Query",
          "from(",
          "Letflow.Modules.Org",
          "Letflow.Modules.Exam",
          "Letflow.Modules.FixtureRefTargets"
        ] do
      refute code =~ banned, banned
    end

    modules_aliased =
      Regex.scan(~r/alias Letflow\.Modules\.(\w+)/, code) |> Enum.map(&List.last/1)

    assert Enum.sort(modules_aliased) == ["Catalog", "Installs"]
  end
end
