defmodule Letflow.Modules.Procurement.RegistrationTest do
  @moduledoc """
  GH #3162 / REQ-544 part 1, criterion 10 (registration half) and criterion 11 (no core change)
  (spec: state/tasks/T-0745/design.md, tests T-R1..T-R3, T-NC1, T-M1): the `procurement` manifest,
  its golden rows, its `docs/roles.md` entry, and a source scan of the module's own files.

  Reads files only; no database. `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Procurement

  @atoms [:ProcurementRequestWrite, :ProcurementRequestRead]

  test "T-R1: the manifest validates and declares exactly the two permissions" do
    manifest = Procurement.manifest()

    assert Catalog.validate(manifest) == :ok
    assert manifest.id == "procurement"
    assert Enum.sort(manifest.permissions) == Enum.sort(@atoms)
    assert manifest.role_grants == %{}
    assert manifest.depends_on == ["org", "catalog_items"]
    assert manifest.pack == nil
    refute function_exported?(Procurement, :router, 0)
    assert Enum.sort(Enum.map(manifest.route_policies, &elem(&1, 2))) == Enum.sort(@atoms)
  end

  test "T-R2: the golden holds the two atoms for the two admin roles only" do
    golden = File.read!("priv/permission_matrix/effective.golden")
    assert golden =~ ~r/^# modules: .*procurement@0\.1\.0/m

    for atom <- @atoms,
        role <-
          ~w(AGENT_RUNNER CANDIDATE PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER TENANT_AUDITOR PLATFORM_ADMIN TENANT_ADMIN) do
      allowed = role in ~w(PLATFORM_ADMIN TENANT_ADMIN)
      assert golden =~ ~r/^#{role} #{atom} #{allowed} module:procurement /m, "#{role} #{atom}"
    end
  end

  test "T-R3: docs/roles.md names both atoms outside the fenced matrix" do
    doc = File.read!("docs/roles.md")
    # the fenced matrix is the one block that starts after the "## Matrix" heading
    [before_fence, rest] =
      String.split(doc, "\npermission                      PLATFORM_ADMIN", parts: 2)

    [matrix | _] = String.split(rest, "```", parts: 2)

    for atom <- @atoms do
      assert before_fence =~ Atom.to_string(atom)
      refute matrix =~ Atom.to_string(atom)
    end
  end

  test "T-M1: the module is registered in both config files and in the catalog" do
    assert Procurement in Catalog.entry_modules()

    for file <- ["config/config.exs", "config/test.exs"] do
      assert File.read!(file) =~ "Letflow.Modules.Procurement"
    end
  end

  describe "T-NC1: no core change, one door to the documents" do
    @files Path.wildcard("lib/letflow/modules/procurement/**/*.ex")

    test "the module does not touch the engine or write document tables itself" do
      assert @files != []

      for file <- @files do
        source = File.read!(file)
        refute source =~ "Letflow.Engine", file
        refute source =~ ~r/Repo\.(insert|update|delete)/, file
      end
    end

    test "no file outside the module calls the purchase request operations" do
      callers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&String.starts_with?(&1, "lib/letflow/modules/procurement/"))
        |> Enum.filter(&(File.read!(&1) =~ "Procurement.PurchaseRequests"))

      assert callers == []
    end
  end
end
