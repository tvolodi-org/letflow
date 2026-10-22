defmodule Letflow.Modules.WriteHandlerSpecTest do
  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureLedger
  alias Letflow.Modules.ManifestHash
  alias Letflow.Modules.WriteHandlerSpec

  @valid %{
    name: "post_entry",
    function: {Letflow.Modules.FixtureLedger.Handlers, :post_entry},
    targets: ["fxl_ledger"],
    args: %{"item" => %{required: true}}
  }

  describe "new/1" do
    test "valid map and keyword list build the struct" do
      assert {:ok, %WriteHandlerSpec{name: "post_entry", targets: ["fxl_ledger"]}} =
               WriteHandlerSpec.new(@valid)

      assert WriteHandlerSpec.new(Map.to_list(@valid)) == WriteHandlerSpec.new(@valid)
      assert {:ok, %WriteHandlerSpec{args: %{}}} = WriteHandlerSpec.new(%{@valid | args: %{}})
    end

    test "every key is enforced on the struct" do
      assert_raise ArgumentError, ~r/must also be given/, fn ->
        struct!(WriteHandlerSpec, name: "a")
      end
    end

    for key <- [:name, :function, :targets, :args] do
      test "missing #{key} is rejected" do
        assert {:error, {:missing_keys, [unquote(key)]}} =
                 WriteHandlerSpec.new(Map.delete(@valid, unquote(key)))
      end
    end

    test "an unknown key is rejected" do
      assert {:error, {:unknown_keys, [:extra]}} =
               WriteHandlerSpec.new(Map.put(@valid, :extra, 1))
    end

    test "not a map or keyword list is rejected" do
      assert {:error, {:not_a_spec, "x"}} = WriteHandlerSpec.new("x")
      assert {:error, {:not_a_spec, ["x"]}} = WriteHandlerSpec.new(["x"])
    end

    @wrong_types [
      name: :atom,
      name: "Bad-Name",
      name: String.duplicate("a", 65),
      function: :f,
      function: {"Foo", :f},
      function: {Foo, "f"},
      targets: "t",
      targets: [:t],
      targets: ["t", "t"],
      args: ["x"],
      args: %{x: %{required: true}},
      args: %{"x" => %{required: "yes"}},
      args: %{"x" => %{required: true, extra: 1}}
    ]

    for {key, value} <- @wrong_types do
      test "ill-typed #{key} #{inspect(value)} is rejected" do
        assert {:error, {:invalid_field, unquote(key)}} =
                 WriteHandlerSpec.new(Map.put(@valid, unquote(key), unquote(Macro.escape(value))))
      end
    end
  end

  describe "valid?/1" do
    test "accepts a built struct, refuses a struct with a bad field and plain maps" do
      {:ok, spec} = WriteHandlerSpec.new(@valid)
      assert WriteHandlerSpec.valid?(spec)
      refute WriteHandlerSpec.valid?(%{spec | name: :atom})
      refute WriteHandlerSpec.valid?(@valid)
    end
  end

  describe "Catalog and ManifestHash use the struct" do
    test "registered fixtures carry structs" do
      assert Enum.all?(FixtureLedger.manifest().write_handlers, &match?(%WriteHandlerSpec{}, &1))
    end

    test "a plain map handler is refused by validate/2" do
      handler = Map.from_struct(hd(FixtureLedger.manifest().write_handlers))
      manifest = Map.put(FixtureLedger.manifest(), :write_handlers, [handler])

      assert {:error, {:invalid_write_handlers, [^handler]}} = Catalog.validate(manifest, [])
    end

    test "a struct with an ill-typed field is refused by validate/2" do
      handler = %{hd(FixtureLedger.manifest().write_handlers) | targets: "t"}
      manifest = Map.put(FixtureLedger.manifest(), :write_handlers, [handler])

      assert {:error, {:invalid_write_handlers, [^handler]}} = Catalog.validate(manifest, [])
    end

    test "the manifest hash of the unchanged registration is the pre-struct value" do
      assert ManifestHash.compute(FixtureLedger.manifest()) ==
               "6394cff92f1f30f14e74d59a45bb7e272087160c7596e6078571fbfb6d8d866d"

      assert ManifestHash.compute(Letflow.Modules.FixtureLedgerOther.manifest()) ==
               "24aff18970d1b5c2629f71b46f7858a2fb2789e85d505710a2360a15353c9b22"

      assert ManifestHash.compute(Letflow.Modules.FixtureLedgerRogue.manifest()) ==
               "20f7d07cb2aa08e4e916cf3bde4fe0dcc4e73d73342d5a42edc2e64b6fae9b98"
    end
  end
end
