defmodule Letflow.AndroidReleaseBuildTest do
  @moduledoc """
  REQ-868 (G16 part 2): scripts/android_release_build.sh runs for real in tmp_dir fixtures with a fake
  `flutter` and a fake `apksigner` first on PATH. The release signing config and the runbook are text checks.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/android_release_build.sh")
  @gradle Path.join(@root, "apps/mobile/android/app/build.gradle.kts")
  @runbook Path.join(@root, "docs/runbooks/mobile-android-release.md")
  @secret "S3cr3t-pass-9f2c"

  defp setup_env(ctx, opts \\ []) do
    dir = ctx.tmp_dir
    mobile = Path.join(dir, "mobile")
    bin = Path.join(dir, "bin")
    repo = Path.join(dir, "repo")
    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(mobile, "android"))
    File.mkdir_p!(bin)
    File.mkdir_p!(repo)
    File.write!(Path.join(mobile, "pubspec.yaml"), "name: letflow\nversion: 1.2.3+7\n")

    unless opts[:no_key] do
      File.write!(
        Path.join(mobile, "android/key.properties"),
        "storeFile=/x/k.jks\nstorePassword=#{@secret}\nkeyAlias=up\nkeyPassword=#{@secret}2\n"
      )
    end

    calls = Path.join(dir, "flutter.calls")

    flutter = Path.join(bin, "flutter")

    File.write!(flutter, """
    #!/usr/bin/env bash
    echo "$@" >> "#{calls}"
    if [ "$2" = "apk" ]; then
      mkdir -p build/app/outputs/flutter-apk && echo apkbytes > build/app/outputs/flutter-apk/app-release.apk
    else
      mkdir -p build/app/outputs/bundle/release && echo aabbytes > build/app/outputs/bundle/release/app-release.aab
    fi
    """)

    signer = Path.join(bin, "apksigner")
    subject = opts[:subject] || "CN=Letflow Upload, O=Test"

    File.write!(signer, """
    #!/usr/bin/env bash
    echo "Signer #1 certificate DN: #{subject}"
    """)

    File.chmod!(flutter, 0o755)
    File.chmod!(signer, 0o755)
    %{mobile: mobile, bin: bin, repo: repo, out: out, calls: calls}
  end

  defp run(env, args) do
    System.cmd("bash", [@script | args],
      env: [
        {"PATH", env.bin <> ":" <> System.get_env("PATH")},
        {"ANDROID_RELEASE_MOBILE_DIR", env.mobile},
        {"ANDROID_RELEASE_REPO_ROOT", env.repo}
      ],
      stderr_to_stdout: true
    )
  end

  defp good_args(env, extra \\ []) do
    [
      "--out",
      env.out,
      "--base-url",
      "https://dl.example.org/android/",
      "--api-base-url",
      "https://api.example.org",
      "--platform-host",
      "qa.example.org"
    ] ++ extra
  end

  defp called?(env), do: File.exists?(env.calls)

  test "1 missing key.properties exits 2, names it, flutter not called", ctx do
    env = setup_env(ctx, no_key: true)
    {out, code} = run(env, good_args(env, ["--first-release"]))
    assert code == 2
    assert out =~ "key.properties"
    refute called?(env)
  end

  test "2a equal version code exits 2 without flutter", ctx do
    env = setup_env(ctx)
    File.mkdir_p!(env.out)
    File.write!(Path.join(env.out, "latest.json"), ~s({"versionCode":7,"minVersionCode":2}))
    {out, code} = run(env, good_args(env))
    assert code == 2
    assert out =~ "not higher"
    refute called?(env)
  end

  test "2b no latest.json and no flag exits 2", ctx do
    env = setup_env(ctx)
    {_out, code} = run(env, good_args(env))
    assert code == 2
    refute called?(env)
  end

  test "2c http urls exit 2", ctx do
    env = setup_env(ctx)
    args = good_args(env, ["--first-release"])
    {_o, c1} = run(env, List.replace_at(args, 3, "http://dl.example.org/"))
    {_o, c2} = run(env, List.replace_at(args, 5, "http://api.example.org"))
    assert {c1, c2} == {2, 2}
    refute called?(env)
  end

  test "2d --out inside the repository exits 2", ctx do
    env = setup_env(ctx)
    inside = Path.join(env.repo, "out")
    args = good_args(env, ["--first-release"]) |> List.replace_at(1, inside)
    {_o, code} = run(env, args)
    assert code == 2
    refute called?(env)
  end

  test "3 good run builds apk and aab with defines and writes the outputs", ctx do
    env = setup_env(ctx)
    notes = Path.join(ctx.tmp_dir, "notes.txt")
    File.write!(notes, "ru: Новая версия\nkk: Жаңа нұсқа\nen: New version\n")
    {out, code} = run(env, good_args(env, ["--first-release", "--notes-file", notes]))
    assert code == 0, out

    calls = File.read!(env.calls) |> String.split("\n", trim: true)
    apk = Enum.find(calls, &String.starts_with?(&1, "build apk --release"))
    aab = Enum.find(calls, &String.starts_with?(&1, "build appbundle --release"))

    for c <- [apk, aab] do
      assert c =~ "--dart-define=LETFLOW_API_BASE_URL=https://api.example.org"
      assert c =~ "--dart-define=LETFLOW_PLATFORM_HOST=qa.example.org"
    end

    apk_path = Path.join(env.out, "letflow-1.2.3-7.apk")
    assert File.exists?(apk_path)
    assert File.exists?(Path.join(env.out, "letflow-1.2.3-7.aab"))

    sha =
      apk_path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    assert File.read!(apk_path <> ".sha256") |> String.trim() == sha

    json = env.out |> Path.join("latest.json") |> File.read!() |> Jason.decode!()

    assert json |> Map.keys() |> Enum.sort() ==
             ~w(minVersionCode notes published sha256 url versionCode versionName)

    assert json["notes"] |> Map.keys() |> Enum.sort() == ~w(en kk ru)
    assert json["url"] == "https://dl.example.org/android/letflow-1.2.3-7.apk"
    assert json["sha256"] == sha
    assert json["versionCode"] == 7
    assert json["minVersionCode"] == 1
    assert json["notes"]["kk"] == "Жаңа нұсқа"
    refute out =~ @secret
  end

  test "4a a debug-signed APK exits 1 and writes no latest.json", ctx do
    env = setup_env(ctx, subject: "CN=Android Debug, O=Android, C=US")
    {out, code} = run(env, good_args(env, ["--first-release"]))
    assert code == 1
    assert out =~ "debug certificate"
    refute File.exists?(Path.join(env.out, "latest.json"))
    refute out =~ @secret
  end

  test "4b dry-run builds nothing and prints no password", ctx do
    env = setup_env(ctx)
    {out, code} = run(env, good_args(env, ["--first-release", "--dry-run"]))
    assert code == 0
    assert out =~ "dry-run"
    refute called?(env)
    refute out =~ @secret
  end

  test "7 --name-prefix names the files and the latest.json url; default stays letflow", ctx do
    env = setup_env(ctx)
    {out, code} = run(env, good_args(env, ["--first-release", "--name-prefix", "qoimeks-qa"]))
    assert code == 0, out
    assert File.exists?(Path.join(env.out, "qoimeks-qa-1.2.3-7.apk"))
    assert File.exists?(Path.join(env.out, "qoimeks-qa-1.2.3-7.apk.sha256"))
    assert File.exists?(Path.join(env.out, "qoimeks-qa-1.2.3-7.aab"))
    refute File.exists?(Path.join(env.out, "letflow-1.2.3-7.apk"))
    json = env.out |> Path.join("latest.json") |> File.read!() |> Jason.decode!()
    assert json["url"] == "https://dl.example.org/android/qoimeks-qa-1.2.3-7.apk"
  end

  test "7b a bad --name-prefix exits 2 without flutter", ctx do
    env = setup_env(ctx)

    for bad <- ["", "a/b", "../x", "-x", "a b"] do
      {_o, code} = run(env, good_args(env, ["--first-release", "--name-prefix", bad]))
      assert code == 2, "prefix #{inspect(bad)}"
    end

    refute called?(env)
  end

  test "8 --key-properties is used for the build, then removed; default key restored", ctx do
    env = setup_env(ctx, no_key: true)
    custom = Path.join(ctx.tmp_dir, "qa-key.properties")
    key_path = Path.join(env.mobile, "android/key.properties")

    File.write!(
      custom,
      "storeFile=/x/q.jks\nstorePassword=#{@secret}\nkeyAlias=qa\nkeyPassword=#{@secret}2\n"
    )

    # the fake flutter records whether the key sat at the build path during the build
    flutter = Path.join(env.bin, "flutter")

    File.write!(
      flutter,
      File.read!(flutter) <>
        "grep -q 'keyAlias=qa' android/key.properties && echo KEYSEEN >> \"#{env.calls}\"\n"
    )

    {out, code} = run(env, good_args(env, ["--first-release", "--key-properties", custom]))
    assert code == 0, out
    assert File.read!(env.calls) =~ "KEYSEEN"
    refute File.exists?(key_path)
    refute out =~ @secret

    # an existing default key is put back afterwards
    File.write!(key_path, "storeFile=/d\nstorePassword=d\nkeyAlias=dflt\nkeyPassword=d\n")
    File.rm!(Path.join(env.out, "latest.json"))
    {out, code} = run(env, good_args(env, ["--first-release", "--key-properties", custom]))
    assert code == 0, out
    assert File.read!(key_path) =~ "keyAlias=dflt"
  end

  test "8b a --key-properties file that is missing or incomplete exits 2", ctx do
    env = setup_env(ctx)
    bad = Path.join(ctx.tmp_dir, "bad.properties")
    File.write!(bad, "storeFile=/x\n")
    {o1, c1} = run(env, good_args(env, ["--first-release", "--key-properties", bad]))
    {_o, c2} = run(env, good_args(env, ["--first-release", "--key-properties", bad <> ".none"]))
    assert {c1, c2} == {2, 2}
    refute o1 =~ "/x"
    refute called?(env)
  end

  test "5 gradle release signing reads key.properties and has no debug key" do
    gradle = File.read!(@gradle)
    assert gradle =~ "key.properties"
    [_, release_block] = String.split(gradle, "buildTypes {", parts: 2)
    refute release_block =~ ~S|getByName("debug")|
    refute gradle =~ ~S|signingConfigs.getByName("debug")|
  end

  test "6 runbook names the required items" do
    text = File.read!(@runbook)

    for needle <- [
          "keytool",
          "key.properties",
          "scripts/android_release_build.sh",
          "latest.json",
          "the store account is the owner's decision"
        ] do
      assert text =~ needle, "runbook lacks #{needle}"
    end
  end
end
