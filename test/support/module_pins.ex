defmodule Letflow.TestSupport.ModulePins do
  @moduledoc """
  Loads the per-module pin files `test/letflow/modules/pins/<Module>.exs` (T-1900).

  Each file holds one map: `%{module: "CatalogItems", hash: "<sha256>"}` (the golden
  `ManifestHash` of the registered manifest; add `shapes: true` when the upgrade-shape test also
  checks it) or `%{module: "MesCore", exempt: "<reason>"}` for a registered module that has no
  fixed golden. A task that bumps module X edits only `pins/X.exs`; the shared tests loop over
  this directory and hold no per-module line.
  """

  @dir Path.expand("../letflow/modules/pins", __DIR__)

  @doc "All pin maps, keyed by the module's short name (`Letflow.Modules.<name>`)."
  def all do
    @dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Map.new(fn path ->
      {pin, _} = Code.eval_file(path)
      name = Path.basename(path, ".exs")
      if pin.module != name, do: raise("#{path}: :module must be #{inspect(name)}")
      {name, pin}
    end)
  end
end
