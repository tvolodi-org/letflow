defmodule Letflow.PlatformFunctions.FailureVocabularyTest do
  @moduledoc """
  The CLOSED vocabulary of the dispatch row's `last_failure_kind` (T-2590,
  pilot gap G1b) and the bodies that answer with it.

  What the tests prove:

    * V1 -- the CLASS covers the class: the vocabulary is not a hand list
      that may drift. Every refusal code every body of the tree declares
      (each body's own `@type refusal`, read from the COMPILED module) is
      one of the dispatcher's codes. The set is derived from the TREE: every
      module under `lib/letflow/platform_functions/impl/`, read from the
      files themselves, not a list of codes written in this file;
    * V2 -- the rule has a NEGATIVE fixture, driven through the same public
      entry point the real tree uses (`Dispatcher.record_outcome/3`): a
      refusal code nobody can enumerate is reduced to the generic code, so
      the row only ever carries a code a reader can act on;
    * V3 -- the rule is not vacuous: the check finds the bodies of the tree
      and their codes;
    * V4 -- a body of the tree is a REGISTERED body: the registry is the
      closed set of names that may run.

  `@moduletag probe_cost_s: 5` -- one tenant fixture (V2) and a read of the
  implementation directory (V1, V3, V4). No network, no clock, no order
  dependence.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.TenantFixture

  @moduletag :security_probe
  @moduletag probe_cost_s: 5

  @function "platform.validate_registration"

  test "V1 every refusal code of every body of the tree is a code of the row" do
    vocabulary = Dispatcher.failure_codes()

    for module <- tree_modules() do
      assert {:ok, atoms} = refusal_atoms(module),
             "#{inspect(module)} cannot be read: the check must not pass vacuously"

      for atom <- atoms do
        assert Atom.to_string(atom) in vocabulary,
               "#{inspect(module)} answers #{inspect(atom)}, which the dispatch row " <>
                 "would not carry: the vocabulary is closed"
      end
    end
  end

  test "V2 a code outside the vocabulary is reduced to the generic code" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-vocab")

    {:ok, %{dispatch: dispatch}} =
      Dispatcher.arm(
        prefix: tenant.schema_name,
        instance_id: Ecto.UUID.generate(),
        definition_id: Ecto.UUID.generate(),
        node_id: "call",
        function: @function,
        inputs: %{
          "slug" => "acme",
          "display_name" => "Acme Ltd",
          "email" => "admin@acme.test"
        }
      )

    # The row in the state a CLAIM leaves it in (the claim is a private step
    # of the dispatch; the outcome write is the public one).
    {1, _} =
      Repo.update_all(
        from(d in StepDispatch, where: d.id == ^dispatch.id),
        [set: [status: :running]],
        prefix: tenant.schema_name
      )

    running = Repo.get!(StepDispatch, dispatch.id, prefix: tenant.schema_name)

    assert :ok =
             Dispatcher.record_outcome(running, tenant.schema_name, {:error, :not_a_known_code})

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: tenant.schema_name)
    assert stored.last_failure_kind == "platform_step_failed"
  end

  test "V3 the check finds the bodies of the tree and their codes" do
    modules = tree_modules()

    # The tree has more than one module, and the check reads their codes.
    assert length(modules) >= 2

    codes =
      Enum.flat_map(modules, fn module ->
        assert {:ok, atoms} = refusal_atoms(module)
        Enum.map(atoms, &Atom.to_string/1)
      end)

    assert codes != []
    assert Enum.all?(codes, &(&1 in Dispatcher.failure_codes()))
  end

  test "V4 every body of the tree is registered" do
    registered =
      Registry.names()
      |> Enum.map(fn name ->
        assert {:ok, {module, :run, 1}} = Registry.fetch(name)
        module
      end)

    for module <- tree_modules() do
      assert {:ok, atoms} = refusal_atoms(module)

      if atoms != [] do
        assert module in registered,
               "#{inspect(module)} declares a refusal vocabulary but no catalogue entry " <>
                 "runs it: the registry is the closed set of bodies"
      end
    end
  end

  # Every module of the implementation directory: the TREE. The name is read
  # from the file's own `defmodule` (a source-derived name), never from a
  # list written here.
  defp tree_modules do
    impl_dir()
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.map(&module_of/1)
    |> Enum.sort()
  end

  defp impl_dir, do: Path.expand("../../../lib/letflow/platform_functions/impl", __DIR__)

  defp module_of(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, _body]} = node, acc ->
          # The alias parts carry the `Elixir` prefix (as the atom `:Elixir`).
          parts = Enum.reject(parts, &(&1 == :"Elixir"))
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    case modules do
      [module | _rest] -> module
      [] -> nil
    end
  end

  # The atoms of the module's own `@type refusal`, read from the compiled
  # module. A module that declares no types (a helper, not a body) has no
  # vocabulary; a module that is NOT compiled is a defect and says so.
  defp refusal_atoms(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} -> {:ok, read_refusal_atoms(module)}
      _other -> {:error, :not_compiled}
    end
  end

  defp read_refusal_atoms(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} ->
        Enum.flat_map(types, fn
          {:type, {:refusal, definition, _args}} -> type_atoms(definition)
          _other -> []
        end)

      _other ->
        []
    end
  rescue
    _error -> []
  end

  # The type definition of a union is `{:type, meta, :union, atoms}`; the
  # definition of a single atom is `{:type, meta, :atom, atom}`.
  defp type_atoms({:type, _meta, :union, atoms}), do: Enum.map(atoms, &atom_name/1)
  defp type_atoms({:type, _meta, :atom, atom}), do: [atom]
  defp type_atoms(_other), do: []

  defp atom_name({:atom, _line, name}), do: name
end
