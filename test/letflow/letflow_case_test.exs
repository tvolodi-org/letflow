defmodule Letflow.LetflowCaseTest do
  @moduledoc """
  T-1599 stage 2, first slice: `LETFLOW_COMPANION_DIR` dual-read helper and its canary.
  Reads the environment but never changes it, so it is async-safe. No database.
  The canary reads the marker `docs/requirements.yaml`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :companion

  alias Letflow.LetflowCase

  @root Path.expand("../..", __DIR__)

  describe "default root" do
    test "R1 unset, empty and blank resolve to the in-tree repo root" do
      for v <- [nil, "", "  "], do: assert(LetflowCase.resolve(v) == @root)
      assert File.regular?(Path.join(@root, "docs/requirements.yaml"))
    end

    test "R2 companion/0 follows the environment" do
      assert LetflowCase.companion() ==
               LetflowCase.resolve(System.get_env("LETFLOW_COMPANION_DIR"))
    end

    test "R3 companion_path/1 joins onto the root" do
      assert LetflowCase.companion_path("docs/roles.md") ==
               Path.join(LetflowCase.companion(), "docs/roles.md")
    end
  end

  test "R4 a set value is honoured and made absolute" do
    assert LetflowCase.resolve("/tmp/x") == "/tmp/x"
    assert Path.type(LetflowCase.resolve("some/rel")) == :absolute
  end

  describe "canary" do
    @tag :companion
    test "C1 the effective companion root is readable" do
      dir = LetflowCase.companion()
      assert LetflowCase.check(dir) == :ok, inspect(LetflowCase.check(dir))
    end

    test "C2 a missing directory fails" do
      assert {:error, msg} = LetflowCase.check("/nonexistent/companion-dir")
      assert msg =~ "not a directory"
    end

    @tag :tmp_dir
    test "C3 a directory without the marker fails", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "docs"))
      assert {:error, msg} = LetflowCase.check(dir)
      assert msg =~ "docs/requirements.yaml"
    end

    @tag :tmp_dir
    test "C4 a directory with a non-empty marker passes", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "docs"))
      File.write!(Path.join(dir, "docs/requirements.yaml"), "x: 1\n")
      assert LetflowCase.check(dir) == :ok
    end

    @tag :tmp_dir
    test "C5 an unreadable marker fails", %{tmp_dir: dir} do
      marker = Path.join(dir, "docs/requirements.yaml")
      File.mkdir_p!(Path.dirname(marker))
      File.write!(marker, "x: 1\n")
      File.chmod!(marker, 0o000)
      on_exit(fn -> File.chmod(marker, 0o644) end)

      # running as root ignores modes: nothing to prove then
      if match?({:error, _}, File.read(marker)) do
        assert {:error, msg} = LetflowCase.check(dir)
        assert msg =~ "not readable"
      end
    end

    @tag :tmp_dir
    test "C6 a marker that is a directory fails", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "docs/requirements.yaml"))
      assert {:error, msg} = LetflowCase.check(dir)
      assert msg =~ "not readable"
    end

    @tag :tmp_dir
    test "C7 an empty marker fails", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "docs"))
      File.write!(Path.join(dir, "docs/requirements.yaml"), "")
      assert {:error, msg} = LetflowCase.check(dir)
      assert msg =~ "empty"
    end
  end
end
