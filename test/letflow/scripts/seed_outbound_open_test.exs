defmodule Letflow.Scripts.SeedOutboundOpenTest do
  @moduledoc """
  T-2724 (SF-08, INV-4): the seed helper that opens the outbound allow-list for demo tenants
  never prints a credential carried in the service base URL, plain or percent-encoded, and
  sends only the bare hostname.
  """
  use ExUnit.Case, async: true

  @helper Path.expand("../../../scripts/lib/seed_outbound_open.sh", __DIR__)

  defp run(url) do
    dir = Path.join(System.tmp_dir!(), "soo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    log = Path.join(dir, "bodies")

    File.write!(
      Path.join(dir, "curl"),
      "#!/usr/bin/env bash\ncat >> \"#{log}\"\necho >> \"#{log}\"\nexit 22\n"
    )

    File.chmod!(Path.join(dir, "curl"), 0o755)

    {out, _} =
      System.cmd(
        "bash",
        ["-c", "source \"$HELPER\"; seed_open_outbound_http"],
        env: [
          {"HELPER", @helper},
          {"PATH", dir <> ":" <> System.get_env("PATH")},
          {"AUTH_HEADER", "Authorization: Bearer x"},
          {"QA_URL", "http://qa.invalid"},
          {"SERVICE_TASK_EFFECTIVE_BASE_URL", url}
        ],
        stderr_to_stdout: true
      )

    {out, if(File.exists?(log), do: File.read!(log), else: "")}
  end

  test "H1 userinfo canaries never reach warnings or the request body" do
    for url <- [
          "https://SECRET_CANARY_T2724@httpbin.org/anything",
          "https://user:SECRET_CANARY_T2724@httpbin.org:8443/x?k=1",
          "https://SECRET%5FCANARY%2DT2724@httpbin.org/anything"
        ] do
      {out, bodies} = run(url)
      refute out =~ "CANARY"
      refute out =~ "CANARY" |> String.downcase()
      refute out =~ "%5F"
      refute bodies =~ "CANARY"
      refute bodies =~ "%5F"
      assert bodies =~ ~s("destination":"httpbin.org")
      assert out =~ "WARNING"
    end
  end

  test "H2 a non-hostname authority is refused with fixed text" do
    {out, bodies} = run("https://SECRET_CANARY_T2724@ev il;rm/x")
    assert bodies == ""
    assert out =~ "not a plain hostname"
    refute out =~ "CANARY"
  end
end
