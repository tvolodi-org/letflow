defmodule Letflow.Modules.WriteHandlerRegistrationSurfaceTest do
  @moduledoc """
  GH #2590 / REQ-501 R1: where write handlers may be registered and who may
  touch the registry.

  ## R1 inertness guards (temporary, edited deliberately by R2 / R4a)

  The two source scans below ("no lib file reads :write_handlers", "no lib file
  other than the Catalog calls the handler API") pin that R1 is INERT. R2
  (`installs.ex` hash reader) and R4a (`HandlerWrites`, `ManagedTypes`) add
  legitimate callers and edit `@allowed_*` here on purpose; that is a reviewed
  closed-set change, not a regression.

  ## What proves what (AC "Registration only from module code")

  Registration is manifest data of a compiled-in entry module. R1's proof is
  static plus settings, by design: the source scans show no route, definition
  body, entity or engine file reads the key; a settings payload and a
  solution-pack document carrying a `write_handlers` key are refused or
  ignored and resolve to `{:error, :not_found}`. Per-route HTTP bodies are not
  exercised because no route reads the key; R2 adds the definitions-API field
  refusals with their own tests.

  ## Boundary (AC "engine names no module handler")

  Covered by `mix letflow.check_boundaries` (output quoted in the PR body) and
  by the scan "no engine file names a module under lib/letflow/modules/<id>/"
  below, which has positive controls and a synthetic negative.

  `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture

  # R2/R4a edit these two lists deliberately.
  @allowed_key_readers [
    "lib/letflow/modules/catalog.ex",
    "lib/letflow/modules/module.ex",
    "lib/letflow/modules/manifest_hash.ex"
  ]
  # R2 (deliberate edit): `ManagedTypes.module_owner/1` calls `Catalog.manifest_hash/1` to
  # fill the `Owner` stamp inputs (`version`, `manifest_hash`); nothing else outside the
  # Catalog may resolve or call a handler. `installs.ex` only READS the `manifest_hash`
  # column it recorded from that owner, and `OwnerStamp`/`TenantModule` only name the field.
  @allowed_api_callers [
    "lib/letflow/modules/catalog.ex",
    "lib/letflow/entities/managed_types.ex"
  ]

  @api_names [:write_handler, :write_handler_in, :call_write_handler, :manifest_hash]

  defp lib_files do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
  end

  # AST scan: any call (local or remote), capture (`&Catalog.write_handler/2`,
  # `&write_handler/2`) or atom literal (`apply(M, :write_handler, ..)`) naming
  # a handler-API function. Comments and docs are not code and do not count.
  # `manifest_hash` is a common name (the Lua engine has its own, and since R2 it is also
  # a struct/column FIELD of `Owner`, `TenantModule` and the process-definition stamp), so
  # it counts only as a call/capture on a `Catalog` receiver, or as a local call in a file
  # that names the `Letflow.Modules.Catalog` module. A bare atom key or a variable named
  # `manifest_hash` is data, not an API reference (R2 deliberate edit).
  defp api_references?(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    names_catalog? = String.contains?(source, "Modules.Catalog")

    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [recv, name]}, _, _} = node, acc when name in @api_names ->
          {node, acc or name != :manifest_hash or catalog_receiver?(recv)}

        {name, _, args} = node, acc when name in @api_names and is_list(args) ->
          {node, acc or name != :manifest_hash or names_catalog?}

        {name, _, args} = node, acc when name in @api_names and is_atom(args) ->
          {node, acc or name != :manifest_hash}

        name, acc when name in @api_names ->
          {name, acc or name != :manifest_hash}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp catalog_receiver?({:__aliases__, _, parts}), do: List.last(parts) == :Catalog
  defp catalog_receiver?(_other), do: false

  describe "R1 inertness guards" do
    test "no lib file outside the Catalog, Module and ManifestHash mentions write_handlers" do
      files = lib_files()
      # positive control: the scan does see the Catalog and its source carries the key
      assert "lib/letflow/modules/catalog.ex" in files
      assert File.read!("lib/letflow/modules/catalog.ex") =~ "write_handlers"
      assert length(files) > 200

      readers =
        files
        |> Enum.reject(&(&1 in @allowed_key_readers))
        |> Enum.filter(&String.contains?(File.read!(&1), "write_handlers"))

      assert readers == []
    end

    test "routers, definitions, entities, engine and installs name no handler resolver" do
      paths =
        Path.wildcard("lib/letflow/{routers,definitions,entities,engine}/**/*.ex") ++
          ["lib/letflow/modules/installs.ex", "lib/letflow/engine.ex"]

      assert length(paths) > 50
      assert Enum.any?(paths, &String.starts_with?(&1, "lib/letflow/routers/"))
      assert Enum.any?(paths, &String.starts_with?(&1, "lib/letflow/engine/"))

      for path <- paths do
        refute File.read!(path) =~ "write_handler",
               "#{path} references the write-handler registry"
      end
    end

    test "no lib file other than the Catalog calls, captures or applies the handler API" do
      callers =
        lib_files()
        |> Enum.reject(&(&1 in @allowed_api_callers))
        |> Enum.filter(&api_references?(File.read!(&1)))

      assert callers == []
    end

    test "the API scan flags calls, captures and apply forms (synthetic positives) and not docs" do
      positives = [
        "Catalog.write_handler(a, b)",
        "Catalog.write_handler_in(l, a, b)",
        "Catalog.call_write_handler(h, m, c, a)",
        "Catalog.manifest_hash(m)",
        "&Catalog.write_handler/2",
        "&write_handler/2",
        "&Catalog.write_handler_in/3",
        "&call_write_handler/4",
        "apply(Catalog, :write_handler, [a, b])",
        "import Catalog, only: [write_handler: 2]",
        "a |> Catalog.manifest_hash()"
      ]

      for source <- positives, do: assert(api_references?(source), source)

      refute api_references?(~s|@moduledoc "see Catalog.write_handler/2"\nCatalog.fetch("x")|)
      refute api_references?("# Catalog.write_handler(a, b)\nCatalog.fetch(1)")
    end

    test "no engine file names a module under lib/letflow/modules/<id>/" do
      module_names = module_names_under_module_dirs()

      # positive controls: module directories exist and define modules
      assert "Letflow.Modules.Exam" in module_names
      assert length(module_names) >= 1

      engine_files =
        ["lib/letflow/engine.ex" | Path.wildcard("lib/letflow/engine/**/*.ex")]
        |> Enum.uniq()

      assert "lib/letflow/engine.ex" in engine_files
      assert length(engine_files) > 5

      offenders =
        for path <- engine_files,
            name <- names_in_source(File.read!(path), module_names),
            do: {path, name}

      assert offenders == []

      # synthetic negative: the detector flags a file that names a module
      snippet = "defmodule X do\n  def f, do: Letflow.Modules.Exam.manifest()\nend\n"
      assert names_in_source(snippet, module_names) == ["Letflow.Modules.Exam"]

      assert names_in_source("alias Letflow.Modules.Exam\nExam.x()", module_names) == [
               "Letflow.Modules.Exam"
             ]
    end
  end

  # Module names defined in files under lib/letflow/modules/<id>/ (subdirectories).
  defp module_names_under_module_dirs do
    "lib/letflow/modules/*/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      ~r/^\s*defmodule\s+([A-Za-z0-9_.]+)\s+do/m
      |> Regex.scan(File.read!(path), capture: :all_but_first)
      |> List.flatten()
    end)
    |> Enum.uniq()
  end

  # Full names, or the alias short form of a full name, appearing as code tokens.
  defp names_in_source(source, module_names) do
    Enum.filter(module_names, fn name ->
      short = name |> String.split(".") |> List.last()

      Regex.match?(~r/(?<![A-Za-z0-9_.])#{Regex.escape(name)}(?![A-Za-z0-9_])/, source) or
        (Regex.match?(~r/alias\s+#{Regex.escape(name)}\b/, source) and
           Regex.match?(~r/(?<![A-Za-z0-9_.])#{short}\./, source))
    end)
  end

  describe "dynamic: tenant-supplied data cannot register a handler" do
    test "settings carrying a write_handlers key are refused and resolve to nothing" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r1-surface")

      {:ok, _} =
        Installs.install("fixture", Ecto.UUID.generate(),
          prefix: prefix,
          rationale: "test: module install"
        )

      payload = %{
        "write_handlers" => [
          %{
            "name" => "post_entry",
            "function" => ["Letflow.Repo", "all"],
            "targets" => ["anything"],
            "args" => %{}
          }
        ]
      }

      before_state = Catalog.write_handler("fixture", "post_entry")
      assert before_state == {:error, :not_found}

      assert {:error, {:settings_validation_failed, _}} =
               Installs.put_settings("fixture", payload, prefix: prefix)

      assert Catalog.write_handler("fixture", "post_entry") == before_state
      assert Catalog.write_handler("fixture", "write_handlers") == {:error, :not_found}
      # and the real registrations are unchanged
      assert {:ok, _} = Catalog.write_handler("fixture_ledger", "post_entry")
    end

    test "a solution-pack document carrying write_handlers keys is ignored and registers nothing" do
      %{schema_name: prefix, tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r1-pack")

      on_exit(fn ->
        Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      end)

      handler = %{
        "name" => "ghost_handler",
        "function" => ["Letflow.Repo", "all"],
        "targets" => ["x"],
        "args" => %{}
      }

      document = %{
        "pack_id" => Ecto.UUID.generate(),
        "version" => "1.0.0",
        "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
        "exported_at" => "2026-01-01T00:00:00Z",
        "definitions" => [],
        "service_catalog_entries" => [],
        "variable_schemas" => [],
        "write_handlers" => [handler],
        "manifest" => %{"required_roles" => [], "write_handlers" => [handler]}
      }

      assert Catalog.write_handler("fixture", "ghost_handler") == {:error, :not_found}

      # accepted-and-ignored or refused: either way nothing registers
      _ = SolutionPack.install(document, Ecto.UUID.generate(), prefix: prefix)

      for module_id <- ["fixture", "fixture_ledger", "fixture_ledger_other", "fixture_managed"] do
        assert Catalog.write_handler(module_id, "ghost_handler") == {:error, :not_found}
      end

      assert Catalog.write_handler("fixture_ledger", "post_entry") |> elem(0) == :ok
    end
  end
end
