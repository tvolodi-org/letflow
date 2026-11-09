defmodule Letflow.PwaClientKitTest do
  @moduledoc """
  T-1503 (PWA M6, D-112): client test kit (scripts in ru/kk/en, result template), the render script and the
  "ready for clients" check. Scripts run for real; `curl` and `flutter` are stubs on PATH.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @kit Path.join(@root, "docs/runbooks/pwa-client-test")
  @render Path.join(@root, "scripts/pwa_client_kit_render.sh")
  @check Path.join(@root, "scripts/pwa_ready_check.sh")
  @runbook Path.join(@root, "docs/runbooks/mobile-web-pwa-ready-check.md")
  @langs ~w(en ru kk)
  @attest "login,scan,voice,offline,sync"

  defp script(l), do: File.read!(Path.join(@kit, "script.#{l}.md"))

  defp sh(script, args, env \\ []) do
    System.cmd("bash", [script | args],
      env: Enum.map(env, fn {k, v} -> {to_string(k), v} end),
      stderr_to_stdout: true
    )
  end

  defp numbered(text), do: Regex.scan(~r/^\d+\. /m, text) |> length()

  test "K1 three scripts, one page, seven steps" do
    for l <- @langs do
      t = script(l)
      assert length(String.split(t, "\n")) <= 45
      assert numbered(t) == 7
    end
  end

  test "K2 only the two placeholders" do
    for l <- @langs do
      t = script(l)
      assert t =~ "@@LINK@@" and t =~ "@@OWNER_EMAIL@@"

      assert t |> String.replace(["@@LINK@@", "@@OWNER_EMAIL@@"], "") |> String.contains?("@@") ==
               false
    end
  end

  test "K3 each language is written in its own script" do
    assert script("en") =~ ~r/\A[\x00-\x7F]*\z/
    assert script("ru") =~ ~r/[а-я]/u
    assert script("kk") =~ ~r/[әқңөұү]/u
  end

  test "K4 step 3 names three codes" do
    for l <- @langs do
      step3 = script(l) |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "3. "))
      assert step3 =~ "3"
    end
  end

  test "K5 render fills link and address", %{tmp_dir: d} do
    out = Path.join(d, "kit")

    {o, 0} =
      sh(@render, ["--link", "https://x.example/app/", "--email", "own@example.kz", "--out", out])

    assert o =~ "wrote 3"

    for l <- @langs do
      t = File.read!(Path.join(out, "script.#{l}.md"))
      refute t =~ "@@"
      assert t =~ "https://x.example/app/"
      assert t =~ "mailto:own@example.kz?subject="
    end
  end

  test "K6 render refuses bad input and writes nothing", %{tmp_dir: d} do
    out = Path.join(d, "kit")
    ok = ["--email", "own@example.kz", "--out", out]
    assert {_, 2} = sh(@render, ["--link", "http://x.example/" | ok])
    assert {_, 2} = sh(@render, ["--link", "https://x y/" | ok])

    assert {_, 2} =
             sh(@render, ["--link", "https://x.example/", "--email", "a b@c.kz", "--out", out])

    assert {_, 2} =
             sh(@render, ["--link", "https://x.example/", "--email", "a&b@c.kz", "--out", out])

    refute File.exists?(out)
    File.mkdir_p!(out)
    File.write!(Path.join(out, "keep"), "x")
    assert {_, 2} = sh(@render, ["--link", "https://x.example/" | ok])
  end

  test "K7 a link with & survives", %{tmp_dir: d} do
    out = Path.join(d, "kit")

    {_, 0} =
      sh(@render, [
        "--link",
        "https://x.example/?a=1&b=2",
        "--email",
        "own@example.kz",
        "--out",
        out
      ])

    assert File.read!(Path.join(out, "script.en.md")) =~ "https://x.example/?a=1&b=2"
  end

  test "K8 result template has seven step rows and device fields" do
    t = File.read!(Path.join(@kit, "result-template.md"))
    assert Regex.scan(~r/^\| [1-7] \|/m, t) |> length() == 7
    assert t =~ "iPhone model" and t =~ "iOS version"
  end

  # --- ready check, with a stub curl driven by env vars ---

  defp stub(d) do
    bin = Path.join(d, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    echo "$*" >> "${CURL_LOG:-/dev/null}"
    hdr=""; out=""; url=""
    while [ $# -gt 0 ]; do
      case "$1" in -D) hdr="$2"; shift 2 ;; -o) out="$2"; shift 2 ;; -w|--max-time|--retry) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
    done
    path="${url#https://h.example/}"
    code=200; ctype="text/html"; body="x"; pp="Permissions-Policy: camera=(self), microphone=(self)"
    case "$path" in
      "") body='<script src="flutter_bootstrap.js"></script>'; [ -n "${ROOT_CODE:-}" ] && code=$ROOT_CODE; [ -n "${NO_PP:-}" ] && pp="" ;;
      manifest.json) body='{"name":"L","start_url":".","icons":[]}' ;;
      build-info.json) body='{"sha":"abc","api_base_url":"https://api.example"}' ;;
      *.wasm) ctype="${WASM_TYPE:-application/wasm}" ;;
      fonts-fallback/*) code="${FONTS_CODE:-404}" ;;
    esac
    printf 'HTTP/1.1 %s\\r\\ncontent-type: %s\\r\\n%s\\r\\n\\r\\n' "$code" "$ctype" "$pp" > "$hdr"
    printf '%s' "$body" > "$out"
    printf '%s' "$code"
    """)

    File.write!(Path.join(bin, "flutter"), "#!/usr/bin/env bash\nexit ${FLUTTER_EXIT:-0}\n")
    File.chmod!(Path.join(bin, "curl"), 0o755)
    File.chmod!(Path.join(bin, "flutter"), 0o755)
    bin
  end

  defp check(d, args, env \\ []) do
    bin = stub(d)
    log = Path.join(d, "curl.log")
    path = bin <> ":" <> System.get_env("PATH")

    {o, c} =
      sh(@check, ["--url", "https://h.example/" | args], [{"PATH", path}, {"CURL_LOG", log} | env])

    {o, c, log}
  end

  @full ["--emulate", "--attest", @attest, "--device", "Pixel 7 Chrome 130", "--operator", "Ann"]

  test "R1 http url exits 2 and probes nothing", %{tmp_dir: d} do
    bin = stub(d)
    log = Path.join(d, "curl.log")

    {_, 2} =
      sh(@check, ["--url", "http://h.example/"], [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"CURL_LOG", log}
      ])

    refute File.exists?(log)
  end

  test "R2 good host passes A1..A8", %{tmp_dir: d} do
    {o, _, _} = check(d, [])

    for n <-
          ~w(A1-https A2-index A3-manifest A4-build-info A5-wasm A6-fonts-404 A7-permissions-policy A8-no-other-host) do
      assert o =~ "PASS #{n}"
    end
  end

  test "R3 each half-broken deploy is RED", %{tmp_dir: d} do
    for {env, name} <- [
          {[WASM_TYPE: "text/plain"], "A5-wasm"},
          {[FONTS_CODE: "200"], "A6-fonts-404"},
          {[NO_PP: "1"], "A7-permissions-policy"},
          {[ROOT_CODE: "301"], "A2-index"}
        ] do
      {o, c, _} = check(d, @full, env)
      assert c == 1, o
      assert o =~ "FAIL #{name}"
      assert o =~ "ready-check: RED"
    end
  end

  test "R4 no attestation is INCOMPLETE", %{tmp_dir: d} do
    {o, c, _} = check(d, ["--emulate"])
    assert c == 3
    assert o =~ "INCOMPLETE" and o =~ "device-attestation"
  end

  test "R5 unknown key, missing key or empty device is INCOMPLETE", %{tmp_dir: d} do
    base = ["--emulate", "--operator", "Ann"]
    {_, c, _} = check(d, base ++ ["--attest", @attest <> ",bogus", "--device", "x"])
    assert c == 3
    {_, c, _} = check(d, base ++ ["--attest", "login,scan", "--device", "x"])
    assert c == 3
    {_, c, _} = check(d, base ++ ["--attest", @attest, "--device", ""])
    assert c == 3
  end

  test "R6 everything given is GREEN with device and operator", %{tmp_dir: d} do
    {o, c, _} = check(d, @full)
    assert c == 0, o
    assert o =~ "device: Pixel 7 Chrome 130" and o =~ "operator: Ann"
    assert o |> String.trim() |> String.split("\n") |> List.last() == "ready-check: GREEN"
  end

  test "R7 failing flutter tests are RED", %{tmp_dir: d} do
    {o, c, _} = check(d, @full, FLUTTER_EXIT: "1")
    assert c == 1
    assert o =~ "FAIL E1-emulation"
  end

  test "R8 no flutter with --emulate is INCOMPLETE", %{tmp_dir: d} do
    bin = stub(d)
    File.rm!(Path.join(bin, "flutter"))
    path = bin <> ":/usr/bin:/bin"

    if Enum.any?(["/usr/bin/flutter", "/bin/flutter"], &File.exists?/1) do
      :ok
    else
      {o, c} = sh(@check, ["--url", "https://h.example/" | @full], [{"PATH", path}])
      assert c == 3, o
      assert o =~ "NOT RUN" and o =~ "emulation-not-run"
    end
  end

  test "R9 broken build dir fails A9", %{tmp_dir: d} do
    empty = Path.join(d, "build")
    File.mkdir_p!(empty)
    {o, c, _} = check(d, ["--build-dir", empty])
    assert c == 1
    assert o =~ "FAIL A9-build-verify"
  end

  test "D1 runbook names devices, emulation tests and the rule" do
    rb = File.read!(@runbook)

    assert rb =~ "real iPhone" and rb =~ "Android phone" and
             rb =~ "use-fake-device-for-media-stream"

    assert rb =~ "only after `scripts/pwa_ready_check.sh` prints `ready-check: GREEN`"

    for [_, p] <- Regex.scan(~r/`(test\/[a-z_\/]+_test\.dart)`/, rb) do
      assert File.exists?(Path.join([@root, "apps", "mobile", p])), p
    end
  end

  test "D2 test list in the check script points at existing files" do
    src = File.read!(@check)
    [_, list] = Regex.run(~r/^tests="([^"]+)"/m, src)
    files = String.split(list)
    assert length(files) == 8
    for p <- files, do: assert(File.exists?(Path.join([@root, "apps", "mobile", p])), p)
  end
end
