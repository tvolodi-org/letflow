defmodule Letflow.SecurityProbe.G01MatrixShard2Test do
  @moduledoc """
  G-01 real-tree matrix, shard 2 of `Letflow.SecurityProbe.G01.shard_count/0`
  (the routes and the rules: `Letflow.SecurityProbe.G01Case.run_shard!/1`;
  the class table: `docs/security-probes/G-01.md`). `async: false`: the
  platform-tenant pin and two feature flags are VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.SecurityProbe.G01Case

  @moduletag :security_probe
  @moduletag probe_cost_s: 22
  @moduletag timeout: 300_000

  test "route x role x tenant x shape, shard 2: the violations equal the ratchet" do
    G01Case.run_shard!(2)
  end
end
