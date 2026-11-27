defmodule SeededTree.MixProject do
  @moduledoc """
  The seeded failing case of the G-12 probe: a project whose lock file pins a package version
  with a known advisory. It is TEXT under test/fixtures/ -- never compiled, never fetched.
  """

  use Mix.Project

  def project do
    [
      app: :seeded_tree,
      version: "0.1.0",
      deps: [
        {:plug, "~> 1.20"},
        {:stream_data, "~> 0.6", only: :test}
      ]
    ]
  end
end
