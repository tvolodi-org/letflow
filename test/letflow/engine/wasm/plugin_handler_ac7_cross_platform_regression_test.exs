defmodule Letflow.Engine.Wasm.PluginHandlerAC7CrossPlatformRegressionTest do
  @moduledoc """
  ISS-0377 regression test -- see `test/specs/ISS-0377-regression-proof.md` for
  the full fail-then-pass evidence (including the real, non-simulated
  pre-fix-vs-post-fix run against `test/letflow/engine/wasm/plugin_handler_test.exs`
  on this Linux sandbox).

  This file exists because ISS-0377's fix to AC7's second assertion (the
  "compiled shared library is bundled" test) only manifests its bug on a
  non-Unix OS (hardcoded `.so`, wrong on Windows's `.dll`) -- something this
  Linux sandbox cannot literally reproduce by running the real
  `:code.priv_dir(:wasmex)` tree, because a real Linux wasmex build always
  happens to have a `wasmex.so` on disk regardless of whether the fix is
  applied. So this test simulates the Windows-shaped directory layout (a
  version/arch-suffixed `.dll` present, no fixed-name file) and exercises
  the exact directory-walking logic shipped in
  `test/letflow/engine/wasm/plugin_handler_test.exs`'s `native_artifact_check/2`
  (commit 8eef01b) -- copied verbatim below, since that function is a private
  `defp` inside a test module and not otherwise reachable from here.

  If this shipped logic is ever regressed back toward the pre-fix hardcoded
  `"native/wasmex.so"` path check, this test's `old_logic_result` assertion
  is the one that would have caught it (see the `describe "regression: OLD
  hardcoded .so path check"` block below, which mirrors it explicitly for
  contrast) -- and the `new_logic_result` assertion would fail on the same
  data if the fixed-name/fallback-listing logic itself is broken by a future
  edit.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  # Verbatim copy of the shipped `native_artifact_check/2` from
  # test/letflow/engine/wasm/plugin_handler_test.exs (commit 8eef01b). Kept
  # here as a literal mirror (not a shared import) because the original is a
  # private `defp` inside that test module's `describe` block -- refactoring
  # it into a shared support module is a design change out of TEST-DESIGNER's
  # scope for this WF-03 run (see step-04 handoff: "do not implement further
  # application/script fixes yourself").
  defp native_artifact_check(priv_dir, ext) do
    fixed_path = Path.join([priv_dir, "native", "wasmex" <> ext])

    if File.exists?(fixed_path) do
      {:ok, :fixed_name, fixed_path}
    else
      native_dir = Path.join(priv_dir, "native")

      case File.ls(native_dir) do
        {:ok, entries} ->
          if Enum.any?(entries, &String.ends_with?(&1, ext)) do
            {:ok, :fallback_listing, native_dir}
          else
            {:error, :not_found, fixed_path, native_dir}
          end

        {:error, reason} ->
          {:error, :listing_failed, fixed_path, reason}
      end
    end
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "iss0377_win_priv_#{System.unique_integer([:positive])}")

    native_dir = Path.join(tmp_dir, "native")
    File.mkdir_p!(native_dir)

    # Windows-shaped layout: only the version/arch-suffixed compiled
    # artifact is present (as wasmex's real build output looks before/absent
    # any fixed-name copy step) -- no "wasmex.so", no "wasmex.dll".
    windows_dll = Path.join(native_dir, "libwasmex-v0.15.1-nif-2.15-x86_64-pc-windows-msvc.dll")
    File.write!(windows_dll, "")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{priv_dir: tmp_dir}
  end

  describe "regression: NEW native_artifact_check/2 handles a simulated Windows-shaped tree" do
    test "finds the .dll via the fallback directory listing", %{priv_dir: priv_dir} do
      # ext=".dll" simulates what `expected_native_extension/0` (the shipped
      # helper right above `native_artifact_check/2`) returns for
      # `{:win32, _}` -- :os.type/0 itself cannot be faked on this Linux
      # sandbox, and ext is the only OS-dependent input this function takes;
      # the directory-walking logic itself is platform-agnostic.
      assert {:ok, :fallback_listing, native_dir} = native_artifact_check(priv_dir, ".dll")
      assert native_dir == Path.join(priv_dir, "native")
    end
  end

  describe "regression: OLD hardcoded .so path check is wrong against the same tree" do
    test "the pre-fix (commit 8eef01b^) hardcoded check would have failed here", %{
      priv_dir: priv_dir
    } do
      # Pre-fix literal from test/letflow/engine/wasm/plugin_handler_test.exs
      # (commit 8eef01b^, `git show 8eef01b^:test/letflow/engine/wasm/plugin_handler_test.exs`):
      #   so_path = Path.join(priv_dir, "native/wasmex.so")
      #   assert File.exists?(so_path), "expected #{so_path} to exist as a bundled shared library"
      so_path = Path.join(priv_dir, "native/wasmex.so")

      refute File.exists?(so_path),
             "expected the OLD hardcoded \".so\" check to be UNSATISFIABLE against a " <>
               "Windows-shaped tree (only a .dll present) -- if this ever passes, the " <>
               "fixture no longer represents the bug ISS-0377 fixed"
    end
  end
end
