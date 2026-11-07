defmodule Letflow.Modules.Stock.VoiceAudioRegressionTest do
  @moduledoc """
  T-1348 / D2d: the audio layer of the voice regression tests (section 8.3 layer 2) as a disabled
  skeleton. Excluded by default (`:voice_audio`, `test/test_helper.exs`). The manifest and the audio
  files need the owner's recordings and provider keys and do not exist yet; run with
  `--include voice_audio` once they do. See `docs/runbooks/stock-voice-regression.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :voice_audio

  @dir Path.expand("../../../fixtures/voice/audio", __DIR__)
  @manifest Path.join(@dir, "manifest.yaml")

  test "A-1 the audio manifest exists and every file matches its sha256" do
    unless File.exists?(@manifest) do
      flunk("no audio manifest: generate it first, see docs/runbooks/stock-voice-regression.md")
    end

    entries = YamlElixir.read_from_file!(@manifest)

    for e <- entries do
      path = Path.join(@dir, e["file"])
      assert File.exists?(path), "missing audio file #{e["file"]}"
      sha = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
      assert sha == e["sha256"], "hash differs for #{e["file"]}"
    end
  end
end
