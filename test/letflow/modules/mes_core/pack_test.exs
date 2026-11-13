defmodule Letflow.Modules.MesCore.PackTest do
  @moduledoc "T-1841 (MES M1): the `letflow-mes-core` pack is valid JSON, matches the manifest and is empty."

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.MesCore

  test "P-01: pack decodes, id and version match, all sections empty" do
    pack =
      Path.join(["priv", MesCore.manifest().pack])
      |> File.read!()
      |> Jason.decode!()

    assert pack["pack_id"] == "letflow-mes-core"
    assert pack["version"] == MesCore.manifest().version
    assert pack["definitions"] == []
    assert pack["entity_definitions"] == []
    assert pack["service_catalog_entries"] == []
    assert pack["variable_schemas"] == []
  end
end
