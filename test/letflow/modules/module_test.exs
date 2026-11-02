defmodule Letflow.Modules.ModuleTest do
  @moduledoc """
  REQ-400 AC1 — `Letflow.Modules.Module` declares `manifest/0` as a required
  callback and `router/0`/`on_install/2` as optional callbacks. See
  `test/specs/REQ-400.md` for the full rationale.

  Pure introspection over compiler-generated `behaviour_info/1` — no I/O, no
  database, `async: true` is safe.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  describe "REQ-400 AC1 — behaviour_info/1" do
    test "behaviour_info(:callbacks) includes manifest/0, router/0, on_install/2" do
      callbacks = Letflow.Modules.Module.behaviour_info(:callbacks)

      assert {:manifest, 0} in callbacks
      assert {:router, 0} in callbacks
      assert {:on_install, 2} in callbacks
    end

    test "behaviour_info(:optional_callbacks) includes router/0 and on_install/2 but not manifest/0" do
      optional_callbacks = Letflow.Modules.Module.behaviour_info(:optional_callbacks)

      assert {:router, 0} in optional_callbacks
      assert {:on_install, 2} in optional_callbacks
      refute {:manifest, 0} in optional_callbacks
    end
  end
end
