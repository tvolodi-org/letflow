defmodule Letflow.PwaWebHostingTest do
  @moduledoc """
  T-1502 (PWA M5, D-112): the web build scripts, the CD workflow, the nginx example and the runbook.
  Scripts run for real in tmp_dir fixtures; a stub `flutter` replaces the 77 s build.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @build Path.join(@root, "scripts/pwa_web_build.sh")
  @verify Path.join(@root, "scripts/pwa_web_verify.sh")
  @package Path.join(@root, "scripts/pwa_web_package.sh")
  @workflow Path.join(@root, ".github/workflows/cd-pwa-web.yml")
  @nginx Path.join(@root, "deploy/nginx/letflow-pwa-web.conf.example")
  @runbook Path.join(@root, "docs/runbooks/mobile-web-pwa-hosting.md")

  @brotli System.find_executable("brotli")

  defp sh(script, args, env \\ []) do
    System.cmd("bash", [script | args],
      env: Enum.map(env, fn {k, v} -> {to_string(k), v} end),
      stderr_to_stdout: true
    )
  end

  defp put(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp good_build(dir) do
    put(dir, "index.html", ~s(<base href="/"><script src="flutter_bootstrap.js"></script>))

    put(
      dir,
      "flutter_bootstrap.js",
      ~s|var c={"useLocalCanvasKit":true};\nfontFallbackBaseUrl: new URL('fonts-fallback/', document.baseURI).href|
    )

    put(dir, "main.dart.js", String.duplicate("var a=1;\n", 500))
    put(dir, "manifest.json", ~s({"name":"Letflow","start_url":"."}))
    put(dir, "canvaskit/canvaskit.wasm", String.duplicate("wasm", 2000))
    put(dir, "zxing/zxing-reader.iife.js", "x")
    put(dir, "zxing/zxing_reader.wasm", "x")
    put(dir, "zxing/zxing-config.js", "ZXingWASM.setZXingModuleOverrides({});")

    put(
      dir,
      "assets/FontManifest.json",
      ~s([{"family":"Roboto","fonts":[{"weight":400,"asset":"assets/fonts/Roboto-Regular.ttf"}]}])
    )

    put(dir, "assets/assets/fonts/Roboto-Regular.ttf", "ttf")
    dir
  end

  defp tmp(ctx, name), do: Path.join(ctx.tmp_dir, name)

  describe "W: workflow" do
    test "W1 builds on main and uploads the artifact" do
      wf = YamlElixir.read_from_file!(@workflow)
      # YAML 1.1 parsers may read the key `on` as true
      on = wf["on"] || wf[true]
      assert on["push"]["branches"] == ["main"]

      assert Enum.any?(
               on["push"]["paths"],
               &String.starts_with?(&1, Enum.join(["apps", "mobile"], "/"))
             )

      assert Map.has_key?(on, "workflow_dispatch")

      job = wf["jobs"]["build"]
      assert is_integer(job["timeout-minutes"])
      assert job["permissions"] == %{"contents" => "read"}
      assert Enum.any?(job["steps"], &(&1["run"] == "bash scripts/pwa_web_build.sh"))

      up = Enum.find(job["steps"], &(&1["uses"] == "actions/upload-artifact@v4"))
      assert up["with"]["if-no-files-found"] == "error"
      assert up["with"]["name"] == "letflow-pwa-web"
    end

    test "W2 no secrets and no expression inside a run block" do
      text = File.read!(@workflow)
      refute text =~ "secrets."
      wf = YamlElixir.read_from_file!(@workflow)

      for step <- wf["jobs"]["build"]["steps"], run = step["run"] do
        refute run =~ "${{"
      end
    end
  end

  describe "B: build script inputs" do
    test "B1 http API URL is refused", ctx do
      {out, code} = sh(@build, [], PWA_API_BASE_URL: "http://x.example", PWA_OUT: tmp(ctx, "o"))
      assert code == 2
      assert out =~ "PWA_API_BASE_URL"
    end

    test "B2 unset API URL is refused" do
      {out, code} = sh(@build, [], PWA_API_BASE_URL: "")
      assert code == 2
      assert out =~ "PWA_API_BASE_URL"
    end

    test "B3 base href without slashes is refused" do
      {out, code} = sh(@build, [], PWA_API_BASE_URL: "https://a.example", PWA_BASE_HREF: "web")
      assert code == 2
      assert out =~ "PWA_BASE_HREF"
    end

    test "B4 a valid build passes the right flutter flags", ctx do
      bin = tmp(ctx, "bin")
      args = tmp(ctx, "args.txt")
      File.mkdir_p!(bin)
      fixture = tmp(ctx, "fixture")
      good_build(fixture)

      File.write!(Path.join(bin, "flutter"), """
      #!/usr/bin/env bash
      echo "$@" >> #{args}
      if [ "$1" = "build" ]; then rm -rf build/web; mkdir -p build; cp -r #{fixture} build/web; fi
      """)

      File.chmod!(Path.join(bin, "flutter"), 0o755)
      path = bin <> ":" <> System.get_env("PATH")
      out_dir = tmp(ctx, "out")

      {out, code} =
        sh(@build, [],
          PATH: path,
          PWA_API_BASE_URL: "https://api.example/",
          PWA_OUT: out_dir,
          GITHUB_SHA: String.duplicate("ab", 20)
        )

      on_exit(fn -> File.rm_rf(Path.join([@root, "apps", "mobile", "build", "web"])) end)
      assert code == 0, out
      recorded = File.read!(args)
      assert recorded =~ "--no-web-resources-cdn"
      assert recorded =~ "--release"
      assert recorded =~ "--base-href /"
      assert recorded =~ "--dart-define=LETFLOW_API_BASE_URL=https://api.example/"
      assert File.exists?(Path.join(out_dir, "letflow-pwa-web-abababababab.tar"))
    end
  end

  describe "V: verify script" do
    test "V1/V10 a good build passes", ctx do
      dir = good_build(tmp(ctx, "b"))
      assert {_, 0} = sh(@verify, [dir])
    end

    test "V2 bootstrap without useLocalCanvasKit fails", ctx do
      dir = good_build(tmp(ctx, "b"))
      put(dir, "flutter_bootstrap.js", "fontFallbackBaseUrl: 'x/'")
      assert {out, 1} = sh(@verify, [dir])
      assert out =~ "pwa-verify:"
    end

    test "V3 missing canvaskit.wasm fails", ctx do
      dir = good_build(tmp(ctx, "b"))
      File.rm!(Path.join(dir, "canvaskit/canvaskit.wasm"))
      assert {out, 1} = sh(@verify, [dir])
      assert out =~ "canvaskit/canvaskit.wasm"
    end

    test "V4 a CDN script in index.html fails", ctx do
      dir = good_build(tmp(ctx, "b"))
      put(dir, "index.html", ~s(<script src="https://cdn.jsdelivr.net/x.js"></script>))
      assert {out, 1} = sh(@verify, [dir])
      assert out =~ "index.html"
    end

    test "V5 missing zxing wasm fails", ctx do
      dir = good_build(tmp(ctx, "b"))
      File.rm!(Path.join(dir, "zxing/zxing_reader.wasm"))
      assert {_, 1} = sh(@verify, [dir])
    end

    test "V6 gstatic in main.dart.js alone is not a failure", ctx do
      dir = good_build(tmp(ctx, "b"))
      put(dir, "main.dart.js", ~s(x="https://fonts.gstatic.com/s/"))
      assert {_, 0} = sh(@verify, [dir])
    end

    test "V7 bootstrap without fontFallbackBaseUrl fails", ctx do
      dir = good_build(tmp(ctx, "b"))
      put(dir, "flutter_bootstrap.js", ~s({"useLocalCanvasKit":true}))
      assert {out, 1} = sh(@verify, [dir])
      assert out =~ "fontFallbackBaseUrl"
    end

    test "V8 an absolute font base URL fails", ctx do
      dir = good_build(tmp(ctx, "b"))

      put(
        dir,
        "flutter_bootstrap.js",
        ~s({"useLocalCanvasKit":true} fontFallbackBaseUrl: "https://fonts.gstatic.com/s/")
      )

      assert {_, 1} = sh(@verify, [dir])
    end

    test "V9 FontManifest without Roboto or with a missing ttf fails", ctx do
      dir = good_build(tmp(ctx, "b"))
      put(dir, "assets/FontManifest.json", ~s([{"family":"MaterialIcons","fonts":[]}]))
      assert {out, 1} = sh(@verify, [dir])
      assert out =~ "Roboto"

      dir2 = good_build(tmp(ctx, "c"))
      File.rm!(Path.join(dir2, "assets/assets/fonts/Roboto-Regular.ttf"))
      assert {out2, 1} = sh(@verify, [dir2])
      assert out2 =~ "Roboto-Regular.ttf"
    end
  end

  describe "P: package script" do
    defp package(ctx, env \\ []) do
      dir = good_build(tmp(ctx, "b"))
      put(dir, "tiny.txt", "a")
      File.write!(Path.join(dir, "pic.png"), :crypto.strong_rand_bytes(300))
      out = tmp(ctx, "out")
      sha = String.duplicate("0123456789abcdef", 2) <> "01234567"

      {o, code} =
        sh(@package, [dir, out], [
          {"GITHUB_SHA", sha},
          {"PWA_API_BASE_URL", "https://a.example"} | env
        ])

      {dir, out, sha, o, code}
    end

    test "P1 gzip only where smaller and round-trips", ctx do
      {dir, _out, _sha, o, code} = package(ctx)
      assert code == 0, o
      assert File.exists?(Path.join(dir, "main.dart.js.gz"))
      assert File.exists?(Path.join(dir, "canvaskit/canvaskit.wasm.gz"))
      refute File.exists?(Path.join(dir, "pic.png.gz"))
      refute File.exists?(Path.join(dir, "tiny.txt.gz"))
      {plain, 0} = System.cmd("gunzip", ["-c", Path.join(dir, "main.dart.js.gz")])
      assert plain == File.read!(Path.join(dir, "main.dart.js"))
    end

    @tag skip: if(@brotli, do: false, else: "brotli not installed")
    test "P2 brotli files decode to the original", ctx do
      {dir, _out, _sha, _o, 0} = package(ctx)
      br = Path.join(dir, "main.dart.js.br")
      assert File.exists?(br)
      {plain, 0} = System.cmd("brotli", ["-d", "-c", br])
      assert plain == File.read!(Path.join(dir, "main.dart.js"))
    end

    test "P3 PWA_REQUIRE_BROTLI fails when brotli is missing", ctx do
      bin = tmp(ctx, "tools")
      File.mkdir_p!(bin)

      for t <- ~w(bash dirname git) do
        if p = System.find_executable(t), do: File.ln_s!(p, Path.join(bin, t))
      end

      dir = good_build(tmp(ctx, "b"))

      {o, code} =
        System.cmd("/bin/bash", [@package, dir, tmp(ctx, "out")],
          env: [{"PATH", bin}, {"PWA_REQUIRE_BROTLI", "1"}],
          stderr_to_stdout: true
        )

      assert code == 1
      assert o =~ "brotli"
    end

    test "P4 build-info.json records sha, base href and API", ctx do
      {dir, _out, sha, _o, 0} = package(ctx, [{"PWA_BASE_HREF", "/web/"}])
      info = dir |> Path.join("build-info.json") |> File.read!() |> Jason.decode!()
      assert info["sha"] == sha
      assert info["base_href"] == "/web/"
      assert info["api_base_url"] == "https://a.example"
      assert is_binary(info["built_at"])
    end

    test "P5 SHA256SUMS lists plain files only and verifies", ctx do
      {dir, _out, _sha, _o, 0} = package(ctx)
      sums = File.read!(Path.join(dir, "SHA256SUMS"))
      refute sums =~ ".gz"
      refute sums =~ ".br"
      assert sums =~ "  main.dart.js\n"
      assert length(String.split(sums, "main.dart.js")) == 2

      assert {_, 0} =
               System.cmd("sha256sum", ["-c", "SHA256SUMS"], cd: dir, stderr_to_stdout: true)
    end

    test "P6 the tar is named after the sha and holds build-info.json", ctx do
      {_dir, out, sha, _o, 0} = package(ctx)
      tar = Path.join(out, "letflow-pwa-web-#{String.slice(sha, 0, 12)}.tar")
      assert File.exists?(tar)
      {list, 0} = System.cmd("tar", ["-tf", tar])
      assert list =~ "build-info.json"
      assert File.exists?(Path.join(out, "SHA256SUMS"))
    end
  end

  describe "N: nginx example and runbook" do
    test "N1 nginx example carries the header rules" do
      conf = File.read!(@nginx)
      assert conf =~ "location /fonts-fallback/"
      assert conf =~ "return 404"
      assert conf =~ "gzip_static on"
      assert conf =~ "application/wasm"
      assert conf =~ ~s(Cache-Control "no-cache" always)
      assert conf =~ "camera=(self)"
      assert conf =~ "try_files"
      refute conf =~ "immutable"
      refute conf =~ "max-age"
    end

    test "N3 no types block replaces the MIME map; runbook checks index content-type" do
      conf = File.read!(@nginx)
      code = conf |> String.split(~r/\R/) |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      refute Enum.any?(code, &(&1 =~ ~r/^\s*types\s*\{/))

      book = File.read!(@runbook)
      assert book =~ "content-type: text/html"
      assert book =~ "do NOT add a `types"
    end

    test "N2 runbook names the headers and every variable the workflow reads" do
      book = File.read!(@runbook)
      text = File.read!(@workflow)
      vars = Regex.scan(~r/vars\.([A-Z_]+)/, text) |> Enum.map(&List.last/1) |> Enum.uniq()
      assert vars != []
      for v <- vars, do: assert(book =~ v)

      for h <- [
            "Cache-Control",
            "Permissions-Policy",
            "application/wasm",
            "ETag",
            "/fonts-fallback/"
          ],
          do: assert(book =~ h)
    end
  end
end
